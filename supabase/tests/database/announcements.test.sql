begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into cotime_book.announcements (title, content, published_at)
values
  ('Older notes', 'First release.', now() - interval '10 days'),
  ('Latest notes', E'New:\n- Announcements', now() - interval '1 day'),
  ('Next release', 'Not out yet.', now() + interval '3 days');

select throws_ok(
  $$ insert into cotime_book.announcements (title) values ('  ') $$,
  '23514',
  null,
  'an announcement needs a title'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000043","role":"authenticated"}',
  true
);

select results_eq(
  $$
    select title from cotime_book.announcements
    where title in ('Older notes', 'Latest notes', 'Next release')
    order by published_at desc
  $$,
  array['Latest notes', 'Older notes'],
  'readers see published announcements, newest first'
);

select is(
  (select content from cotime_book.announcements where title = 'Latest notes'),
  E'New:\n- Announcements',
  'the content keeps its line breaks'
);

select is_empty(
  $$ select id from cotime_book.announcements where title = 'Next release' $$,
  'an announcement scheduled for later stays hidden until then'
);

select throws_ok(
  $$ insert into cotime_book.announcements (title) values ('Spoofed') $$,
  '42501',
  null,
  'readers cannot post announcements'
);

select throws_ok(
  $$ update cotime_book.announcements set title = 'Changed' $$,
  '42501',
  null,
  'readers cannot change announcements'
);

reset role;

select * from finish();
rollback;
