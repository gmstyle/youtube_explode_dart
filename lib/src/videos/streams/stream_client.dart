import 'dart:collection';

import 'package:logging/logging.dart';

import '../../exceptions/exceptions.dart';
import '../../extensions/helpers_extension.dart';
import '../../retry.dart';
import '../../reverse_engineering/challenges/js_challenge.dart';
import '../../reverse_engineering/heuristics.dart';
import '../../reverse_engineering/models/stream_info_provider.dart';
import '../../reverse_engineering/pages/watch_page.dart';
import '../../reverse_engineering/player/player_response.dart';
import '../../reverse_engineering/po_token/po_token_policy.dart';
import '../../reverse_engineering/po_token/po_token_provider.dart';
import '../../reverse_engineering/sabr/sabr_downloader.dart';
import '../../reverse_engineering/sabr/sabr_stream_context.dart';
import '../../reverse_engineering/youtube_http_client.dart';
import '../video_id.dart';
import '../youtube_api_client.dart';
import 'stream_controller.dart';
import 'streams.dart';

/// Queries related to media streams of YouTube videos.
class StreamClient {
  static final _logger = Logger('YoutubeExplode.StreamsClient');
  final YoutubeHttpClient _httpClient;
  final StreamController _controller;
  final BaseJSChallengeSolver? _jsChallengeSolver;
  final BasePoTokenProvider? _poTokenProvider;
  final BaseSabrDownloader? _sabrDownloader;

  /// Initializes an instance of [StreamClient]
  StreamClient(this._httpClient,
      {BaseJSChallengeSolver? jsSolver,
      BasePoTokenProvider? poTokenProvider,
      BaseSabrDownloader? sabrDownloader})
      : _controller = StreamController(_httpClient),
        _jsChallengeSolver = jsSolver,
        _poTokenProvider = poTokenProvider,
        _sabrDownloader = sabrDownloader;

