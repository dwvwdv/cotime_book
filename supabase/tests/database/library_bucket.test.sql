begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

select is(
  (
    select file_size_limit
    from storage.buckets
    where id = 'cotime-book-library'
  ),
  (40 * 1024 * 1024)::bigint,
  'the library accepts books up to the app limit'
);

select ok(
  (select public from storage.buckets where id = 'cotime-book-library'),
  'the library is public'
);

-- Another app's private bucket in the same project.
insert into storage.buckets (id, name, public)
values ('library-test-private', 'library-test-private', false);

insert into storage.objects (bucket_id, name, metadata)
values
  ('cotime-book-library', 'Alice in Wonderland.epub', '{"size": 1024}'),
  ('library-test-private', 'secret.epub', '{"size": 1024}');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000031","role":"authenticated"}',
  true
);

select is(
  (
    select array_agg(name order by name)
    from storage.objects
    where bucket_id = 'cotime-book-library'
  ),
  array['Alice in Wonderland.epub'],
  'a signed-in reader can list the library'
);

select is(
  (
    select count(*)::bigint
    from storage.objects
    where bucket_id = 'library-test-private'
  ),
  0::bigint,
  'the library policy does not open other buckets'
);

select throws_ok(
  $$
    insert into storage.objects (bucket_id, name)
    values ('cotime-book-library', 'uploaded-by-a-reader.epub')
  $$,
  '42501',
  null,
  'readers cannot add books to the library'
);

select is_empty(
  $$
    update storage.objects
    set name = 'replaced.epub'
    where bucket_id = 'cotime-book-library'
    returning name
  $$,
  'readers cannot rename or replace library books'
);

reset role;

select * from finish();
rollback;
