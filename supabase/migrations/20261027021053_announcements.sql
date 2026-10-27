-- Announcements: release notes and news, shown from the home screen.
--
-- Kept in the database rather than bundled with the app, so a note can be
-- posted (or corrected) without a release, and an app that is a few versions
-- behind still reads what changed since it was built. Like the library
-- catalog, rows are written only from the dashboard or with the service role.

create table cotime_book.announcements (
  id bigint generated always as identity primary key,
  title text not null check (btrim(title) <> ''),
  -- Plain text; line breaks are kept as written.
  content text not null default '',
  -- The date shown under the title, and the order (newest first). A time in
  -- the future keeps a written announcement hidden until then, so the notes
  -- for a release can go in before the release reaches the store.
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index announcements_published_at_idx
on cotime_book.announcements (published_at desc);

alter table cotime_book.announcements enable row level security;

create policy "cotime_book published announcements are readable"
on cotime_book.announcements
for select
to authenticated
using (published_at <= now());

grant select on cotime_book.announcements to authenticated;
grant all on cotime_book.announcements to service_role;
