import 'package:dart_ytmusic_api/parsers/album_parser.dart';
import 'package:dart_ytmusic_api/parsers/playlist_parser.dart';
import 'package:dart_ytmusic_api/parsers/song_parser.dart';
import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class Parser {
  static int? parseDuration(String? time) {
    if (time == null) return null;

    final timeMatch = RegExp(r'(\d+):(\d+)(?::(\d+))?').firstMatch(time);
    if (timeMatch == null) return null;

    final parts = <int>[];
    for (int i = 1; i <= timeMatch.groupCount; i++) {
      final group = timeMatch.group(i);
      if (group != null) parts.add(int.parse(group));
    }

    if (parts.isEmpty) return null;
    if (parts.length == 2) return parts[1] + parts[0] * 60;
    if (parts.length == 3) return parts[2] + parts[1] * 60 + parts[0] * 3600;
    return null;
  }

  static double parseNumber(String string) {
    if (string.endsWith("K") ||
        string.endsWith("M") ||
        string.endsWith("B") ||
        string.endsWith("T")) {
      final number = double.parse(string.substring(0, string.length - 1));
      final multiplier = string.substring(string.length - 1);
      return {
            "K": number * 1000,
            "M": number * 1000 * 1000,
            "B": number * 1000 * 1000 * 1000,
            "T": number * 1000 * 1000 * 1000 * 1000,
          }[multiplier] ??
          double.nan;
    } else {
      return double.parse(string);
    }
  }

  // ─── Home section parser ──────────────────────────────────────────────────

  /// Parses one raw entry from sectionListRenderer.contents into a [HomeSection].
  ///
  /// Mirrors ytmusicapi's parse_mixed_content() logic exactly:
  ///  - musicCarouselShelfRenderer  → carousel of albums/playlists/songs/artists
  ///  - musicImmersiveCarouselShelfRenderer → same as carousel
  ///  - gridRenderer                → mood/genre grid
  ///  - musicDescriptionShelfRenderer → skip (description-only shelf)
  static HomeSection? parseHomeSection(dynamic data) {
    if (data is! Map) return null;

    // ── 1. Identify and unwrap the shelf renderer ────────────────────────
    Map? shelf;

    if (data.containsKey('musicCarouselShelfRenderer')) {
      shelf = data['musicCarouselShelfRenderer'] as Map?;
    } else if (data.containsKey('musicImmersiveCarouselShelfRenderer')) {
      shelf = data['musicImmersiveCarouselShelfRenderer'] as Map?;
    } else if (data.containsKey('gridRenderer')) {
      shelf = data['gridRenderer'] as Map?;
    } else if (data.containsKey('musicDescriptionShelfRenderer')) {
      // Skip text-only shelves — they contain no playable content
      return null;
    } else {
      // Could be a continuationItemRenderer or something unknown — skip
      return null;
    }

    if (shelf == null) return null;

    // ── 2. Extract the shelf title ───────────────────────────────────────
    // Carousel headers live at shelf.header.musicCarouselShelfBasicHeaderRenderer.title.runs[0].text
    // Grid headers live at shelf.header.gridHeaderRenderer.title.runs[0].text
    String title = '';

    final header = shelf['header'];
    if (header is Map) {
      // Try musicCarouselShelfBasicHeaderRenderer
      final carouselHeader = header['musicCarouselShelfBasicHeaderRenderer'];
      if (carouselHeader is Map) {
        title = _extractRunText(carouselHeader['title']) ??
            _extractRunText(carouselHeader['strapline']) ??
            '';
      }
      // Try gridHeaderRenderer
      final gridHeader = header['gridHeaderRenderer'];
      if (gridHeader is Map && title.isEmpty) {
        title = _extractRunText(gridHeader['title']) ?? '';
      }
      // Try musicCardShelfHeaderBasicRenderer
      final cardHeader = header['musicCardShelfHeaderBasicRenderer'];
      if (cardHeader is Map && title.isEmpty) {
        title = cardHeader['title']?.toString() ?? '';
      }
    }

    // ── 3. Extract raw item list ─────────────────────────────────────────
    // IMPORTANT: Access directly — do NOT use deep traversal here.
    // traverseList recurses into sub-maps and picks up nested "contents" nodes.
    final rawItems = <dynamic>[];
    final contentsRaw = shelf['contents'];
    if (contentsRaw is List) {
      for (final item in contentsRaw) {
        // Skip continuationItemRenderer entries
        if (item is Map && item.containsKey('continuationItemRenderer')) continue;
        rawItems.add(item);
      }
    }
    // gridRenderer uses "items" instead of "contents"
    final itemsRaw = shelf['items'];
    if (itemsRaw is List) {
      for (final item in itemsRaw) {
        if (item is Map && item.containsKey('continuationItemRenderer')) continue;
        rawItems.add(item);
      }
    }

    // ── 4. Parse each item ───────────────────────────────────────────────
    final contents = <dynamic>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      try {
        final parsed = _parseHomeSectionItem(raw);
        if (parsed != null) contents.add(parsed);
      } catch (_) {
        // Never let a single bad item crash the whole section
      }
    }

    if (contents.isEmpty) return null;

    return HomeSection(
      title: title,
      stableTitle: _stableTitle(title),
      contents: contents,
    );
  }

  /// Parses one item inside a home-page carousel/grid.
  ///
  /// ytmusicapi logic (parse_mixed_content inner loop):
  ///  musicTwoRowItemRenderer:
  ///    page_type = title.runs[0].navigationEndpoint.browseEndpoint.pageType
  ///    if page_type is None:
  ///      if watchPlaylistEndpoint → watch_playlist (PlaylistDetailed)
  ///      elif videoId             → song (SongDetailed)
  ///    elif ALBUM / AUDIOBOOK     → AlbumDetailed
  ///    elif ARTIST                → skip (artist cards — no content to play)
  ///    elif PLAYLIST              → PlaylistDetailed
  ///  musicResponsiveListItemRenderer → SongDetailed (song_flat)
  static dynamic _parseHomeSectionItem(Map raw) {
    // ── musicTwoRowItemRenderer (main home page card format) ─────────────
    final mtrir = raw['musicTwoRowItemRenderer'];
    if (mtrir is Map) {
      return _parseMusicTwoRowItem(mtrir);
    }

    // ── musicResponsiveListItemRenderer (list-style items) ───────────────
    final mrlir = raw['musicResponsiveListItemRenderer'];
    if (mrlir is Map) {
      return SongParser.parseHomeSection(mrlir);
    }

    // ── musicMultiRowListItemRenderer ─────────────────────────────────────
    final mmrir = raw['musicMultiRowListItemRenderer'];
    if (mmrir is Map) {
      // Treat as a song/episode — delegate to song parser
      return SongParser.parseHomeSection(mmrir);
    }

    return null;
  }

  /// Parses a musicTwoRowItemRenderer map following ytmusicapi's exact logic.
  static dynamic _parseMusicTwoRowItem(Map data) {
    // ── Determine pageType from title.runs[0].navigationEndpoint ─────────
    String? pageType;
    final titleRuns = _getList(data['title'], 'runs');
    if (titleRuns.isNotEmpty && titleRuns[0] is Map) {
      final firstRun = titleRuns[0] as Map;
      pageType = _deepGet(firstRun, [
        'navigationEndpoint',
        'browseEndpoint',
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ])?.toString();
    }

    // Also try navigationEndpoint directly on the renderer
    if (pageType == null) {
      pageType = _deepGet(data, [
        'navigationEndpoint',
        'browseEndpoint',
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ])?.toString();
    }

    // ── Route by pageType ─────────────────────────────────────────────────
    if (pageType == null) {
      // No browse pageType — check for watchPlaylistEndpoint (playlist/mix) or videoId (song)
      final watchPlaylistId = _deepGet(data, [
            'navigationEndpoint',
            'watchPlaylistEndpoint',
            'playlistId',
          ])?.toString() ??
          _deepGet(data, [
            'navigationEndpoint',
            'watchEndpoint',
            'playlistId',
          ])?.toString();

      if (watchPlaylistId != null && watchPlaylistId.isNotEmpty) {
        return _parseTwoRowAsPlaylist(data, watchPlaylistId);
      }

      final videoId = _deepGet(data, [
        'navigationEndpoint',
        'watchEndpoint',
        'videoId',
      ])?.toString();
      if (videoId != null && videoId.isNotEmpty) {
        return _parseTwoRowAsSong(data, videoId);
      }

      // No playable endpoint found — skip
      return null;
    }

    if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
        pageType == 'MUSIC_PAGE_TYPE_AUDIOBOOK' ||
        pageType == 'MUSIC_PAGE_TYPE_ALBUM_RELEASE_DETAIL') {
      return AlbumParser.parseHomeSection(data);
    }

    if (pageType == 'MUSIC_PAGE_TYPE_PLAYLIST') {
      return PlaylistParser.parseHomeSection(data);
    }

    if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
        pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
      // Artist cards appear in "Similar artists" — not playable content,
      // skip them on the home page to keep contents homogeneous
      return null;
    }

    if (pageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE') {
      // Treat podcasts as playlists (they have a browseId)
      return PlaylistParser.parseHomeSection(data);
    }

    // Unknown pageType — skip
    return null;
  }

  /// Parses a musicTwoRowItemRenderer as a PlaylistDetailed.
  static PlaylistDetailed _parseTwoRowAsPlaylist(Map data, String playlistId) {
    final name = _extractRunText(data['title']) ?? '';

    // Artist / author from subtitle runs — first run with a navigationEndpoint
    final subtitleRuns = _getList(data['subtitle'], 'runs');
    dynamic artistRun = subtitleRuns.firstWhere(
      (r) => r is Map && r.containsKey('navigationEndpoint'),
      orElse: () => subtitleRuns.isNotEmpty ? subtitleRuns.first : null,
    );

    return PlaylistDetailed(
      type: 'PLAYLIST',
      playlistId: playlistId,
      name: name,
      artist: ArtistBasic(
        name: artistRun is Map ? (artistRun['text']?.toString() ?? '') : '',
        artistId: artistRun is Map
            ? _deepGet(artistRun, [
                'navigationEndpoint',
                'browseEndpoint',
                'browseId',
              ])?.toString()
            : null,
      ),
      thumbnails: _extractTwoRowThumbnails(data),
    );
  }

  /// Parses a musicTwoRowItemRenderer as a SongDetailed.
  static SongDetailed _parseTwoRowAsSong(Map data, String videoId) {
    final name = _extractRunText(data['title']) ?? '';

    final subtitleRuns = _getList(data['subtitle'], 'runs');
    // First run with navigationEndpoint is the artist
    dynamic artistRun = subtitleRuns.firstWhere(
      (r) => r is Map && r.containsKey('navigationEndpoint'),
      orElse: () => subtitleRuns.isNotEmpty ? subtitleRuns.first : null,
    );
    // Album is a run with browseEndpoint pointing to an MPREb_ or OLAK id
    dynamic albumRun;
    for (final r in subtitleRuns) {
      if (r is Map && r.containsKey('navigationEndpoint')) {
        final bId = _deepGet(r, ['navigationEndpoint', 'browseEndpoint', 'browseId'])?.toString() ?? '';
        if (bId.startsWith('MPREb_') || bId.startsWith('OLAK')) {
          albumRun = r;
          break;
        }
      }
    }

    return SongDetailed(
      type: 'SONG',
      videoId: videoId,
      name: name,
      artist: ArtistBasic(
        name: artistRun is Map ? (artistRun['text']?.toString() ?? '') : '',
        artistId: artistRun is Map
            ? _deepGet(artistRun, ['navigationEndpoint', 'browseEndpoint', 'browseId'])?.toString()
            : null,
      ),
      album: albumRun is Map
          ? AlbumBasic(
              name: albumRun['text']?.toString() ?? '',
              albumId: _deepGet(albumRun, ['navigationEndpoint', 'browseEndpoint', 'browseId'])?.toString() ?? '',
            )
          : null,
      duration: null, // not available in home page cards
      thumbnails: _extractTwoRowThumbnails(data),
    );
  }

  // ─── Shared helpers ───────────────────────────────────────────────────────

  /// Extracts thumbnails from a musicTwoRowItemRenderer following ytmusicapi's
  /// THUMBNAIL_RENDERER path:
  ///   thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails
  static List<ThumbnailFull> _extractTwoRowThumbnails(Map data) {
    // Primary path (most musicTwoRowItemRenderer items)
    final renderer = data['thumbnailRenderer'];
    if (renderer is Map) {
      final mtr = renderer['musicThumbnailRenderer'];
      if (mtr is Map) {
        final thumb = mtr['thumbnail'];
        if (thumb is Map) {
          final thumbs = thumb['thumbnails'];
          if (thumbs is List) return _thumbsFromList(thumbs);
        }
      }
    }

    // Fallback: thumbnail.musicThumbnailRenderer.thumbnail.thumbnails
    final thumb2 = data['thumbnail'];
    if (thumb2 is Map) {
      final mtr2 = thumb2['musicThumbnailRenderer'];
      if (mtr2 is Map) {
        final t = mtr2['thumbnail'];
        if (t is Map) {
          final thumbs = t['thumbnails'];
          if (thumbs is List) return _thumbsFromList(thumbs);
        }
      }
      // Direct thumbnails array (older format)
      final directThumbs = thumb2['thumbnails'];
      if (directThumbs is List) return _thumbsFromList(directThumbs);
    }

    // Last resort: croppedSquareThumbnailRenderer
    final cropped = data['thumbnail'];
    if (cropped is Map) {
      final cst = cropped['croppedSquareThumbnailRenderer'];
      if (cst is Map) {
        final thumbs = cst['thumbnail']?['thumbnails'];
        if (thumbs is List) return _thumbsFromList(thumbs);
      }
    }

    return const [];
  }

  static List<ThumbnailFull> _thumbsFromList(List thumbs) {
    return thumbs.whereType<Map>().map((t) => ThumbnailFull(
      url: t['url']?.toString() ?? '',
      width: (t['width'] as num?)?.toInt() ?? 0,
      height: (t['height'] as num?)?.toInt() ?? 0,
    )).toList();
  }

  /// Safely gets a nested value by explicit key path. No recursion.
  static dynamic _deepGet(dynamic root, List<String> keys) {
    dynamic current = root;
    for (final key in keys) {
      if (current is Map) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Gets a List from an object's named key. Returns [] if missing or wrong type.
  static List<dynamic> _getList(dynamic obj, String key) {
    if (obj is Map) {
      final v = obj[key];
      if (v is List) return v;
    }
    return const [];
  }

  /// Extracts text from a title/strapline object that has a runs[] array.
  static String? _extractRunText(dynamic obj) {
    if (obj is Map) {
      final runs = obj['runs'];
      if (runs is List && runs.isNotEmpty && runs[0] is Map) {
        return runs[0]['text']?.toString();
      }
      // Some objects just have a plain "text" field
      final text = obj['text'];
      if (text is String && text.isNotEmpty) return text;
    }
    if (obj is String && obj.isNotEmpty) return obj;
    return null;
  }

  // ─── Legacy home section parser (kept for getHomeSections()) ─────────────

  static HomeSection parseHomeSectionLegacy(dynamic data) {
    final shelf =
        (data is Map && data.containsKey('musicCarouselShelfRenderer'))
            ? data['musicCarouselShelfRenderer']
            : (data is Map && data.containsKey('gridRenderer'))
                ? data['gridRenderer']
                : data;

    final title = traverseString(shelf, ["header", "title", "runs", "text"]) ??
        traverseString(shelf, ["header", "title", "text"]) ??
        traverseString(shelf, ["header", "runs", "text"]) ??
        traverseString(shelf, ["title", "runs", "text"]) ??
        traverseString(shelf, ["title", "text"]) ??
        '';

    final shelfPageType = traverseString(
            shelf, ["header", "title", "browseEndpoint", "pageType"]) ??
        traverseString(shelf,
            ["header", "moreContentButton", "browseEndpoint", "pageType"]);

    final titleLower = title.toLowerCase();
    final shelfIsAlbum = shelfPageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
        shelfPageType == 'MUSIC_PAGE_TYPE_ALBUM_RELEASE_DETAIL' ||
        titleLower.contains('album') ||
        titleLower.contains('release');

    final shelfIsPlaylist = shelfPageType == 'MUSIC_PAGE_TYPE_PLAYLIST' ||
        titleLower.contains('playlist');

    final rawContents = [
      ...traverseList(shelf, ["contents"]),
      ...traverseList(shelf, ["items"]),
    ];

    return HomeSection(
      title: title,
      stableTitle: _stableTitle(title),
      contents: rawContents
          .map((item) {
            if (item is! Map) return null;
            try {
              final renderer = item.containsKey('musicTwoRowItemRenderer')
                  ? (item['musicTwoRowItemRenderer'] as Map)
                  : item.containsKey('musicResponsiveListItemRenderer')
                      ? (item['musicResponsiveListItemRenderer'] as Map)
                      : item;
              final navEndpoint = renderer['navigationEndpoint'];
              final titleNavEp = (renderer['title'] is Map &&
                      renderer['title']['runs'] is List &&
                      renderer['title']['runs'].isNotEmpty &&
                      renderer['title']['runs'][0] is Map)
                  ? renderer['title']['runs'][0]['navigationEndpoint']
                  : null;
              final effectiveNav = (navEndpoint is Map &&
                      navEndpoint.containsKey('browseEndpoint'))
                  ? navEndpoint
                  : (titleNavEp is Map &&
                          titleNavEp.containsKey('browseEndpoint')
                      ? titleNavEp
                      : navEndpoint);
              final browseEpNav =
                  effectiveNav is Map ? effectiveNav['browseEndpoint'] : null;
              final contextConfigs = browseEpNav is Map
                  ? browseEpNav['browseEndpointContextSupportedConfigs']
                  : null;
              final musicConfig = contextConfigs is Map
                  ? contextConfigs['browseEndpointContextMusicConfig']
                  : null;
              final itemPageType = musicConfig is Map
                  ? musicConfig['pageType']?.toString()
                  : traverseString(renderer, ["pageType"]);
              final browseId = (browseEpNav is Map
                      ? browseEpNav['browseId']?.toString()
                      : null) ??
                  traverseString(renderer,
                      ["navigationEndpoint", "browseEndpoint", "browseId"]) ??
                  traverseString(renderer,
                      ["title", "runs", "browseEndpoint", "browseId"]) ??
                  traverseString(renderer, ["browseId"]) ??
                  '';
              final navEpMap = renderer['navigationEndpoint'];
              final playlistId = ((navEpMap is Map &&
                      navEpMap['watchPlaylistEndpoint'] is Map)
                  ? navEpMap['watchPlaylistEndpoint']['playlistId']?.toString()
                  : (traverseString(
                          renderer, ["watchPlaylistEndpoint", "playlistId"]) ??
                      traverseString(
                          renderer, ["thumbnailOverlay", "playlistId"]) ??
                      traverseString(renderer, ["playlistId"]))) ??
                  '';
              final subtitleRuns = renderer['subtitle'] is Map
                  ? (renderer['subtitle']['runs'] as List? ?? [])
                  : traverseList(renderer, ["subtitle", "runs"]);
              final subtitleText = subtitleRuns
                  .map((r) =>
                      r is Map ? (r['text']?.toString() ?? '') : r.toString())
                  .join(' ')
                  .toLowerCase();
              final isItemAlbum = itemPageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
                  itemPageType == 'MUSIC_PAGE_TYPE_ALBUM_RELEASE_DETAIL' ||
                  browseId.startsWith('MPREb_') ||
                  browseId.startsWith('OLAK') ||
                  playlistId.startsWith('OLAK') ||
                  playlistId.startsWith('MPREb_') ||
                  subtitleText.contains('album') ||
                  subtitleText.contains('single') ||
                  subtitleText.contains(' ep') ||
                  subtitleText.startsWith('ep') ||
                  (shelfIsAlbum &&
                      !subtitleText.contains('playlist') &&
                      !browseId.startsWith('VLPL') &&
                      !browseId.startsWith('PL') &&
                      !playlistId.startsWith('PL') &&
                      !playlistId.startsWith('VLPL'));
              final isItemPlaylist =
                  itemPageType == 'MUSIC_PAGE_TYPE_PLAYLIST' ||
                      browseId.startsWith('VLPL') ||
                      browseId.startsWith('PL') ||
                      browseId.startsWith('VLRD') ||
                      browseId.startsWith('RD') ||
                      playlistId.startsWith('PL') ||
                      playlistId.startsWith('RD') ||
                      subtitleText.contains('playlist') ||
                      (shelfIsPlaylist && !isItemAlbum);
              if (isItemAlbum) {
                return AlbumParser.parseHomeSection(renderer);
              } else if (isItemPlaylist) {
                return PlaylistParser.parseHomeSection(renderer);
              } else {
                final hasVideoId = (navEpMap is Map &&
                        navEpMap['watchEndpoint'] is Map &&
                        navEpMap['watchEndpoint']['videoId'] != null) ||
                    traverseString(renderer, ["videoId"]) != null;
                if (hasVideoId && playlistId.isEmpty) {
                  return SongParser.parseHomeSection(renderer);
                } else if (playlistId.isNotEmpty) {
                  return PlaylistParser.parseHomeSection(renderer);
                } else {
                  return SongParser.parseHomeSection(renderer);
                }
              }
            } catch (_) {
              return null;
            }
          })
          .where((element) => element != null)
          .cast<dynamic>()
          .toList(),
    );
  }

  // ─── stableTitle mapping ──────────────────────────────────────────────────

  static String _stableTitle(String raw) {
    final lower = raw.toLowerCase().trim();

    const knownMappings = <String, String>{
      'top pick': 'top_picks',
      'quick pick': 'top_picks',
      'recommended for you': 'recommended',
      'our picks': 'top_picks',
      'trending': 'trending',
      // Global hits / charts — must come before the generic 'chart' key
      'top global hits': 'global_hits',
      'global chart': 'global_charts',
      'chart': 'charts',
      'top song': 'trending',
      'top track': 'trending',
      'hot hit': 'trending',
      'new release': 'new_releases',
      'new album': 'new_releases',
      'new single': 'new_releases',
      'latest release': 'new_releases',
      'top album': 'top_albums',
      'album': 'top_albums',
      'top single': 'top_singles',
      'single': 'top_singles',
      ' ep': 'top_singles',
      'top video': 'top_videos',
      'music video': 'top_videos',
      'video': 'top_videos',
      'mixed for you': 'mixed_for_you',
      'mix for you': 'mixed_for_you',
      'your mix': 'mixed_for_you',
      // Pop/mood/feel-good — specific keys first
      "today's pop hits": 'pop_hits',
      'pop hit': 'pop_hits',
      'feeling happy': 'feel_good',
      'feel-good': 'feel_good',
      'mood': 'moods_and_genres',
      'genre': 'moods_and_genres',
      'feel': 'moods_and_genres',
      'artist mix': 'artist_mixes',
      'playlist mix': 'playlist_mixes',
      'radio': 'radio',
      'podcast': 'podcasts',
      'episode': 'podcasts',
    };

    for (final entry in knownMappings.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }

    return lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}
