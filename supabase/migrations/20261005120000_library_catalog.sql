-- Library catalog: what a file name cannot say.
--
-- Storage object keys only accept ASCII, so a Chinese title cannot be the
-- file name, and a file name carries no author, language or category. The
-- maintainers describe each book here, keyed by its path in the bucket.
--
-- The app reads library_catalog, which lists the bucket and joins this table
-- onto it: a book dropped into the bucket without a row still shows up (under
-- its file name), and a row whose file is gone shows nothing. Like the bucket,
-- the catalog is written only from the dashboard or with the service role.

create table cotime_book.library_books (
  -- The object's name in the cotime-book-library bucket, folders included.
  path text primary key,
  title text not null check (btrim(title) <> ''),
  author text,
  -- A BCP 47 tag ('en', 'zh-Hant', 'ja'); the app names the common ones.
  language text,
  category text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table cotime_book.library_books enable row level security;

create policy "cotime_book library catalog is readable"
on cotime_book.library_books
for select
to authenticated
using (true);

grant select on cotime_book.library_books to authenticated;
grant all on cotime_book.library_books to service_role;

-- security_invoker: the caller's own storage.objects policy decides what is
-- listed, so this view cannot open any bucket the caller could not list.
create view cotime_book.library_catalog
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
  book.category
from storage.objects as object
left join cotime_book.library_books as book on book.path = object.name
where object.bucket_id = 'cotime-book-library'
  and lower(object.name) like '%.epub';

grant select on cotime_book.library_catalog to authenticated;
grant select on cotime_book.library_catalog to service_role;
