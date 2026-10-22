begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

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
    ('00000000-0000-0000-0000-000000000061'::uuid, 'topic-member@example.invalid'),
    ('00000000-0000-0000-0000-000000000062'::uuid, 'topic-stranger@example.invalid'),
    ('00000000-0000-0000-0000-000000000063'::uuid, 'topic-closed@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('TPCA22'), ('TPCB22')
on conflict (code) do nothing;

insert into cotime_book.rooms (
  id,
  code,
  channel_id,
  host_user_id,
  expires_at,
  last_activity_at
)
values
  (
    '60000000-0000-0000-0000-000000000001',
    'TPCA22',
    '6c000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000061',
    now() + interval '24 hours',
    now()
  ),
  (
    '60000000-0000-0000-0000-000000000002',
    'TPCB22',
    '6c000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000063',
    now() + interval '24 hours',
    now()
  );

insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values
  (
    '60000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000061',
    'Member',
    now(),
    now()
  ),
  (
    '60000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000063',
    'Closed',
    now(),
    now()
  );

-- TPCB22 has closed but its last member's row is still there.
update cotime_book.rooms
set is_active = false,
    closed_at = now()
where id = '60000000-0000-0000-0000-000000000002';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000061","role":"authenticated"}',
  true
);

select ok(
  cotime_book_private.can_access_room_topic('cotime_book:room:TPCA22'),
  'a member can open the room''s code topic, the one every app uses'
);

select ok(
  not cotime_book_private.can_access_room_topic(
    'cotime_book:room:6c000000-0000-0000-0000-000000000001'
  ),
  'the room''s channel_id is not a second topic for it'
);

select ok(
  not cotime_book_private.can_access_room_topic('cotime_book:room:tpca22'),
  'only the exact code topic is accepted'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000062","role":"authenticated"}',
  true
);

select ok(
  not cotime_book_private.can_access_room_topic('cotime_book:room:TPCA22'),
  'someone outside the room cannot open its topic'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000063","role":"authenticated"}',
  true
);

select ok(
  not cotime_book_private.can_access_room_topic('cotime_book:room:TPCB22'),
  'a closed room''s topic is closed to its members too'
);

reset role;

select * from finish();
rollback;
