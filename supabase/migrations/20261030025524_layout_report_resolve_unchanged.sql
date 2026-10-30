-- resolve_layout_reports() leaves reports that already have the outcome it
-- is given as they are.
--
-- Maintainers mark every report of one bug at once, and run it again when a
-- later report of the same bug comes in. Each run used to stamp the earlier
-- reports with a new resolved_at, and the app tells answers apart by that
-- time: readers who had read the answer were told on Home that they had a
-- new one. An outcome that changes (another status, release or note) is
-- still news and gets a new time.

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
  new_fixed_in text := case when p_status = 'resolved' then p_fixed_in end;
  new_note text := case
    when p_status = 'open' then null
    else nullif(btrim(p_note), '')
  end;
begin
  if p_status not in ('open', 'resolved', 'declined') then
    raise exception 'Unknown report status %', p_status
      using errcode = '22023';
  end if;

  update cotime_book_private.layout_reports as report
  set
    status = p_status,
    resolved_at = case when p_status = 'open' then null else now() end,
    fixed_in = new_fixed_in,
    resolution_note = new_note
  where report.id = any(p_ids)
    and (report.status, report.fixed_in, report.resolution_note)
      is distinct from (p_status, new_fixed_in, new_note);

  get diagnostics changed = row_count;
  return changed;
end;
$$;

revoke all on function cotime_book_private.resolve_layout_reports(uuid[], text, text, text)
  from public, anon, authenticated;
