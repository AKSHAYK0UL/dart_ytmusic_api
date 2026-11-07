import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dart_ytmusic_api/enums.dart';
import 'package:dart_ytmusic_api/parsers/album_parser.dart';
import 'package:dart_ytmusic_api/parsers/artist_parser.dart';
import 'package:dart_ytmusic_api/parsers/parser.dart';
import 'package:dart_ytmusic_api/parsers/playlist_parser.dart';
import 'package:dart_ytmusic_api/parsers/search_parser.dart';
import 'package:dart_ytmusic_api/parsers/song_parser.dart';
import 'package:dart_ytmusic_api/parsers/video_parser.dart';
import 'package:dart_ytmusic_api/types.dart';

import 'package:dart_ytmusic_api/utils/traverse.dart';
import 'package:http/http.dart' as http;

class YTMusic {
  // Creates a new YTMusic client.
  // [apiKey] is your YouTube Data API v3 key (from Google Cloud Console).
  // It is used as a fallback by [getPlaylistVideos] when the fast internal
  // browse endpoint rejects a non-music YouTube playlist.
  // You can also supply or override it later via [initialize].
  YTMusic({String? apiKey}) {
    cookieJar = CookieJar();
    config = {
       if (apiKey != null && apiKey.isNotEmpty) 'INNERTUBE_API_KEY': apiKey,
      'INNERTUBE_API_VERSION': 'v1',
      'INNERTUBE_CLIENT_NAME': 'WEB_REMIX',
      'INNERTUBE_CLIENT_VERSION': '1.20241104.01.00',
      'INNERTUBE_CONTEXT_CLIENT_NAME': '67',
      'GL': 'US',
      'HL': 'en',
      if (apiKey != null && apiKey.isNotEmpty) 'DATA_API_KEY': apiKey,
    };
    _client = http.Client();
    _baseHeaders = {
      "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.129 Safari/537.36",
      "Accept": "*/*",
      "Accept-Language": "en-US,en;q=0.9",
    };
  }

  late CookieJar cookieJar;
  late Map<String, String> config;
  late http.Client _client;
  late Map<String, String> _baseHeaders;
  bool hasInitialized = false;
  bool _isAuthenticated = false;
  String? ytMusicHomeRawHtml;

  // Returns true if auth cookies have been loaded into the session.
  // When true, [getHome] returns a personalised feed and [reportPlayback]
  // will update the account's watch history on Google's servers.
  bool get isAuthenticated => _isAuthenticated;

  /// Initializes the YTMusic instance with provided cookies, geolocation, and language.
  ///
  /// [dataApiKey] is a YouTube Data API v3 key (from Google Cloud Console).
  /// It is used as a fallback by [getPlaylistVideos] if the fast internal browse
  /// endpoint rejects a non-music YouTube playlist.
  // Supplying it here overrides the key passed to the [YTMusic] constructor.
  Future<YTMusic> initialize({
    String? cookies,
    String? gl,
    String? hl,
    String? ytMusicHomeRawHtml,
    String? dataApiKey,
  }) async {
    if (hasInitialized) {
      return this;
    }

    this.ytMusicHomeRawHtml = ytMusicHomeRawHtml;

    if (cookies != null) {
      for (final cookieString in cookies.split('; ')) {
        try {
          final cookie = Cookie.fromSetCookieValue(cookieString);
          cookieJar.saveFromResponse(
            Uri.parse('https://www.youtube.com/'),
            [cookie],
          );
        } catch (_) {}
      }
      _isAuthenticated = true;
    }

    if (gl != null) config['GL'] = gl;
    if (hl != null) config['HL'] = hl;

    // initialize(dataApiKey:) overrides the constructor key when provided.
    if (dataApiKey != null && dataApiKey.isNotEmpty) {
      config['DATA_API_KEY'] = dataApiKey;
    }

    hasInitialized = true;

    // Fetch live configuration asynchronously without blocking initial user operations
    if (ytMusicHomeRawHtml != null) {
      await fetchConfig();
    } else {
      unawaited(fetchConfig().catchError((_) {}));
    }

    return this;
  }

  /// Fetches the configuration data required for API requests.
  Future<void> fetchConfig() async {
    late final String html;
    final uri = Uri.parse("https://music.youtube.com/");
    if (ytMusicHomeRawHtml != null) {
      html = ytMusicHomeRawHtml!;
    } else {
      final cookies = await cookieJar.loadForRequest(uri);
      final cookieString =
          cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
      final headers = {..._baseHeaders};
      if (cookieString.isNotEmpty) {
        headers['cookie'] = cookieString;
      }
      final response = await _client.get(uri, headers: headers);

      _saveCookiesFromHeaders(uri, response.headers);
      html = response.body;
    }

    if (html.contains('not optimized for your browser')) {
      print('Browser compatibility error in HTML response');
      throw Exception('Browser compatibility error detected');
    }
    config['VISITOR_DATA'] = _extractValue(html, r'"VISITOR_DATA":"(.*?)"');
    config['INNERTUBE_CONTEXT_CLIENT_NAME'] = _extractValue(
        html, r'"INNERTUBE_CONTEXT_CLIENT_NAME":\s*(-?\d+|\"(.*?)\")');
    config['INNERTUBE_CLIENT_VERSION'] =
        _extractValue(html, r'"INNERTUBE_CLIENT_VERSION":"(.*?)"');
    config['DEVICE'] = _extractValue(html, r'"DEVICE":"(.*?)"');
    config['PAGE_CL'] = _extractValue(html, r'"PAGE_CL":\s*(-?\d+|\"(.*?)\")');
    config['PAGE_BUILD_LABEL'] =
        _extractValue(html, r'"PAGE_BUILD_LABEL":"(.*?)"');
    config['INNERTUBE_API_KEY'] =
        _extractValue(html, r'"INNERTUBE_API_KEY":"(.*?)"');
    config['INNERTUBE_API_VERSION'] =
        _extractValue(html, r'"INNERTUBE_API_VERSION":"(.*?)"');
    config['INNERTUBE_CLIENT_NAME'] =
        _extractValue(html, r'"INNERTUBE_CLIENT_NAME":"(.*?)"');
    config['GL'] = _extractValue(html, r'"GL":"(.*?)"');
    config['HL'] = _extractValue(html, r'"HL":"(.*?)"');
  }

