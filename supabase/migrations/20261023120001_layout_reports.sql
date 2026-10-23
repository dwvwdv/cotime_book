-- Page layout reports sent from the reader (GH-49).
--
-- Cut-off pages and turns that skip ahead have only ever shown up in a real
-- Android WebView. The reader used to put its layout state on the clipboard
-- for the reader to paste into an issue; most never did, and the ones who did
-- sent one device's half of a two-device problem. Reports now go straight to
-- this table. The room id pairs up the reports that readers of the same room
-- sent about the same moment, and outlives the room on purpose: rooms are
-- deleted 30 days after closing, the reports are what the bug is solved from.
--
-- Private schema: the app can only add a report through the function below,
-- and nobody reads them through the Data API. Maintainers read them in the
-- dashboard or SQL editor.

create table if not exists cotime_book_private.layout_reports (
  id uuid primary key default extensions.gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null references auth.users(id) on delete cascade,
  room_id uuid,
  app_version text not null,
  note text,
  report jsonb not null,
  constraint layout_reports_app_version_length
    check (char_length(app_version) between 1 and 40),
  constraint layout_reports_note_length
    check (note is null or char_length(note) <= 2000),
  -- The app's reports are a few KB; the cap is what keeps the table from
  -- being used as free storage.
  constraint layout_reports_report_shape
    check (
      jsonb_typeof(report) = 'object'
      and octet_length(report::text) <= 65536
    )
);

alter table cotime_book_private.layout_reports enable row level security;

create index if not exists layout_reports_user_created_idx
  on cotime_book_private.layout_reports (user_id, created_at desc);
create index if not exists layout_reports_room_created_idx
  on cotime_book_private.layout_reports (room_id, created_at)
  where room_id is not null;

-- Returns the report's id, which the reader can quote in an issue.
--
-- The room is recorded only for a member of it, so nobody can attach reports
-- to someone else's room. Twenty reports an hour per account is far more than
-- a reader chasing one bug sends, and caps what a script can write.
create or replace function cotime_book.submit_layout_report(
  p_room_id uuid,
  p_app_version text,
  p_note text,
  p_report jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  report_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- Serialises one account's reports so the hourly count cannot be raced.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('layout_report:' || current_user_id::text, 0)
  );

  if (
    select count(*)
    from cotime_book_private.layout_reports as report
    where report.user_id = current_user_id
      and report.created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'Too many layout reports, try again later'
      using errcode = '54000';
  end if;

  insert into cotime_book_private.layout_reports (
    user_id,
    room_id,
    app_version,
    note,
    report
  )
  values (
    current_user_id,
    case
      when p_room_id is not null
           and cotime_book_private.is_active_room_member(p_room_id)
        then p_room_id
    end,
    p_app_version,
    nullif(btrim(p_note), ''),
    p_report
  )
  returning id into report_id;

  return report_id;
end;
$$;

revoke all on function cotime_book.submit_layout_report(uuid, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function cotime_book.submit_layout_report(uuid, text, text, jsonb)
  to authenticated;
