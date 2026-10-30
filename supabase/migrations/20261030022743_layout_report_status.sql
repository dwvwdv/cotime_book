-- What became of each page layout report, for the reader who sent it.
--
-- A report used to vanish into the table: the reader got an id to quote in an
-- issue and never heard back. The home screen now lists the account's own
-- reports with where each stands, so the reader learns that the page they
-- reported was fixed — and, since the fix only reaches them in a new release,
-- in which version (`fixed_in`): the app tells a reader still on an older one
-- to update instead of calling the report solved while the bug is still on
-- their screen.
--
-- Maintainers set the outcome with resolve_layout_reports(), from the SQL
-- editor or the service role. The app only reads its own rows, and only the
-- columns below: never the report itself, which is what the bug is solved
-- from and none of the reader's business to scroll through.

alter table cotime_book_private.layout_reports
  add column status text not null default 'open',
  add column resolved_at timestamptz,
  -- The release with the fix, as major.minor.patch (pubspec's version
  -- without the build number).
  add column fixed_in text,
  -- Shown to the reader as written: one note in both languages, since the
  -- reader's interface may be either.
  add column resolution_note text,
  add constraint layout_reports_status
    check (status in ('open', 'resolved', 'declined')),
  add constraint layout_reports_resolved_at
    check ((status = 'open') = (resolved_at is null)),
  add constraint layout_reports_fixed_in
    check (
      fixed_in is null
      or (status = 'resolved' and fixed_in ~ '^[0-9]+\.[0-9]+\.[0-9]+$')
    ),
  add constraint layout_reports_resolution_note_length
    check (resolution_note is null or char_length(resolution_note) <= 2000);

-- The account's reports, newest first. Fifty is more than anyone chasing a
-- bug sends, and keeps the list a list.
create or replace function cotime_book.my_layout_reports()
returns table (
  id uuid,
  created_at timestamptz,
  book_title text,
  note text,
  status text,
  resolved_at timestamptz,
  fixed_in text,
  resolution_note text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  return query
  select
    report.id,
    report.created_at,
    left(report.report -> 'book' ->> 'title', 200),
    report.note,
    report.status,
    report.resolved_at,
    report.fixed_in,
    report.resolution_note
  from cotime_book_private.layout_reports as report
  where report.user_id = current_user_id
  order by report.created_at desc
  limit 50;
end;
$$;

revoke all on function cotime_book.my_layout_reports()
  from public, anon, authenticated;
grant execute on function cotime_book.my_layout_reports()
  to authenticated;

-- Sets the outcome of [p_ids] at once: one bug usually comes in as several
-- reports (two readers of a room, the same reader twice). 'open' puts them
-- back as they were, for a report closed by mistake. Returns how many rows it
-- changed. Maintainers only: not callable from the app.
create or replace function cotime_book_private.resolve_layout_reports(
  p_ids uuid[],
  p_status text,
  p_fixed_in text default null,
  p_note text default null
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  changed integer;
begin
  if p_status not in ('open', 'resolved', 'declined') then
    raise exception 'Unknown report status %', p_status
      using errcode = '22023';
  end if;

  update cotime_book_private.layout_reports as report
  set
    status = p_status,
    resolved_at = case when p_status = 'open' then null else now() end,
    fixed_in = case when p_status = 'resolved' then p_fixed_in end,
    resolution_note = case
      when p_status = 'open' then null
      else nullif(btrim(p_note), '')
    end
  where report.id = any(p_ids);

  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function cotime_book_private.resolve_layout_reports(uuid[], text, text, text)
  from public, anon, authenticated;
