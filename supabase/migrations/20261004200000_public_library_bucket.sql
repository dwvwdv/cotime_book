-- Public library: open-source EPUBs any room can share.
--
-- Books are plain files in a Storage bucket; the file name is the title shown
-- in the app. There is deliberately no catalog table yet. Books are added by
-- the maintainers (dashboard or service role): there is no insert, update or
-- delete policy, so app users can only list and download.
--
-- No allowed_mime_types: browsers and operating systems disagree about the
-- type of an .epub (application/epub+zip, application/octet-stream or none),
-- and a mismatch would only make the maintainer's upload fail. The app shows
-- nothing but *.epub objects.

insert into storage.buckets (id, name, public, file_size_limit)
values (
  'cotime-book-library',
  'cotime-book-library',
  true,
  -- Must match AppConstants.maxFileSize: a larger book could be listed but
  -- every device would refuse it.
  40 * 1024 * 1024
)
on conflict (id) do nothing;

-- Listing goes through storage.search() under the caller's role, so a public
-- bucket still needs a SELECT policy for the app to see what is in it.
create policy "cotime_book library is readable"
on storage.objects
for select
to authenticated
using (bucket_id = 'cotime-book-library');
