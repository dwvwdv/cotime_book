-- Let the people who read in a room go back to it after it closes.
--
-- A room closes when its last member leaves or its lease runs out, and the
-- closed row is kept for 30 days before cleanup deletes it. Until now join_room
-- treated a closed room as gone, so tapping it in the app's recent-room list
-- always produced a brand-new room with a new code that had to be handed out
-- again, and the book and reading position were left behind.
--
-- Reopening is limited to people who have been members of that room. The code
-- alone is not enough: a closed room's code may have been shared long ago, and
-- anyone else still gets the same "not found" as for a code that never existed,
-- so this does not reveal which closed codes are real.

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

drop trigger if exists record_room_participant_after_insert
  on cotime_book.room_members;
create trigger record_room_participant_after_insert
after insert on cotime_book.room_members
for each row execute function cotime_book_private.record_room_participant();

create or replace function cotime_book.join_room(
  p_code text,
  p_nickname text,
  p_avatar_color_index integer default 0
)
returns cotime_book.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_room_id uuid;
  previous_room_id uuid;
  joined_room cotime_book.rooms;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_nickname, ''))) not between 1 and 30 then
    raise exception 'Nickname must contain between 1 and 30 characters'
      using errcode = '22023';
  end if;
  if p_avatar_color_index not between 0 and 7 then
    raise exception 'Avatar color index must be between 0 and 7'
      using errcode = '22023';
  end if;

  select room.id
  into target_room_id
  from cotime_book.rooms as room
  where room.code = upper(btrim(p_code));

  if target_room_id is null then
    raise exception 'Room not found or no longer active'
      using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_user_id::text, 0)
  );

  -- Include both the destination and all previous rooms in one ordered lock set.
  perform room.id
  from cotime_book.rooms as room
  where room.id = target_room_id
     or exists (
       select 1
       from cotime_book.room_members as member
       where member.room_id = room.id
         and member.user_id = current_user_id
     )
  order by room.id
  for update;

  -- Read under the lock: two former members reopening at once are serialized
  -- here, and the second one finds an open room and simply joins it.
  select room.*
  into joined_room
  from cotime_book.rooms as room
  where room.id = target_room_id;

  if joined_room.id is null then
    -- Purged by cleanup between the lookup and the lock.
    raise exception 'Room not found or no longer active'
      using errcode = 'P0002';
  end if;

  if not (
    joined_room.is_active
    and joined_room.closed_at is null
    and joined_room.expires_at > now()
  ) then
    if not exists (
      select 1
      from cotime_book_private.room_participants as participant
      where participant.room_id = target_room_id
        and participant.user_id = current_user_id
    ) then
      raise exception 'Room not found or no longer active'
        using errcode = 'P0002';
    end if;

    -- An expired lease that cleanup has not reached yet is closed in all but
    -- name: nobody has heartbeated for a day. Clear whoever is left, as cleanup
    -- would, so the reopened room starts with only the people who come back.
    delete from cotime_book.room_members
    where room_id = target_room_id;

    -- The room keeps its book and last position; whoever brings it back hosts
    -- it, because the previous host is not in it any more.
    update cotime_book.rooms
    set is_active = true,
        closed_at = null,
        host_user_id = current_user_id,
        updated_at = now(),
        revision = revision + 1
    where id = target_room_id;
  end if;

  for previous_room_id in
    select member.room_id
    from cotime_book.room_members as member
    where member.user_id = current_user_id
      and member.room_id <> target_room_id
    order by member.room_id
  loop
    perform cotime_book_private.remove_membership_locked(
      previous_room_id,
      current_user_id
    );
  end loop;

  insert into cotime_book.room_members (
    room_id,
    user_id,
    nickname,
    avatar_color_index,
    last_seen_at
  ) values (
    target_room_id,
    current_user_id,
    btrim(p_nickname),
    p_avatar_color_index,
    now()
  )
  on conflict (room_id, user_id) do update
  set nickname = excluded.nickname,
      avatar_color_index = excluded.avatar_color_index,
      last_seen_at = now();

  update cotime_book.rooms
  set last_activity_at = now(),
      expires_at = now() + interval '24 hours',
      updated_at = now(),
      revision = revision + 1
  where id = target_room_id
  returning * into joined_room;

  return joined_room;
end;
$$;

revoke all on function cotime_book_private.record_room_participant()
  from public, anon, authenticated, service_role;
revoke all on function cotime_book.join_room(text, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function cotime_book.join_room(text, text, integer)
  to authenticated, service_role;

notify pgrst, 'reload schema';
