begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into cotime_book.library_books (path, title)
values ('untagged.epub', 'Untagged');

select is(
  (select tags from cotime_book.library_books where path = 'untagged.epub'),
  '{}'::text[],
  'a book catalogued without tags has none, not null'
);

select throws_ok(
  $$
    insert into cotime_book.library_books (path, title, tags)
    values ('null-tag.epub', 'Null Tag', array['小說', null])
  $$,
  '23514',
  null,
  'a tag cannot be null'
);

select is_empty(
  $$
    select path from cotime_book.library_books
    where path like 'pg%-images-3.epub'
      and (language is null or cardinality(tags) = 0 or original_title is null)
  $$,
  'every book first put in the folder has a language, tags and its original title'
);

select is(
  (
    select row(title, original_title, language, tags)::text
    from cotime_book.library_books
    where path = 'pg23962-images-3.epub'
  ),
  row(
    '西遊記', 'Journey to the West', 'zh-Hant', array['中國古典', '奇幻']
  )::text,
  'a Chinese book is catalogued in its own language'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000042","role":"authenticated"}',
  true
);

select is(
  (
    select row(original_author, tags)::text
    from cotime_book.library_books
    where path = 'pg1342-images-3.epub'
  ),
  row('Jane Austen', array['愛情', '文學經典'])::text,
  'readers can read the tags and the original names'
);

select throws_ok(
  $$ update cotime_book.library_books set tags = array['Changed'] $$,
  '42501',
  null,
  'readers cannot change the tags'
);

reset role;

select * from finish();
rollback;
