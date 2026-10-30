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
    ('00000000-0000-0000-0000-000000000081'::uuid, 'report-history@example.invalid'),
    ('00000000-0000-0000-0000-000000000082'::uuid, 'report-other@example.invalid')
) as test_user(id, email)
on conflict (id) do nothing;

insert into cotime_book_private.layout_reports (
  id, created_at, user_id, app_version, note, report
)
values
  (
    '80000000-0000-0000-0000-000000000001',
    now() - interval '2 days',
    '00000000-0000-0000-0000-000000000081',
    '1.0.27+31',
    'turns take forever',
    '{"book":{"title":"少年實用機械","hash":"abc"},"viewer":[384,645]}'::jsonb
  ),
  (
    '80000000-0000-0000-0000-000000000002',
    now() - interval '1 day',
    '00000000-0000-0000-0000-000000000081',
    '1.0.27+31',
    null,
    '{}'::jsonb
  ),
  (
    '80000000-0000-0000-0000-000000000003',
    now(),
    '00000000-0000-0000-0000-000000000082',
    '1.0.27+31',
    'not yours',
    '{"book":{"title":"Someone else"}}'::jsonb
  );

select ok(
  not has_function_privilege(
    'authenticated',
    'cotime_book_private.resolve_layout_reports(uuid[], text, text, text)',
    'EXECUTE'
  ),
  'the app cannot set what became of a report'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000081","role":"authenticated"}',
  true
);

select results_eq(
  $$select id::text, book_title, note, status from cotime_book.my_layout_reports()$$,
  $$values
    ('80000000-0000-0000-0000-000000000002', null::text, null::text, 'open'),
    ('80000000-0000-0000-0000-000000000001', '少年實用機械', 'turns take forever', 'open')$$,
  'a reader sees their own reports, newest first, with the book and their note'
);
reset role;

select is(
  cotime_book_private.resolve_layout_reports(
    array[
      '80000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-000000000003'
    ]::uuid[],
    'resolved',
    '1.0.28',
    '  已修正 / Fixed  '
  ),
  2,
  'several reports of one bug are resolved at once'
);

set local role authenticated;
select results_eq(
  $$
    select status, fixed_in, resolution_note, resolved_at is not null
    from cotime_book.my_layout_reports()
    where id = '80000000-0000-0000-0000-000000000001'
  $$,
  $$values ('resolved', '1.0.28', '已修正 / Fixed', true)$$,
  'the reader sees it resolved, in which release, with the note'
);
reset role;

-- now() is the same all through a transaction, so what the rerun changed is
-- read from the count rather than from resolved_at.
select is(
  cotime_book_private.resolve_layout_reports(
    array[
      '80000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-000000000003'
    ]::uuid[],
    'resolved',
    '1.0.28',
    '已修正 / Fixed'
  ),
  0,
  'marking reports again with the outcome they have leaves them as they are'
);

select is(
  cotime_book_private.resolve_layout_reports(
    array[
      '80000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-000000000003'
    ]::uuid[],
    'resolved',
    '1.0.29',
    '已修正 / Fixed'
  ),
  2,
  'a new outcome is a new answer'
);

select cotime_book_private.resolve_layout_reports(
  array['80000000-0000-0000-0000-000000000002']::uuid[],
  'declined',
  '1.0.28',
  '無法重現 / Could not reproduce'
);

select is(
  (
    select array[status, fixed_in, resolution_note]
    from cotime_book_private.layout_reports
    where id = '80000000-0000-0000-0000-000000000002'
  ),
  array['declined', null, '無法重現 / Could not reproduce'],
  'a declined report has no release with a fix'
);

select cotime_book_private.resolve_layout_reports(
  array['80000000-0000-0000-0000-000000000002']::uuid[],
  'open'
);

select is(
  (
    select array[status, resolved_at::text, resolution_note]
    from cotime_book_private.layout_reports
    where id = '80000000-0000-0000-0000-000000000002'
  ),
  array['open', null, null],
  'a report closed by mistake goes back to open'
);

select throws_ok(
  $$select cotime_book_private.resolve_layout_reports(
    array['80000000-0000-0000-0000-000000000001']::uuid[], 'resolved', '1.0.28+32'
  )$$,
  '23514',
  null,
  'the release is major.minor.patch, without the build number'
);

select throws_ok(
  $$select cotime_book_private.resolve_layout_reports(
    array['80000000-0000-0000-0000-000000000001']::uuid[], 'fixed'
  )$$,
  '22023',
  null,
  'an unknown status is refused'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000082","role":"authenticated"}',
  true
);
select results_eq(
  $$select id::text from cotime_book.my_layout_reports()$$,
  $$values ('80000000-0000-0000-0000-000000000003')$$,
  'another reader sees only their own report'
);

select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(
  $$select * from cotime_book.my_layout_reports()$$,
  '42501',
  'Authentication required',
  'the history needs a signed-in reader'
);
reset role;

select * from finish();
rollback;
