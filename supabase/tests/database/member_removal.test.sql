begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

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
    ('00000000-0000-0000-0000-000000000071'::uuid, 'removal-a@example.invalid'),
    ('00000000-0000-0000-0000-000000000072'::uuid, 'removal-b@example.invalid'),
    ('00000000-0000-0000-0000-000000000073'::uuid, 'removal-c@example.invalid'),
    ('00000000-0000-0000-0000-000000000074'::uuid, 'removal-d@example.invalid'),
    ('00000000-0000-0000-0000-000000000075'::uuid, 'removal-e@example.invalid'),
    ('00000000-0000-0000-0000-000000000076'::uuid, 'removal-f@example.invalid'),
    ('00000000-0000-0000-0000-000000000077'::uuid, 'removal-g@example.invalid'),
    ('00000000-0000-0000-0000-000000000078'::uuid, 'removal-outsider@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('RMVA22'), ('RMVB22'), ('RMVC22')
on conflict (code) do nothing;

-- Room 1: two readers, A is the host and closed the app.
-- Room 2: three readers who are all around.
-- Room 3: three readers, one of whom has not been heard from in a while.
insert into cotime_book.rooms (id, code, host_user_id, expires_at, last_activity_at)
values
  (
    '70000000-0000-0000-0000-000000000001',
    'RMVA22',
    '00000000-0000-0000-0000-000000000071',
    now() + interval '24 hours',
    now()
  ),
  (
    '70000000-0000-0000-0000-000000000002',
    'RMVB22',
    '00000000-0000-0000-0000-000000000073',
    now() + interval '24 hours',
    now()
  ),
  (
    '70000000-0000-0000-0000-000000000003',
    'RMVC22',
    '00000000-0000-0000-0000-000000000076',
    now() + interval '24 hours',
    now()
  );

insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000071', 'A', now() - interval '1 hour', now() - interval '3 minutes'),
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000072', 'B', now() - interval '50 minutes', now()),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000073', 'C', now() - interval '1 hour', now()),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000074', 'D', now() - interval '50 minutes', now()),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000075', 'E', now() - interval '40 minutes', now()),
  ('70000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000076', 'F', now() - interval '1 hour', now()),
  ('70000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000077', 'G', now() - interval '50 minutes', now() - interval '25 minutes'),
  ('70000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000078', 'H', now() - interval '40 minutes', now());

select ok(
  not has_table_privilege(
    'authenticated',
    'cotime_book_private.member_removal_votes',
    'SELECT, INSERT, UPDATE, DELETE'
  ),
  'votes are only reachable through the vote RPC'
);

set local role authenticated;

-- Room 1 -------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000072","role":"authenticated"}',
  true
);

select throws_ok(
  $$select cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000072'
  )$$,
  '22023',
  null,
  'nobody votes themselves out'
);

select is(
  cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000071'
  ) ->> 'status',
  'removed',
  'in a room of two, the other reader alone removes the one who is gone'
);
reset role;

select is(
  (
    select array_agg(user_id::text order by user_id)
    from cotime_book.room_members
    where room_id = '70000000-0000-0000-0000-000000000001'
  ),
  array['00000000-0000-0000-0000-000000000072'],
  'the removed reader is no longer a member'
);

select is(
  (
    select host_user_id::text
    from cotime_book.rooms
    where id = '70000000-0000-0000-0000-000000000001'
  ),
  '00000000-0000-0000-0000-000000000072',
  'removing the host hands the room to who is left, text size and all'
);

set local role authenticated;
select is(
  cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000071'
  ) ->> 'status',
  'gone',
  'a vote for someone who is already out says so instead of failing'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000071","role":"authenticated"}',
  true
);
select throws_ok(
  $$select cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000072'
  )$$,
  '42501',
  'Room membership is inactive or expired',
  'someone outside the room cannot vote in it'
);

-- Room 2 -------------------------------------------------------------------

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000074","role":"authenticated"}',
  true
);
select is(
  (
    select array[result ->> 'status', result ->> 'votes', result ->> 'needed']
    from cotime_book.vote_remove_member(
      '70000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000000073'
    ) as result
  ),
  array['voting', '1', '2'],
  'with another reader around, one vote is not enough'
);

select is(
  cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000073'
  ) ->> 'votes',
  '1',
  'voting twice still counts once'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000075","role":"authenticated"}',
  true
);
select is(
  cotime_book.vote_remove_member(
    '70000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000073'
  ) ->> 'status',
  'removed',
  'the second vote completes it'
);
reset role;

-- Room 3 -------------------------------------------------------------------

-- A stale vote against H, from before H joined and long run out: not counted.
insert into cotime_book_private.member_removal_votes (
  room_id, target_user_id, voter_user_id, voted_at
) values
  (
    '70000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000078',
    '00000000-0000-0000-0000-000000000077',
    now() - interval '45 minutes'
  );

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000076","role":"authenticated"}',
  true
);
select is(
  (
    select array[result ->> 'status', result ->> 'needed']
    from cotime_book.vote_remove_member(
      '70000000-0000-0000-0000-000000000003',
      '00000000-0000-0000-0000-000000000078'
    ) as result
  ),
  array['removed', '1'],
  'a reader who has not been heard from for a while does not hold up the vote'
);
reset role;

select is(
  (
    select count(*)::integer
    from cotime_book_private.member_removal_votes
    where room_id = '70000000-0000-0000-0000-000000000003'
  ),
  0,
  'a completed removal leaves no votes behind for when they come back'
);

-- H joins again: an old vote against them must not carry over.
insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values (
  '70000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000078',
  'H',
  now(),
  now()
);
update cotime_book.room_members
set last_seen_at = now()
where room_id = '70000000-0000-0000-0000-000000000003'
  and user_id = '00000000-0000-0000-0000-000000000077';
insert into cotime_book_private.member_removal_votes (
  room_id, target_user_id, voter_user_id, voted_at
) values (
  '70000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000078',
  '00000000-0000-0000-0000-000000000077',
  now() - interval '1 minute'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000076","role":"authenticated"}',
  true
);
select is(
  (
    select array[result ->> 'status', result ->> 'votes', result ->> 'needed']
    from cotime_book.vote_remove_member(
      '70000000-0000-0000-0000-000000000003',
      '00000000-0000-0000-0000-000000000078'
    ) as result
  ),
  array['voting', '1', '2'],
  'a vote from before the member came back does not count'
);
reset role;

select is(
  (
    select count(*)::integer
    from cotime_book.room_members
    where room_id = '70000000-0000-0000-0000-000000000003'
  ),
  3,
  'an incomplete vote removes nobody'
);

select * from finish();
rollback;
