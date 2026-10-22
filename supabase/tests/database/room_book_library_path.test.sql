begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);

insert into auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
select
  test_user.id,
  'authenticated',
  'authenticated',
  test_user.email,
  '',
  now(),
  '{}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from (
  values
    ('00000000-0000-0000-0000-000000000051'::uuid, 'library-sharer@example.invalid'),
    ('00000000-0000-0000-0000-000000000052'::uuid, 'library-latecomer@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('LBPA22')
on conflict (code) do nothing;

insert into cotime_book.rooms (id, code, host_user_id, expires_at, last_activity_at)
values (
  '50000000-0000-0000-0000-000000000001',
  'LBPA22',
  '00000000-0000-0000-0000-000000000051',
  now() + interval '24 hours',
  now()
);

insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000051',
  'Sharer',
  now(),
  now()
);

select ok(
  has_column_privilege(
    'authenticated',
    'cotime_book.rooms',
    'current_book_library_path',
    'UPDATE'
  ),
  'members can record where the room''s book is in the library'
);

-- The sharer shares a library book the way the current app does: title,
-- hash and path in one update.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000051","role":"authenticated"}',
  true
);
update cotime_book.rooms
set current_book_title = 'Moby-Dick',
    current_book_hash = repeat('a', 64),
    current_book_library_path = 'classics/moby-dick.epub'
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select array[current_book_hash::text, current_book_library_path]
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  array[repeat('a', 64), 'classics/moby-dick.epub'],
  'a library share records the path with its book'
);

-- Someone opens the lobby after the share broadcast went out.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000052","role":"authenticated"}',
  true
);
select is(
  (select current_book_library_path from cotime_book.join_room('LBPA22', 'Latecomer', 3)),
  'classics/moby-dick.epub',
  'a member who joins after the share is told where to download the book'
);
select is(
  (
    select current_book_library_path
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  'classics/moby-dick.epub',
  'a member re-reading the room sees the library path'
);
reset role;

create temporary table revision_before as
select revision
from cotime_book.rooms
where id = '50000000-0000-0000-0000-000000000001';

-- The same hash written again by an app from before the column existed.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000051","role":"authenticated"}',
  true
);
update cotime_book.rooms
set current_book_title = 'Moby-Dick',
    current_book_hash = repeat('a', 64)
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select current_book_library_path
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  'classics/moby-dick.epub',
  're-sharing the same book without a path keeps the path that locates it'
);

-- A different book written with title and hash only: an older app, or a
-- current app sharing a book that is not from the library.
set local role authenticated;
update cotime_book.rooms
set current_book_title = 'Old app book',
    current_book_hash = repeat('b', 64)
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select array[current_book_hash::text, current_book_library_path]
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  array[repeat('b', 64), null::text],
  'a new book shared without a path does not inherit the previous book''s path'
);

-- Back to a library book, then a book from someone's device.
set local role authenticated;
update cotime_book.rooms
set current_book_title = 'Moby-Dick',
    current_book_hash = repeat('a', 64),
    current_book_library_path = 'classics/moby-dick.epub'
where id = '50000000-0000-0000-0000-000000000001';
update cotime_book.rooms
set current_book_title = 'Notes',
    current_book_hash = repeat('c', 64),
    current_book_library_path = null
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select array[current_book_hash::text, current_book_library_path]
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  array[repeat('c', 64), null::text],
  'a book that is not from the library clears the path'
);

-- One library book straight after another.
set local role authenticated;
update cotime_book.rooms
set current_book_title = 'Moby-Dick',
    current_book_hash = repeat('a', 64),
    current_book_library_path = 'classics/moby-dick.epub'
where id = '50000000-0000-0000-0000-000000000001';
update cotime_book.rooms
set current_book_title = 'Walden',
    current_book_hash = repeat('d', 64),
    current_book_library_path = 'classics/walden.epub'
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select array[current_book_hash::text, current_book_library_path]
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  array[repeat('d', 64), 'classics/walden.epub'],
  'switching between library books records the new path'
);

select cmp_ok(
  (
    select revision
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  '>',
  (select revision from revision_before),
  'book changes keep bumping the room revision'
);

truncate revision_before;
insert into revision_before
select revision
from cotime_book.rooms
where id = '50000000-0000-0000-0000-000000000001';

-- The same book turns out to be in the library: only the path changes.
set local role authenticated;
update cotime_book.rooms
set current_book_library_path = 'classics/walden-2.epub'
where id = '50000000-0000-0000-0000-000000000001';
reset role;

select is(
  (
    select revision
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  (select revision + 1 from revision_before),
  'changing only the path is a reading-state change that bumps the revision'
);

set local role authenticated;
select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = '../secrets.epub'
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'a path that climbs out of the library is refused'
);
select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = '/etc/passwd'
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'an absolute path is refused'
);
select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = 'classics//walden.epub'
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'a path with an empty segment is refused'
);
select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = 'classics\walden.epub'
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'a path with a backslash is refused'
);
select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = ''
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'an empty path is refused'
);
reset role;

-- Clearing the book clears its path too, even when the update names only
-- the hash.
update cotime_book.rooms
set current_book_hash = null
where id = '50000000-0000-0000-0000-000000000001';

select is(
  (
    select current_book_library_path
    from cotime_book.rooms
    where id = '50000000-0000-0000-0000-000000000001'
  ),
  null,
  'a room without a book has no library path'
);

select throws_ok(
  $$
    update cotime_book.rooms
    set current_book_library_path = 'classics/walden.epub'
    where id = '50000000-0000-0000-0000-000000000001'
  $$,
  '23514',
  null,
  'a library path without a book is refused'
);

select * from finish();
rollback;
