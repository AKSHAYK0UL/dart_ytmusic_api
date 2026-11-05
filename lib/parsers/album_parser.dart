import 'package:dart_ytmusic_api/parsers/song_parser.dart';
import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/utils/filters.dart';
import 'package:dart_ytmusic_api/utils/traverse.dart';

class AlbumParser {
  static AlbumFull parse(dynamic data, String albumId) {
    // Fast direct header lookup
    final header = (data is Map)
        ? (data['header']?['musicDetailHeaderRenderer'] ??
            data['header']?['musicResponsiveHeaderRenderer'] ??
            data['header'])
        : null;

    String name = '';
    String artistName = '';
    String? artistId;
    String? yearString;
    List<ThumbnailFull> thumbnails = const [];
    String playlistId = '';

    if (header is Map) {
      // Title
      try {
        final titleRuns = header['title']?['runs'] as List?;
        if (titleRuns != null && titleRuns.isNotEmpty) {
          name = titleRuns[0]?['text']?.toString() ?? '';
        }
      } catch (_) {}

      // Artist
      try {
        final strapRuns = header['straplineTextOne']?['runs'] as List?;
        if (strapRuns != null && strapRuns.isNotEmpty) {
          artistName = strapRuns[0]?['text']?.toString() ?? '';
          artistId = strapRuns[0]?['navigationEndpoint']?['browseEndpoint']
                  ?['browseId']
              ?.toString();
        }
      } catch (_) {}

      // Subtitle / Year
      try {
        final subRuns = header['subtitle']?['runs'] as List?;
        if (subRuns != null) {
          for (final run in subRuns) {
            final t = run['text']?.toString() ?? '';
            if (RegExp(r'^\d{4}$').hasMatch(t)) {
              yearString = t;
              break;
            }
          }
        }
      } catch (_) {}

      // Thumbnails
      try {
        final rawThumbs = (header['thumbnail']
                    ?['croppedSquareThumbnailRenderer']?['thumbnail']
                ?['thumbnails'] ??
            header['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
                ?['thumbnails'] ??
            header['thumbnail']?['thumbnails']) as List?;
        if (rawThumbs != null && rawThumbs.isNotEmpty) {
          thumbnails = rawThumbs
              .whereType<Map>()
              .map((t) => ThumbnailFull.fromMap(Map<String, dynamic>.from(t)))
              .toList();
        }
      } catch (_) {}

      // Playlist ID
      try {
        playlistId = header['menu']?['menuRenderer']?['topLevelButtons']?[0]
                    ?['musicPlayButtonRenderer']?['playlistId']
                ?.toString() ??
            '';
      } catch (_) {}
    }

    // Fallbacks if direct header lookup missed anything
    if (name.isEmpty) {
      name = traverseString(data, ["header", "title", "text"]) ??
          traverseString(data, ["tabs", "title", "text"]) ??
          traverseString(data, ["title", "text"]) ??
          '';
    }

    if (artistName.isEmpty) {
      final artistData =
          traverse(data, ["header", "straplineTextOne", "runs"]) ??
              traverse(data, ["tabs", "straplineTextOne", "runs"]) ??
              traverse(data, ["straplineTextOne", "runs"]) ??
              traverse(data, ["subtitle", "runs"]);
      artistName = traverseString(artistData, ["text"]) ?? '';
      artistId = traverseString(artistData, ["browseId"]);
    }

    if (yearString == null) {
      final sub = traverseList(data, ["header", "subtitle", "runs", "text"])
              .lastOrNull ??
          traverseList(data, ["tabs", "subtitle", "text"]).lastOrNull ??
          traverseList(data, ["subtitle", "text"]).lastOrNull;
      yearString = sub?.toString();
    }

    if (thumbnails.isEmpty) {
      final rawThumbnails =
          traverseList(data, ["header", "thumbnail", "thumbnails"]);
      thumbnails = (rawThumbnails.isNotEmpty
              ? rawThumbnails
              : traverseList(data, ["background", "thumbnails"]))
          .map((item) => ThumbnailFull.fromMap(item))
          .toList();
    }

    if (playlistId.isEmpty) {
      playlistId =
          traverseString(data, ["musicPlayButtonRenderer", "playlistId"]) ?? '';
    }

    final albumBasic = AlbumBasic(
      albumId: albumId,
      name: name,
    );

    final artistBasic = ArtistBasic(
      artistId: artistId,
      name: artistName,
    );

    // Fast direct lookup of songs list
    List? rawItems;
    try {
      final tabs = data['contents']?['singleColumnBrowseResultsRenderer']
          ?['tabs'] as List?;
      if (tabs != null && tabs.isNotEmpty) {
        final sectionContents = tabs[0]?['tabRenderer']?['content']
            ?['sectionListRenderer']?['contents'] as List?;
        if (sectionContents != null && sectionContents.isNotEmpty) {
          final shelf = sectionContents[0]?['musicShelfRenderer'] ??
              sectionContents[0]?['musicPlaylistShelfRenderer'];
          rawItems = shelf?['contents'] as List?;
        }
      }
    } catch (_) {}

    rawItems ??= traverseList(data, ["musicResponsiveListItemRenderer"]);

    final songs = rawItems
        .map(
          (item) => SongParser.parseAlbumSong(
            item,
            artistBasic,
            albumBasic,
            thumbnails,
          ),
        )
        .where((s) => s.videoId.isNotEmpty)
        .toList();

    return AlbumFull(
      name: albumBasic.name,
      type: "ALBUM",
      albumId: albumId,
      playlistId: playlistId,
      artist: artistBasic,
      year: processYear(yearString),
      thumbnails: thumbnails,
      songs: songs,
    );
  }

  static AlbumDetailed parseSearchResult(dynamic item) {
    final columns = traverseList(item, ["flexColumns", "runs"])
        .expand((e) => e is List ? e : [e])
        .toList();

    // No specific way to identify the title
    final title = columns[0];
    final artist = columns.firstWhere(isArtist, orElse: () => columns[3]);
    final playlistId = traverseString(item, ["overlay", "playlistId"]) ??
        traverseString(item, ["thumbnailOverlay", "playlistId"]);

    return AlbumDetailed(
      type: "ALBUM",
      albumId: traverseList(item, ["browseId"]).last,
      playlistId: playlistId ?? '',
      artist: ArtistBasic(
        name: traverseString(artist, ["text"]) ?? '',
        artistId: traverseString(artist, ["browseId"]),
      ),
      year: processYear(columns.last?['text']),
      name: traverseString(title, ["text"]) ?? '',
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

  static AlbumDetailed parseArtistAlbum(dynamic item, ArtistBasic artistBasic) {
    return AlbumDetailed(
      type: "ALBUM",
      albumId: traverseList(item, ["browseId"])
              .where((element) => element != artistBasic.artistId)
              .firstOrNull ??
          '',
      playlistId:
          traverseString(item, ["thumbnailOverlay", "playlistId"]) ?? '',
      name: traverseString(item, ["title", "text"]) ?? '',
      artist: artistBasic,
      year: processYear(traverseList(item, ["subtitle", "text"]).last),
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

  static AlbumDetailed parseArtistTopAlbum(
      dynamic item, ArtistBasic artistBasic) {
    return AlbumDetailed(
      type: "ALBUM",
      albumId: traverseList(item, ["browseId"]).isEmpty
          ? ''
          : traverseList(item, ["browseId"]).last,
      playlistId:
          traverseString(item, ["musicPlayButtonRenderer", "playlistId"]) ?? '',
      name: traverseString(item, ["title", "text"]) ?? '',
      artist: artistBasic,
      year: processYear(traverseList(item, ["subtitle", "text"]).last),
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

  static AlbumDetailed parseHomeSection(dynamic item) {
    final itemMap = item is Map ? item : null;

    // 1. Extract title
    final title = traverseString(item, ["title", "runs", "text"]) ??
        traverseString(item, ["title", "text"]) ??
        traverseString(item, ["runs", "text"]) ??
        '';

    // 2. Extract albumId
    String? titleBrowseId;
    if (itemMap != null) {
      final titleObj = itemMap['title'];
      if (titleObj is Map) {
        final runs = titleObj['runs'];
        if (runs is List && runs.isNotEmpty) {
          final firstRun = runs[0];
          if (firstRun is Map) {
            final navEp = firstRun['navigationEndpoint'];
            if (navEp is Map) {
              final browseEp = navEp['browseEndpoint'];
              if (browseEp is Map) {
                titleBrowseId = browseEp['browseId']?.toString();
              }
            }
          }
        }
      }
    }

    String? navBrowseId;
    String? navPlaylistId;
    if (itemMap != null) {
      final navEp = itemMap['navigationEndpoint'];
      if (navEp is Map) {
        final browseEp = navEp['browseEndpoint'];
        if (browseEp is Map) {
          navBrowseId = browseEp['browseId']?.toString();
        }
        final watchPlaylistEp = navEp['watchPlaylistEndpoint'];
        if (watchPlaylistEp is Map) {
          navPlaylistId = watchPlaylistEp['playlistId']?.toString();
        }
      }
    }

    String albumId = (titleBrowseId != null && titleBrowseId.isNotEmpty)
        ? titleBrowseId
        : (navBrowseId != null && navBrowseId.isNotEmpty)
            ? navBrowseId
            : (traverseString(item, ["navigationEndpoint", "browseEndpoint", "browseId"]) ??
               '');

    if (albumId.isEmpty || albumId.startsWith('UC')) {
      final allBrowseIds = traverseList(item, ["browseId"]);
      for (final id in allBrowseIds) {
        final idStr = id?.toString() ?? '';
        if (idStr.startsWith('MPREb_') || idStr.startsWith('OLAK')) {
          albumId = idStr;
          break;
        }
      }
    }

    // 3. Extract playlistId
    final playlistId = navPlaylistId ??
        traverseString(item, ["thumbnailOverlay", "playlistId"]) ??
        traverseString(item, ["playlistId"]) ??
        '';

    if (albumId.isEmpty || albumId.startsWith('UC')) {
      albumId = playlistId;
    }

    // 4. Extract artist
    final artistRuns = traverseList(item, ["subtitle", "runs"]);
    dynamic artistRun;
    for (final r in artistRuns) {
      if (r is Map && r.containsKey('navigationEndpoint')) {
        final bId = traverseString(r, ["navigationEndpoint", "browseEndpoint", "browseId"]);
        if (bId != null && (bId.startsWith('UC') || bId.startsWith('FEmusic_artist'))) {
          artistRun = r;
          break;
        }
      }
    }
    artistRun ??= artistRuns.firstWhere(
      (r) => r is Map && r.containsKey('navigationEndpoint'),
      orElse: () => artistRuns.isNotEmpty ? artistRuns.first : null,
    );

    final artistName = traverseString(artistRun, ["text"]) ?? '';
    final artistId = traverseString(artistRun, ["navigationEndpoint", "browseEndpoint", "browseId"]) ??
        traverseString(artistRun, ["browseId"]);

    // 5. Extract year
    int? year;
    for (final r in artistRuns) {
      String? t;
      if (r is Map) {
        t = r['text']?.toString();
      } else if (r != null) {
        t = r.toString();
      }
      final trimmed = t?.trim() ?? '';
      if (RegExp(r'^\d{4}$').hasMatch(trimmed)) {
        year = int.tryParse(trimmed);
        break;
      }
    }

    // 6. Thumbnails
    final thumbnails = traverseList(item, ["thumbnails"])
        .whereType<Map>()
        .map((thumb) => ThumbnailFull(
              url: thumb['url']?.toString() ?? '',
              width: (thumb['width'] as num?)?.toInt() ?? 0,
              height: (thumb['height'] as num?)?.toInt() ?? 0,
            ))
        .toList();

    return AlbumDetailed(
      type: "ALBUM",
      albumId: albumId,
      playlistId: playlistId.isNotEmpty ? playlistId : albumId,
      name: title,
      artist: ArtistBasic(
        name: artistName,
        artistId: artistId,
      ),
      year: year,
      thumbnails: thumbnails,
    );
  }

  static int? processYear(String? year) {
    return year != null && RegExp(r"^\d{4}$").hasMatch(year)
        ? int.parse(year)
        : null;
  }
}