  /// Extracts a value from HTML using a regular expression.
  String _extractValue(String html, String regex) {
    final match = RegExp(regex).firstMatch(html);
    return match != null ? match.group(1)! : '';
  }

  /// Constructs and performs an API request to the specified endpoint with optional body and query parameters.
  Future<dynamic> constructRequest(
    String endpoint, {
    Map<String, dynamic> body = const {},
    Map<String, String> query = const {},
    ClientRequestOptions? options,
  }) async {
    final baseUrl = "https://music.youtube.com/";
    final cleanedQuery = <String, String>{};
    for (final entry in query.entries) {
      final v = entry.value;
      if (v.isNotEmpty && v != 'null') {
        cleanedQuery[entry.key] = v;
      }
    }
    final fullQuery = {
      ...cleanedQuery,
      "alt": "json",
      "key": config['INNERTUBE_API_KEY'],
    };

    final uri = Uri.parse(baseUrl).replace(
      path: "youtubei/${config['INNERTUBE_API_VERSION']}/$endpoint",
      queryParameters: fullQuery,
    );

    final cookies = await cookieJar.loadForRequest(uri);
    final cookieString =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');

    final headers = <String, String>{
      ..._baseHeaders,
      "x-origin": baseUrl,
      "X-Goog-Visitor-Id": config['VISITOR_DATA'] ?? "",
      "X-YouTube-Client-Name": config['INNERTUBE_CONTEXT_CLIENT_NAME'] ?? '',
      "X-YouTube-Client-Version": config['INNERTUBE_CLIENT_VERSION'] ?? '',
      "X-YouTube-Device": config['DEVICE'] ?? '',
      "X-YouTube-Page-CL": config['PAGE_CL'] ?? '',
      "X-YouTube-Page-Label": config['PAGE_BUILD_LABEL'] ?? '',
      "X-YouTube-Utc-Offset":
          (-DateTime.now().timeZoneOffset.inMinutes).toString(),
      "Content-Type": "application/json",
    };

    if (cookieString.isNotEmpty) {
      headers['cookie'] = cookieString;
    }

    final requestBody = {
      "context": {
        "capabilities": {},
        "client": {
          "clientName": options?.clientName ?? config['INNERTUBE_CLIENT_NAME'],
          "clientVersion":
              options?.clientVersion ?? config['INNERTUBE_CLIENT_VERSION'],
          "experimentIds": [],
          "experimentsToken": "",
          "gl": config['GL'],
          "hl": config['HL'],
          "locationInfo": {
            "locationPermissionAuthorizationStatus":
                "LOCATION_PERMISSION_AUTHORIZATION_STATUS_UNSUPPORTED",
          },
          "musicAppInfo": {
            "musicActivityMasterSwitch":
                "MUSIC_ACTIVITY_MASTER_SWITCH_INDETERMINATE",
            "musicLocationMasterSwitch":
                "MUSIC_LOCATION_MASTER_SWITCH_INDETERMINATE",
            "pwaInstallabilityStatus": "PWA_INSTALLABILITY_STATUS_UNKNOWN",
          },
          "utcOffsetMinutes": -DateTime.now().timeZoneOffset.inMinutes,
        },
        "request": {
          "internalExperimentFlags": [
            {
              "key": "force_music_enable_outertube_tastebuilder_browse",
              "value": "true",
            },
            {
              "key": "force_music_enable_outertube_playlist_detail_browse",
              "value": "true",
            },
            {
              "key": "force_music_enable_outertube_search_suggestions",
              "value": "true",
            },
          ],
          "sessionIndex": {},
        },
        "user": {
          "enableSafetyMode": false,
        },
      },
      ...body,
    };

    try {
      final response = await _client.post(
        uri,
        headers: headers,
        body: json.encode(requestBody),
      );

      _saveCookiesFromHeaders(uri, response.headers);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final jsonData = json.decode(response.body);
        return jsonData;
      } else {
        throw Exception(
            'Failed to make request to $uri - ${response.statusCode} - [${response.body}]');
      }
    } on http.ClientException catch (e) {
      print('HTTP Client Exception during request to $uri: $e');
      rethrow;
    } catch (e) {
      print('Error during request to $uri: $e');
      rethrow;
    }
  }

  void _saveCookiesFromHeaders(Uri uri, Map<String, String> headers) {
    final setCookieHeader = headers['set-cookie'];
    if (setCookieHeader == null) return;
    try {
      final cookie = Cookie.fromSetCookieValue(setCookieHeader);
      cookieJar.saveFromResponse(uri, [cookie]);
    } catch (e) {
      //
    }
  }

  // Reports a song playback to YouTube Music's servers, which updates the
  // account's watch history and drives personalised recommendations in [getHome].
  
  // Call this once per song, ideally when the song finishes or when the user
  // skips to the next track.
  
  // [videoId]        — the song's YouTube videoId (e.g. `"dQw4w9WgXcQ"`)
  // [songDuration]   — total duration of the song in seconds
  // [listenedSeconds] — how many seconds the user actually listened to.
  //                    Defaults to [songDuration] (full listen).
  //                    Pass a lower value if the user skipped early.
  //
  // Does nothing if the instance is not authenticated (no cookies loaded).
  // Errors are silently swallowed so a reporting failure never disrupts playback.
  Future<void> reportPlayback({
    required String videoId,
    required int songDuration,
    int? listenedSeconds,
  }) async {
    if (!_isAuthenticated) return;

    final actualListened = listenedSeconds ?? songDuration;

    // Generate a random 16-character content playback nonce (cpn).
    // YouTube uses this to deduplicate pings — each play session needs a unique one.
    const cpnChars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final random = DateTime.now().microsecondsSinceEpoch;
    final cpn = List.generate(16, (i) {
      // Simple deterministic shuffle — good enough for a nonce
      return cpnChars[(random ~/ (1 << i)) % cpnChars.length];
    }).join();

    final uri =
        Uri.parse('https://www.youtube.com/api/stats/watchtime').replace(
      queryParameters: {
        'ns': 'yt',
        'el': 'detailpage',
        'cpn': cpn,
        'docid': videoId,
        'ver': '2',
        'cmt': actualListened.toString(),
        'len': songDuration.toString(),
        'st': '0',
        'et': actualListened.toString(),
        'state': 'playing',
        'cl': config['PAGE_CL'] ?? '',
        'ei': config['VISITOR_DATA'] ?? '',
        'c': config['INNERTUBE_CLIENT_NAME'] ?? 'WEB_REMIX',
        'cver': config['INNERTUBE_CLIENT_VERSION'] ?? '',
        'hl': config['HL'] ?? 'en',
        'cr': config['GL'] ?? 'US',
        'muted': '0',
        'volume': '100',
        'fs': '0',
      },
    );

    try {
      final cookies = await cookieJar.loadForRequest(uri);
      final cookieString =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final headers = <String, String>{
        ..._baseHeaders,
        if (cookieString.isNotEmpty) 'cookie': cookieString,
        'referer': 'https://music.youtube.com/',
        'origin': 'https://music.youtube.com',
      };

      await _client.get(uri, headers: headers);
    } catch (_) {
      // Silently ignore a failed ping must never interrupt playback
    }
  }

  /// Retrieves search suggestions for a given query.
  Future<List<String>> getSearchSuggestions(String query) async {
    final response = await constructRequest("music/get_search_suggestions",
        body: {"input": query});

    return traverseList(response, ["query"]).whereType<String>().toList();
  }

  /// Performs a search for music with the given query and returns a list of search results.
  Future<List<SearchResult>> search(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {"query": query, "params": null},
    );

    return traverseList(searchData, ["musicResponsiveListItemRenderer"])
        .map(SearchParser.parse)
        .where((e) => e != null)
        .cast<SearchResult>()
        .toList();
  }

  /// Performs a search specifically for songs with the given query and returns a list of song details.
  Future<List<SongDetailed>> searchSongs(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {
        "query": query,
        "params": "Eg-KAQwIARAAGAAgACgAMABqChAEEAMQCRAFEAo%3D"
      },
    );

    final results =
        traverseList(searchData, ["musicResponsiveListItemRenderer"]);
    final mappedResults = results.map(SongParser.parseSearchResult).toList();

    return mappedResults;
  }

  /// Performs a search specifically for videos with the given query and returns a list of video details.
  Future<List<VideoDetailed>> searchVideos(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {
        "query": query,
        "params": "Eg-KAQwIABABGAAgACgAMABqChAEEAMQCRAFEAo%3D"
      },
    );

    return traverseList(searchData, ["musicResponsiveListItemRenderer"])
        .map(VideoParser.parseSearchResult)
        .toList();
  }

  /// Performs a search specifically for artists with the given query and returns a list of artist details.
  Future<List<ArtistDetailed>> searchArtists(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {
        "query": query,
        "params": "Eg-KAQwIABAAGAAgASgAMABqChAEEAMQCRAFEAo%3D"
      },
    );

    return traverseList(searchData, ["musicResponsiveListItemRenderer"])
        .map(ArtistParser.parseSearchResult)
        .toList();
  }

  /// Performs a search specifically for albums with the given query and returns a list of album details.
  Future<List<AlbumDetailed>> searchAlbums(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {
        "query": query,
        "params": "Eg-KAQwIABAAGAEgACgAMABqChAEEAMQCRAFEAo%3D"
      },
    );

    return traverseList(searchData, ["musicResponsiveListItemRenderer"])
        .map(AlbumParser.parseSearchResult)
        .toList();
  }

  /// Performs a search specifically for playlists with the given query and returns a list of playlist details.
  Future<List<PlaylistDetailed>> searchPlaylists(String query) async {
    final searchData = await constructRequest(
      "search",
      body: {
        "query": query,
        "params": "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D"
      },
    );

    return traverseList(searchData, ["musicResponsiveListItemRenderer"])
        .map(PlaylistParser.parseSearchResult)
        .toList();
  }

  /// Retrieves detailed information about a song given its video ID.
  Future<SongFull> getSong(String videoId) async {
    if (!RegExp(r"^[a-zA-Z0-9-_]{11}$").hasMatch(videoId)) {
      throw Exception("Invalid videoId");
    }

    final data = await constructRequest("player", body: {"videoId": videoId});

    final song = SongParser.parse(data);
    if (song.videoId != videoId) {
      throw Exception("Invalid videoId");
    }
    return song;
  }

  /// Retrieves a list of up next songs for a given video ID.
  Future<List<UpNextsDetails>> getUpNexts(String videoId) async {
    if (!RegExp(r"^[a-zA-Z0-9-_]{11}$").hasMatch(videoId)) {
      throw Exception("Invalid videoId");
    }

    final data = await constructRequest("next", body: {
      "videoId": videoId,
      "playlistId": "RDAMVM$videoId",
      "isAudioOnly": true,
    });

    final tabs = data?['contents']?['singleColumnMusicWatchNextResultsRenderer']
                ?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']
            ?[0]?['tabRenderer']?['content']?['musicQueueRenderer']?['content']
        ?['playlistPanelRenderer']?['contents'];

    if (tabs == null) {
      throw Exception("Invalid response structure");
    }

    final List<dynamic> tabsList = tabs is List ? tabs : [];

    return tabsList.skip(1).map((item) {
      final renderer = item['playlistPanelVideoRenderer'];
      final videoId = renderer['videoId'] ?? '';
      final title = renderer['title']?['runs']?[0]?['text'] ?? '';

      // Parse artist information from longBylineText
      final longBylineRuns = renderer['longBylineText']?['runs'];
      final artistName = longBylineRuns?[0]?['text'] ?? '';
      final artistId = longBylineRuns?[0]?['navigationEndpoint']
          ?['browseEndpoint']?['browseId'];

      // Parse album information (usually at index 2 in longBylineText.runs)
      AlbumBasic? album;
      if (longBylineRuns != null && longBylineRuns.length > 2) {
        final albumName = longBylineRuns[2]?['text'];
        final albumId = longBylineRuns[2]?['navigationEndpoint']
            ?['browseEndpoint']?['browseId'];
        if (albumName != null && albumId != null) {
          album = AlbumBasic(
            name: albumName,
            albumId: albumId,
          );
        }
      }

      // Parse duration
      final durationText = renderer['lengthText']?['runs']?[0]?['text'];
      final duration = Parser.parseDuration(durationText) ?? 0;

      // Parse thumbnails
      final thumbnailsList = renderer['thumbnail']?['thumbnails'];
      final thumbnails = thumbnailsList is List
          ? thumbnailsList.map((item) => ThumbnailFull.fromMap(item)).toList()
          : <ThumbnailFull>[];

      return UpNextsDetails(
        type: "SONG",
        videoId: videoId,
        title: title,
        artists: ArtistBasic(
          name: artistName,
          artistId: artistId,
        ),
        album: album,
        duration: duration,
        thumbnails: thumbnails,
      );
    }).toList();
  }

  /// Retrieves detailed information about a video given its video ID.
  Future<VideoFull> getVideo(String videoId) async {
    if (!RegExp(r"^[a-zA-Z0-9-_]{11}$").hasMatch(videoId)) {
      throw Exception("Invalid videoId");
    }

    final data = await constructRequest("player", body: {"videoId": videoId});

    final video = VideoParser.parse(data);
    if (video.videoId != videoId) {
      throw Exception("Invalid videoId");
    }
    return video;
  }

  /// Retrieves the lyrics of a song given its video ID.
  Future<String?> getLyrics(String videoId) async {
    if (!RegExp(r"^[a-zA-Z0-9-_]{11}$").hasMatch(videoId)) {
      throw Exception("Invalid videoId");
    }

    final data = await constructRequest("next", body: {"videoId": videoId});
    final browseId =
        traverse(traverseList(data, ["tabs", "tabRenderer"])[1], ["browseId"]);

    final lyricsData =
        await constructRequest("browse", body: {"browseId": browseId});
    final lyrics =
        traverseString(lyricsData, ["description", "runs", "text"])?.trim();

    return lyrics
        ?.replaceAll("\r", "")
        .split("\n")
        .where((element) => element.isNotEmpty)
        .join("\n");
  }

  Future<TimedLyricsRes?> getTimedLyrics(String videoId) async {
    if (!RegExp(r"^[a-zA-Z0-9-_]{11}$").hasMatch(videoId)) {
      throw Exception("Invalid videoId");
    }

    final data = await constructRequest("next", body: {"videoId": videoId});
    final browseId =
        traverse(traverseList(data, ["tabs", "tabRenderer"])[1], ["browseId"]);

    final lyricsData = await constructRequest(
      "browse",
      body: {"browseId": browseId},
      options: ClientRequestOptions(
          clientName: androidClientName, clientVersion: androidClientVersion),
    );

    final timedLyrics =
        traverse(lyricsData, ['contents', 'type', 'lyricsData']);

    if (timedLyrics == null) {
      return null;
    }

    if (timedLyrics is List) {
      return null;
    }

    return TimedLyricsRes.fromMap(timedLyrics);
  }

  /// Retrieves detailed information about an artist given its artist ID.
  Future<ArtistFull> getArtist(String artistId) async {
    final data = await constructRequest("browse", body: {"browseId": artistId});

    return ArtistParser.parse(data, artistId);
  }

  /// Retrieves a list of songs by a specific artist given the artist's ID.
  Future<List<SongDetailed>> getArtistSongs(String artistId) async {
    final artistData =
        await constructRequest("browse", body: {"browseId": artistId});
    final browseToken =
        traverse(artistData, ["musicShelfRenderer", "title", "browseId"]);

    if (browseToken is List) {
      return [];
    }

    final songsData =
        await constructRequest("browse", body: {"browseId": browseToken});
    final continueToken = traverse(songsData, ["continuation"]);
    late final Map moreSongsData;

    if (continueToken is String &&
        continueToken.isNotEmpty &&
        continueToken != 'null') {
      moreSongsData = await constructRequest(
        "browse",
        query: {"continuation": continueToken},
      );
    } else {
      moreSongsData = {};
    }

    return [
      ...traverseList(songsData, ["musicResponsiveListItemRenderer"]),
      ...traverseList(moreSongsData, ["musicResponsiveListItemRenderer"]),
    ]
        .map((s) => SongParser.parseArtistSong(
              s,
              ArtistBasic(
                artistId: artistId,
                name: traverseString(artistData, ["header", "title", "text"]) ??
                    '',
              ),
            ))
        .toList();
  }

  /// Retrieves a list of albums by a specific artist given the artist's ID.
  Future<List<AlbumDetailed>> getArtistAlbums(String artistId) async {
    final artistData =
        await constructRequest("browse", body: {"browseId": artistId});
    final artistAlbumsData =
        traverseList(artistData, ["musicCarouselShelfRenderer"])[0];
    final browseBody =
        traverse(artistAlbumsData, ["moreContentButton", "browseEndpoint"]);
    if (browseBody is List) {
      return [];
    }
    final albumsData = await constructRequest(
      "browse",
      body: browseBody is List ? {} : browseBody,
    );

    return [
      ...traverseList(albumsData, ["musicTwoRowItemRenderer"])
          .map(
            (item) => AlbumParser.parseArtistAlbum(
              item,
              ArtistBasic(
                artistId: artistId,
                name: traverseString(albumsData, ["header", "runs", "text"]) ??
                    '',
              ),
            ),
          )
          .where(
            (album) => album.artist.artistId == artistId,
          ),
    ];
  }

  Future<List<AlbumDetailed>> getArtistSingles(String artistId) async {
    final artistData =
        await constructRequest("browse", body: {"browseId": artistId});

    final artistSinglesData =
        traverseList(artistData, ["musicCarouselShelfRenderer"]).length < 2
            ? []
            : traverseList(artistData, ["musicCarouselShelfRenderer"])
                .elementAt(1);

    final browseBody =
        traverse(artistSinglesData, ["moreContentButton", "browseEndpoint"]);
    if (browseBody is List) {
      return [];
    }

    final singlesData = await constructRequest(
      "browse",
      body: browseBody is List ? {} : browseBody,
    );

    return [
      ...traverseList(singlesData, ["musicTwoRowItemRenderer"])
          .map(
            (item) => AlbumParser.parseArtistAlbum(
              item,
              ArtistBasic(
                artistId: artistId,
                name: traverseString(singlesData, ["header", "runs", "text"]) ??
                    '',
              ),
            ),
          )
          .where(
            (album) => album.artist.artistId == artistId,
          ),
    ];
  }

  /// Retrieves detailed information about an album given its album ID.
  ///
  /// Songs (including videoIds, durations, thumbnails) are fully parsed from
  /// the single browse response — no secondary artist-songs fetch needed.
  Future<AlbumFull> getAlbum(String albumId) async {
    final browseId = (albumId.startsWith("OLAK") && !albumId.startsWith("VL"))
        ? "VL$albumId"
        : albumId;
    final data = await constructRequest("browse", body: {"browseId": browseId});
    return AlbumParser.parse(data, albumId);
  }

  /// Retrieves detailed information about a playlist given its playlist ID.
  Future<PlaylistFull> getPlaylist(String playlistId) async {
    if (!playlistId.startsWith("VL") && !playlistId.startsWith("MPREb_")) {
      playlistId = "VL$playlistId";
    }

    final data =
        await constructRequest("browse", body: {"browseId": playlistId});

    return PlaylistParser.parse(data, playlistId);
  }

  /// Retrieves a list of videos from a playlist given its playlist ID.
  ///
  /// Uses the fast internal YT Music browse endpoint first (1 single HTTP request
  /// returning up to 100 songs with duration and thumbnails in ~500ms).
  /// Falls back to the YouTube Data API v3 if the playlist is not a YT Music playlist.
  Future<List<VideoDetailed>> getPlaylistVideos(String playlistId) async {
    // 1. Fast Path: YT Music InnerTube browse
    try {
      final videos = await _getPlaylistVideosViaBrowse(playlistId);
      if (videos.isNotEmpty) {
        return videos;
      }
    } catch (_) {}

    // 2. Fallback Path: YouTube Data API v3
    final dataApiKey = config['DATA_API_KEY'];
    if (dataApiKey != null && dataApiKey.isNotEmpty) {
      try {
        return await _getPlaylistVideosViaDataApi(playlistId, dataApiKey);
      } catch (_) {}
    }

    return const [];
  }

  /// Fast path: uses the internal YT Music browse endpoint with full continuation support.
  Future<List<VideoDetailed>> _getPlaylistVideosViaBrowse(
      String playlistId) async {
    if (!playlistId.startsWith("VL") && !playlistId.startsWith("MPREb_")) {
      playlistId = "VL$playlistId";
    }

    final playlistData =
        await constructRequest("browse", body: {"browseId": playlistId});

    // 1. Direct shelf and continuation token extraction
    List? rawItems;
    String? continuationToken;
    try {
      final tabs = playlistData['contents']?['singleColumnBrowseResultsRenderer']?['tabs'] as List?;
      if (tabs != null && tabs.isNotEmpty) {
        final sectionContents = tabs[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents'] as List?;
        if (sectionContents != null && sectionContents.isNotEmpty) {
          for (final section in sectionContents) {
            if (section is Map) {
              final shelf = section['musicPlaylistShelfRenderer'] ?? section['musicShelfRenderer'];
              if (shelf is Map) {
                rawItems = shelf['contents'] as List?;
                continuationToken = _extractContinuationTokenFromShelf(shelf);
                if (rawItems != null) break;
              }
            }
          }
        }
      }
    } catch (_) {}

    // Fallback if direct tabs extraction missed it
    rawItems ??= traverseList(
      playlistData,
      ["musicPlaylistShelfRenderer", "musicResponsiveListItemRenderer"],
    );

    // Fallback for continuation token if not found in shelf
    continuationToken ??= _extractContinuationToken(playlistData);

    // Keep only song items, excluding continuationItemRenderer
    final songs = <dynamic>[];
    if (rawItems.isNotEmpty) {
      for (final item in rawItems) {
        if (item is Map && item.containsKey('continuationItemRenderer')) continue;
        songs.add(item);
      }
    }

    // 2. Fetch continuation pages if the playlist has more songs (>100 songs)
    var pageCount = 0;
    const maxPages = 20; // Support up to 2,100 songs
    final seenContinuations = <String>{};

    while (continuationToken != null &&
        continuationToken.isNotEmpty &&
        continuationToken != 'null' &&
        pageCount < maxPages) {
      if (!seenContinuations.add(continuationToken)) break;
      pageCount++;

      try {
        final songsData = await constructRequest(
          "browse",
          query: {"continuation": continuationToken},
        );

        // Reset token before extracting from the new response
        continuationToken = null;

        List? contItems;
        final shelfCont = songsData['continuationContents']?['musicPlaylistShelfContinuation'] ??
            songsData['continuationContents']?['musicShelfContinuation'] ??
            songsData['sectionListContinuation'];

        if (shelfCont is Map) {
          final contents = shelfCont['contents'] as List?;
          if (contents != null && contents.isNotEmpty) {
            contItems = contents;
          }
          continuationToken = _extractContinuationTokenFromShelf(shelfCont);
        }

        // Fallback token extraction from entire continuation response
        continuationToken ??= _extractContinuationToken(songsData);

        if (contItems != null && contItems.isNotEmpty) {
          for (final item in contItems) {
            if (item is Map && item.containsKey('continuationItemRenderer')) continue;
            songs.add(item);
          }
        } else {
          final fallbackItems =
              traverseList(songsData, ["musicResponsiveListItemRenderer"]);
          if (fallbackItems.isNotEmpty) {
            songs.addAll(fallbackItems);
          } else {
            break;
          }
        }
      } catch (_) {
        break;
      }
    }

    return songs
        .map(VideoParser.parsePlaylistVideo)
        .whereType<VideoDetailed>()
        .toList();
  }

  /// Extracts continuation token directly from a shelf or continuation shelf map.
  static String? _extractContinuationTokenFromShelf(Map shelf) {
    // 1. Check inside shelf['contents'] for continuationItemRenderer
    final contents = shelf['contents'] as List?;
    if (contents != null && contents.isNotEmpty) {
      for (int i = contents.length - 1; i >= 0 && i >= contents.length - 5; i--) {
        final item = contents[i];
        if (item is Map && item.containsKey('continuationItemRenderer')) {
          final token = _tokenFromContinuationEndpoint(
              item['continuationItemRenderer']?['continuationEndpoint']);
          if (token != null) return token;
        }
      }
    }

    // 2. Check shelf['continuations']
    final continuations = shelf['continuations'] as List?;
    if (continuations != null && continuations.isNotEmpty) {
      for (final c in continuations) {
        if (c is Map) {
          final token = c['nextContinuationData']?['continuation'] ??
              c['reloadContinuationData']?['continuation'] ??
              c['nextRadioContinuationData']?['continuation'];
          if (token != null &&
              token.toString().isNotEmpty &&
              token.toString() != 'null') {
            return token.toString();
          }
        }
      }
    }

    return null;
  }

  /// Extracts token from a continuation endpoint map.
  static String? _tokenFromContinuationEndpoint(dynamic endpoint) {
    if (endpoint is! Map) return null;
    final command = endpoint['continuationCommand'];
    if (command is Map) {
      final token = command['token'] ?? command['continuation'];
      if (token != null &&
          token.toString().isNotEmpty &&
          token.toString() != 'null') {
        return token.toString();
      }
    }
    final token = endpoint['continuation'] ?? endpoint['token'];
    if (token != null &&
        token.toString().isNotEmpty &&
        token.toString() != 'null') {
      return token.toString();
    }
    return null;
  }

  /// Deep recursive search for a continuation token in any InnerTube JSON response.
  static String? _extractContinuationToken(dynamic node) {
    if (node == null) return null;

    if (node is Map) {
      // Check continuationCommand -> token
      if (node.containsKey('continuationCommand') &&
          node['continuationCommand'] is Map) {
        final token = node['continuationCommand']['token'] ??
            node['continuationCommand']['continuation'];
        if (token != null &&
            token.toString().isNotEmpty &&
            token.toString() != 'null') {
          return token.toString();
        }
      }

      // Check nextContinuationData -> continuation
      if (node.containsKey('nextContinuationData') &&
          node['nextContinuationData'] is Map) {
        final token = node['nextContinuationData']['continuation'];
        if (token != null &&
            token.toString().isNotEmpty &&
            token.toString() != 'null') {
          return token.toString();
        }
      }

      // Check continuationItemRenderer
      if (node.containsKey('continuationItemRenderer') &&
          node['continuationItemRenderer'] is Map) {
        final token = _tokenFromContinuationEndpoint(
            node['continuationItemRenderer']['continuationEndpoint']);
        if (token != null) return token;
      }

      for (final v in node.values) {
        if (v is Map || v is List) {
          final token = _extractContinuationToken(v);
          if (token != null) return token;
        }
      }
    } else if (node is List) {
      for (int i = node.length - 1; i >= 0; i--) {
        final item = node[i];
        if (item is Map || item is List) {
          final token = _extractContinuationToken(item);
          if (token != null) return token;
        }
      }
    }

    return null;
  }

  /// Optimized Data API v3 fallback:
  /// Requests 'part=snippet,contentDetails' on playlistItems so metadata is retrieved immediately,
  /// then fetches only 'part=contentDetails' (duration) in parallel batches from videos.list.
  Future<List<VideoDetailed>> _getPlaylistVideosViaDataApi(
      String playlistId, String apiKey) async {
    const itemsUrl = 'https://www.googleapis.com/youtube/v3/playlistItems';
    const videosUrl = 'https://www.googleapis.com/youtube/v3/videos';

    final cleanPlaylistId = playlistId.startsWith("VL")
        ? playlistId.substring(2)
        : playlistId;

    Uri buildItemsUri(String? pageToken) =>
        Uri.parse(itemsUrl).replace(queryParameters: <String, String>{
          'part': 'snippet,contentDetails',
          'playlistId': cleanPlaylistId,
          'maxResults': '50',
          'key': apiKey,
          if (pageToken != null) 'pageToken': pageToken,
        });

    final firstResponse = await _client.get(buildItemsUri(null));
    if (firstResponse.statusCode != 200) {
      throw Exception(
          'getPlaylistVideos [playlistItems]: HTTP ${firstResponse.statusCode} — ${firstResponse.body}');
    }
    final firstBody = json.decode(firstResponse.body) as Map<String, dynamic>;

    final allPageBodies = <Map<String, dynamic>>[firstBody];

    // Fetch up to 10 additional pages (550 songs total)
    var currentPageToken = firstBody['nextPageToken'] as String?;
    final seenTokens = <String>{};
    var pageCount = 0;
    while (currentPageToken != null && currentPageToken.isNotEmpty && pageCount < 10) {
      if (!seenTokens.add(currentPageToken)) break;
      pageCount++;
      try {
        final resp = await _client.get(buildItemsUri(currentPageToken));
        if (resp.statusCode != 200) break;
        final body = json.decode(resp.body) as Map<String, dynamic>;
        allPageBodies.add(body);
        currentPageToken = body['nextPageToken'] as String?;
      } catch (_) {
        break;
      }
    }

    // Extract video items and IDs
    final videoItems = <Map<String, dynamic>>[];
    final videoIds = <String>[];
    final seenIds = <String>{};

    for (final body in allPageBodies) {
      final items = body['items'] as List<dynamic>? ?? [];
      for (final item in items) {
        if (item is Map<String, dynamic>) {
          final cd = item['contentDetails'] as Map<String, dynamic>?;
          final sn = item['snippet'] as Map<String, dynamic>?;
          final id = cd?['videoId']?.toString() ?? sn?['resourceId']?['videoId']?.toString();
          if (id != null && id.isNotEmpty && seenIds.add(id)) {
            videoIds.add(id);
            videoItems.add(item);
          }
        }
      }
    }

    if (videoIds.isEmpty) return const [];

    // Fetch ONLY durations from videos.list in parallel batches
    const batchSize = 50;
    final batchUris = <Uri>[];
    for (var i = 0; i < videoIds.length; i += batchSize) {
      final batch = videoIds.sublist(i, (i + batchSize).clamp(0, videoIds.length));
      batchUris.add(Uri.parse(videosUrl).replace(queryParameters: <String, String>{
        'part': 'contentDetails',
        'id': batch.join(','),
        'key': apiKey,
      }));
    }

    final durationMap = <String, int>{};
    try {
      final responses = await Future.wait(batchUris.map((uri) => _client.get(uri)));
      for (final response in responses) {
        if (response.statusCode == 200) {
          final body = json.decode(response.body) as Map<String, dynamic>;
          final items = body['items'] as List<dynamic>? ?? [];
          for (final item in items) {
            final id = item['id'] as String? ?? '';
            final cd = item['contentDetails'] as Map<String, dynamic>? ?? {};
            final dur = _parseIso8601Duration(cd['duration'] as String? ?? '');
            if (id.isNotEmpty) durationMap[id] = dur;
          }
        }
      }
    } catch (_) {}

    // Map directly from videoItems
    final results = <VideoDetailed>[];
    const thumbOrder = ['maxres', 'standard', 'high', 'medium', 'default'];

    for (final item in videoItems) {
      final cd = item['contentDetails'] as Map<String, dynamic>? ?? {};
      final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
      final id = cd['videoId']?.toString() ?? snippet['resourceId']?['videoId']?.toString() ?? '';

      final title = snippet['title'] as String? ?? '';
      final channelTitle = snippet['videoOwnerChannelTitle'] as String? ??
          snippet['channelTitle'] as String? ?? '';
      final channelId = snippet['videoOwnerChannelId'] as String? ??
          snippet['channelId'] as String?;

      final rawThumbs = snippet['thumbnails'] as Map<String, dynamic>? ?? {};
      final thumbnails = thumbOrder
          .where((k) => rawThumbs.containsKey(k))
          .map((k) {
            final t = rawThumbs[k] as Map<String, dynamic>;
            return ThumbnailFull(
              url: t['url'] as String? ?? '',
              width: t['width'] as int? ?? 0,
              height: t['height'] as int? ?? 0,
            );
          })
          .toList();

      final dur = durationMap[id] ?? 0;

      results.add(VideoDetailed(
        type: 'VIDEO',
        videoId: id,
        name: title,
        artist: ArtistBasic(
          name: channelTitle,
          artistId: channelId,
        ),
        duration: dur > 0 ? dur : null,
        thumbnails: thumbnails,
      ));
    }

    return results;
  }

  /// Parses an ISO 8601 duration string (e.g. `PT3H4M12S`) into seconds.
  static int _parseIso8601Duration(String raw) {
    final match = RegExp(
      r'P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?',
    ).firstMatch(raw);
    if (match == null) return 0;
    final weeks   = int.tryParse(match.group(1) ?? '') ?? 0;
    final days    = int.tryParse(match.group(2) ?? '') ?? 0;
    final hours   = int.tryParse(match.group(3) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(4) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(5) ?? '') ?? 0;
    return (weeks * 7 + days) * 86400 + hours * 3600 + minutes * 60 + seconds;
  }

  /// Retrieves the home sections of the music platform.
  Future<List<HomeSection>> getHomeSections() async {
    final homeFuture =
        constructRequest("browse", body: {"browseId": feMusicHome});
    final newReleasesFuture =
        constructRequest("browse", body: {"browseId": feMusicNewReleases})
            .catchError((_) => null);

    final results = await Future.wait([homeFuture, newReleasesFuture]);
    final homeData = results[0];
    final newReleasesData = results[1];

    final sections = <dynamic>[];
    if (homeData != null) {
      sections.addAll(
          traverseList(homeData, ["sectionListRenderer", "contents"]));
    }
    if (newReleasesData != null) {
      sections.addAll(
          traverseList(newReleasesData, ["sectionListRenderer", "contents"]));
    }

    dynamic continuation = _extractContinuationToken(homeData);
    final seen = <String>{};
    var pageCount = 0;
    while (continuation != null &&
        continuation.toString().isNotEmpty &&
        continuation != 'null' &&
        pageCount < 3) {
      if (!seen.add(continuation.toString())) break;
      pageCount++;
      try {
        final contData = await constructRequest("browse",
            query: {"continuation": continuation.toString()});

        List<dynamic> newContents = [];
        final contContents = contData?['continuationContents'];
        if (contContents is Map) {
          final slc = contContents['sectionListContinuation'];
          if (slc is Map) {
            final c = slc['contents'];
            if (c is List) newContents = c;
          }
        }
        if (newContents.isEmpty) {
          newContents =
              traverseList(contData, ["sectionListContinuation", "contents"]);
        }
        sections.addAll(newContents
            .where((i) => i is! Map || !i.containsKey('continuationItemRenderer')));
        continuation = _extractContinuationToken(contData);
      } catch (_) {
        break;
      }
    }

    return sections
        .map((item) {
          try {
            return Parser.parseHomeSection(item);
          } catch (_) {
            return null;
          }
        })
        .whereType<HomeSection>()
        .where((section) => section.contents.isNotEmpty)
        .toList();
  }

  //  Returns the YT Music home page as a list of [HomeSection] objects,
  //  mirroring exactly what the app shows: Top picks, Trending, New releases,
  //  Top albums, Moods & genres, etc.
  
  //  [country] is an ISO 3166-1 alpha-2 country code (e.g. `"US"`, `"IN"`,
  //  `"GB"`, `"JP"`).  Pass `null` or omit it to use the global / default
  //  locale that was set during [initialize].  Pass `"global"` to explicitly
  //  request the worldwide feed (`GL = "US"` is used as the neutral default
  //  when YT Music has no per-country feed).
  
  //  Each [HomeSection] has:
  //  - [HomeSection.title]       — localised display title (e.g. "Top picks")
  //  - [HomeSection.stableTitle] — locale-independent slug for reliable
  //    programmatic matching (e.g. `"top_picks"`, `"trending"`, `"top_albums"`)
  //  - [HomeSection.contents]    — list of [AlbumDetailed], [PlaylistDetailed],
  //    or [SongDetailed] items
  Future<List<HomeSection>> getHome({String? country}) async {
    final String? previousGl = config['GL'];
    final String? previousHl = config['HL'];

    if (country != null) {
      final resolved =
          country.toLowerCase() == 'global' ? 'US' : country.toUpperCase();
      config['GL'] = resolved;
    }

    try {
      // ── 1. Fetch all feeds in parallel ───────────────────────────────
      // Unauthenticated InnerTube sessions split home content across:
      // - feMusicHome:    Quick picks (songs) & personalized regional mixes (playlists)
      // - feMusicExplore: New albums & singles (albums), Trending (songs), New music videos
      // - feMusicCharts:  Regional video charts, Language playlists
      // - Global Charts:  FEmusic_charts with formData → ZZ (Global)
      // - Pop/Hits:       FEmusic_moods_and_genres_category → Featured playlists
      // - Feel Good:      FEmusic_moods_and_genres_category → Feeling happy playlists
      final responses = await Future.wait([
        constructRequest("browse", body: {"browseId": feMusicHome}),
        constructRequest("browse", body: {"browseId": feMusicExplore})
            .catchError((_) => null),
        constructRequest("browse", body: {"browseId": feMusicCharts})
            .catchError((_) => null),
        // Global Charts
        constructRequest("browse", body: {
          "browseId": feMusicCharts,
          "formData": {
            "selectedValues": [
              // "ZZ" (Global) form entity key from the charts country selector
              "EidleHBsb3JlX2NoYXJ0c19jb3VudHJ5X21lbnVfMzE2NzY2NTY3WlogkQEoAQ%3D%3D"
            ]
          }
        }).catchError((_) => null),
        // Pop / Today's biggest pop hits
        constructRequest("browse", body: {
          "browseId": "FEmusic_moods_and_genres_category",
          "params": "ggMPOg1uX1lLQkxHbHhWQUUy", // Pop genre
        }).catchError((_) => null),
        // Feel Good / Feeling happy
        constructRequest("browse", body: {
          "browseId": "FEmusic_moods_and_genres_category",
          "params": "ggMPOg1uXzZQbDB5eThLRTQ3", // Feel good mood
        }).catchError((_) => null),
      ]);

      // ── 2. Extract sections from all response feeds ────────────────────
      final sections = <dynamic>[];

      // Feeds 0–2: Home, Explore, Local Charts — add all shelves as-is
      for (final resp in responses.sublist(0, 3)) {
        if (resp != null) {
          sections.addAll(
              traverseList(resp, ["sectionListRenderer", "contents"]));
        }
      }

      // Helper to extract shelf title from a musicCarouselShelfBasicHeaderRenderer map
      String shelfTitle(Map bhr) {
        final runs = bhr['title']?['runs'];
        if (runs is List && runs.isNotEmpty && runs[0] is Map) {
          return (runs[0] as Map)['text']?.toString() ?? '';
        }
        return '';
      }

      // Feed 3: Global Charts — rename "Video charts" to "Top Global Hits"
      if (responses[3] != null) {
        final globalShelves = traverseList(
            responses[3], ["sectionListRenderer", "contents"]);
        for (final s in globalShelves) {
          if (s is Map && s.containsKey('musicCarouselShelfRenderer')) {
            final shelf = s['musicCarouselShelfRenderer'];
            if (shelf is Map) {
              final header = shelf['header'];
              if (header is Map) {
                final bhr = header['musicCarouselShelfBasicHeaderRenderer'];
                if (bhr is Map) {
                  final title = shelfTitle(bhr);
                  if (title.toLowerCase().contains('video chart') ||
                      title.toLowerCase().contains('chart')) {
                    // Rename so it doesn't collide with local "Video charts"
                    bhr['title'] = {
                      'runs': [
                        {'text': 'Top Global Hits'}
                      ]
                    };
                    sections.add(s);
                  }
                }
              }
            }
          }
        }
      }

      // Feed 4: Pop — take only "Featured playlists" shelf, rename to "Today's Pop Hits"
      if (responses[4] != null) {
        final popShelves = traverseList(
            responses[4], ["sectionListRenderer", "contents"]);
        for (final s in popShelves) {
          if (s is Map && s.containsKey('musicCarouselShelfRenderer')) {
            final shelf = s['musicCarouselShelfRenderer'];
            if (shelf is Map) {
              final header = shelf['header'];
              if (header is Map) {
                final bhr = header['musicCarouselShelfBasicHeaderRenderer'];
                if (bhr is Map) {
                  final title = shelfTitle(bhr);
                  if (title.toLowerCase().contains('featured')) {
                    bhr['title'] = {
                      'runs': [
                        {'text': "Today's Pop Hits"}
                      ]
                    };
                    sections.add(s);
                    break;
                  }
                }
              }
            }
          }
        }
      }

      // Feed 5: Feel Good — take only "Feeling happy" / feel-good shelf
      if (responses[5] != null) {
        final fgShelves = traverseList(
            responses[5], ["sectionListRenderer", "contents"]);
        for (final s in fgShelves) {
          if (s is Map && s.containsKey('musicCarouselShelfRenderer')) {
            final shelf = s['musicCarouselShelfRenderer'];
            if (shelf is Map) {
              final header = shelf['header'];
              if (header is Map) {
                final bhr = header['musicCarouselShelfBasicHeaderRenderer'];
                if (bhr is Map) {
                  final title = shelfTitle(bhr);
                  if (title.toLowerCase().contains('feeling happy') ||
                      title.toLowerCase().contains('feel-good')) {
                    sections.add(s);
                    break;
                  }
                }
              }
            }
          }
        }
      }

      // ── 3. Follow continuation pages if available ──────────────────────
      dynamic continuation = _extractContinuationToken(responses[0]);
      final seen = <String>{};
      var pageCount = 0;

      while (continuation != null &&
          continuation.toString().isNotEmpty &&
          continuation.toString() != 'null' &&
          pageCount < 3) {
        if (!seen.add(continuation.toString())) break;
        pageCount++;
        try {
          final contData = await constructRequest("browse",
              query: {"continuation": continuation.toString()});

          List<dynamic> newContents = [];
          final contContents = contData?['continuationContents'];
          if (contContents is Map) {
            final slc = contContents['sectionListContinuation'];
            if (slc is Map) {
              final c = slc['contents'];
              if (c is List) newContents = c;
            }
          }

          if (newContents.isEmpty) {
            newContents = traverseList(
                contData, ["sectionListContinuation", "contents"]);
          }

          for (final item in newContents) {
            if (item is Map &&
                !item.containsKey('continuationItemRenderer')) {
              sections.add(item);
            }
          }

          continuation = _extractContinuationToken(contData);
        } catch (_) {
          break;
        }
      }

      // ── 4. Parse sections using the accurate parser ────────────────────
      final seenTitles = <String>{};
      final result = <HomeSection>[];

      for (final item in sections) {
        try {
          final section = Parser.parseHomeSection(item);
          if (section == null) continue;
          if (section.contents.isEmpty) continue;
          final cleanTitle = section.title.toLowerCase().trim();
          if (cleanTitle.isEmpty || !seenTitles.add(cleanTitle)) continue;
          result.add(section);
        } catch (_) {
          continue;
        }
      }

      return result;
    } finally {
      if (country != null) {
        if (previousGl != null) {
          config['GL'] = previousGl;
        } else {
          config.remove('GL');
        }
        if (previousHl != null) {
          config['HL'] = previousHl;
        }
      }
    }
  }
}
