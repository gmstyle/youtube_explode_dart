import 'channels/channels.dart';
import 'playlists/playlist_client.dart';
import 'reverse_engineering/challenges/js_challenge.dart';
import 'reverse_engineering/po_token/po_token_provider.dart';
import 'reverse_engineering/sabr/sabr_downloader.dart';
import 'reverse_engineering/youtube_http_client.dart';
import 'search/search_client.dart';
import 'videos/video_client.dart';

/// Library entry point.
class YoutubeExplode {
  final YoutubeHttpClient _httpClient;

  /// Queries related to YouTube videos.
  late final VideoClient videos;

  /// Queries related to YouTube playlists.
  late final PlaylistClient playlists;

  /// Queries related to YouTube channels.
  late final ChannelClient channels;

  /// YouTube search queries.
  late final SearchClient search;

  late final BaseJSChallengeSolver? _jsSolver;
  late final BasePoTokenProvider? _poTokenProvider;
  late final BaseSabrDownloader? _sabrDownloader;

  /// Initializes an instance of [YoutubeExplode].
  ///
  /// Optionally provide a [jsSolver] to decode YouTube's JavaScript challenges
  /// (n-sig and signature parameters), and/or a [poTokenProvider] to supply
  /// content-bound Proof-of-Origin tokens required by YouTube's CDN for most
  /// clients (iOS, Android, Web) since 2025.
  ///
  /// Optionally provide a [sabrDownloader] to download SABR-only adaptive streams
  /// returned by the WEB client (requires Deno on desktop).
  ///
  /// Without a [poTokenProvider] the library will still attempt to fetch
  /// streams, but may receive HTTP 403 responses from the Google Video Server
  /// for clients that require PO tokens.
  YoutubeExplode({
    YoutubeHttpClient? httpClient,
    BaseJSChallengeSolver? jsSolver,
    BasePoTokenProvider? poTokenProvider,
    BaseSabrDownloader? sabrDownloader,
  }) : _httpClient = httpClient ?? YoutubeHttpClient() {
    _jsSolver = jsSolver;
    _poTokenProvider = poTokenProvider;
    _sabrDownloader = sabrDownloader;
    videos = VideoClient(_httpClient,
        jsSolver: jsSolver,
        poTokenProvider: poTokenProvider,
        sabrDownloader: sabrDownloader);
    playlists = PlaylistClient(_httpClient);
    channels = ChannelClient(_httpClient);
    search = SearchClient(_httpClient);
  }

  /// Closes the HttpClient assigned to this [YoutubeHttpClient].
  /// Should be called after this is not used anymore.
  void close() {
    _httpClient.close();
    _jsSolver?.dispose();
    _poTokenProvider?.dispose();
    _sabrDownloader?.dispose();
  }
}
