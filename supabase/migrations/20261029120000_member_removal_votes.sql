-- Members of a room can vote someone out of it.
--
-- A reader who closes the app without leaving holds the room: page turns
-- wait for them while they are "reconnecting", and they stay a member (and,
-- if they were the host, the host) until cleanup evicts them half an hour
-- later (GH-34). Nobody else could do anything about it.
--
-- Removing someone is a vote rather than a host power, because the reader who
-- is gone may well be the host. The votes are counted here, not by the apps:
-- an app cannot claim agreement it does not have.
--
-- * Who votes: every other member who has been heard from recently. A
--   member's heartbeat refreshes last_seen_at every few minutes while the
--   app is open, so someone who is also gone does not block the vote; the
--   member casting a vote always counts.
-- * How many: more than half of them. In the common two-reader room that is
--   the one other reader.
-- * Votes last a few minutes, and only count for the membership they were
--   cast in: a vote from before the target (or the voter) last joined does
--   not carry over.
-- * Removal is not a ban. The member goes the same way as leaving
--   (remove_membership_locked, which also hands the host role over), and
--   can join again with the room code.

create table if not exists cotime_book_private.member_removal_votes (
  room_id uuid not null
    references cotime_book.rooms(id) on delete cascade,
  target_user_id uuid not null,
  voter_user_id uuid not null,
  voted_at timestamptz not null default now(),
  primary key (room_id, target_user_id, voter_user_id),
  constraint member_removal_votes_not_self
    check (target_user_id <> voter_user_id)
);

revoke all on cotime_book_private.member_removal_votes
  from public, anon, authenticated, service_role;
alter table cotime_book_private.member_removal_votes
  enable row level security;

-- Returns {status, votes, needed, new_host_user_id}:
--   removed  this vote completed it; the target is no longer a member
--   voting   recorded; `needed` votes in all, `votes` so far
--   gone     the target is not in the room (left, or removed already)
--
-- A caller who is no longer in the room gets the same 42501 as
-- heartbeat_room, which the app reads as "the membership is gone".
create or replace function cotime_book.vote_remove_member(
  p_room_id uuid,
  p_target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  -- RoomNotifier.heartbeatInterval is 5 minutes; two missed heartbeats and
  -- a margin mean the app is closed or in the background.
  recently_seen constant interval := interval '12 minutes';
  vote_window constant interval := interval '5 minutes';
  target_room cotime_book.rooms;
  target_joined_at timestamptz;
  eligible_count integer;
  vote_count integer;
  needed_count integer;
  removal jsonb;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_target_user_id is null or p_target_user_id = current_user_id then
    raise exception 'Choose another member to remove' using errcode = '22023';
  end if;

  -- The same parent lock as join, leave, heartbeat and cleanup: two votes
  -- that complete the count at once remove the member once.
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

  select member.joined_at
  into target_joined_at
  from cotime_book.room_members as member
  where member.room_id = p_room_id
    and member.user_id = p_target_user_id;

  if target_joined_at is null then
    return jsonb_build_object('status', 'gone', 'votes', 0, 'needed', 0);
  end if;

  delete from cotime_book_private.member_removal_votes
  where room_id = p_room_id
    and voted_at <= now() - vote_window;

  insert into cotime_book_private.member_removal_votes (
    room_id,
    target_user_id,
    voter_user_id,
    voted_at
  ) values (
    p_room_id,
    p_target_user_id,
    current_user_id,
    now()
  )
  on conflict (room_id, target_user_id, voter_user_id) do update
  set voted_at = excluded.voted_at;

  select count(*)
  into eligible_count
  from cotime_book.room_members as member
  where member.room_id = p_room_id
    and member.user_id <> p_target_user_id
    and (
      member.user_id = current_user_id
      or member.last_seen_at > now() - recently_seen
    );

  select count(*)
  into vote_count
  from cotime_book_private.member_removal_votes as vote
  join cotime_book.room_members as voter
    on voter.room_id = vote.room_id
   and voter.user_id = vote.voter_user_id
  where vote.room_id = p_room_id
    and vote.target_user_id = p_target_user_id
    and vote.voted_at >= target_joined_at
    and vote.voted_at >= voter.joined_at
    and (
      voter.user_id = current_user_id
      or voter.last_seen_at > now() - recently_seen
    );

  needed_count := eligible_count / 2 + 1;

  if vote_count < needed_count then
    return jsonb_build_object(
      'status', 'voting',
      'votes', vote_count,
      'needed', needed_count
    );
  end if;

  removal := cotime_book_private.remove_membership_locked(
    p_room_id,
    p_target_user_id
  );

  delete from cotime_book_private.member_removal_votes
  where room_id = p_room_id
    and (target_user_id = p_target_user_id
      or voter_user_id = p_target_user_id);

  return jsonb_build_object(
    'status', 'removed',
    'votes', vote_count,
    'needed', needed_count,
    'new_host_user_id', removal -> 'new_host_user_id'
  );
end;
$$;

revoke all on function cotime_book.vote_remove_member(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function cotime_book.vote_remove_member(uuid, uuid)
  to authenticated;
