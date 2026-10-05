# CoTime Book

A collaborative reading app built with Flutter and Supabase.

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

`supabase/migrations/20261004200000_public_library_bucket.sql` creates the public
Storage bucket `cotime-book-library` (40MB per file, the same limit as the app).
To add a book, upload an `.epub` file to that bucket from the Supabase Dashboard
(**Storage → cotime-book-library**); folders are fine. App users can list and
download books but cannot add, change, or remove them.

`supabase/migrations/20261005120000_library_catalog.sql` adds the catalog the
app's library browser searches and filters by. For each book, add a row to
`cotime_book.library_books` (**Table Editor**):

| Column | Example | Notes |
|--------|---------|-------|
| `path` | `classics/hongloumeng.epub` | The object's name in the bucket, folders included |
| `title` | `紅樓夢` | Any script; object names themselves only accept ASCII |
| `author` | `曹雪芹` | Optional |
| `language` | `zh-Hant` | Optional BCP 47 tag; `en`, `zh-Hant`, `zh-Hans`, `ja`… are shown by name |
| `category` | `Classics` | Optional; shown as written, one filter per distinct value |
| `cover_path` | `covers/hongloumeng.jpg` | Optional; an image in the same bucket (about 400px wide JPEG), added by `20261005130000_library_covers.sql` |

Upload covers to the `covers/` folder of the bucket; most EPUBs carry one
(the `cover-image` item in the book's OPF). A book without a cover shows a
plain jacket with its title.

A book without a row is still listed, titled by its file name
(`The_Time_Machine.epub` shows as "The Time Machine"), and only appears when no
category or language filter is chosen. The app reads `cotime_book.library_catalog`,
a view of the bucket joined with this table.

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
- A public library of open-source books any room can read, shown as a shelf of covers, searchable by title or author and filterable by category and language

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
