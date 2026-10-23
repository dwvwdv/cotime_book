begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(9);

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
    ('00000000-0000-0000-0000-000000000071'::uuid, 'report-reader@example.invalid'),
    ('00000000-0000-0000-0000-000000000072'::uuid, 'report-outsider@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.room_code_reservations (code)
values ('RPRT22')
on conflict (code) do nothing;

insert into cotime_book.rooms (id, code, host_user_id, expires_at, last_activity_at)
values (
  '70000000-0000-0000-0000-000000000001',
  'RPRT22',
  '00000000-0000-0000-0000-000000000071',
  now() + interval '24 hours',
  now()
);

insert into cotime_book.room_members (room_id, user_id, nickname, joined_at, last_seen_at)
values (
  '70000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000071',
  'Reader',
  now(),
  now()
);

select ok(
  not has_table_privilege(
    'authenticated',
    'cotime_book_private.layout_reports',
    'SELECT'
  )
  and not has_table_privilege(
    'authenticated',
    'cotime_book_private.layout_reports',
    'INSERT'
  ),
  'the app can neither read reports nor write them around the function'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000071","role":"authenticated"}',
  true
);
select set_config(
  'test.report_id',
  cotime_book.submit_layout_report(
    '70000000-0000-0000-0000-000000000001',
    '1.0.9+13',
    '  bottom line cut off  ',
    '{"viewer":[384,600]}'::jsonb
  )::text,
  true
);
reset role;

select is(
  (
    select array[
      report.user_id::text,
      report.room_id::text,
      report.app_version,
      report.note,
      report.report ->> 'viewer'
    ]
    from cotime_book_private.layout_reports as report
    where report.id = current_setting('test.report_id')::uuid
  ),
  array[
    '00000000-0000-0000-0000-000000000071',
    '70000000-0000-0000-0000-000000000001',
    '1.0.9+13',
    'bottom line cut off',
    '[384, 600]'
  ],
  'a report is stored with who sent it, from which room, and the trimmed note'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000072","role":"authenticated"}',
  true
);
select set_config(
  'test.report_id',
  cotime_book.submit_layout_report(
    '70000000-0000-0000-0000-000000000001',
    '1.0.9+13',
    '   ',
    '{}'::jsonb
  )::text,
  true
);
reset role;

select is(
  (
    select array[report.room_id::text, report.note]
    from cotime_book_private.layout_reports as report
    where report.id = current_setting('test.report_id')::uuid
  ),
  array[null::text, null::text],
  'a report about a room the sender is not in is kept without the room'
);

set local role authenticated;
select throws_ok(
  $$select cotime_book.submit_layout_report(null, '1.0.9+13', null, '[]'::jsonb)$$,
  '23514',
  null,
  'a report has to be an object'
);

select throws_ok(
  $$select cotime_book.submit_layout_report(
    null,
    '1.0.9+13',
    null,
    jsonb_build_object('padding', repeat('x', 70000))
  )$$,
  '23514',
  null,
  'an oversized report is refused'
);

select throws_ok(
  $$select cotime_book.submit_layout_report(null, '', null, '{}'::jsonb)$$,
  '23514',
  null,
  'a report says which app version sent it'
);

select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(
  $$select cotime_book.submit_layout_report(null, '1.0.9+13', null, '{}'::jsonb)$$,
  '42501',
  'Authentication required',
  'a report needs a signed-in sender'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000072","role":"authenticated"}',
  true
);
select lives_ok(
  $$
    select cotime_book.submit_layout_report(null, '1.0.9+13', null, '{}'::jsonb)
    from generate_series(1, 19)
  $$,
  'one account can send twenty reports in an hour'
);

select throws_ok(
  $$select cotime_book.submit_layout_report(null, '1.0.9+13', null, '{}'::jsonb)$$,
  '54000',
  'Too many layout reports, try again later',
  'the twenty-first report in an hour is refused'
);
reset role;

select * from finish();
rollback;
