-- GH-31: Realtime topics are authorized by room code only.
--
-- can_access_room_topic() used to accept both `cotime_book:room:<code>` and
-- `cotime_book:room:<channel_id>`. Every released client subscribes with the
-- code, so the channel_id path was never used; it only doubled the topics a
-- member could open without adding any isolation.
--
-- The code path is the one kept, not the channel_id one:
--   * Room codes are reserved forever in
--     cotime_book_private.room_code_reservations and never reissued, so a code
--     topic can never reach a different room than the one it was issued for.
--     The channel_id would not isolate anything the code does not already.
--   * Keeping the code needs no client change, so apps already installed keep
--     working. Moving to channel_id would cut off every older app the moment
--     the code path was removed (or need a release that tracks both).
--
-- Membership, the active/closed state and the lease are checked exactly as
-- before. `create or replace` keeps the existing EXECUTE grants, and the
-- policies on realtime.messages call this function, so they pick it up as is.

create or replace function cotime_book_private.can_access_room_topic(
  target_topic text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from cotime_book.rooms as room
    join cotime_book.room_members as member on member.room_id = room.id
    where target_topic = 'cotime_book:room:' || room.code
      and room.is_active = true
      and room.closed_at is null
      and room.expires_at > now()
      and member.user_id = (select auth.uid())
  );
$$;