  /// Gets the manifest that contains information
  /// about available streams in the specified video.
  ///
  /// See [YoutubeApiClient] for all the possible clients that can be set using the [ytClients] parameter.
  /// If [ytClients] is null the library automatically manages the clients, otherwise only the clients provided are used.
  /// Currently by default the [YoutubeApiClient.visionos] client is used,
  /// with [YoutubeApiClient.androidVr] as fallback when [ytClients] is null.
  /// If a js solver is provided, [YoutubeApiClient.safari] is used additionally.
  ///
  ///
  /// Note: if using any android client youtube often prevents downloading the same stream multiple times or downloading more than one stream from the same manifest.
  /// Note: that age restricted videos are no longer support due to the changes in the YouTube API.
  /// Note: [YoutubeApiClient.androidSdkless] / [YoutubeApiClient.android] often return adaptive
  /// (audio/video-only) URLs that the CDN rejects with HTTP 403; prefer [YoutubeApiClient.androidVr].
  ///
  /// If [requireWatchPage] (default: true) is set to false the watch page is not used to extract the streams (so the process can be faster) but
  /// it probably will be less reliable.
  /// If the extracted streams require signature decoding for which the watch page is required, the client will automatically fetch the watch page anyways (e.g. [YoutubeApiClient.tv]).
  ///
  /// If the extraction fails an exception is thrown, to diagnose the issue enable the logging from the `logging` package, and open an issue with the output.
  /// For example add at the beginning of your code:
  /// ```dart
  /// Logger.root.level = Level.FINER;
  /// Logger.root.onRecord.listen((e)  {
  ///   print(e);
  ///    if (e.error != null) {
  ///     print(e.error);
  ///     print(e.stackTrace);
  ///   }
  /// });
  /// ```
  Future<StreamManifest> getManifest(dynamic videoId,
      {@Deprecated(
          'Use the ytClient parameter instead passing the proper [YoutubeApiClient]s')
      bool fullManifest = false,
      List<YoutubeApiClient>? ytClients,
      bool requireWatchPage = true}) async {
    assert(ytClients == null || ytClients.isNotEmpty,
        'ytClients cannot be an empty list');

    videoId = VideoId.fromString(videoId);
    final clients = ytClients ??
        (_poTokenProvider != null
            ? [YoutubeApiClient.safari]
            : [YoutubeApiClient.visionos, YoutubeApiClient.androidVr]);

    if (_jsChallengeSolver != null &&
        ytClients == null &&
        _poTokenProvider == null) {
      clients.add(YoutubeApiClient.safari);
    }

    final clientQueue = Queue<YoutubeApiClient>.from(
      ytClients ?? _initialClients(sharedWatchPage),
    );
    final triedClients = <YoutubeApiClient>{};

    final uniqueStreams = LinkedHashSet<StreamInfo>(
      equals: (a, b) {
        if (a.runtimeType != b.runtimeType) return false;
        if (a is AudioStreamInfo && b is AudioStreamInfo) {
          return a.tag == b.tag && a.audioTrack == b.audioTrack;
        }
        return a.tag == b.tag;
      },
      hashCode: (e) {
        if (e is AudioStreamInfo) {
          return e.tag.hashCode ^ e.audioTrack.hashCode;
        }
        return e.tag.hashCode;
      },
    );

    Object? lastException;
    String? hlsManifestUrl;

    while (clientQueue.isNotEmpty) {
      final client = clientQueue.removeFirst();
      if (!triedClients.add(client)) continue;

      _logger.fine(
          'Getting stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}');
      try {
        await retry(_httpClient, () async {
          String? hlsUrlCandidate;
          final streams = (await _getStreams(
            videoId,
            ytClient: client,
            requireWatchPage: ytClients != null ? requireWatchPage : false,
            watchPage: sharedWatchPage,
            skipSabr: hasDirectHttps,
            onHlsManifest: (url) => hlsUrlCandidate = url,
          ).toList())
              .where(_hasPlayableUrl)
              .toList();
          if (streams.isEmpty) {
            throw VideoUnavailableException(
              'Video "$videoId" does not contain any playable streams.',
            );
          }

          if (streams.any((s) => s is! SabrStreamInfo)) {
            hasDirectHttps = true;
          }

          final probe = streams.firstWhere(
            (s) => s is! SabrStreamInfo,
            orElse: () => streams.first,
          );
(??)          if (_poTokenProvider == null &&
(??)              !streams.any((s) => s is SabrStreamInfo)) {
(??)            final response = await _httpClient.head(probe.url);
(??)            if (response.statusCode == 403) {
              throw YoutubeExplodeException(
                'Video $videoId returned 403 (stream: ${adaptive.tag})',
              );
            }

            // Muxed-only HEAD can hide CDN 403s on adaptive URLs (e.g. androidSdkless).
            final adaptive = streams.cast<StreamInfo?>().firstWhere(
                  (s) =>
                      s is AudioOnlyStreamInfo || s is VideoOnlyStreamInfo,
                  orElse: () => null,
                );
            if (adaptive != null) {
              final adaptiveHead = await _httpClient.head(adaptive.url);
              if (adaptiveHead.statusCode == 403) {
                throw YoutubeExplodeException(
                  'Video $videoId returned 403 (stream: ${adaptive.tag})',
                );
              }
            }
          }
          uniqueStreams.addAll(streams);
          hlsManifestUrl ??= hlsUrlCandidate;
        });
      } catch (e, s) {
        _logger.severe(
            'Failed to get stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}. Reason: $e\n',
            e,
            s);
        lastException = e;
        _appendDynamicFallbackClients(
          clientQueue,
          triedClients,
          client,
          sharedWatchPage,
        );
      }
    }

    // Last-resort TV clients for restricted videos (no PO provider — tokens are WEB-bound).
    if (uniqueStreams.isEmpty &&
        ytClients == null &&
        _poTokenProvider == null) {
      return getManifest(
        videoId,
        ytClients: [
          YoutubeApiClient.tvDowngraded,
          YoutubeApiClient.tv,
        ],
        requireWatchPage: requireWatchPage,
      );
    }
    if (uniqueStreams.isEmpty) {
      if (lastException is Error && lastException.stackTrace != null) {
        throw Error.throwWithStackTrace(
            lastException, lastException.stackTrace!);
      }
      throw lastException ??
          VideoUnavailableException(
              'Video "$videoId" has no available streams');
    }
    return StreamManifest(uniqueStreams.toList(),
        hlsManifestUrl: hlsManifestUrl);
  }

  /// Default innertube clients (yt-dlp Jan 2026: visionos, then WEB when configured).
  List<YoutubeApiClient> _defaultClients() {
    final clients = <YoutubeApiClient>[YoutubeApiClient.visionos];
    if (_poTokenProvider != null || _jsChallengeSolver != null) {
      clients.add(YoutubeApiClient.safari);
    }
    return clients;
  }

