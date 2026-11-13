# XtreamTV: Google TV Xtream Codes Player

Date: 2026-08-29
Status: approved in chat, pending spec review

## Purpose

A sideloaded Android TV app for a Chromecast with Google TV that plays the owner's Xtream Codes IPTV subscription: live TV, movies (VOD), and series, all searchable and playable with the remote.

## Constraints

- Single user, single provider, credentials already in hand.
- Sideload-only distribution (adb over Wi-Fi). No Play Store, no signing ceremony beyond debug keys for now.
- Text entry on a TV remote is painful: credentials ship in a build-time config file, never typed on screen and never committed.
- Toolchain fixed by what the Mac has: Java 17, compileSdk 33, AGP 7.4.2, Gradle 7.6.4 wrapper.

## Architecture

Three layers inside one `app` module. Small app; no multi-module ceremony.

### 1. Data layer (`data/`)

- `XtreamApi`: Retrofit interface for the provider's `player_api.php`:
  - `get_live_categories`, `get_live_streams`
  - `get_vod_categories`, `get_vod_streams`
  - `get_series_categories`, `get_series`, `get_series_info` (episodes)
- `XtreamRepository`: fetches all catalogs once at app start, holds them in memory, exposes:
  - `liveChannels`, `movies`, `seriesList` (each with category grouping)
  - `search(query)`: case-insensitive name match across all three catalogs
  - `streamUrl(item)`: builds playback URLs in the Xtream convention:
    - live: `{server}/live/{user}/{pass}/{stream_id}.ts`
    - vod: `{server}/movie/{user}/{pass}/{stream_id}.{ext}`
    - series episode: `{server}/series/{user}/{pass}/{episode_id}.{ext}`
- Credentials: read from `BuildConfig` fields injected from `xtream.properties` at the repo root (gitignored). Keys: `XTREAM_SERVER`, `XTREAM_USER`, `XTREAM_PASS`. Missing file fails the build with a clear message.

### 2. UI layer (`ui/`)

Jetpack Compose for TV (`androidx.tv:tv-foundation`, `tv-material`). D-pad-first navigation.

- `HomeScreen`: top tab row [Live, Movies, Series, Search]. Below it, category rows of cards (channel name/logo for live; poster + title for VOD/series). Focus follows D-pad; OK plays (or opens episode list for series).
- `SearchScreen`: text field (on-screen keyboard) filtering all catalogs as you type; results grouped Live / Movies / Series.
- `SeriesDetailScreen`: seasons and episode list; OK on an episode plays it.
- `ErrorScreen`: shown when catalog fetch fails (bad credentials, provider down) with a Retry action and the underlying error text.

### 3. Player (`player/`)

- `PlayerActivity`: full-screen Media3 ExoPlayer.
- Live `.ts` streams and HLS play via ExoPlayer's TS/HLS extractors; VOD MP4/MKV via progressive source. Container is inferred from the URL; ExoPlayer sniffing covers the rest.
- Remote mapping: OK toggles play/pause and controls overlay; Back exits to browse; channel up/down (or D-pad up/down) switches to next/previous live channel within the current category; left/right seeks in VOD.

## Data flow

App start -> repository fetches the three catalogs in parallel -> home renders from memory. No local database in v1: catalogs re-fetch each app start (they change rarely and fetch in a few seconds). If that startup wait annoys, v2 adds a disk cache.

## Error handling

- Catalog fetch failure -> ErrorScreen with retry.
- Playback failure -> in-player message with the ExoPlayer error, Back returns to browse.
- Timeouts: 15s connect/read on API calls.

## Testing

- Unit tests: `streamUrl` construction, search filtering, API response parsing against canned JSON fixtures.
- Device verification: install to the Chromecast, confirm one live channel, one movie, one episode plays, and search finds a known channel.
- No UI test framework in v1.

## Out of scope (v1)

EPG (program guide), favorites, multi-profile, catch-up/timeshift, disk caching, parental controls, Play Store distribution.
