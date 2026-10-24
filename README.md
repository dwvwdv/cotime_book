# 頁間 CoTime Book

頁間 (CoTime Book in English) is a collaborative reading app built with Flutter and Supabase.

## 🚀 Quick Start

### Prerequisites

- Flutter SDK (3.0 or higher)
- A Supabase account and project

### 1. Set Up Supabase Database

The database uses a dedicated `cotime_book` schema. To create or upgrade it:

1. Go to your [Supabase Dashboard](https://app.supabase.com)
2. Select your project
3. Click on **SQL Editor** in the left sidebar
4. Click **New Query**
5. Run every file in `supabase/migrations/` in filename order
6. Confirm the `cotime_book` schema is listed under **Data API → Exposed Schemas**

This Supabase project is shared by multiple apps. CoTime Book channels are already
private and protected by Realtime RLS. Do not change the project-wide **Allow public
access to channels** setting unless every app sharing the project has been audited.

### Room lifecycle maintenance

Room membership is changed only through the `create_room`, `join_room`, and
`leave_room` RPCs. Active clients should call `heartbeat_room` periodically; a
heartbeat extends the room lease for 24 hours. The app sends one every five minutes
while it is in the foreground. A member is stale after 30 minutes without a
heartbeat. Existing rooms and memberships receive one 24-hour grace window when
the migration is first applied, so deployed legacy clients are not evicted
immediately. Do not restore direct `DELETE` access on `cotime_book.room_members`,
because the RPC serializes concurrent leaves, stale-member eviction, and host
transfer on the parent room row.

The lifecycle maintenance function stays in the unexposed private schema and is
owned and invoked by the database Cron worker:

```sql
select cotime_book_private.cleanup_expired_rooms();
```

The migration enables Supabase Cron (`pg_cron`) and idempotently installs the
`cotime_book-room-lifecycle` job to run every ten minutes. The cleanup evicts stale
members, transfers the host to the earliest live member, closes empty or expired
rooms, hard-deletes rooms 30 days after closure, and permanently retains their
six-character codes in `cotime_book_private.room_code_reservations`.

Database lifecycle tests live in `supabase/tests/database/room_lifecycle.test.sql` and
run with `supabase test db` after applying migrations to a local Supabase database.

This will create:
- `rooms` - Stores reading rooms
- `room_members` - Tracks who is in each room
- `profiles` - User profile information
- Least-privilege grants and Row Level Security (RLS) policies
- Private Realtime Broadcast and Presence authorization

### Public library

The books are files in a pCloud public folder, set in `AppConstants.libraryUrl`
(`lib/config/app_constants.dart`). To add a book, put an `.epub` file in that
folder; the app lists the folder's page itself, so there is no storage quota in
Supabase to stay under. Files larger than 40MB (the app's limit) are not listed,
and only `.epub` files directly in the folder count: subfolders (for covers) and
notes are ignored. App users can only list and download.

The catalog the browser searches and filters by is `cotime_book.library_books`
(**Table Editor**), one row per file:

| Column | Example | Notes |
|--------|---------|-------|
| `path` | `pg1342-images-3.epub` | The file's name in the folder |
| `title` | `傲慢與偏見` | Shown on the shelf; any script |
| `original_title` | `Pride and Prejudice` | Optional; the published title when `title` is a translation. Searchable |
| `author` | `珍·奧斯汀` | Optional, searchable |
| `original_author` | `Jane Austen` | Optional, searchable |
| `language` | `en` | The language the book is written in, as a BCP 47 tag; `en`, `zh-Hant`, `zh-Hans`, `ja`… are shown by name |
| `tags` | `{愛情,文學經典}` | Any number; each distinct tag is a filter, the most used first |
| `cover_path` | `covers/pg1342.jpg` | Optional; an image in the folder (about 400px wide JPEG) or a full URL |

The help button next to the library's title shows `書籍來源聲明.txt`
(`AppConstants.libraryNoticeFile`) from the same folder: a plain UTF-8 text
file saying where the books come from. Edit it in the folder to change it.

The browser's tag filter takes any number of tags and shows the books that
carry any of them; a ribbon across each cover's top-left corner names the
book's language (`English`, `Chinese`).

`20261024054844_library_public_folder.sql` catalogues the books the folder
started with. A book without a row is still listed, titled by its file name
(`The_Time_Machine.epub` shows as "The Time Machine"), and only appears when no
tag or language filter is chosen. A row whose file is not in the folder shows
nothing.

The Storage bucket `cotime-book-library`, its `library_catalog` view and the
`category` column are what apps before 1.0.12 read; current apps do not use them.

### Direct book transfer (TURN)

Books a member shares from their device go device to device over WebRTC; the
room's Realtime channel only carries the connection details. Devices that cannot
reach each other connect through Cloudflare's managed TURN relay, which needs
short-lived credentials from the `turn-credentials` Edge Function:

1. In the Cloudflare dashboard, open **Realtime** → **TURN Server** and create a
   key. Note its key ID and API token.
2. Store them as function secrets and deploy the function:

   ```bash
   supabase secrets set CLOUDFLARE_TURN_KEY_ID=... CLOUDFLARE_TURN_API_TOKEN=...
   supabase functions deploy turn-credentials
   ```

3. Set a usage notification in Cloudflare. The first 1,000 GB a month are free.

The function only answers signed-in users who are in a room, and tells Cloudflare
nothing about who asked. Until it is deployed the app connects with STUN alone,
and a transfer that cannot connect falls back to Realtime as before.

### 2. Get Your Supabase Credentials

1. In your Supabase Dashboard, go to **Settings** → **API**
2. Copy your:
   - **Project URL** (looks like `https://xxxxx.supabase.co`)
   - **Anon/Public Key** (starts with `eyJxxx...`)

### 3. Run the App

Run the app with your Supabase credentials:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key-here
```

**Tip:** Create a `.env` file or a launch script to avoid typing this every time:

```bash
#!/bin/bash
# run.sh
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key-here
```

Then run: `chmod +x run.sh && ./run.sh`

## 📱 Features

- Create and join reading rooms with 6-character codes
- Collaborative reading with synchronized page positions
- Real-time updates when room members change pages
- Anonymous authentication (no sign-up required)
- EPUB book support (up to 40MB per book)
- A TXT to EPUB tool on the home screen (UTF-8, UTF-16, GBK or Big5; several files become one book): read the result on your own device, save it, then share the EPUB in a room
- A public library of open-source books any room can read, shown as a shelf of covers, searchable by title or author (translated or original) and filterable by tag and language

## 🛠️ Development

### Project Structure

```
lib/
├── config/          # App configuration (theme, Supabase)
├── models/          # Data models (Room, RoomMember, etc.)
├── providers/       # State management (Riverpod)
├── screens/         # UI screens
├── services/        # Backend services (Supabase)
└── widgets/         # Reusable UI components

supabase/
├── functions/       # Edge Functions (turn-credentials)
└── migrations/      # Database schema migrations
```

### Troubleshooting

**Error: "The schema must be one of the following: public"**
- Run the latest migration and reload the Data API configuration
- Confirm `cotime_book` is in **Data API → Exposed Schemas**

**Error: "relation 'cotime_book.rooms' does not exist"**
- You need to run the SQL migration file in Supabase (see step 1 above)

**Error: "Supabase not configured"**
- Make sure you're running the app with `--dart-define` flags (see step 3 above)

**Button not responding / No error messages**
- Check your internet connection
- Verify your Supabase credentials are correct
- Check the Supabase Dashboard for any API issues

### Publishing to Google Play

`.github/workflows/publish-play-store.yml` builds a signed AAB and uploads it to Google Play
(package `com.lazyrhythm.cotime_book`). Run it from **Actions → Publish to Google Play**.

Repository secrets it needs:

| Secret | Used for |
| --- | --- |
| `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS` | Upload-key signing |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Baked into the build via `--dart-define` |
| `SERVICE_ACCOUNT_JSON` | Play Developer API (service account with release permission on this app) |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Optional result notification |

Inputs:

- `track`: `internal` / `alpha` / `beta` / `production`
- `inAppUpdatePriority`: `5` forces an update, `0` doesn't
- `version_code`: overrides the build number from `pubspec.yaml`; every upload needs a new one
- `skip_build`: promote a version code that is already on Google Play to `track` without rebuilding
- `release_status`: `draft` until the app has passed its first review — Play rejects
  `completed` releases on a draft app
- `release_notes`: optional "What's new" text (≤500 characters, used for zh-TW and en-US)

The Play Developer API can't create an app: the first AAB must be uploaded by hand in Play
Console before this workflow can publish to it.

### Other CI settings

- `TEST_KEYSTORE_BASE64` / `TEST_KEYSTORE_PASSWORD` (secrets): used only by the manual
  **Test Signing Key** workflow, which checks that `KEYSTORE_BASE64` is the same key as
  another keystore (e.g. your local upload key) before you burn a version code on it.
- `CI_RUNNER` / `CI_LIGHT_RUNNER` (variables): runner labels for the main and the light
  (pgTAP) jobs; both default to `ubuntu-latest`.
- `SKIP_COMPILER` (variable): set to `true` to make Build Check run analyze and tests only,
  without building an APK.

Versioning, changelog and CI notes live in `.claude/skills/` (see `CLAUDE.md`).

## 📄 License

MIT License
