-- Which of these codes can the caller still go back to? The app's recent-room
-- list asks this so a room that cleanup has deleted (closed for 30 days) drops
-- off the list instead of failing when tapped.
--
-- Only rooms the caller has been a member of are answered, open or closed.
-- Answering for any open room would turn this into a batch lookup of which
-- codes exist, which join_room deliberately never offers.
create or replace function cotime_book.available_room_codes(p_codes text[])
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  available text[];
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_codes), 0) > 50 then
    raise exception 'At most 50 room codes can be checked at once'
      using errcode = '22023';
  end if;

  select coalesce(array_agg(room.code::text order by room.code), array[]::text[])
  into available
  from cotime_book.rooms as room
  where room.code = any (
      select upper(btrim(requested.code))
      from unnest(coalesce(p_codes, array[]::text[])) as requested(code)
    )
    and exists (
      select 1
      from cotime_book_private.room_participants as participant
      where participant.room_id = room.id
        and participant.user_id = current_user_id
    );

  return available;
end;
$$;

revoke all on function cotime_book.available_room_codes(text[])
  from public, anon, authenticated, service_role;
grant execute on function cotime_book.available_room_codes(text[])
  to authenticated, service_role;

notify pgrst, 'reload schema';
