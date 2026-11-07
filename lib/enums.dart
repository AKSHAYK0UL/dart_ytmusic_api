enum PageType {
  musicPageTypeAlbum,
  musicPageTypePlaylist,
  musicVideoTypeOmv;

  static string(PageType pageType) {
    switch (pageType) {
      case PageType.musicPageTypeAlbum:
        return 'MUSIC_PAGE_TYPE_ALBUM';
      case PageType.musicPageTypePlaylist:
        return 'MUSIC_PAGE_TYPE_PLAYLIST';
      case PageType.musicVideoTypeOmv:
        return 'MUSIC_VIDEO_TYPE_OMV';
    }
  }
}

const String feMusicHome = "FEmusic_home";
const String feMusicExplore = "FEmusic_explore";
const String feMusicCharts = "FEmusic_charts";
const String feMusicNewReleases = "FEmusic_new_releases";
const String feMusicNewReleasesAlbums = "FEmusic_new_releases_albums";
const String androidClientName = 'ANDROID_MUSIC';
const String androidClientVersion = '8.05.50';