  /// Builds the initial client queue including static and watch-page fallbacks.
  List<YoutubeApiClient> _initialClients(WatchPage? watchPage) {
    final clients = _defaultClients();
    if (watchPage == null) return clients;

    if (watchPage.isMadeForKids &&
        (_jsChallengeSolver != null || _poTokenProvider != null)) {
      _appendClientIfAbsent(clients, YoutubeApiClient.webEmbedded);
      _appendClientIfAbsent(clients, YoutubeApiClient.tvDowngraded);
    }
    if (watchPage.playerResponse?.isAgeGated ?? false) {
      _appendClientIfAbsent(clients, YoutubeApiClient.webEmbedded);
    }
    return clients;
  }

  void _appendClientIfAbsent(
    List<YoutubeApiClient> clients,
    YoutubeApiClient client,
  ) {
    if (!clients.contains(client)) clients.add(client);
  }

  void _enqueueClientIfAbsent(
    Queue<YoutubeApiClient> queue,
    Set<YoutubeApiClient> tried,
    YoutubeApiClient client,
  ) {
    if (!tried.contains(client) && !queue.contains(client)) {
      queue.add(client);
    }
  }

  void _appendDynamicFallbackClients(
    Queue<YoutubeApiClient> queue,
    Set<YoutubeApiClient> tried,
    YoutubeApiClient failedClient,
    WatchPage? watchPage,
  ) {
    if (watchPage == null) return;

    if (watchPage.isMadeForKids &&
        (failedClient == YoutubeApiClient.visionos ||
            failedClient == YoutubeApiClient.androidVr) &&
        (_jsChallengeSolver != null || _poTokenProvider != null)) {
      _enqueueClientIfAbsent(queue, tried, YoutubeApiClient.webEmbedded);
      _enqueueClientIfAbsent(queue, tried, YoutubeApiClient.tvDowngraded);
    }

    if (watchPage.playerResponse?.isAgeGated ?? false) {
      _enqueueClientIfAbsent(queue, tried, YoutubeApiClient.webEmbedded);
    }
  }

  /// Gets the HTTP Live Stream (HLS) manifest URL
  /// for the specified video (if it's a live video stream).
  Future<String> getHttpLiveStreamUrl(VideoId videoId) async {
    final watchPage = await WatchPage.get(_httpClient, videoId.value);

    final playerResponse = watchPage.playerResponse;

    if (playerResponse == null) {
      throw TransientFailureException(
        "Couldn't extract the playerResponse from the Watch Page!",
      );
    }

    if (!playerResponse.isVideoPlayable) {
      throw VideoUnplayableException.unplayable(
        videoId,
        reason: playerResponse.videoPlayabilityError ?? '',
      );
    }

    final hlsManifest = playerResponse.hlsManifestUrl;
    if (hlsManifest == null) {
      throw VideoUnplayableException.notLiveStream(videoId);
    }
    return hlsManifest;
  }

  /// Gets the actual stream which is identified by the specified metadata.
  /// Usually this downloads the bytes of the stream.
  /// For HLS streams all the fragments are concatenated into a single stream.
  /// For SABR streams bytes are fetched via [BaseSabrDownloader].
  /// The SABR session is refreshed immediately before download so the PO token
  /// and /player response stay bound to the same watch-page session.
  Stream<List<int>> get(StreamInfo streamInfo) async* {
    if (streamInfo is SabrStreamInfo) {
      final downloader = _sabrDownloader;
      if (downloader == null) {
        throw YoutubeExplodeException(
          'SABR stream itag ${streamInfo.tag} requires a SabrDownloader '
          '(e.g. DenoSabrDownloader.init()).',
        );
      }

      Object? lastError;
      StackTrace? lastStack;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final fresh = await _fetchFreshSabrStream(streamInfo);
          if (attempt > 0) {
            _logger.info(
              'Retrying SABR download for itag ${streamInfo.tag} with fresh session',
            );
          }
          await for (final chunk in downloader.download(fresh)) {
            yield chunk;
          }
          return;
        } on YoutubeExplodeException catch (e, s) {
          lastError = e;
          lastStack = s;
          _logger.warning('SABR download attempt ${attempt + 1} failed: $e');
        }
      }
      Error.throwWithStackTrace(lastError!, lastStack!);
    }
    yield* _httpClient.getStream(streamInfo, streamClient: this);
  }

