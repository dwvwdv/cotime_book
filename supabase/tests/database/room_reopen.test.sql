begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(21);

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
    ('00000000-0000-0000-0000-000000000011'::uuid, 'reopen-host@example.invalid'),
    ('00000000-0000-0000-0000-000000000012'::uuid, 'reopen-reader@example.invalid'),
    ('00000000-0000-0000-0000-000000000013'::uuid, 'reopen-stranger@example.invalid'),
    ('00000000-0000-0000-0000-000000000014'::uuid, 'reopen-creator@example.invalid'),
    ('00000000-0000-0000-0000-000000000015'::uuid, 'reopen-lapsed@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('RPNA22'), ('RPXP22')
on conflict (code) do nothing;

insert into cotime_book.rooms (
  id,
  code,
  host_user_id,
  current_book_title,
  current_book_hash,
  current_cfi,
  expires_at,
  last_activity_at
)
values
  (
    '20000000-0000-0000-0000-000000000001',
    'RPNA22',
    '00000000-0000-0000-0000-000000000011',
    'Moby-Dick',
    repeat('a', 64),
    'epubcfi(/6/14!/4/2/1:0)',
    now() + interval '24 hours',
    now()
  ),
  (
    '20000000-0000-0000-0000-000000000002',
    'RPXP22',
    '00000000-0000-0000-0000-000000000015',
    null,
    null,
    null,
    now() - interval '1 minute',
    now() - interval '25 hours'
  );

insert into cotime_book.room_members (
  room_id,
  user_id,
  nickname,
  joined_at,
  last_seen_at
)
values
  (
    '20000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000011',
    'Host',
    now() - interval '2 minutes',
    now()
  ),
  (
    '20000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000012',
    'Reader',
    now() - interval '1 minute',
    now()
  ),
  (
    '20000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000015',
    'Lapsed',
    now() - interval '25 hours',
    now() - interval '25 hours'
  ),
  (
    '20000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000013',
    'Left behind',
    now() - interval '25 hours',
    now() - interval '25 hours'
  );

select ok(
  not has_table_privilege(
    'authenticated',
    'cotime_book_private.room_participants',
    'select'
  ),
  'room history is not readable through the API'
);

-- Everyone leaves RPNA22, which closes it.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000011","role":"authenticated"}',
  true
);
select cotime_book.leave_room('20000000-0000-0000-0000-000000000001');
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000012","role":"authenticated"}',
  true
);
select cotime_book.leave_room('20000000-0000-0000-0000-000000000001');
reset role;

