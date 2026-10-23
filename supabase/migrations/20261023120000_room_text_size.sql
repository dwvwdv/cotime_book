-- The room's text size belongs to the host unless the host hands it over.
--
-- Every reader lays the book out at the largest text size anyone in the room
-- asked for (issue #20), so any one member turning the type up re-laid the
-- book out for everyone, and a re-layout takes a few seconds on an e-reader.
-- The room now keeps who decides: while text_size_locked is set (the default,
-- also for rooms that existed before this column), every reader asks for
-- text_size, which only the host can change. The host can unlock it, and
-- then each reader asks for their own size again, as before.
--
-- The layout itself is still computed the same way from everyone's published
-- page fit, so readers on an older app (which ignore the lock and ask for
-- their own size) still read the same pages as everyone else; they only push
-- the size up past the host's.

alter table cotime_book.rooms
  add column if not exists text_size_locked boolean not null default true,
  add column if not exists text_size smallint;

-- ReadingPreferences.minFontSize / maxFontSize in
-- lib/providers/reading_preferences_provider.dart. Null until the host first
-- opens the book with the lock on; readers fall back to the default size.
alter table cotime_book.rooms
  add constraint rooms_text_size_range
    check (text_size is null or text_size between 12 and 32);

-- A text size change is a change to the room's reading state: it bumps the
-- revision, so a re-read of the room is applied over the copy a member
-- already has (RoomNotifier._applyRoomUpdate keeps only newer revisions).
create or replace trigger touch_room_reading_state_before_update
before update of
  current_book_title,
  current_book_hash,
  current_book_library_path,
  current_cfi,
  text_size_locked,
  text_size
on cotime_book.rooms
for each row execute function cotime_book_private.touch_room_reading_state();

-- Host only, so not a column grant: the "Members can update room reading
-- state" policy lets every member update the granted columns.
--
-- p_text_size null keeps the size the room has. A caller who is no longer in
-- the room gets the same 42501 as heartbeat_room, which the app reads as "the
-- membership is gone"; a member who is not the host (the host changed while
-- the settings were open) gets P0001 and stays in the room.
create or replace function cotime_book.set_room_text_size(
  p_room_id uuid,
  p_locked boolean,
  p_text_size integer default null
)
returns cotime_book.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_room cotime_book.rooms;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_locked is null then
    raise exception 'p_locked is required' using errcode = '22004';
  end if;

  select room.*
  into target_room
  from cotime_book.rooms as room
  where room.id = p_room_id
  for update;

  if target_room.id is null
     or target_room.is_active = false
     or target_room.closed_at is not null
     or target_room.expires_at <= now()
     or not exists (
       select 1
       from cotime_book.room_members as member
       where member.room_id = p_room_id
         and member.user_id = current_user_id
     ) then
    raise exception 'Room membership is inactive or expired'
      using errcode = '42501';
  end if;

  if target_room.host_user_id <> current_user_id then
    raise exception 'Only the host can change the room text size'
      using errcode = 'P0001';
  end if;

  update cotime_book.rooms
  set text_size_locked = p_locked,
      text_size = coalesce(p_text_size::smallint, text_size)
  where id = p_room_id
  returning * into target_room;

  return target_room;
end;
$$;

revoke all on function cotime_book.set_room_text_size(uuid, boolean, integer)
  from public, anon, authenticated;
grant execute on function cotime_book.set_room_text_size(uuid, boolean, integer)
  to authenticated;
