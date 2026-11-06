# Dart YouTube Music API

An unofficial YouTube Music API for Dart and Flutter. Search songs, albums, artists and playlists, retrieve detailed information, get a personalised home feed, and report playback so recommendations stay up to date.

> **Note:** This package is ported from [ts-npm-ytmusic-api](https://github.com/zS1L3NT/ts-npm-ytmusic-api). Credits to the original author.

---

## Installation

**Flutter**
```bash
flutter pub add dart_ytmusic_api
```

**Dart**
```bash
dart pub add dart_ytmusic_api
```

**pubspec.yaml**
```yaml
dependencies:
  dart_ytmusic_api: ^1.4.0
```

---

## Quick start

```dart
import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';

void main() async {
  // Basic — no API key needed for most features
  final ytmusic = YTMusic();
  await ytmusic.initialize();

  // With a YouTube Data API v3 key (only needed for getPlaylistVideos fallback)
  final ytmusic = YTMusic(apiKey: 'YOUR_YOUTUBE_DATA_API_KEY');
  await ytmusic.initialize();

  final songs = await ytmusic.searchSongs('Blinding Lights');
}
```

---

## Authentication & personalisation

Passing cookies from a logged-in YT Music session activates a personalised home feed and enables playback reporting so recommendations evolve as the user listens.

```dart
// Pass cookies from a WebView YT Music login
final ytmusic = YTMusic(apiKey: 'YOUR_KEY');
await ytmusic.initialize(cookies: cookieString);

print(ytmusic.isAuthenticated); // true
```

> **Flutter app tip:** Use `flutter_inappwebview` to open `music.youtube.com`, let the user sign in, then extract cookies from the WebView cookie store and pass them here. Store them with `flutter_secure_storage` — they stay valid for ~2 years.

---

## API reference

### Constructor

```dart
YTMusic({String? apiKey})
```

| Parameter | Description |
|---|---|
| `apiKey` | YouTube Data API v3 key. Only required as a fallback for `getPlaylistVideos` on non-music playlists. |

---

### Initialization

#### `initialize`
```dart
Future<YTMusic> initialize({
  String? cookies,
  String? gl,
  String? hl,
  String? dataApiKey,
})
```

| Parameter | Description |
|---|---|
| `cookies` | Cookie string from a logged-in `music.youtube.com` session. Enables personalised home feed and playback reporting. |
| `gl` | ISO 3166-1 country code (e.g. `"US"`, `"IN"`). Sets the default region for all requests. |
| `hl` | BCP-47 language code (e.g. `"en"`, `"hi"`). Sets the response language. |
| `dataApiKey` | YouTube Data API v3 key. Overrides the key passed to the constructor. |

#### `isAuthenticated`
```dart
bool get isAuthenticated
```
Returns `true` when auth cookies are loaded. Use this to decide whether to show a personalised or generic home feed in your UI.

---

### Home feed

#### `getHome`
```dart
Future<List<HomeSection>> getHome({String? country})
```

Returns the full YT Music home page as a list of `HomeSection` objects — Top picks, Trending, New releases, Top albums, Moods & genres, and more.

- When **not authenticated**, returns a regional/trending feed.
- When **authenticated** (cookies provided), returns the user's personalised feed — Quick picks, Listen again, Mixed for you, Recommended albums, etc.
- `country` accepts an ISO 3166-1 alpha-2 code (`"US"`, `"IN"`, `"GB"`, `"JP"`) or `"global"`. Temporarily overrides the session's GL for this call only.

```dart
// Generic feed
final sections = await ytmusic.getHome();

// Country-specific
final sections = await ytmusic.getHome(country: 'IN');

// Personalised (requires cookies)
final sections = await ytmusic.getHome();
```

**`HomeSection`**

| Field | Type | Description |
|---|---|---|
| `title` | `String` | Localised display title — e.g. `"Top picks"` |
| `stableTitle` | `String` | Locale-independent slug for programmatic matching — e.g. `"top_picks"` |
| `contents` | `List<dynamic>` | Items: `AlbumDetailed`, `PlaylistDetailed`, or `SongDetailed` |

**Known `stableTitle` values**

| `stableTitle` | Typical `title` |
|---|---|
| `top_picks` | "Top picks" / "Quick picks" |
| `trending` | "Trending" |
| `new_releases` | "New albums & singles" |
| `top_albums` | "Top albums" |
| `top_singles` | "Top singles" |
| `top_videos` | "Top music videos" |
| `mixed_for_you` | "Mixed for you" |
| `charts` | "Charts" |
| `moods_and_genres` | "Moods & genres" |
| `recommended` | "Recommended albums" |
| `radio` | "Radio" |

```dart
// Iterate sections
for (final section in sections) {
  print('${section.title} [${section.stableTitle}]');

  for (final item in section.contents) {
    if (item is AlbumDetailed) {
      print('  ALBUM: ${item.name} · ${item.artist.name} (${item.year})');
    } else if (item is PlaylistDetailed) {
      print('  PLAYLIST: ${item.name} · ${item.artist.name}');
    } else if (item is SongDetailed) {
      print('  SONG: ${item.name} · ${item.artist.name}');
    }
  }
}

// Filter by stableTitle
final topPicks = sections.firstWhere(
  (s) => s.stableTitle == 'top_picks',
  orElse: () => null,
);
```

#### `getHomeSections` *(legacy)*
```dart
Future<List<HomeSection>> getHomeSections()
```
Original home sections method. Kept for backwards compatibility. Prefer `getHome()` for new code.

---

### Playback reporting

#### `reportPlayback`
```dart
Future<void> reportPlayback({
  required String videoId,
  required int songDuration,
  int? listenedSeconds,
})
```

Sends a watchtime ping to YouTube's servers so the user's listening activity in your app updates their recommendation model. Call this when a song finishes or the user skips.

- Does nothing if `isAuthenticated` is `false`.
- Errors are silently swallowed — a failed ping never interrupts playback.
- Recommendations reflect reported plays after Google's daily model refresh (~24 hours).

| Parameter | Description |
|---|---|
| `videoId` | The song's YouTube videoId |
| `songDuration` | Full duration of the song in seconds |
| `listenedSeconds` | How long the user actually listened. Defaults to `songDuration` (full listen). Pass a lower value if they skipped early. |

```dart
// Song finished naturally
audioPlayer.onPlayerComplete.listen((_) async {
  await ytmusic.reportPlayback(
    videoId: currentSong.videoId,
    songDuration: currentSong.duration,
  );
});

// User skipped — report how far they got
void onSkip() async {
  await ytmusic.reportPlayback(
    videoId: currentSong.videoId,
    songDuration: currentSong.duration,
    listenedSeconds: audioPlayer.position.inSeconds,
  );
}
```

> **How personalisation works:** Once authenticated, every `reportPlayback()` call tells Google "this account listened to this song". Google's recommendation engine uses this to update the home feed. A new account typically starts seeing personalised results after 10–20 songs, with a fully personalised feed after 50+ songs.

---

### Search

```dart
Future<List<String>>         getSearchSuggestions(String query)
Future<List<SearchResult>>   search(String query)
Future<List<SongDetailed>>   searchSongs(String query)
Future<List<VideoDetailed>>  searchVideos(String query)
Future<List<ArtistDetailed>> searchArtists(String query)
Future<List<AlbumDetailed>>  searchAlbums(String query)
Future<List<PlaylistDetailed>> searchPlaylists(String query)
```

---

### Songs & videos

```dart
Future<SongFull>  getSong(String videoId)
Future<VideoFull> getVideo(String videoId)
Future<String?>   getLyrics(String videoId)
Future<TimedLyricsRes?> getTimedLyrics(String videoId)
Future<List<UpNextsDetails>> getUpNexts(String videoId)
```

---

### Artists

```dart
Future<ArtistFull>           getArtist(String artistId)
Future<List<SongDetailed>>   getArtistSongs(String artistId)
Future<List<AlbumDetailed>>  getArtistAlbums(String artistId)
Future<List<AlbumDetailed>>  getArtistSingles(String artistId)
```

---

### Albums & playlists

```dart
Future<AlbumFull>            getAlbum(String albumId)
Future<PlaylistFull>         getPlaylist(String playlistId)
Future<List<VideoDetailed>>  getPlaylistVideos(String playlistId)
```

`getPlaylistVideos` uses a fast internal browse endpoint and falls back to the YouTube Data API v3 (`apiKey` required) for non-music YouTube playlists.

---

## Personalised home — Flutter integration example

```dart
class MusicService {
  late final YTMusic _client;

  Future<void> init({String? cookies}) async {
    _client = YTMusic(apiKey: 'YOUR_KEY');
    await _client.initialize(cookies: cookies);
  }

  bool get isConnected => _client.isAuthenticated;

  Future<List<HomeSection>> getHome() => _client.getHome();

  Future<void> onSongFinished(SongDetailed song) =>
      _client.reportPlayback(
        videoId: song.videoId,
        songDuration: song.duration ?? 0,
      );
}
```

---

## Contributing

Contributions are welcome. Feel free to open issues or submit pull requests.

## License

GNU General Public License v3. See the [LICENSE](LICENSE) file for details.
