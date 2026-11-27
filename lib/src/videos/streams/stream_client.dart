import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';

import '../../exceptions/exceptions.dart';
import '../../extensions/helpers_extension.dart';
import '../../retry.dart';
import '../../reverse_engineering/challenges/js_challenge.dart';
import '../../reverse_engineering/challenges/po_token_policy.dart';
import '../../reverse_engineering/challenges/po_token_provider.dart';
import '../../reverse_engineering/cipher/cipher_manifest.dart';
import '../../reverse_engineering/heuristics.dart';
import '../../reverse_engineering/models/stream_info_provider.dart';
import '../../reverse_engineering/pages/watch_page.dart';
import '../../reverse_engineering/player/player_response.dart';
import '../../reverse_engineering/player/player_source.dart';
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
  final Map<String, CipherManifest> _cipherManifestCache = {};

  /// Initializes an instance of [StreamClient]
  StreamClient(
    this._httpClient, {
    BaseJSChallengeSolver? jsSolver,
    this._poTokenProvider,
  }) : _controller = StreamController(_httpClient),
       _jsChallengeSolver = jsSolver;

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
  Future<StreamManifest> getManifest(
    dynamic videoId, {
    @Deprecated(
      'Use the ytClient parameter instead passing the proper [YoutubeApiClient]s',
    )
    bool fullManifest = false,
    List<YoutubeApiClient>? ytClients,
    bool requireWatchPage = true,
  }) async {
    assert(
      ytClients == null || ytClients.isNotEmpty,
      'ytClients cannot be an empty list',
    );

    videoId = VideoId.fromString(videoId);
    final clients =
        ytClients ?? [YoutubeApiClient.visionos, YoutubeApiClient.androidVr];

    if (_jsChallengeSolver != null && ytClients == null) {
      clients.add(YoutubeApiClient.safari);
    }

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

    for (final client in clients) {
      _logger.fine(
        'Getting stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}',
      );
      final clientUa =
          (client.payload['context']?['client']?['userAgent']) as String?;
      final probeHeaders = clientUa != null
          ? <String, String>{'User-Agent': clientUa}
          : const <String, String>{};
      try {
        await retry(_httpClient, () async {
          String? hlsUrlCandidate;
          final streams = (await _getStreams(
            videoId,
            ytClient: client,
            requireWatchPage: requireWatchPage,
            onHlsManifest: (url) => hlsUrlCandidate = url,
          ).toList()).where(_hasPlayableUrl).toList();
          if (streams.isEmpty) {
            throw VideoUnavailableException(
              'Video "$videoId" does not contain any playable streams.',
            );
          }

          final sabrStreams = streams.whereType<SabrStreamInfo>().toList();
          final directStreams = streams
              .where((s) => s is! SabrStreamInfo)
              .toList();
          var acceptedStreams = streams;
          if (directStreams.isNotEmpty) {
            try {
              final probe = directStreams.first;
              await _assertStreamReachable(videoId, probe, probeHeaders);

              // Muxed-only probe can hide CDN 403s on adaptive URLs (e.g. androidSdkless).
              final adaptive = directStreams.cast<StreamInfo?>().firstWhere(
                (s) => s is AudioOnlyStreamInfo || s is VideoOnlyStreamInfo,
                orElse: () => null,
              );
              if (adaptive != null && !identical(adaptive, probe)) {
                await _assertStreamReachable(videoId, adaptive, probeHeaders);
              }
            } on FatalFailureException catch (e) {
              if (sabrStreams.isNotEmpty) {
                _logger.warning(
                  'Direct stream probe failed ($e); falling back to '
                  '${sabrStreams.length} SABR streams for $videoId.',
                );
                acceptedStreams = sabrStreams;
              } else {
                rethrow;
              }
            }
          }
          uniqueStreams.addAll(acceptedStreams);
          hlsManifestUrl ??= hlsUrlCandidate;
        });
        if (uniqueStreams.isNotEmpty) {
          break;
        }
      } catch (e, s) {
        _logger.severe(
          'Failed to get stream manifest for video $videoId with client: ${client.payload['context']['client']['clientName']}. Reason: $e\n',
          e,
          s,
        );
        lastException = e;
      }
    }

    // If the user has not provided any client retry with the tv which work also in some restricted videos.
    if (uniqueStreams.isEmpty && ytClients == null) {
      return getManifest(videoId, ytClients: [YoutubeApiClient.tv]);
    }
    if (uniqueStreams.isEmpty) {
      if (lastException is Error && lastException.stackTrace != null) {
        throw Error.throwWithStackTrace(
          lastException,
          lastException.stackTrace!,
        );
      }
      throw lastException ??
          VideoUnavailableException(
            'Video "$videoId" has no available streams',
          );
    }
    return StreamManifest(
      uniqueStreams.toList(),
      hlsManifestUrl: hlsManifestUrl,
    );
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
  /// For SABR streams this opens a [SabrStream] and emits its container bytes.
  Stream<List<int>> get(StreamInfo streamInfo) {
    if (streamInfo is SabrStreamInfo) {
      return openSabrStream(streamInfo).bytes();
    }
    return _httpClient.getStream(streamInfo, streamClient: this);
  }

  /// Opens a controllable [SabrStream] for [streamInfo], supporting time-based
  /// seeking via [initialPlayerTimeMs], readahead pacing via [playbackPositionMs],
  /// and deferred GVS PO token supply via [lateTokenSupplier].
  SabrStream openSabrStream(
    SabrStreamInfo streamInfo, {
    int initialPlayerTimeMs = 0,
    int Function()? playbackPositionMs,
    Future<Uint8List?> Function()? lateTokenSupplier,
  }) {
    final bootstrap = streamInfo.sabrBootstrap;
    var effectiveLateSupplier = lateTokenSupplier;
    if (effectiveLateSupplier == null &&
        bootstrap.poToken == null &&
        _poTokenProvider != null) {
      final clientForToken = _clientForId(bootstrap.clientNameId);
      if (clientForToken != null &&
          YoutubeClientPoPolicy.forClient(clientForToken).usesGvsPoToken) {
        effectiveLateSupplier = () async {
          final res = await _poTokenProvider.getPoToken(
            client: clientForToken,
            videoId: streamInfo.videoId,
            visitorData: bootstrap.tokenVisitorData,
          );
          final tok = res?.streamingDataPoToken;
          if (tok == null || tok.isEmpty) return null;
          return _decodeBase64Url(tok);
        };
      }
    }

    return SabrStream(
      httpClient: _httpClient,
      bootstrap: bootstrap,
      mediaType: streamInfo is SabrVideoStreamInfo
          ? SabrMediaType.video
          : SabrMediaType.audio,
      initialPlayerTimeMs: initialPlayerTimeMs,
      playbackPositionMs: playbackPositionMs,
      lateTokenSupplier: effectiveLateSupplier,
    );
  }

  Stream<StreamInfo> _getStreams(
    VideoId videoId, {
    required YoutubeApiClient ytClient,
    bool requireWatchPage = true,
    void Function(String? hlsManifestUrl)? onHlsManifest,
  }) async* {
    // Use await for instead of yield* to catch exceptions
    await for (final stream in _getStream(
      videoId,
      ytClient,
      requireWatchPage: requireWatchPage,
      onHlsManifest: onHlsManifest,
    )) {
      yield stream;
    }
  }

  Stream<StreamInfo> _getStream(
    VideoId videoId,
    YoutubeApiClient ytClient, {
    bool requireWatchPage = true,
    void Function(String? hlsManifestUrl)? onHlsManifest,
  }) async* {
    WatchPage? watchPage;
    if (requireWatchPage) {
      watchPage = await WatchPage.get(_httpClient, videoId.value);
    }

    final policy = YoutubeClientPoPolicy.forClient(ytClient);
    PoTokenResult? poTokenResult;
    Future<PoTokenResult?>? poTokenFuture;

    if (_poTokenProvider != null &&
        (policy.requiresPlayerPoToken || policy.usesGvsPoToken)) {
      if (policy.requiresPlayerPoToken) {
        try {
          poTokenResult = await _poTokenProvider.getPoToken(
            client: ytClient,
            videoId: videoId,
            watchPage: watchPage,
          );
        } catch (e, s) {
          _logger.warning('PO token provider failed for /player: $e', e, s);
        }
      } else {
        poTokenFuture = _poTokenProvider
            .getPoToken(
              client: ytClient,
              videoId: videoId,
              watchPage: watchPage,
            )
            .then<PoTokenResult?>((res) {
              poTokenResult = res;
              return res;
            })
            .catchError((Object e, StackTrace s) {
              _logger.warning('PO token provider failed: $e', e, s);
              return null;
            });
      }
    }

    var playerResponse = await _controller.getPlayerResponse(
      videoId,
      ytClient,
      watchPage: watchPage,
      sessionPoToken: policy.requiresPlayerPoToken
          ? poTokenResult?.sessionPoToken
          : null,
      visitorDataOverride: poTokenResult?.visitorData,
      signatureTimestampOverride: poTokenResult?.signatureTimestamp,
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

    final hasCipheredStreams = playerResponse.streams.any(
      (s) => s.signatureParameter != null && s.signature != null,
    );
    final sabrNeedsNDecipher =
        _jsChallengeSolver != null &&
        playerResponse.hasSabrStreaming &&
        (Uri.tryParse(playerResponse.serverAbrStreamingUrl ?? '')
                ?.queryParameters
                .containsKey('n') ??
            false);
    if (watchPage == null && (hasCipheredStreams || sabrNeedsNDecipher)) {
      watchPage = await WatchPage.get(_httpClient, videoId.value);
      if (_poTokenProvider != null &&
          policy.requiresPlayerPoToken &&
          poTokenResult == null) {
        try {
          poTokenResult = await _poTokenProvider.getPoToken(
            client: ytClient,
            videoId: videoId,
            watchPage: watchPage,
          );
        } catch (e, s) {
          _logger.warning('PO token retry failed: $e', e, s);
        }
      }
      if (hasCipheredStreams) {
        playerResponse = await _controller.getPlayerResponse(
          videoId,
          ytClient,
          watchPage: watchPage,
          sessionPoToken: policy.requiresPlayerPoToken
              ? poTokenResult?.sessionPoToken
              : null,
          visitorDataOverride: poTokenResult?.visitorData,
          signatureTimestampOverride: poTokenResult?.signatureTimestamp,
        );
        if (!playerResponse.isVideoPlayable) {
          throw VideoUnplayableException.unplayable(
            videoId,
            reason: playerResponse.videoPlayabilityError ?? '',
          );
        }
      }
    }

    final clientUa =
        (ytClient.payload['context']?['client']?['userAgent']) as String?;
    final probeHeaders = clientUa != null
        ? <String, String>{'User-Agent': clientUa}
        : const <String, String>{};
    onHlsManifest?.call(playerResponse.hlsManifestUrl);

    final hasDirectStreams =
        playerResponse.streams.any((s) => s.url.isNotEmpty) ||
        !playerResponse.dashManifestUrl.isNullOrWhiteSpace ||
        !playerResponse.hlsManifestUrl.isNullOrWhiteSpace;

    if (playerResponse.hasSabrStreaming) {
      if (poTokenFuture != null &&
          poTokenResult == null &&
          (!policy.sabrAllowsLateToken || hasDirectStreams)) {
        poTokenResult = await poTokenFuture;
      }
      yield* _parseSabrStreams(
        videoId: videoId,
        ytClient: ytClient,
        policy: policy,
        playerResponse: playerResponse,
        watchPage: watchPage,
        poTokenResult: poTokenResult,
      );
    }

    if (hasDirectStreams && poTokenFuture != null && poTokenResult == null) {
      poTokenResult = await poTokenFuture;
    }
    final gvsPoToken = policy.usesGvsPoToken
        ? poTokenResult?.streamingDataPoToken
        : null;

    yield* _parseStreamInfo(
      playerResponse.streams,
      watchPage: watchPage,
      videoId: videoId,
      probeHeaders: probeHeaders,
      gvsPoToken: gvsPoToken,
    );

    if (!playerResponse.dashManifestUrl.isNullOrWhiteSpace) {
      final dashUrl = gvsPoToken != null && gvsPoToken.isNotEmpty
          ? _appendGvsPoToManifestPath(
              Uri.parse(playerResponse.dashManifestUrl!),
              gvsPoToken,
            ).toString()
          : playerResponse.dashManifestUrl!;
      final dashManifest = await _controller.getDashManifest(dashUrl);
      yield* _parseStreamInfo(
        dashManifest.streams,
        watchPage: watchPage,
        videoId: videoId,
        probeHeaders: probeHeaders,
        gvsPoToken: gvsPoToken,
      );
    }
    if (!playerResponse.hlsManifestUrl.isNullOrWhiteSpace) {
      final hlsUrl = gvsPoToken != null && gvsPoToken.isNotEmpty
          ? _appendGvsPoToManifestPath(
              Uri.parse(playerResponse.hlsManifestUrl!),
              gvsPoToken,
            ).toString()
          : playerResponse.hlsManifestUrl!;
      final hlsManifest = await _controller.getHlsManifest(hlsUrl);
      yield* _parseStreamInfo(
        hlsManifest.streams,
        watchPage: watchPage,
        videoId: videoId,
        probeHeaders: probeHeaders,
        gvsPoToken: gvsPoToken,
      );
    }
  }

  Stream<StreamInfo> _parseSabrStreams({
    required VideoId videoId,
    required YoutubeApiClient ytClient,
    required YoutubeClientPoPolicy policy,
    required PlayerResponse playerResponse,
    WatchPage? watchPage,
    PoTokenResult? poTokenResult,
  }) async* {
    final rawSabrUrl = playerResponse.serverAbrStreamingUrl;
    final rawUstreamer = playerResponse.videoPlaybackUstreamerConfig;
    if (rawSabrUrl == null || rawSabrUrl.isEmpty || rawUstreamer == null) {
      return;
    }

    var sabrUri = Uri.parse(rawSabrUrl);
    if (_jsChallengeSolver != null &&
        watchPage?.sourceUrl != null &&
        sabrUri.queryParameters.containsKey('n')) {
      final nParam = sabrUri.queryParameters['n']!;
      try {
        final solvedN = await _jsChallengeSolver.solve(
          watchPage!.sourceUrl!,
          JSChallengeType.n,
          nParam,
        );
        sabrUri = sabrUri.setQueryParam('n', solvedN);
      } catch (e) {
        _logger.warning('Could not decipher SABR n parameter: $e');
      }
    }

    final Uint8List ustreamerBytes;
    try {
      ustreamerBytes = _decodeBase64Url(rawUstreamer);
    } catch (e) {
      _logger.warning('Invalid videoPlaybackUstreamerConfig: $e');
      return;
    }

    final discardVideo = playerResponse.adaptiveStreams
        .where(
          (s) =>
              !s.audioOnly &&
              (s.videoHeight ?? 0) > 0 &&
              (s.lastModified ?? 0) > 0,
        )
        .sorted(
          (a, b) => (a.videoHeight ?? 0) != (b.videoHeight ?? 0)
              ? (a.videoHeight ?? 0).compareTo(b.videoHeight ?? 0)
              : (a.bitrate ?? 0).compareTo(b.bitrate ?? 0),
        )
        .firstOrNull;
    if (discardVideo == null) {
      return;
    }

    final discardAudio = playerResponse.adaptiveStreams
        .where(
          (s) =>
              s.videoCodec.isNullOrWhiteSpace &&
              !s.audioCodec.isNullOrWhiteSpace &&
              (s.lastModified ?? 0) > 0,
        )
        .sorted((a, b) => (a.bitrate ?? 0).compareTo(b.bitrate ?? 0))
        .firstOrNull;
    final discardAudioFormatId = discardAudio != null
        ? SabrFormatId(
            discardAudio.tag,
            lastModified: discardAudio.lastModified ?? 0,
            xtags: discardAudio.xtags,
          )
        : null;

    final clientMap =
        (ytClient.payload['context'] as Map<String, dynamic>)['client']
            as Map<String, dynamic>;
    final clientName = clientMap['clientName'] as String;
    final clientVersion = clientMap['clientVersion'] as String? ?? '';
    final clientNameId = YoutubeApiClient.clientIdForClientName(clientName);
    if (clientNameId == null) return;
    final clientUa = clientMap['userAgent'] as String?;

    final rawPoToken = policy.usesGvsPoToken
        ? poTokenResult?.streamingDataPoToken
        : null;
    Uint8List? poTokenBytes;
    if (rawPoToken != null && rawPoToken.isNotEmpty) {
      try {
        poTokenBytes = _decodeBase64Url(rawPoToken);
      } catch (e) {
        _logger.warning('Invalid GVS PO token bytes: $e');
      }
    }

    final discardFormatId = SabrFormatId(
      discardVideo.tag,
      lastModified: discardVideo.lastModified ?? 0,
      xtags: discardVideo.xtags,
    );
    final discardHeight = discardVideo.videoHeight ?? 144;
    final fallbackDurationMs = playerResponse.videoDuration.inMilliseconds;
    final sabrUrlStr = sabrUri.toString();

    for (final stream in playerResponse.adaptiveStreams) {
      final lmt = stream.lastModified;
      if (stream.tag <= 0 || lmt == null || lmt <= 0) continue;
      final durationMs =
          (stream.approxDurationMs != null && stream.approxDurationMs! > 0)
          ? stream.approxDurationMs!
          : fallbackDurationMs;
      if (durationMs <= 0) continue;

      final bitrateVal = stream.bitrate;
      if (bitrateVal == null || bitrateVal <= 0) continue;
      final contentLen =
          stream.contentLength ?? ((bitrateVal * durationMs) ~/ 8000);
      if (contentLen <= 0) continue;

      final initRange = stream.initRange != null
          ? SabrByteRange(stream.initRange!.start, stream.initRange!.end)
          : null;
      final indexRange = stream.indexRange != null
          ? SabrByteRange(stream.indexRange!.start, stream.indexRange!.end)
          : null;

      final container = StreamContainer.parse(stream.container!);
      final fileSize = FileSize(contentLen);
      final bitrate = Bitrate(bitrateVal);
      final duration = Duration(milliseconds: durationMs);
      final formatId = SabrFormatId(
        stream.tag,
        lastModified: lmt,
        xtags: stream.xtags,
      );

      final videoCodec = stream.videoCodec;
      final audioCodec = stream.audioCodec;

      if (!videoCodec.isNullOrWhiteSpace) {
        if (discardAudioFormatId == null) continue;
        final framerate = Framerate(stream.framerate ?? 24);
        final videoQuality = VideoQualityUtil.fromLabel(stream.qualityLabel);
        final w = stream.videoWidth;
        final h = stream.videoHeight;
        final res = (w != null && h != null)
            ? VideoResolution(w, h)
            : videoQuality.toVideoResolution();

        final bootstrap = SabrBootstrap(
          videoId: videoId.value,
          serverAbrStreamingUrl: sabrUrlStr,
          videoPlaybackUstreamerConfig: ustreamerBytes,
          clientNameId: clientNameId,
          clientVersion: clientVersion,
          audioFormat: discardAudioFormatId,
          discardVideoFormat: discardFormatId,
          discardVideoHeight: discardHeight,
          selectedVideoFormat: formatId,
          selectedVideoWidth: w,
          selectedVideoHeight: h,
          selectedVideoContentLengthBytes: stream.contentLength,
          selectedVideoMimeType: stream.codec.mimeType,
          selectedVideoBitrate: bitrateVal,
          durationMs: durationMs,
          contentLengthBytes: stream.contentLength,
          mimeType: stream.codec.mimeType,
          poToken: poTokenBytes,
          requestUserAgent: clientUa,
          requestOrigin: policy.sabrOrigin,
          tokenVisitorData: poTokenResult?.visitorData,
          initRange: initRange,
          indexRange: indexRange,
        );

        yield SabrVideoStreamInfo(
          videoId,
          stream.tag,
          sabrUri,
          container,
          fileSize,
          bitrate,
          videoCodec!,
          videoQuality.qualityString,
          videoQuality,
          res,
          framerate,
          const [],
          stream.codec,
          bootstrap,
          duration,
          initRange: initRange,
          indexRange: indexRange,
        );
      } else if (!audioCodec.isNullOrWhiteSpace) {
        final bootstrap = SabrBootstrap(
          videoId: videoId.value,
          serverAbrStreamingUrl: sabrUrlStr,
          videoPlaybackUstreamerConfig: ustreamerBytes,
          clientNameId: clientNameId,
          clientVersion: clientVersion,
          audioFormat: formatId,
          discardVideoFormat: discardFormatId,
          discardVideoHeight: discardHeight,
          durationMs: durationMs,
          contentLengthBytes: stream.contentLength,
          mimeType: stream.codec.mimeType,
          audioTrackId: stream.audioTrack?.id,
          isDrc: stream.isDrc,
          poToken: poTokenBytes,
          requestUserAgent: clientUa,
          requestOrigin: policy.sabrOrigin,
          tokenVisitorData: poTokenResult?.visitorData,
          initRange: initRange,
          indexRange: indexRange,
        );

        yield SabrAudioStreamInfo(
          videoId,
          stream.tag,
          sabrUri,
          container,
          fileSize,
          bitrate,
          audioCodec!,
          stream.qualityLabel ?? '',
          const [],
          stream.codec,
          stream.audioTrack,
          bootstrap,
          duration,
          initRange: initRange,
          indexRange: indexRange,
        );
      }
    }
  }

  Stream<StreamInfo> _parseStreamInfo(
    Iterable<StreamInfoProvider> streams, {
    WatchPage? watchPage,
    VideoId? videoId,
    Map<String, String> probeHeaders = const {},
    String? gvsPoToken,
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
        solvedChallenges.addAll(
          await solver.solveBulk(watchPage.sourceUrl!, requests),
        );
      } catch (e) {
        _logger.warning('Could not bulk solve challenges: $e');
        // Fall back to individual solving if bulk fails
      }
    }

    CipherManifest? cipherManifest;
    final sourceUrl = watchPage?.sourceUrl;
    if (solver == null &&
        sourceUrl != null &&
        streams.any(
          (s) => s.signatureParameter != null && s.signature != null,
        )) {
      cipherManifest = _cipherManifestCache[sourceUrl];
      if (cipherManifest == null) {
        try {
          final source = await PlayerSource.get(_httpClient, sourceUrl);
          cipherManifest = CipherManifest.decode(source.root);
          if (cipherManifest != null) {
            if (_cipherManifestCache.length >= 4) {
              _cipherManifestCache.clear();
            }
            _cipherManifestCache[sourceUrl] = cipherManifest;
          }
        } catch (e) {
          _logger.warning('Could not decode fallback cipher manifest: $e');
        }
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
          'Skipping stream itag $itag with non-absolute URL: "${stream.url}"',
        );
        continue;
      }

      if (solver == null &&
          cipherManifest != null &&
          stream.signatureParameter != null &&
          stream.signature != null) {
        final sigParam = stream.signatureParameter!;
        final deciphered = cipherManifest.decipher(stream.signature!);
        url = url.setQueryParam(sigParam, deciphered);
      }

      if (solver != null && watchPage != null) {
        if (url.queryParameters.containsKey('n')) {
          final nParam = url.queryParameters['n']!;
          final decoded = solvedChallenges[nParam];
          if (decoded != null) {
            url = url.setQueryParam('n', decoded);
            _logger.fine(
              'Decoded n-sig for stream itag $itag. $nParam -> $decoded}',
            );
          } else {
            // Fallback to individual solving if bulk solving didn't provide result
            try {
              final individualDecoded = await solver.solve(
                watchPage.sourceUrl!,
                JSChallengeType.n,
                nParam,
              );
              url = url.setQueryParam('n', individualDecoded);
              _logger.fine(
                'Decoded n-sig for stream itag $itag (individual). $nParam -> $individualDecoded}',
              );
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
              'Decoded signature for stream itag $itag. $sigParam -> $decoded}',
            );
          } else {
            // Fallback to individual solving if bulk solving didn't provide result
            try {
              final individualDecoded = await solver.solve(
                watchPage.sourceUrl!,
                JSChallengeType.sig,
                sig,
              );
              url = url.setQueryParam(sigParam, individualDecoded);
              _logger.fine(
                'Decoded signature for stream itag $itag (individual). $sigParam -> $individualDecoded}',
              );
            } catch (e) {
              _logger.warning(
                'Could not decipher signature using JS solver: $e',
              );
            }
          }
        }
      }

      if (gvsPoToken != null && gvsPoToken.isNotEmpty) {
        if (stream.source == StreamSource.hls) {
          url = _appendGvsPoToManifestPath(url, gvsPoToken);
        } else {
          url = url.setQueryParam('pot', gvsPoToken);
        }
      }

      final contentLength =
          stream.contentLength ??
          (await _httpClient.getContentLength(
            url,
            headers: probeHeaders,
            validate: false,
          )) ??
          0;

      if (contentLength <= 0) {
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
          stream.audioTrack,
        );
      } else {
        throw YoutubeExplodeException('Could not extract stream codec');
      }
    }
  }

  Future<void> _assertStreamReachable(
    VideoId videoId,
    StreamInfo stream,
    Map<String, String> probeHeaders,
  ) async {
    final response = await _httpClient.head(stream.url, headers: probeHeaders);
    if (response.statusCode != 403) return;

    // googlevideo rejects HEAD on ANDROID_VR / IOS streams with 403 while
    // serving byte-range GET requests normally.
    final rangeProbe = await _httpClient.get(
      stream.url,
      headers: {...probeHeaders, 'Range': 'bytes=0-0'},
    );
    if (rangeProbe.statusCode == 200 || rangeProbe.statusCode == 206) {
      return;
    }

    throw FatalFailureException(
      'Video $videoId returned 403 (stream: ${stream.tag})',
      403,
    );
  }

  /// Absolute http(s) URL with a non-empty host — safe for [HttpClient] HEAD/GET.
  static bool _isAbsoluteHttpUrl(Uri url) =>
      (url.scheme == 'http' || url.scheme == 'https') && url.host.isNotEmpty;

  static bool _hasPlayableUrl(StreamInfo stream) =>
      stream is SabrStreamInfo || _isAbsoluteHttpUrl(stream.url);

  static Uri _appendGvsPoToManifestPath(Uri url, String token) {
    final segments = List<String>.from(url.pathSegments);
    final potIndex = segments.indexOf('pot');
    if (potIndex != -1 && potIndex + 1 < segments.length) {
      segments[potIndex + 1] = token;
    } else {
      segments.addAll(['pot', token]);
    }
    return url.replace(pathSegments: segments);
  }

  static Uint8List _decodeBase64Url(String value) {
    final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.padRight(
      normalized.length + (4 - normalized.length % 4) % 4,
      '=',
    );
    return Uint8List.fromList(base64Decode(padded));
  }

  static YoutubeApiClient? _clientForId(int clientId) => switch (clientId) {
    1 => YoutubeApiClient.web,
    2 => YoutubeApiClient.mweb,
    67 => YoutubeApiClient.webRemix,
    75 => YoutubeApiClient.tvHtml5Simply,
    101 => YoutubeApiClient.visionosSabr,
    _ => null,
  };
}
