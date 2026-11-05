import 'package:dart_ytmusic_api/parsers/parser.dart';
import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/filters.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class SongParser {
  static SongFull parse(dynamic data) {
    return SongFull(
      type: "SONG",
      videoId: traverseString(data, ["videoDetails", "videoId"]) ?? '',
      name: traverseString(data, ["videoDetails", "title"]) ?? '',
      artist: ArtistBasic(
        name: traverseString(data, ["author"]) ?? '',
        artistId: traverseString(data, ["videoDetails", "channelId"]),
      ),
      duration: int.parse(
          traverseString(data, ["videoDetails", "lengthSeconds"]) ?? '0'),
      thumbnails: traverseList(data, ["videoDetails", "thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
      formats: traverseList(data, ["streamingData", "formats"]),
      adaptiveFormats: traverseList(data, ["streamingData", "adaptiveFormats"]),
    );
  }

  static SongDetailed parseSearchResult(dynamic item) {
    final columns = traverseList(item, ["flexColumns", "runs"]);
    // It is not possible to identify the title and author
    final title = columns[0];
    final artist = columns.firstWhere(isArtist, orElse: () => columns[3]);
    final album = columns.firstWhere(isAlbum, orElse: () => null);
    final duration = columns.firstWhere(
        (item) => isDuration(item) && item != title,
        orElse: () => null);

    return SongDetailed(
      type: "SONG",
      videoId: traverseString(item, ["watchEndpoint", "videoId"]) ?? '',
      name: traverseString(title, ["text"]) ?? '',
      artist: ArtistBasic(
        name: traverseString(artist, ["text"]) ?? '',
        artistId: traverseString(artist, ["browseId"]),
      ),
      album: album != null
          ? AlbumBasic(
              name: traverseString(album, ["text"]) ?? '',
              albumId: traverseString(album, ["browseId"]) ?? '',
            )
          : null,
      duration: Parser.parseDuration(duration?['text']),
      thumbnails: traverseList(item, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static SongDetailed parseArtistSong(dynamic item, ArtistBasic artistBasic) {
    final columns = traverseList(item, ["flexColumns", "runs"])
        .expand((e) => e is List ? e : [e])
        .toList();

    final title = columns.firstWhere(isTitle, orElse: () => null);
    final album = columns.firstWhere(isAlbum, orElse: () => null);
    final duration = columns.firstWhere(isDuration, orElse: () => null);
    final cleanedDuration =
        duration?['text']?.replaceAll(RegExp(r'[^0-9:]'), '');

    return SongDetailed(
      type: "SONG",
      videoId: traverseString(item, ["watchEndpoint", "videoId"]) ?? '',
      name: traverseString(title, ["text"]) ?? '',
      artist: artistBasic,
      album: album != null
          ? AlbumBasic(
              name: traverseString(album, ["text"]) ?? '',
              albumId: traverseString(album, ["browseId"]) ?? '',
            )
          : null,
      duration: Parser.parseDuration(cleanedDuration),
      thumbnails: traverseList(item, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static SongDetailed parseArtistTopSong(
      dynamic item, ArtistBasic artistBasic) {
    final columns = traverseList(item, ["flexColumns", "runs"])
        .expand((e) => e is List ? e : [e])
        .toList();

    final title = columns.firstWhere(isTitle, orElse: () => null);
    final album = columns.firstWhere(isAlbum, orElse: () => null);

    return SongDetailed(
      type: "SONG",
      videoId: traverseString(item, ["watchEndpoint", "videoId"]) ?? '',
      name: traverseString(title, ["text"]) ?? '',
      artist: artistBasic,
      album: album != null
          ? AlbumBasic(
              name: traverseString(album, ["text"]) ?? '',
              albumId: traverseString(album, ["browseId"]) ?? '',
            )
          : null,
      duration: null,
      thumbnails: traverseList(item, ["thumbnails"])
          .map((item) => ThumbnailFull.fromMap(item))
          .toList(),
    );
  }

  static SongDetailed parseAlbumSong(
    dynamic item,
    ArtistBasic artistBasic,
    AlbumBasic albumBasic,
    List<ThumbnailFull> thumbnails,
  ) {
    final renderer =
        (item is Map && item.containsKey('musicResponsiveListItemRenderer'))
            ? item['musicResponsiveListItemRenderer'] as Map
            : (item is Map ? item : null);
    if (renderer == null) {
      return SongDetailed(
        type: "SONG",
        videoId: '',
        name: '',
        artist: artistBasic,
        album: albumBasic,
        duration: null,
        thumbnails: thumbnails,
      );
    }

    // Fast direct videoId extraction
    String videoId = '';
    try {
      if (renderer['playlistItemData'] is Map) {
        videoId = renderer['playlistItemData']['videoId']?.toString() ?? '';
      }
      if (videoId.isEmpty) {
        final flexCols = renderer['flexColumns'] as List?;
        if (flexCols != null && flexCols.isNotEmpty) {
          final runs = flexCols[0]?['musicResponsiveListItemFlexColumnRenderer']
              ?['text']?['runs'] as List?;
          if (runs != null && runs.isNotEmpty) {
            videoId = runs[0]?['navigationEndpoint']?['watchEndpoint']
                        ?['videoId']
                    ?.toString() ??
                '';
          }
        }
      }
      if (videoId.isEmpty) {
        videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
                        ?['content']?['musicPlayButtonRenderer']
                    ?['playNavigationEndpoint']?['watchEndpoint']?['videoId']
                ?.toString() ??
            '';
      }
    } catch (_) {}
    if (videoId.isEmpty) {
      videoId = traverseString(renderer, ["watchEndpoint", "videoId"]) ??
          traverseString(renderer, ["playNavigationEndpoint", "videoId"]) ??
          '';
    }

    // Fast direct title extraction
    String title = '';
    try {
      final flexCols = renderer['flexColumns'] as List?;
      if (flexCols != null && flexCols.isNotEmpty) {
        final runs = flexCols[0]?['musicResponsiveListItemFlexColumnRenderer']
            ?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty) {
          title = runs[0]?['text']?.toString() ?? '';
        }
      }
    } catch (_) {}
    if (title.isEmpty) {
      final flexColumns = traverseList(renderer, ["flexColumns", "runs"])
          .expand((e) => e is List ? e : [e])
          .toList();
      final titleObj = flexColumns.firstWhere(isTitle,
          orElse: () => flexColumns.isNotEmpty ? flexColumns[0] : null);
      title = traverseString(titleObj, ["text"]) ?? '';
    }

    // Fast direct duration extraction
    int? duration;
    try {
      final fixedCols = renderer['fixedColumns'] as List?;
      if (fixedCols != null && fixedCols.isNotEmpty) {
        final runs = fixedCols[0]?['musicResponsiveListItemFixedColumnRenderer']
            ?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty) {
          final durText = runs[0]?['text']?.toString();
          if (durText != null) {
            duration = Parser.parseDuration(durText);
          }
        }
      }
    } catch (_) {}
    if (duration == null) {
      final fixedColumns = traverseList(renderer, ["fixedColumns", "runs"])
          .expand((e) => e is List ? e : [e])
          .toList();
      final durObj = fixedColumns.firstWhere(isDuration, orElse: () => null);
      duration = Parser.parseDuration(durObj?['text']?.toString());
    }

    return SongDetailed(
      type: "SONG",
      videoId: videoId,
      name: title,
      artist: artistBasic,
      album: albumBasic,
      duration: duration,
      thumbnails: thumbnails,
    );
  }

  static SongDetailed parseHomeSection(dynamic item) {
    return parseSearchResult(item);
  }
}
