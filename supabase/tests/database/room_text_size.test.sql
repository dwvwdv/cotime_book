begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

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
    ('00000000-0000-0000-0000-000000000061'::uuid, 'text-host@example.invalid'),
    ('00000000-0000-0000-0000-000000000062'::uuid, 'text-reader@example.invalid'),
    ('00000000-0000-0000-0000-000000000063'::uuid, 'text-outsider@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('TXTS22')
on conflict (code) do nothing;

insert into cotime_book.rooms (id, code, host_user_id, expires_at, last_activity_at)
values (
  '60000000-0000-0000-0000-000000000001',
  'TXTS22',
  '00000000-0000-0000-0000-000000000061',
  now() + interval '24 hours',
  now()
);

insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values
  (
    '60000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000061',
    'Host',
    now(),
    now()
  ),
  (
    '60000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000062',
    'Reader',
    now(),
    now()
  );

select is(
  (
    select array[text_size_locked::text, text_size::text]
    from cotime_book.rooms
    where id = '60000000-0000-0000-0000-000000000001'
  ),
  array['true', null::text],
  'a room starts with the host setting the text size'
);

select ok(
  not has_column_privilege(
    'authenticated',
    'cotime_book.rooms',
    'text_size',
    'UPDATE'
  )
  and not has_column_privilege(
    'authenticated',
    'cotime_book.rooms',
    'text_size_locked',
    'UPDATE'
  ),
  'members cannot write the text size around the host check'
);

create temporary table revision_before as
select revision
from cotime_book.rooms
where id = '60000000-0000-0000-0000-000000000001';
grant select on revision_before to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000061","role":"authenticated"}',
  true
);
select is(
  (
    select array[text_size_locked::text, text_size::text]
    from cotime_book.set_room_text_size(
      '60000000-0000-0000-0000-000000000001',
      true,
      24
    )
  ),
  array['true', '24'],
  'the host sets the room text size and gets the updated room back'
);
reset role;

select is(
  (
    select revision
    from cotime_book.rooms
    where id = '60000000-0000-0000-0000-000000000001'
  ),
  (select revision + 1 from revision_before),
  'a text size change bumps the revision, so members re-reading the room apply it'
);

set local role authenticated;
select is(
  (
    select array[text_size_locked::text, text_size::text]
    from cotime_book.set_room_text_size(
      '60000000-0000-0000-0000-000000000001',
      false
    )
  ),
  array['false', '24'],
  'unlocking without a size keeps the size the room had'
);

select throws_ok(
  $$select cotime_book.set_room_text_size(
    '60000000-0000-0000-0000-000000000001',
    true,
    40
  )$$,
  '23514',
  null,
  'a size outside what the app offers is refused'
);

select throws_ok(
  $$select cotime_book.set_room_text_size(
    '60000000-0000-0000-0000-000000000001',
    null,
    20
  )$$,
  '22004',
  null,
  'the lock has to be stated'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000062","role":"authenticated"}',
  true
);
select throws_ok(
  $$select cotime_book.set_room_text_size(
    '60000000-0000-0000-0000-000000000001',
    true,
    14
  )$$,
  'P0001',
  'Only the host can change the room text size',
  'a member who is not the host cannot change it, and is not told they left'
);

select throws_ok(
  $$
    update cotime_book.rooms
    set text_size = 14
    where id = '60000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  null,
  'a member cannot write the column directly either'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000063","role":"authenticated"}',
  true
);
select throws_ok(
  $$select cotime_book.set_room_text_size(
    '60000000-0000-0000-0000-000000000001',
    true,
    14
  )$$,
  '42501',
  'Room membership is inactive or expired',
  'someone outside the room is refused like any other room call'
);
reset role;

select is(
  (
    select array[text_size_locked::text, text_size::text]
    from cotime_book.rooms
    where id = '60000000-0000-0000-0000-000000000001'
  ),
  array['false', '24'],
  'refused calls change nothing'
);

-- The host left and the reader took over: the setting stays with the room.
update cotime_book.rooms
set host_user_id = '00000000-0000-0000-0000-000000000062'
where id = '60000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000062","role":"authenticated"}',
  true
);
select is(
  (
    select array[text_size_locked::text, text_size::text]
    from cotime_book.set_room_text_size(
      '60000000-0000-0000-0000-000000000001',
      true,
      20
    )
  ),
  array['true', '20'],
  'the new host takes over the text size'
);
reset role;

select * from finish();
rollback;
