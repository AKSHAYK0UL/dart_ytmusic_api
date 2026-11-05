import 'package:dart_ytmusic_api/parsers/parser.dart';
import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/filters.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class VideoParser {
  static VideoFull parse(dynamic data) {
    return VideoFull(
      type: "VIDEO",
      videoId: traverseString(data, ["videoDetails", "videoId"]) ?? '',
      name: traverseString(data, ["videoDetails", "title"]) ?? '',
      artist: ArtistBasic(
        artistId: traverseString(data, ["videoDetails", "channelId"]),
        name: traverseString(data, ["author"]) ?? '',
      ),
      duration: int.parse(
          traverseString(data, ["videoDetails", "lengthSeconds"]) ?? '0'),
      thumbnails: traverseList(data, ["videoDetails", "thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
      unlisted: traverse(data, ["unlisted"]),
      familySafe: traverse(data, ["familySafe"]),
      paid: traverse(data, ["paid"]),
      tags: traverseList(data, ["tags"]).whereType<String>().toList(),
    );
  }

  static VideoDetailed parseSearchResult(dynamic item) {
    final columns = traverseList(item, ["flexColumns", "runs"])
        .expand((e) => e is List ? e : [e])
        .toList();

    final title = columns.firstWhere(isTitle, orElse: () => null);
    final artist = columns.firstWhere(isArtist, orElse: () => columns[1]);
    final duration = columns.firstWhere(isDuration, orElse: () => null);

    return VideoDetailed(
      type: "VIDEO",
      videoId:
          traverseString(item, ["playNavigationEndpoint", "videoId"]) ?? '',
      name: traverseString(title, ["text"]) ?? '',
      artist: ArtistBasic(
        artistId: traverseString(artist, ["browseId"]),
        name: traverseString(artist, ["text"]) ?? '',
      ),
      duration: Parser.parseDuration(duration?['text']),
      thumbnails: traverseList(item, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static VideoDetailed parseArtistTopVideo(
      dynamic item, ArtistBasic artistBasic) {
    return VideoDetailed(
      type: "VIDEO",
      videoId: traverseString(item, ["videoId"]) ?? '',
      name: traverseString(item, ["runs", "text"]) ?? '',
      artist: artistBasic,
      duration: null,
      thumbnails: traverseList(item, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static VideoDetailed? parsePlaylistVideo(dynamic item) {
    final renderer = (item is Map && item.containsKey('musicResponsiveListItemRenderer'))
        ? item['musicResponsiveListItemRenderer'] as Map
        : (item is Map ? item : null);
    if (renderer == null) return null;

    // Fast direct videoId extraction
    String? videoId;
    try {
      if (renderer['playlistItemData'] is Map) {
        videoId = renderer['playlistItemData']['videoId']?.toString();
      }
      if (videoId == null || videoId.isEmpty) {
        final flexCols = renderer['flexColumns'] as List?;
        if (flexCols != null && flexCols.isNotEmpty) {
          final runs = flexCols[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
          if (runs != null && runs.isNotEmpty) {
            videoId = runs[0]?['navigationEndpoint']?['watchEndpoint']?['videoId']?.toString();
          }
        }
      }
      if (videoId == null || videoId.isEmpty) {
        videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId']?.toString();
      }
    } catch (_) {}

    // Fallback if direct lookup missed it
    if (videoId == null || videoId.isEmpty) {
      videoId = traverseString(renderer, ["playNavigationEndpoint", "videoId"]) ??
          traverseString(renderer, ["watchEndpoint", "videoId"]);
    }
    if (videoId == null || videoId.isEmpty) {
      final thumbUrl = traverseString(renderer, ["thumbnails", "url"]) ?? '';
      videoId = RegExp(r"https:\/\/i\.ytimg\.com\/vi\/(.+?)\/").firstMatch(thumbUrl)?.group(1);
    }
    if (videoId == null || videoId.isEmpty) {
      return null;
    }

    // Fast direct title extraction
    String title = '';
    try {
      final flexCols = renderer['flexColumns'] as List?;
      if (flexCols != null && flexCols.isNotEmpty) {
        final runs = flexCols[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty) {
          title = runs[0]?['text']?.toString() ?? '';
        }
      }
    } catch (_) {}
    if (title.isEmpty) {
      final flexColumns = traverseList(renderer, ['flexColumns', 'runs'])
          .expand((e) => e is List ? e : [e])
          .toList();
      final titleObj = flexColumns.firstWhere(isTitle,
          orElse: () => flexColumns.isNotEmpty ? flexColumns[0] : null);
      title = traverseString(titleObj, ["text"]) ?? '';
    }

    // Fast direct artist extraction
    String artistName = '';
    String? artistId;
    try {
      final flexCols = renderer['flexColumns'] as List?;
      if (flexCols != null && flexCols.length > 1) {
        final runs = flexCols[1]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty) {
          for (final run in runs) {
            if (run is Map) {
              final text = run['text']?.toString() ?? '';
              if (text.isNotEmpty && text != ' • ' && text != ', ') {
                artistName = text;
                artistId = run['navigationEndpoint']?['browseEndpoint']?['browseId']?.toString();
                break;
              }
            }
          }
        }
      }
    } catch (_) {}
    if (artistName.isEmpty) {
      final flexColumns = traverseList(renderer, ['flexColumns', 'runs'])
          .expand((e) => e is List ? e : [e])
          .toList();
      final artistObj = flexColumns.firstWhere(isArtist,
          orElse: () => flexColumns.length > 1 ? flexColumns[1] : null);
      artistName = traverseString(artistObj, ["text"]) ?? '';
      artistId = traverseString(artistObj, ["browseId"]);
    }

    // Fast direct duration extraction
    int? duration;
    try {
      final fixedCols = renderer['fixedColumns'] as List?;
      if (fixedCols != null && fixedCols.isNotEmpty) {
        final runs = fixedCols[0]?['musicResponsiveListItemFixedColumnRenderer']?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty) {
          final durText = runs[0]?['text']?.toString();
          if (durText != null) {
            duration = Parser.parseDuration(durText);
          }
        }
      }
    } catch (_) {}
    if (duration == null) {
      final fixedColumns = traverseList(renderer, ['fixedColumns', 'runs'])
          .expand((e) => e is List ? e : [e])
          .toList();
      final durObj = fixedColumns.firstWhere(isDuration, orElse: () => null);
      duration = Parser.parseDuration(durObj?['text']?.toString());
    }

    // Fast direct thumbnails extraction
    List<ThumbnailFull> thumbnails = const [];
    try {
      final rawThumbs = renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] as List?;
      if (rawThumbs != null && rawThumbs.isNotEmpty) {
        thumbnails = rawThumbs
            .whereType<Map>()
            .map((t) => ThumbnailFull.fromMap(Map<String, dynamic>.from(t)))
            .toList();
      }
    } catch (_) {}
    if (thumbnails.isEmpty) {
      thumbnails = traverseList(renderer, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList();
    }

    return VideoDetailed(
      type: "VIDEO",
      videoId: videoId,
      name: title,
      artist: ArtistBasic(
        name: artistName,
        artistId: artistId,
      ),
      duration: duration,
      thumbnails: thumbnails,
    );
  }
}
