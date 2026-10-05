-- Library covers: a small image per book, kept in the same bucket.
--
-- cover_path names an image object in cotime-book-library (by convention
-- covers/<name>.jpg, about 400px wide so a list of them stays light). The
-- bucket is public, so the app loads it by its public URL. The catalog view
-- only lists *.epub objects, so cover images never show up as books.

alter table cotime_book.library_books add column cover_path text;

-- New columns can only be appended to a view that is replaced in place.
create or replace view cotime_book.library_catalog
with (security_invoker = true)
as
select
  object.name as path,
  case
    when object.metadata ->> 'size' ~ '^[0-9]+$'
      then (object.metadata ->> 'size')::bigint
  end as size_bytes,
  book.title,
  book.author,
  book.language,
  book.category,
  book.cover_path
from storage.objects as object
left join cotime_book.library_books as book on book.path = object.name
where object.bucket_id = 'cotime-book-library'
  and lower(object.name) like '%.epub';
