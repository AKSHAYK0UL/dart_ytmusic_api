import 'package:dart_ytmusic_api/parsers/album_parser.dart';
import 'package:dart_ytmusic_api/parsers/playlist_parser.dart';
import 'package:dart_ytmusic_api/parsers/song_parser.dart';
import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class Parser {
  static int? parseDuration(String? time) {
    if (time == null) return null;

    // Extract only the time portion using regex (format: H:MM:SS or MM:SS or M:SS)
    final timeMatch = RegExp(r'(\d+):(\d+)(?::(\d+))?').firstMatch(time);
    if (timeMatch == null) return null;

    // Parse the matched groups
    final parts = <int>[];
    for (int i = 1; i <= timeMatch.groupCount; i++) {
      final group = timeMatch.group(i);
      if (group != null) {
        parts.add(int.parse(group));
      }
    }

    if (parts.isEmpty) return null;

    // Handle different time formats
    if (parts.length == 2) {
      // MM:SS format
      final minutes = parts[0];
      final seconds = parts[1];
      return seconds + minutes * 60;
    } else if (parts.length == 3) {
      // H:MM:SS format
      final hours = parts[0];
      final minutes = parts[1];
      final seconds = parts[2];
      return seconds + minutes * 60 + hours * 60 * 60;
    }

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

  static HomeSection parseHomeSection(dynamic data) {
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
              // Unwrap musicTwoRowItemRenderer or musicResponsiveListItemRenderer if present
              final renderer = item.containsKey('musicTwoRowItemRenderer')
                  ? (item['musicTwoRowItemRenderer'] as Map)
                  : item.containsKey('musicResponsiveListItemRenderer')
                      ? (item['musicResponsiveListItemRenderer'] as Map)
                      : item;

              // 1. Direct pageType from InnerTube's browseEndpointContextSupportedConfigs
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

              // 2. BrowseId
              final browseId = (browseEpNav is Map
                      ? browseEpNav['browseId']?.toString()
                      : null) ??
                  traverseString(renderer,
                      ["navigationEndpoint", "browseEndpoint", "browseId"]) ??
                  traverseString(renderer,
                      ["title", "runs", "browseEndpoint", "browseId"]) ??
                  traverseString(renderer, ["browseId"]) ??
                  '';

              // 3. PlaylistId
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

              // 4. Subtitle text (e.g. "Album • Artist", "Single • Year", "EP • Year")
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
                    (navEpMap is Map &&
                        navEpMap['watchPlaylistEndpoint'] is Map &&
                        navEpMap['watchPlaylistEndpoint']['videoId'] != null) ||
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

  // Normalises a localised YT Music shelf title to a stable, locale-independent slug.
  static String _stableTitle(String raw) {
    final lower = raw.toLowerCase().trim();

    // Ordered from most-specific to least-specific so a phrase like
    // "new albums & singles" matches "new_releases" before "top_albums".
    const knownMappings = <String, String>{
      // Top picks / Quick picks
      'top pick': 'top_picks',
      'quick pick': 'top_picks',
      'recommended for you': 'recommended',
      'our picks': 'top_picks',

      // Trending / Charts
      'trending': 'trending',
      'chart': 'charts',
      'top song': 'trending',
      'top track': 'trending',
      'hot hit': 'trending',

      // New releases (before individual album/single checks)
      'new release': 'new_releases',
      'new album': 'new_releases',
      'new single': 'new_releases',
      'latest release': 'new_releases',

      // Albums
      'top album': 'top_albums',
      'album': 'top_albums',

      // Singles / EPs
      'top single': 'top_singles',
      'single': 'top_singles',
      ' ep': 'top_singles',

      // Videos
      'top video': 'top_videos',
      'music video': 'top_videos',
      'video': 'top_videos',

      // Personalised / mood
      'mixed for you': 'mixed_for_you',
      'mix for you': 'mixed_for_you',
      'your mix': 'mixed_for_you',
      'mood': 'moods_and_genres',
      'genre': 'moods_and_genres',
      'feel': 'moods_and_genres',

      // Artist / playlist mixes
      'artist mix': 'artist_mixes',
      'playlist mix': 'playlist_mixes',

      // Radio / station
      'radio': 'radio',

      // Podcasts
      'podcast': 'podcasts',
      'episode': 'podcasts',
    };

    for (final entry in knownMappings.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }

    // Fallback: convert raw title to snake_case
    return lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}
