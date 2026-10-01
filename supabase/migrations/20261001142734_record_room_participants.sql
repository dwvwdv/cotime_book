-- Who has been in each room, so a closed room can be reopened by its former
-- members and only them (see reopen_closed_rooms).

create table if not exists cotime_book_private.room_participants (
  room_id uuid not null
    references cotime_book.rooms(id) on delete cascade,
  user_id uuid not null
    references auth.users(id) on delete cascade,
  first_joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

revoke all on cotime_book_private.room_participants
  from public, anon, authenticated, service_role;
alter table cotime_book_private.room_participants
  enable row level security;

create index if not exists room_participants_user_idx
  on cotime_book_private.room_participants (user_id);

-- Everyone in a room right now, and every room's last host, has been in it.
-- Earlier members of rooms that are already closed were never recorded, so for
-- those rooms only the last host can reopen them.
insert into cotime_book_private.room_participants (room_id, user_id, first_joined_at)
select member.room_id, member.user_id, member.joined_at
from cotime_book.room_members as member
on conflict do nothing;

insert into cotime_book_private.room_participants (room_id, user_id, first_joined_at)
select room.id, room.host_user_id, room.created_at
from cotime_book.rooms as room
on conflict do nothing;

-- Recorded from the membership row rather than in create_room and join_room so
-- that no future path into a room can forget to record it.
create or replace function cotime_book_private.record_room_participant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into cotime_book_private.room_participants (room_id, user_id)
  values (new.room_id, new.user_id)
  on conflict do nothing;
  return new;
end;
$$;

revoke all on function cotime_book_private.record_room_participant()
  from public, anon, authenticated, service_role;

-- create or replace rather than drop + create: same result, and the Supabase
-- MCP holds any top-level DROP for a confirmation that never arrives here.
create or replace trigger record_room_participant_after_insert
after insert on cotime_book.room_members
for each row execute function cotime_book_private.record_room_participant();
