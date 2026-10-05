begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

-- Another app's private bucket in the same project.
insert into storage.buckets (id, name, public)
values ('catalog-test-private', 'catalog-test-private', false);

insert into storage.objects (bucket_id, name, metadata)
values
  ('cotime-book-library', 'classics/hongloumeng.epub', '{"size": 2048}'),
  ('cotime-book-library', 'The_Time_Machine.epub', '{"size": 1024}'),
  ('cotime-book-library', 'classics/.emptyFolderPlaceholder', '{"size": 0}'),
  ('cotime-book-library', 'covers/hongloumeng.jpg', '{"size": 30000}'),
  ('catalog-test-private', 'secret.epub', '{"size": 1024}');

insert into cotime_book.library_books (
  path, title, author, language, category, cover_path
)
values
  (
    'classics/hongloumeng.epub', '紅樓夢', '曹雪芹', 'zh-Hant', 'Classics',
    'covers/hongloumeng.jpg'
  ),
  -- Catalogued, but the file was never uploaded (or was removed).
  ('missing.epub', 'Missing Book', null, 'en', 'Classics', null),
  ('secret.epub', 'Secret', null, 'en', 'Private', null);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000041","role":"authenticated"}',
  true
);

select is(
  (
    select array_agg(path order by path collate "C")
    from cotime_book.library_catalog
  ),
  array['The_Time_Machine.epub', 'classics/hongloumeng.epub'],
  'the catalog lists the EPUB files in the library bucket, folders included, and not their covers'
);

select is(
  (
    select row(title, author, language, category, size_bytes, cover_path)::text
    from cotime_book.library_catalog
    where path = 'classics/hongloumeng.epub'
  ),
  row(
    '紅樓夢', '曹雪芹', 'zh-Hant', 'Classics', 2048::bigint,
    'covers/hongloumeng.jpg'
  )::text,
  'a catalogued book carries its title, author, language, category and cover'
);

select is(
  (
    select row(title, author, language, category, size_bytes, cover_path)::text
    from cotime_book.library_catalog
    where path = 'The_Time_Machine.epub'
  ),
  row(
    null::text, null::text, null::text, null::text, 1024::bigint, null::text
  )::text,
  'a book with no catalog row is still listed'
);

select is_empty(
  $$ select 1 from cotime_book.library_catalog where path = 'secret.epub' $$,
  'the catalog does not list another bucket, even with a matching row'
);

select throws_ok(
  $$
    insert into cotime_book.library_books (path, title)
    values ('mine.epub', 'Mine')
  $$,
  '42501',
  null,
  'readers cannot add to the catalog'
);

select throws_ok(
  $$ update cotime_book.library_books set title = 'Changed' $$,
  '42501',
  null,
  'readers cannot change the catalog'
);

reset role;
set local role anon;

select throws_ok(
  $$ select 1 from cotime_book.library_catalog $$,
  '42501',
  null,
  'a client that is not signed in cannot read the catalog'
);

reset role;

select * from finish();
rollback;