select ok(
  (
    select not is_active and closed_at is not null
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  'the room is closed once everyone has left'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000013","role":"authenticated"}',
  true
);
select throws_ok(
  $$select cotime_book.join_room('RPNA22', 'Stranger', 1)$$,
  'P0002',
  'Room not found or no longer active',
  'someone who was never in a closed room cannot reopen it'
);
reset role;

select ok(
  (
    select not is_active
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  'a refused reopen leaves the room closed'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000012","role":"authenticated"}',
  true
);
select cotime_book.join_room('RPNA22', 'Reader', 2);
reset role;

select ok(
  (
    select is_active and closed_at is null and expires_at > now()
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  'a former member rejoining reopens the closed room'
);

select is(
  (
    select host_user_id
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  '00000000-0000-0000-0000-000000000012'::uuid,
  'whoever reopens the room hosts it'
);

select is(
  (
    select array[current_book_title, current_book_hash, current_cfi]
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  array['Moby-Dick', repeat('a', 64), 'epubcfi(/6/14!/4/2/1:0)'],
  'the reopened room keeps its book and last position'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000011","role":"authenticated"}',
  true
);
select cotime_book.join_room('RPNA22', 'Host', 0);
reset role;

select is(
  (
    select count(*)::bigint
    from cotime_book.room_members
    where room_id = '20000000-0000-0000-0000-000000000001'
  ),
  2::bigint,
  'the next former member joins the reopened room normally'
);

select is(
  (
    select host_user_id
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000001'
  ),
  '00000000-0000-0000-0000-000000000012'::uuid,
  'joining an open room does not take over as host'
);

-- RPXP22's lease ran out but cleanup has not closed it yet.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000012","role":"authenticated"}',
  true
);
select throws_ok(
  $$select cotime_book.join_room('RPXP22', 'Reader', 2)$$,
  'P0002',
  'Room not found or no longer active',
  'an expired room still turns away people who were never in it'
);
reset role;

select is(
  (
    select room_id
    from cotime_book.room_members
    where user_id = '00000000-0000-0000-0000-000000000012'
  ),
  '20000000-0000-0000-0000-000000000001'::uuid,
  'a refused join does not pull the user out of their current room'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000015","role":"authenticated"}',
  true
);
select cotime_book.join_room('RPXP22', 'Lapsed', 4);
reset role;

select ok(
  (
    select is_active and closed_at is null and expires_at > now()
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000002'
  ),
  'a former member can bring back a room whose lease ran out'
);

select is(
  (
    select array_agg(user_id)
    from cotime_book.room_members
    where room_id = '20000000-0000-0000-0000-000000000002'
  ),
  array['00000000-0000-0000-0000-000000000015'::uuid],
  'members left over from the lapsed session are cleared on reopen'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000014","role":"authenticated"}',
  true
);
create temporary table created_room on commit drop as
select * from cotime_book.create_room('Creator', 5);
reset role;

select ok(
  exists (
    select 1
    from cotime_book_private.room_participants as participant
    join created_room on created_room.id = participant.room_id
    where participant.user_id = '00000000-0000-0000-0000-000000000014'
  ),
  'creating a room records the creator as a member who may reopen it'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000011","role":"authenticated"}',
  true
);
select is(
  cotime_book.available_room_codes(array['rpna22', 'RPXP22', 'NOPE22']),
  array['RPNA22'],
  'available_room_codes answers only for rooms the caller has been in'
);
reset role;

-- Close RPNA22 again; a closed room is still one its members can go back to.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000011","role":"authenticated"}',
  true
);
select cotime_book.leave_room('20000000-0000-0000-0000-000000000001');
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000012","role":"authenticated"}',
  true
);
select cotime_book.leave_room('20000000-0000-0000-0000-000000000001');
select is(
  cotime_book.available_room_codes(array['RPNA22']),
  array['RPNA22'],
  'a closed room is still available to its former members'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000013","role":"authenticated"}',
  true
);
select is(
  cotime_book.available_room_codes(array['RPNA22']),
  array[]::text[],
  'available_room_codes does not reveal rooms to people never in them'
);
select throws_ok(
  $$select cotime_book.available_room_codes(
    array(select 'AAAAAA' from generate_series(1, 51))
  )$$,
  '22023',
  'At most 50 room codes can be checked at once',
  'available_room_codes refuses oversized lookups'
);
reset role;

-- Once cleanup purges a closed room, its history goes with it.
delete from cotime_book.room_members
where room_id = '20000000-0000-0000-0000-000000000002';
update cotime_book.rooms
set is_active = false,
    closed_at = now() - interval '31 days',
    expires_at = now() - interval '31 days'
where id = '20000000-0000-0000-0000-000000000002';
select cotime_book_private.cleanup_expired_rooms();

select ok(
  not exists (
    select 1
    from cotime_book.rooms
    where id = '20000000-0000-0000-0000-000000000002'
  ),
  'cleanup still purges closed rooms after retention'
);

select is(
  (
    select count(*)::bigint
    from cotime_book_private.room_participants
    where room_id = '20000000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'a purged room takes its member history with it'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000015","role":"authenticated"}',
  true
);
select is(
  cotime_book.available_room_codes(array['RPXP22']),
  array[]::text[],
  'a purged room is no longer available, even to its members'
);
reset role;

select * from finish();
rollback;
