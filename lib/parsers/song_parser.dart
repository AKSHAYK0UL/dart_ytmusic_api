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
    final renderer =
        (item is Map && item.containsKey('musicResponsiveListItemRenderer'))
            ? item['musicResponsiveListItemRenderer'] as Map
            : (item is Map ? item : null);

    if (renderer == null) {
      return SongDetailed(
        type: "SONG",
        videoId: '',
        name: '',
        artist: ArtistBasic(name: ''),
        album: null,
        duration: null,
        thumbnails: const [],
      );
    }

    // 1. Direct, robust videoId extraction
    String videoId = '';
    if (renderer['playlistItemData'] is Map) {
      videoId = renderer['playlistItemData']['videoId']?.toString() ?? '';
    }
    final flexCols = renderer['flexColumns'] as List?;
    if (videoId.isEmpty && flexCols != null && flexCols.isNotEmpty) {
      final col0 = flexCols[0];
      if (col0 is Map) {
        final runs = col0['musicResponsiveListItemFlexColumnRenderer']?['text']
            ?['runs'] as List?;
        if (runs != null && runs.isNotEmpty && runs[0] is Map) {
          videoId = runs[0]['navigationEndpoint']?['watchEndpoint']?['videoId']
                  ?.toString() ??
              '';
        }
      }
    }
    if (videoId.isEmpty) {
      videoId = renderer['overlay']?['musicItemThumbnailOverlayRenderer']
              ?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']
          ?['watchEndpoint']?['videoId']
          ?.toString() ??
          '';
    }
    if (videoId.isEmpty) {
      videoId = renderer['navigationEndpoint']?['watchEndpoint']?['videoId']
              ?.toString() ??
          '';
    }
    if (videoId.isEmpty) {
      videoId = renderer['onTap']?['watchEndpoint']?['videoId']?.toString() ??
          renderer['doubleTapCommand']?['watchEndpoint']?['videoId']
              ?.toString() ??
          '';
    }
    if (videoId.isEmpty) {
      videoId = traverseString(renderer, ["watchEndpoint", "videoId"]) ??
          traverseString(renderer,
              ["playNavigationEndpoint", "watchEndpoint", "videoId"]) ??
          '';
    }

    // 2. Direct, robust title extraction from flexColumns[0]
    String titleText = '';
    if (flexCols != null && flexCols.isNotEmpty && flexCols[0] is Map) {
      final runs = flexCols[0]['musicResponsiveListItemFlexColumnRenderer']
          ?['text']?['runs'] as List?;
      if (runs != null && runs.isNotEmpty) {
        titleText = runs
            .whereType<Map>()
            .map((r) => r['text']?.toString() ?? '')
            .join('')
            .trim();
      }
    }
    if (titleText.isEmpty) {
      titleText = traverseString(renderer, ["title", "runs", "text"]) ??
          traverseString(renderer, ["title", "text"]) ??
          '';
    }

    // 3. Subtitle extraction (artist, album, duration) from flexColumns[1]
    String artistName = '';
    String? artistId;
    String? albumName;
    String? albumId;
    String? durationText;

    if (flexCols != null && flexCols.length > 1 && flexCols[1] is Map) {
      final runs = flexCols[1]['musicResponsiveListItemFlexColumnRenderer']
          ?['text']?['runs'] as List?;
      if (runs != null) {
        for (final r in runs) {
          if (r is! Map) continue;
          final text = r['text']?.toString() ?? '';
          if (text == ' • ' || text.trim().isEmpty) continue;

          final pageType = _deepGet(r, [
                'navigationEndpoint',
                'browseEndpoint',
                'browseEndpointContextSupportedConfigs',
                'browseEndpointContextMusicConfig',
                'pageType',
              ])?.toString() ??
              traverseString(r, ["pageType"]);

          final browseId = _deepGet(r, [
                'navigationEndpoint',
                'browseEndpoint',
                'browseId',
              ])?.toString() ??
              traverseString(r, ["browseId"]);

          if (RegExp(r'(\d{1,2}:)?\d{1,2}:\d{1,2}').hasMatch(text)) {
            durationText = text;
          } else if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
              pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
              (browseId != null && browseId.startsWith('UC'))) {
            if (artistName.isEmpty) {
              artistName = text;
              artistId = browseId;
            }
          } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
              (browseId != null &&
                  (browseId.startsWith('MPREb_') ||
                      browseId.startsWith('OLAK')))) {
            if (albumName == null) {
              albumName = text;
              albumId = browseId;
            }
          } else if (artistName.isEmpty) {
            artistName = text;
            artistId = browseId;
          } else if (albumName == null) {
            albumName = text;
            albumId = browseId;
          }
        }
      }
    }

    // Check fixedColumns for duration if not found in flexColumns
    if (durationText == null) {
      final fixedCols = renderer['fixedColumns'] as List?;
      if (fixedCols != null && fixedCols.isNotEmpty && fixedCols[0] is Map) {
        final runs = fixedCols[0]['musicResponsiveListItemFixedColumnRenderer']
            ?['text']?['runs'] as List?;
        if (runs != null && runs.isNotEmpty && runs[0] is Map) {
          durationText = runs[0]['text']?.toString();
        }
      }
    }

    // Fallback: If artistName is still empty, try deep search
    if (artistName.isEmpty) {
      final columns = traverseList(renderer, ["flexColumns", "runs"]);
      for (final c in columns) {
        if (c is! Map) continue;
        final text = c['text']?.toString() ?? '';
        if (text == ' • ' || text.trim().isEmpty || text == titleText) continue;
        if (isArtist(c)) {
          artistName = text;
          artistId = traverseString(c, ["browseId"]);
          break;
        }
      }
    }

    // 4. Thumbnails extraction
    List<ThumbnailFull> thumbnails = [];
    final thumbObj = renderer['thumbnail']?['musicThumbnailRenderer']
            ?['thumbnail']?['thumbnails'] ??
        renderer['thumbnails'];
    if (thumbObj is List) {
      thumbnails = thumbObj
          .whereType<Map>()
          .map((t) => ThumbnailFull.fromMap(t))
          .toList();
    }
    if (thumbnails.isEmpty) {
      thumbnails = traverseList(renderer, ["thumbnails"])
          .whereType<Map>()
          .map((item) => ThumbnailFull.fromMap(item))
          .toList();
    }

    return SongDetailed(
      type: "SONG",
      videoId: videoId,
      name: titleText,
      artist: ArtistBasic(
        name: artistName,
        artistId: artistId,
      ),
      album: albumName != null
          ? AlbumBasic(
              name: albumName,
              albumId: albumId ?? '',
            )
          : null,
      duration: Parser.parseDuration(durationText),
      thumbnails: thumbnails,
    );
  }

  static dynamic _deepGet(dynamic current, List<dynamic> path) {
    for (final segment in path) {
      if (current == null) return null;
      if (segment is int) {
        if (current is List && segment >= 0 && segment < current.length) {
          current = current[segment];
        } else {
          return null;
        }
      } else {
        if (current is Map) {
          current = current[segment];
        } else {
          return null;
        }
      }
    }
    return current;
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
