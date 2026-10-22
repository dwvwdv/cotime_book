-- GH-28: the room remembers where its book is in the public library.
--
-- The library path used to travel only in the `book_shared` broadcast, so a
-- member who opened the lobby after the share saw just current_book_hash and
-- fell back to the slower peer-to-peer transfer, which also needs a holder
-- online. The room row now keeps the path next to the hash it belongs to.

alter table cotime_book.rooms
  add column if not exists current_book_library_path text;

-- Mirrors isPlainLibraryPath() in lib/providers/book_provider.dart: an object
-- name inside the library bucket, never an absolute path, a `..` segment, an
-- empty segment or a backslash. 1024 bytes is Storage's own limit on object
-- names. A path means nothing without the book it locates, hence the hash.
alter table cotime_book.rooms
  add constraint rooms_current_book_library_path_format
    check (
      current_book_library_path is null
      or (
        current_book_hash is not null
        and octet_length(current_book_library_path) between 1 and 1024
        and current_book_library_path !~ '(^/|/$|//|\\)'
        and current_book_library_path !~ '(^|/)\.\.(/|$)'
      )
    );

-- Keeps the path from outliving its book. Apps released before this column
-- existed share a book by writing current_book_hash alone; left as it was,
-- the path would keep pointing at the previous book. So whenever the hash
-- changes and the same update does not also change the path, the path is
-- cleared and late joiners fall back to peer-to-peer, as before.
--
-- Current apps always write the path together with the hash (null for a book
-- that is not from the library). The one write this rule gets wrong is a new
-- hash at the very path the room already had, which only happens if a
-- maintainer replaced a library file in place and the room re-shares it. It
-- errs towards no path, which costs speed, never the wrong book. Receivers
-- verify the download against the hash in any case, so even a stale path
-- could only fail over to peer-to-peer.
create or replace function cotime_book_private.clear_stale_room_library_path()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.current_book_hash is distinct from old.current_book_hash
     and new.current_book_library_path
       is not distinct from old.current_book_library_path then
    new.current_book_library_path := null;
  end if;
  return new;
end;
$$;

revoke all on function cotime_book_private.clear_stale_room_library_path()
  from public, anon, authenticated, service_role;

create or replace trigger clear_stale_room_library_path_before_update
before update of current_book_hash
on cotime_book.rooms
for each row execute function cotime_book_private.clear_stale_room_library_path();

-- Changing the path is a change to the room's reading state like the others:
-- it bumps the revision and renews the lease.
create or replace trigger touch_room_reading_state_before_update
before update of
  current_book_title,
  current_book_hash,
  current_book_library_path,
  current_cfi
on cotime_book.rooms
for each row execute function cotime_book_private.touch_room_reading_state();

grant update (current_book_library_path) on cotime_book.rooms to authenticated;
