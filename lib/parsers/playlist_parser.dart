import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/filters.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class PlaylistParser {
  static PlaylistFull parse(dynamic data, String playlistId) {
    final artist = traverse(data, ["tabs", "straplineTextOne"]);

    return PlaylistFull(
      type: "PLAYLIST",
      playlistId: playlistId,
      name: traverseString(data, ["tabs", "title", "text"]) ?? '',
      artist: ArtistBasic(
        name: traverseString(artist, ["text"]) ?? '',
        artistId: traverseString(artist, ["browseId"]),
      ),
      videoCount: () {
        final list = traverseList(data, ["tabs", "secondSubtitle", "text"]);
        for (final item in list) {
          final str = item?.toString() ?? '';
          final match =
              RegExp(r'([\d,]+)\s*(?:songs?|tracks?|videos?)').firstMatch(str);
          if (match != null) {
            return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
          }
        }
        if (list.length > 2) {
          return int.tryParse(
                  list[2].toString().split(" ").first.replaceAll(",", "")) ??
              0;
        }
        return 0;
      }(),
      thumbnails: traverseList(data, ["tabs", "thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static PlaylistDetailed parseSearchResult(dynamic item) {
    final columns = traverseList(item, ["flexColumns", "runs"])
        .expand((e) => e is List ? e : [e])
        .toList();

    // No specific way to identify the title
    final title = columns[0];
    final artist = columns.firstWhere(
      isArtist,
      orElse: () => columns.length > 2
          ? columns[3]
          : AlbumBasic(
              albumId: '',
              name: '',
            ),
    );

    return PlaylistDetailed(
      type: "PLAYLIST",
      playlistId: traverseString(item, ["overlay", "playlistId"]) ?? '',
      name: traverseString(title, ["text"]) ?? '',
      artist: ArtistBasic(
        name: traverseString(artist, ["text"]) ?? '',
        artistId: traverseString(artist, ["browseId"]),
      ),
      thumbnails: traverseList(item, ["thumbnails"])
          .whereType<Map>()
          .map((thumb) => ThumbnailFull(
                url: thumb['url']?.toString() ?? '',
                width: (thumb['width'] as num?)?.toInt() ?? 0,
                height: (thumb['height'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
    );
  }

  static PlaylistDetailed parseArtistFeaturedOn(
      dynamic item, ArtistBasic artistBasic) {
    return PlaylistDetailed(
      type: "PLAYLIST",
      playlistId:
          traverseString(item, ["navigationEndpoint", "browseId"]) ?? '',
      name: traverseString(item, ["runs", "text"]) ?? '',
      artist: artistBasic,
      thumbnails: traverseList(item, ["thumbnails"])
          .whereType<Map>()
          .map((thumb) => ThumbnailFull(
                url: thumb['url']?.toString() ?? '',
                width: (thumb['width'] as num?)?.toInt() ?? 0,
                height: (thumb['height'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
    );
  }

  static PlaylistDetailed parseHomeSection(dynamic item) {
    final artistRuns = traverseList(item, ["subtitle", "runs"]);
    final artist = artistRuns.firstWhere(
      (r) => r is Map && r.containsKey('navigationEndpoint'),
      orElse: () => artistRuns.isNotEmpty ? artistRuns.first : null,
    );

    final playlistId = traverseString(item,
            ["navigationEndpoint", "watchPlaylistEndpoint", "playlistId"]) ??
        traverseString(item, ["navigationEndpoint", "playlistId"]) ??
        traverseString(item, ["thumbnailOverlay", "playlistId"]) ??
        traverseString(item, ["playlistId"]) ??
        '';

    final name = traverseString(item, ["title", "runs", "text"]) ??
        traverseString(item, ["title", "text"]) ??
        traverseString(item, ["runs", "text"]) ??
        '';

    return PlaylistDetailed(
      type: "PLAYLIST",
      playlistId: playlistId,
      name: name,
      artist: ArtistBasic(
        name: traverseString(artist, ["text"]) ?? '',
        artistId: traverseString(artist, ["browseId"]),
      ),
      thumbnails: traverseList(item, ["thumbnails"])
          .whereType<Map>()
          .map((thumb) => ThumbnailFull(
                url: thumb['url']?.toString() ?? '',
                width: (thumb['width'] as num?)?.toInt() ?? 0,
                height: (thumb['height'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
    );
  }
}