(??)  Stream<StreamInfo> _getStreams(VideoId videoId,
(??)      {required YoutubeApiClient ytClient,
(??)      bool requireWatchPage = true}) async* {
(??)    // Use await for instead of yield* to catch exceptions
(??)    await for (final stream
(??)        in _getStream(videoId, ytClient, requireWatchPage: requireWatchPage)) {
      yield stream;
    }
  }

(??)  Stream<StreamInfo> _getStream(VideoId videoId, YoutubeApiClient ytClient,
(??)      {bool requireWatchPage = true}) async* {
(??)    WatchPage? watchPage;
(??)    if (requireWatchPage) {
(??)      watchPage = await WatchPage.get(_httpClient, videoId.value);
(??)    }

    final usesPoToken = YoutubeClientPoPolicy.usesWebPoToken(ytClient);

    String? playerPoToken;
    String? gvsPoToken;
    if (_poTokenProvider != null && watchPage != null && usesPoToken) {
      try {
        final innertubeCtx =
            watchPage.ytCfg['INNERTUBE_CONTEXT'] as Map<String, dynamic>? ?? {};
        final clientCtx = innertubeCtx['client'] as Map<String, dynamic>? ?? {};
        final context = PoTokenContext(
          visitorData: clientCtx['visitorData'] as String? ?? '',
          clientVersion: clientCtx['clientVersion'] as String? ?? '',
          innertubeContext: innertubeCtx,
          ytConfig: watchPage.ytCfg,
          initialAttestationDataSource: watchPage.initialAttestationDataSource,
        );
        playerPoToken = await _poTokenProvider!.generatePoToken(
          videoId.value,
          context,
          kind: PoTokenKind.player,
        );
        gvsPoToken = await _poTokenProvider!.generatePoToken(
          videoId.value,
          context,
          kind: PoTokenKind.gvs,
        );
        _logger.fine('Generated PO tokens for video ${videoId.value}');
      } catch (e) {
        _logger.warning('Failed to generate PO Token: $e');
      }
    }

    final playerClient =
        playerPoToken != null && watchPage != null && usesPoToken
            ? _webClientFromWatchPage(watchPage)
            : ytClient;

    final playerResponse = await _controller.getPlayerResponse(
      videoId,
      playerClient,
      watchPage: watchPage,
      poToken: playerPoToken,
    );

    if (!playerResponse.previewVideoId.isNullOrWhiteSpace) {
      throw VideoRequiresPurchaseException.preview(
        videoId,
        VideoId(playerResponse.previewVideoId!),
      );
    }

    if (playerResponse.videoPlayabilityError?.contains('payment') ?? false) {
      throw VideoRequiresPurchaseException(videoId);
    }

    if (!playerResponse.isVideoPlayable) {
      throw VideoUnplayableException.unplayable(
        videoId,
        reason: playerResponse.videoPlayabilityError ?? '',
      );
    }
    onHlsManifest?.call(playerResponse.hlsManifestUrl);
    yield* _parseStreamInfo(
      playerResponse.streams,
      watchPage: watchPage,
      videoId: videoId,
      gvsPoToken: gvsPoToken,
      ytClient: ytClient,
    );

    if (!skipSabr &&
        _sabrDownloader != null &&
        gvsPoToken != null &&
        watchPage != null &&
        playerResponse.hasSabrStreaming) {
      yield* _parseSabrStreams(
        playerResponse: playerResponse,
        watchPage: watchPage,
        videoId: videoId,
        poToken: gvsPoToken,
      );
    }

    if (!playerResponse.dashManifestUrl.isNullOrWhiteSpace &&
        watchPage != null) {
      final dashUrl = await _prepareManifestUrl(
        playerResponse.dashManifestUrl!,
        watchPage,
        gvsPoToken,
        ytClient,
        StreamingProtocol.dash,
      );
      if (dashUrl != null) {
        final dashManifest = await _controller.getDashManifest(dashUrl);
        yield* _parseStreamInfo(
          dashManifest.streams,
          watchPage: watchPage,
          videoId: videoId,
          gvsPoToken: gvsPoToken,
          ytClient: ytClient,
        );
      }
    }
    if (!playerResponse.hlsManifestUrl.isNullOrWhiteSpace &&
        watchPage != null) {
      final hlsUrl = await _prepareManifestUrl(
        playerResponse.hlsManifestUrl!,
        watchPage,
        gvsPoToken,
        ytClient,
        StreamingProtocol.hls,
      );
      if (hlsUrl != null) {
        final hlsManifest = await _controller.getHlsManifest(hlsUrl);
        yield* _parseStreamInfo(
          hlsManifest.streams,
          watchPage: watchPage,
          videoId: videoId,
          gvsPoToken: gvsPoToken,
          ytClient: ytClient,
        );
      }
    }
  }

  Stream<StreamInfo> _parseStreamInfo(
    Iterable<StreamInfoProvider> streams, {
    WatchPage? watchPage,
    VideoId? videoId,
    String? gvsPoToken,
    YoutubeApiClient? ytClient,
  }) async* {
    // First pass: collect all unique challenges
    final nChallenges = <String>{};
    final sigChallenges = <String>{};

    final solver = _jsChallengeSolver;
    if (solver != null) {
      for (final stream in streams) {
        try {
          final url = Uri.parse(stream.url);
          if (url.queryParameters.containsKey('n')) {
            nChallenges.add(url.queryParameters['n']!);
          }
          if (stream.signatureParameter != null) {
            sigChallenges.add(stream.signature!);
          }
        } catch (e) {
          // Skip invalid URLs, will be handled in second pass
        }
      }
    }

    // Bulk solve all challenges
    final solvedChallenges = <String, String?>{};
    if (watchPage != null &&
        solver != null &&
        (nChallenges.isNotEmpty || sigChallenges.isNotEmpty)) {
      final requests = <JSChallengeType, List<String>>{};
      if (nChallenges.isNotEmpty) {
        requests[JSChallengeType.n] = nChallenges.toList();
      }
      if (sigChallenges.isNotEmpty) {
        requests[JSChallengeType.sig] = sigChallenges.toList();
      }

      try {
        solvedChallenges
            .addAll(await solver.solveBulk(watchPage.sourceUrl!, requests));
      } catch (e) {
        _logger.warning('Could not bulk solve challenges: $e');
        // Fall back to individual solving if bulk fails
      }
    }

    // Second pass: process streams with solved challenges
    for (final stream in streams) {
      final itag = stream.tag;
      late Uri url;
      try {
        url = Uri.parse(stream.url);
      } catch (e) {
        continue;
      }
      // YouTube occasionally returns blank / relative URLs; HEAD-ing those
      // throws ArgumentError("No host specified in URI") and aborts the client.
      if (!_isAbsoluteHttpUrl(url)) {
        _logger.warning(
            'Skipping stream itag $itag with non-absolute URL: "${stream.url}"');
        continue;
      }

      if (solver != null && watchPage != null) {
        if (url.queryParameters.containsKey('n')) {
          final nParam = url.queryParameters['n']!;
          final decoded = solvedChallenges[nParam];
          if (decoded != null) {
            url = url.setQueryParam('n', decoded);
            _logger.fine(
                'Decoded n-sig for stream itag $itag. $nParam -> $decoded}');
          } else {
            // Fallback to individual solving if bulk solving didn't provide result
            try {
              final individualDecoded = await solver.solve(
                  watchPage.sourceUrl!, JSChallengeType.n, nParam);
              url = url.setQueryParam('n', individualDecoded);
              _logger.fine(
                  'Decoded n-sig for stream itag $itag (individual). $nParam -> $individualDecoded}');
            } catch (e) {
              _logger.warning('Could not decipher n-sig using JS solver: $e');
            }
          }
        }
        if (stream.signatureParameter != null) {
          final sigParam = stream.signatureParameter!;
          final sig = stream.signature!;
          final decoded = solvedChallenges[sig];
          if (decoded != null) {
            url = url.setQueryParam(sigParam, decoded);
            _logger.fine(
                'Decoded signature for stream itag $itag. $sigParam -> $decoded}');
          } else {
            // Fallback to individual solving if bulk solving didn't provide result
            try {
              final individualDecoded = await solver.solve(
                  watchPage.sourceUrl!, JSChallengeType.sig, sig);
              url = url.setQueryParam(sigParam, individualDecoded);
              _logger.fine(
                  'Decoded signature for stream itag $itag (individual). $sigParam -> $individualDecoded}');
            } catch (e) {
              _logger
                  .warning('Could not decipher signature using JS solver: $e');
            }
          }
        }
      }

      // Append GVS PO Token when client policy requires it (WEB tier).
      if (gvsPoToken != null &&
          ytClient != null &&
          YoutubeClientPoPolicy.shouldAppendGvsPoToken(
            ytClient,
            StreamingProtocol.https,
            gvsPoToken,
          )) {
        url = url.setQueryParam('pot', gvsPoToken);
      }

      var contentLength = stream.contentLength ??
          (await _httpClient.getContentLength(url, validate: false));

      if ((contentLength == null || contentLength <= 0) && gvsPoToken != null) {
        final isMuxed = stream.source != StreamSource.adaptive &&
            !stream.audioCodec.isNullOrWhiteSpace &&
            !stream.videoCodec.isNullOrWhiteSpace;
        if (isMuxed) {
          _logger.warning(
              'Keeping muxed stream itag $itag without verified content length (PO token flow)');
          contentLength = stream.contentLength ?? 1;
        }
      }

      if (contentLength == null || contentLength <= 0) {
        continue;
      }

      final container = StreamContainer.parse(stream.container!);
      final fileSize = FileSize(contentLength);
      final bitrate = Bitrate(stream.bitrate!);

      final audioCodec = stream.audioCodec;
      final videoCodec = stream.videoCodec;

      // HLS
      if (stream.source == StreamSource.hls) {
        if (stream.audioOnly) {
          yield HlsAudioStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            '',
            '',
            stream.codec,
          );
          continue;
        }

        final framerate = Framerate(stream.framerate ?? 24);
        // TODO: Implement quality from itag
        final videoQuality = VideoQualityUtil.fromLabel(stream.qualityLabel);
        final videoWidth = stream.videoWidth;
        final videoHeight = stream.videoHeight;
        final videoResolution = videoWidth != null && videoHeight != null
            ? VideoResolution(videoWidth, videoHeight)
            : videoQuality.toVideoResolution();

        if (stream.videoOnly) {
          yield HlsVideoStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            videoCodec ?? '',
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
            stream.audioItag,
          );
        } else {
          yield HlsMuxedStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            videoCodec!,
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
          );
        }
        continue;
      }

      // Muxed or Video-only
      if (!videoCodec.isNullOrWhiteSpace) {
        final framerate = Framerate(stream.framerate ?? 24);
        // TODO: Implement quality from itag
        final videoQuality = VideoQualityUtil.fromLabel(stream.qualityLabel);

        final videoWidth = stream.videoWidth;
        final videoHeight = stream.videoHeight;
        final videoResolution = videoWidth != null && videoHeight != null
            ? VideoResolution(videoWidth, videoHeight)
            : videoQuality.toVideoResolution();

        // Muxed
        if (!audioCodec.isNullOrWhiteSpace &&
            stream.source != StreamSource.adaptive) {
          assert(stream.audioTrack == null);
          yield MuxedStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            videoCodec!,
            videoQuality.qualityString,
            videoQuality,
            videoResolution,
            framerate,
            stream.codec,
          );
          continue;
        }

        // Video only
        yield VideoOnlyStreamInfo(
          videoId ?? watchPage!.videoId,
          itag,
          url,
          container,
          fileSize,
          bitrate,
          videoCodec!,
          videoQuality.qualityString,
          videoQuality,
          videoResolution,
          framerate,
          stream.fragments ?? const [],
          stream.codec,
        );
        continue;
        // Audio-only
      } else if (!audioCodec.isNullOrWhiteSpace) {
        yield AudioOnlyStreamInfo(
            videoId ?? watchPage!.videoId,
            itag,
            url,
            container,
            fileSize,
            bitrate,
            audioCodec!,
            stream.qualityLabel!,
            stream.fragments ?? const [],
            stream.codec,
            stream.audioTrack);
      } else {
        throw YoutubeExplodeException('Could not extract stream codec');
      }
    }
  }

  /// Absolute http(s) URL with a non-empty host — safe for [HttpClient] HEAD/GET.
  static bool _isAbsoluteHttpUrl(Uri url) =>
      (url.scheme == 'http' || url.scheme == 'https') && url.host.isNotEmpty;

  static bool _hasPlayableUrl(StreamInfo stream) =>
      stream is SabrStreamInfo || _isAbsoluteHttpUrl(stream.url);

  Stream<StreamInfo> _parseSabrStreams({
    required PlayerResponse playerResponse,
    required WatchPage watchPage,
    required VideoId videoId,
    required String poToken,
  }) async* {
    final rawSabrUrl = playerResponse.serverAbrStreamingUrl!;
    final sabrUrl = await _decipherUrlIfNeeded(rawSabrUrl, watchPage);
    if (sabrUrl == null) {
      _logger.warning('Could not parse serverAbrStreamingUrl');
      return;
    }

    final playerJson = Map<String, dynamic>.from(playerResponse.root);
    final streamingData = Map<String, dynamic>.from(
      playerJson['streamingData'] as Map<String, dynamic>,
    );
    streamingData['serverAbrStreamingUrl'] = sabrUrl;
    playerJson['streamingData'] = streamingData;
    if (rawSabrUrl != sabrUrl) {
      _logger.fine('Deciphered serverAbrStreamingUrl for SABR');
    }

    final clientCtx = watchPage.ytCfg['INNERTUBE_CONTEXT']?['client']
            as Map<String, dynamic>? ??
        {};
    final clientName = innertubeClientNameId(
      clientCtx['clientName'] as String? ?? 'WEB',
    );
    final clientVersion = clientCtx['clientVersion'] as String? ?? '';

    final sabrContext = SabrStreamContext(
      videoId: videoId,
      poToken: poToken,
      clientName: clientName,
      clientVersion: clientVersion,
      playerResponse: playerJson,
    );

    final sabrUri = Uri.parse(sabrUrl);
    final durationSec = playerResponse.videoDuration.inSeconds;

    for (final stream in playerResponse.adaptiveStreams) {
      if (_isAbsoluteHttpUrl(Uri.tryParse(stream.url) ?? Uri())) {
        continue;
      }

      final audioCodec = stream.audioCodec;
      final videoCodec = stream.videoCodec;
      final itag = stream.tag;
      final container = StreamContainer.parse(stream.container ?? 'webm');
      final bitrate = Bitrate(stream.bitrate ?? 0);

      var contentLength = stream.contentLength;
      if ((contentLength == null || contentLength <= 0) &&
          stream.bitrate != null &&
          durationSec > 0) {
        contentLength = (stream.bitrate! * durationSec) ~/ 8;
      }
      contentLength ??= 1;
      final fileSize = FileSize(contentLength);

      if (!videoCodec.isNullOrWhiteSpace && audioCodec.isNullOrWhiteSpace) {
        final framerate = Framerate(stream.framerate ?? 24);
        final videoQuality =
            VideoQualityUtil.fromLabel(stream.qualityLabel ?? '');
        final videoWidth = stream.videoWidth;
        final videoHeight = stream.videoHeight;
        final videoResolution = videoWidth != null && videoHeight != null
            ? VideoResolution(videoWidth, videoHeight)
            : videoQuality.toVideoResolution();

        yield SabrVideoStreamInfo(
          videoId: videoId,
          tag: itag,
          url: sabrUri,
          container: container,
          size: fileSize,
          bitrate: bitrate,
          videoCodec: videoCodec!,
          qualityLabel: stream.qualityLabel ?? videoQuality.qualityString,
          videoQuality: videoQuality,
          videoResolution: videoResolution,
          framerate: framerate,
          fragments: const [],
          codec: stream.codec,
          sabrContext: sabrContext,
        );
        continue;
      }

      if (!audioCodec.isNullOrWhiteSpace && videoCodec.isNullOrWhiteSpace) {
        yield SabrAudioStreamInfo(
          videoId: videoId,
          tag: itag,
          url: sabrUri,
          container: container,
          size: fileSize,
          bitrate: bitrate,
          audioCodec: audioCodec!,
          fragments: const [],
          codec: stream.codec,
          qualityLabel: stream.qualityLabel ?? '',
          audioTrack: stream.audioTrack,
          sabrContext: sabrContext,
        );
      }
    }
  }

  Future<String?> _prepareManifestUrl(
    String rawUrl,
    WatchPage watchPage,
    String? gvsPoToken,
    YoutubeApiClient ytClient,
    StreamingProtocol protocol,
  ) async {
    final deciphered = await _decipherUrlIfNeeded(rawUrl, watchPage);
    if (deciphered == null) return null;

    if (gvsPoToken != null &&
        YoutubeClientPoPolicy.shouldAppendGvsPoToken(
          ytClient,
          protocol,
          gvsPoToken,
        )) {
      return _appendGvsPoToManifestPath(deciphered, gvsPoToken);
    }
    return deciphered;
  }

  /// yt-dlp appends `/pot/{token}` to DASH/HLS manifest paths for WEB clients.
  static String _appendGvsPoToManifestPath(String url, String poToken) {
    final uri = Uri.parse(url);
    final basePath = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: '${basePath}pot/$poToken').toString();
  }

  Future<String?> _decipherUrlIfNeeded(
    String url,
    WatchPage watchPage,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    var resolved = uri;
    final solver = _jsChallengeSolver;
    if (solver != null &&
        watchPage.sourceUrl != null &&
        resolved.queryParameters.containsKey('n')) {
      final n = resolved.queryParameters['n']!;
      try {
        final decoded =
            await solver.solve(watchPage.sourceUrl!, JSChallengeType.n, n);
        resolved = resolved.setQueryParam('n', decoded);
      } catch (e) {
        _logger.warning('Could not decipher serverAbrStreamingUrl n param: $e');
      }
    }
    return resolved.toString();
  }

  /// Re-fetches watch page, PO token and /player to build a fresh [SabrStreamInfo].
  Future<SabrStreamInfo> _fetchFreshSabrStream(
      SabrStreamInfo streamInfo) async {
    if (_poTokenProvider == null) return streamInfo;

    final videoId = streamInfo.videoId;
    final watchPage = await WatchPage.get(_httpClient, videoId.value);

    String? gvsPoToken;
    String? playerPoToken;
    late final PoTokenContext context;
    try {
      final innertubeCtx =
          watchPage.ytCfg['INNERTUBE_CONTEXT'] as Map<String, dynamic>? ?? {};
      final clientCtx = innertubeCtx['client'] as Map<String, dynamic>? ?? {};
      context = PoTokenContext(
        visitorData: clientCtx['visitorData'] as String? ?? '',
        clientVersion: clientCtx['clientVersion'] as String? ?? '',
        innertubeContext: innertubeCtx,
        ytConfig: watchPage.ytCfg,
        initialAttestationDataSource: watchPage.initialAttestationDataSource,
      );
      playerPoToken = await _poTokenProvider!.generatePoToken(
        videoId.value,
        context,
        kind: PoTokenKind.player,
      );
      gvsPoToken = await _poTokenProvider!.generatePoToken(
        videoId.value,
        context,
        kind: PoTokenKind.gvs,
      );
      _logger.fine('Refreshed PO Token for SABR download ${videoId.value}');
    } catch (e) {
      _logger.warning('Failed to refresh PO Token for SABR: $e');
      return streamInfo;
    }

    final playerResponse = await _controller.getPlayerResponse(
      videoId,
      _webClientFromWatchPage(watchPage),
      watchPage: watchPage,
      poToken: playerPoToken,
    );

    if (!playerResponse.hasSabrStreaming) {
      throw YoutubeExplodeException(
        'Video "$videoId" no longer exposes SABR streaming data.',
      );
    }

    await for (final stream in _parseSabrStreams(
      playerResponse: playerResponse,
      watchPage: watchPage,
      videoId: videoId,
      poToken: gvsPoToken,
    )) {
      if (stream.tag == streamInfo.tag &&
          stream.runtimeType == streamInfo.runtimeType) {
        return stream as SabrStreamInfo;
      }
    }

    throw YoutubeExplodeException(
      'SABR stream itag ${streamInfo.tag} is no longer available.',
    );
  }

  /// Builds a WEB innertube client from the watch page session, mirroring
  /// FreeTube's `buildSessionFromYtConfig`. PO tokens are bound to this client.
  static YoutubeApiClient _webClientFromWatchPage(WatchPage watchPage) {
    final ytCfg = watchPage.ytCfg;
    final innertubeContext = Map<String, dynamic>.from(
      ytCfg['INNERTUBE_CONTEXT'] as Map<String, dynamic>,
    );
    innertubeContext.remove('clickTracking');

    final client = Map<String, dynamic>.from(
      innertubeContext['client'] as Map<String, dynamic>,
    );
    client['timeZone'] ??= 'UTC';
    client['utcOffsetMinutes'] ??= 0;
    innertubeContext['client'] = client;
    innertubeContext['user'] = {
      'enableSafetyMode': false,
      'lockedSafetyMode': false,
    };

    final apiKey = ytCfg['INNERTUBE_API_KEY'] as String?;
    final apiUrl = apiKey != null
        ? 'https://www.youtube.com/youtubei/v1/player?key=$apiKey&prettyPrint=false'
        : 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

    final userAgent = client['userAgent'] as String?;

    return YoutubeApiClient(
      {
        'context': innertubeContext,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      apiUrl,
      headers: {
        if (userAgent != null) 'User-Agent': userAgent,
      },
    );
  }
}
