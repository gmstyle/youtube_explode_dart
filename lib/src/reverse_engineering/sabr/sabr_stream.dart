import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../exceptions/sabr_protocol_exception.dart';
import '../../extensions/helpers_extension.dart';
import '../youtube_http_client.dart';
import 'proto_wire.dart';
import 'sabr_models.dart';
import 'sabr_proto_codec.dart';
import 'sabr_ump_processor.dart';

/// Pure-Dart SABR/UMP streaming transport for a single [SabrBootstrap] format.
class SabrStream {
  static const String _contentTypeProtobuf = 'application/x-protobuf';
  static const String _contentTypeUmp = 'application/vnd.yt-ump';
  static const int _keepExisting = 2;
  static const int _protectionAccepted = 1;
  static const int _protectionPending = 2;
  static const int _protectionRequired = 3;
  static const int _maxOmittedProtectionPending = 5;
  static const int _lateTokenMediaLimitMs = 80000;
  static const int _lateTokenTimeoutMs = 30000;
  static const int _maxPoTokenBytes = 16 * 1024;
  static const int _maxRequestCount = 10000;
  static const int _maxBackoffMs = 30000;
  static const int _maxResponseMediaBytes = 64 * 1024 * 1024;
  static const int _maxPendingSegments = 1024;
  static const int _maxContextCount = 64;
  static const int _maxContextValueBytes = 64 * 1024;
  static const int _maxContextBytes = 256 * 1024;
  static const int _maxPlaybackCookieBytes = 64 * 1024;
  static const int _startTimeToleranceMs = 1;
  static const int _minDurationToleranceMs = 2000;
  static const int _starvationToleranceMs = 2000;
  static const int _playbackPollIntervalMs = 250;
  static const int _maxReadaheadPollIntervalMs = 1000;
  static const int _defaultHeartbeatIntervalMs = 60000;
  static const int _maxHeartbeatIntervalMs = 60000;
  static const int _maxTransientRetries = 2;
  static const int _retryBaseDelayMs = 250;
  static const int _retryMaxDelayMs = 5000;
  static const Set<int> _transientHttpStatuses = {408, 425, 429, 500, 502, 503, 504};

  final YoutubeHttpClient httpClient;
  final SabrBootstrap bootstrap;
  final SabrMediaType mediaType;
  final int initialPlayerTimeMs;
  final int Function()? playbackPositionMs;
  final int maxRequestsWithoutProgress;
  final Future<Uint8List?> Function()? lateTokenSupplier;
  final Future<void> Function(Duration delay) _retryDelay;

  late final SabrFormatId _selectedFormat = mediaType == SabrMediaType.audio
      ? bootstrap.audioFormat
      : (bootstrap.selectedVideoFormat ??
            (throw StateError('SABR video format is not selected')));

  late final int? _expectedContentLengthBytes = mediaType == SabrMediaType.audio
      ? bootstrap.contentLengthBytes
      : bootstrap.selectedVideoContentLengthBytes;

  SabrStream({
    required this.httpClient,
    required this.bootstrap,
    this.mediaType = SabrMediaType.audio,
    this.initialPlayerTimeMs = 0,
    this.playbackPositionMs,
    this.maxRequestsWithoutProgress = 3,
    this.lateTokenSupplier,
    Future<void> Function(Duration delay)? retryDelay,
  }) : _retryDelay = retryDelay ?? Future<void>.delayed;

  /// Streams raw container bytes (initialization segment followed by sequential
  /// media segments).
  Stream<List<int>> bytes() => chunks().map((c) => c.data);

  /// Streams decoded [SabrChunk] segments with container byte offsets and timestamps.
  Stream<SabrChunk> chunks() {
    late StreamController<SabrChunk> controller;
    var cancelled = false;
    StreamSubscription<List<int>>? activeResponseSub;

    controller = StreamController<SabrChunk>(
      onListen: () {
        _run(
          emit: (chunk) {
            if (!cancelled && !controller.isClosed) {
              controller.add(chunk);
            }
          },
          isCancelled: () => cancelled || httpClient.closed,
          registerActiveSub: (sub) {
            activeResponseSub = sub;
          },
        ).then(
          (_) {
            if (!controller.isClosed) controller.close();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!cancelled && !controller.isClosed) {
              controller.addError(error, stackTrace);
              controller.close();
            }
          },
        );
      },
      onCancel: () async {
        cancelled = true;
        await activeResponseSub?.cancel();
      },
    );
    return controller.stream;
  }

  Future<void> _run({
    required void Function(SabrChunk chunk) emit,
    required bool Function() isCancelled,
    required void Function(StreamSubscription<List<int>>? sub) registerActiveSub,
  }) async {
    Future<Uint8List?>? pendingTokenFuture;
    if (bootstrap.poToken == null && lateTokenSupplier != null) {
      pendingTokenFuture = _fetchLateToken(lateTokenSupplier!);
    }

    var poToken = bootstrap.poToken;
    var retryWithToken = false;
    var streamingUrl = requireAllowedSabrUrl(bootstrap.serverAbrStreamingUrl);
    streamingUrl = _ensureCpn(streamingUrl);

    final maxStart = math.max(0, bootstrap.durationMs - 1);
    var playerTimeMs = initialPlayerTimeMs.clamp(0, maxStart);
    var initialized = false;
    SabrFormatInitialization? initialization;
    var initSegmentEmitted = false;
    Uint8List? playbackCookie;
    var targetAudioReadaheadMs = 0;
    var maxTimeSinceLastRequestMs = 0;
    var lastRequestStarted = DateTime.now();
    var bufferedRanges = <SabrBufferedRange>[];
    SabrMediaHeader? firstBufferedSegment;
    var backoffTimeMs = 0;
    var requestsWithoutProgress = 0;
    var ended = false;
    int? firstSequenceNumber;
    int? lastSequenceNumber;
    var seekStartEstablished = false;
    var consecutiveTransientFailures = 0;
    var cumulativeStreamBytes = 0;
    var protectionPending = false;
    var protectionRetryCount = 0;
    int? protectionRetryLimit;
    var omittedAllowancePending = false;
    var omittedProtectionPendingCount = 0;
    final contexts = <int, SabrContext>{};
    final activeContextTypes = <int>{};
    var retainedContextBytes = 0;
    final requestWriter = ProtoWriter();
    var requestNumber = 0;

    final processor = SabrUmpProcessor(
      shouldCollectMedia: (header) =>
          header.formatId.matches(_selectedFormat) &&
          (header.videoId == null || header.videoId == bootstrap.videoId),
    );

    int expectedDurationMs() =>
        (initialization?.durationMs != null && initialization!.durationMs! > 0)
        ? initialization!.durationMs!
        : bootstrap.durationMs;

    while (!isCancelled() &&
        (retryWithToken ||
            (!ended &&
                (initialization?.endSegmentNumber == null ||
                    lastSequenceNumber == null ||
                    lastSequenceNumber! < initialization!.endSegmentNumber!) &&
                playerTimeMs < expectedDurationMs()))) {
      retryWithToken = false;

      if (poToken == null &&
          pendingTokenFuture != null &&
          playerTimeMs >= _lateTokenMediaLimitMs) {
        poToken = await pendingTokenFuture;
      }
      if (requestNumber >= _maxRequestCount) {
        throw SabrProtocolException('SABR exceeded $_maxRequestCount requests');
      }

      if (playbackPositionMs != null &&
          targetAudioReadaheadMs > 0 &&
          playerTimeMs > 0) {
        await _awaitReadaheadCapacity(
          downloadedPositionMs: playerTimeMs,
          targetAudioReadaheadMs: targetAudioReadaheadMs,
          deadline: _heartbeatDeadline(
            lastRequestStarted,
            maxTimeSinceLastRequestMs,
          ),
          isCancelled: isCancelled,
        );
      }
      if (isCancelled()) return;

      if (backoffTimeMs > 0) {
        final backoff = math.min(backoffTimeMs, _maxBackoffMs);
        final remaining = _remainingWaitMs(
          _heartbeatDeadline(lastRequestStarted, maxTimeSinceLastRequestMs),
        );
        final waitMs = maxTimeSinceLastRequestMs > 0
            ? math.min(backoff, remaining)
            : backoff;
        if (waitMs > 0) {
          await _retryDelay(Duration(milliseconds: waitMs));
        }
      }
      if (isCancelled()) return;

      final requestPlayerTimeMs = playerTimeMs;
      final requestBytes = SabrProtoCodec.encodeRequest(
        bootstrap: bootstrap,
        playerTimeMs: requestPlayerTimeMs,
        initialized: initialized,
        bufferedRanges: bufferedRanges,
        playbackCookie: playbackCookie,
        contexts: contexts.values,
        activeContextTypes: activeContextTypes,
        mediaType: mediaType,
        writer: requestWriter,
        poToken: poToken,
      );

      lastRequestStarted = DateTime.now();
      final postUri = _withRequestNumber(streamingUrl, requestNumber++);
      final req = http.Request('POST', Uri.parse(postUri))
        ..followRedirects = false
        ..headers['Content-Type'] = _contentTypeProtobuf
        ..headers['Accept'] = _contentTypeUmp
        ..headers['Accept-Encoding'] = 'identity'
        ..bodyBytes = requestBytes;
      if (bootstrap.requestUserAgent != null) {
        req.headers['User-Agent'] = bootstrap.requestUserAgent!;
      }
      if (bootstrap.requestOrigin != null) {
        req.headers['Origin'] = bootstrap.requestOrigin!;
        req.headers['Referer'] = '${bootstrap.requestOrigin!}/';
      }

      final response = await httpClient.send(req);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.stream.drain<void>();
        throw SabrProtocolException(
          'SABR HTTP redirects are not allowed',
          httpStatusCode: response.statusCode,
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        if (_transientHttpStatuses.contains(response.statusCode) &&
            consecutiveTransientFailures < _maxTransientRetries) {
          consecutiveTransientFailures++;
          final retryAfterSec = int.tryParse(
            response.headers['retry-after'] ?? '',
          );
          final delayMs = retryAfterSec != null
              ? (retryAfterSec * 1000).clamp(_retryBaseDelayMs, _retryMaxDelayMs)
              : (_retryBaseDelayMs << (consecutiveTransientFailures - 1));
          await _retryDelay(Duration(milliseconds: delayMs));
          continue;
        }
        throw SabrProtocolException(
          'SABR request failed with HTTP ${response.statusCode}',
          kind: response.statusCode == 403
              ? SabrFailureKind.attestationRequired
              : SabrFailureKind.protocol,
          httpStatusCode: response.statusCode,
        );
      }

      final responseContentType = response.headers['content-type'] ?? '';
      if (!responseContentType.startsWith(_contentTypeUmp)) {
        await response.stream.drain<void>();
        throw SabrProtocolException(
          'Unexpected SABR content type: $responseContentType',
        );
      }
      consecutiveTransientFailures = 0;

      processor.resetForNextResponse();
      var responseMediaBytes = 0;
      var responseInitSegmentCount = 0;
      int? responseProtectionStatus;
      var terminalProtection = false;
      int? responseProtectionMaxRetries;
      final pendingMediaBySequence = <int, SabrSegment>{};
      SabrMediaHeader? firstNewSegmentHeader;
      SabrMediaHeader? lastNewSegmentHeader;
      var newSegmentCount = 0;

      void emitMediaSegment(SabrSegment segment) {
        if (firstSequenceNumber == null) {
          final startGapMs = segment.header.startMs - requestPlayerTimeMs;
          if (startGapMs > _startTimeToleranceMs ||
              segment.checkedEndTimeMs <= requestPlayerTimeMs) {
            throw SabrProtocolException(
              'SABR first media segment does not cover the requested start',
            );
          }
        }
        emit(segment.toChunk());
        firstSequenceNumber ??= segment.header.sequenceNumber;
        lastSequenceNumber = segment.header.sequenceNumber;
        playerTimeMs = math.max(playerTimeMs, segment.checkedEndTimeMs);
        cumulativeStreamBytes += segment.data.length;
        firstNewSegmentHeader ??= segment.header;
        lastNewSegmentHeader = segment.header;
        newSegmentCount++;
      }

      void emitReadyMediaSegments({
        int? initialSeekSequence,
        bool establishFromMinimum = false,
      }) {
        if (!initSegmentEmitted && pendingMediaBySequence.isNotEmpty) {
          throw SabrProtocolException(
            'SABR media arrived without initialization',
          );
        }
        if (lastSequenceNumber == null) {
          if (requestPlayerTimeMs > 0) {
            pendingMediaBySequence.removeWhere(
              (_, seg) => seg.checkedEndTimeMs <= requestPlayerTimeMs,
            );
          }
          if (initialSeekSequence != null) {
            pendingMediaBySequence.removeWhere(
              (seq, _) => seq < initialSeekSequence,
            );
          }
          final int? firstSeq;
          if (initialSeekSequence != null) {
            firstSeq = pendingMediaBySequence.containsKey(initialSeekSequence)
                ? initialSeekSequence
                : null;
          } else if (pendingMediaBySequence.containsKey(0) &&
              (requestPlayerTimeMs <= 0 || establishFromMinimum)) {
            firstSeq = 0;
          } else if (establishFromMinimum && pendingMediaBySequence.isNotEmpty) {
            firstSeq = pendingMediaBySequence.keys.reduce(math.min);
          } else {
            firstSeq = null;
          }
          if (firstSeq == null) return;
          emitMediaSegment(pendingMediaBySequence.remove(firstSeq)!);
        }

        while (true) {
          final expected = lastSequenceNumber! + 1;
          final nextSeg = pendingMediaBySequence.remove(expected);
          if (nextSeg == null) break;
          emitMediaSegment(nextSeg);
        }
      }

      int? initialSeekSequence() {
        if (firstSequenceNumber != null || requestPlayerTimeMs <= 0) return null;
        for (final seg in pendingMediaBySequence.values) {
          if (seg.header.startMs - requestPlayerTimeMs <=
                  _startTimeToleranceMs &&
              requestPlayerTimeMs < seg.checkedEndTimeMs) {
            return seg.header.sequenceNumber;
          }
        }
        return null;
      }

      void emitAvailableMediaSegments() {
        final seekSeq = initialSeekSequence();
        if (seekSeq != null) seekStartEstablished = true;
        emitReadyMediaSegments(initialSeekSequence: seekSeq);
      }

      void processEvent(SabrEvent event) {
        switch (event) {
          case SabrMediaHeaderEvent():
            break;
          case SabrSegmentEvent(:final segment):
            responseMediaBytes += segment.data.length;
            if (responseMediaBytes > _maxResponseMediaBytes) {
              throw SabrProtocolException(
                'SABR response media exceeded the memory limit',
              );
            }
            if (segment.header.isInitSegment) {
              responseInitSegmentCount++;
              if (responseInitSegmentCount > 1) {
                throw SabrProtocolException(
                  'SABR returned duplicate initialization segments',
                );
              }
              if (!initSegmentEmitted) {
                emit(segment.toChunk());
                initSegmentEmitted = true;
                cumulativeStreamBytes += segment.data.length;
                emitAvailableMediaSegments();
              }
            } else {
              final seq = segment.header.sequenceNumber;
              final precedesEstablishedSeek =
                  seekStartEstablished &&
                  firstSequenceNumber != null &&
                  seq < firstSequenceNumber!;
              final alreadyEmitted =
                  precedesEstablishedSeek ||
                  (lastSequenceNumber != null &&
                      seq >= firstSequenceNumber! &&
                      seq <= lastSequenceNumber!);
              if (!alreadyEmitted) {
                if (pendingMediaBySequence.length >= _maxPendingSegments) {
                  throw SabrProtocolException(
                    'SABR pending segment count exceeded the memory limit',
                  );
                }
                if (pendingMediaBySequence.containsKey(seq)) {
                  throw SabrProtocolException(
                    'SABR returned duplicate segment $seq',
                  );
                }
                pendingMediaBySequence[seq] = segment;
                if (initSegmentEmitted) {
                  emitAvailableMediaSegments();
                }
              }
            }
          case SabrFormatInitializedEvent(:final initialization):
            if (initialization != null &&
                initialization.formatId.matches(_selectedFormat)) {
              initialized = true;
              // Capture metadata from initialization part
              // (duration / endSegmentNumber).
              // Keep non-null assignment local via outer variable:
            }
          case SabrNextRequestPolicyEvent():
            targetAudioReadaheadMs = event.targetAudioReadaheadMs;
            maxTimeSinceLastRequestMs = event.maxTimeSinceLastRequestMs;
            backoffTimeMs = event.backoffTimeMs;
            if ((event.playbackCookie?.length ?? 0) > _maxPlaybackCookieBytes) {
              throw SabrProtocolException(
                'SABR playback cookie exceeded the memory limit',
              );
            }
            playbackCookie = event.playbackCookie;
          case SabrRedirectEvent(:final url):
            streamingUrl = _ensureCpn(requireAllowedSabrUrl(url));
          case SabrContextUpdateEvent(:final context):
            final existing = contexts[context.type];
            if (context.writePolicy != _keepExisting || existing == null) {
              if (context.value.length > _maxContextValueBytes) {
                throw SabrProtocolException(
                  'SABR context value exceeded the memory limit',
                );
              }
              if (existing == null && contexts.length >= _maxContextCount) {
                throw SabrProtocolException(
                  'SABR context count exceeded the memory limit',
                );
              }
              final updatedBytes =
                  retainedContextBytes -
                  (existing?.value.length ?? 0) +
                  context.value.length;
              if (updatedBytes > _maxContextBytes) {
                throw SabrProtocolException(
                  'SABR contexts exceeded the memory limit',
                );
              }
              contexts[context.type] = context;
              retainedContextBytes = updatedBytes;
              if (context.sendByDefault) {
                activeContextTypes.add(context.type);
              }
            }
          case SabrContextSendingPolicyEvent(
            :final start,
            :final stop,
            :final discard,
          ):
            if (start.length > _maxContextCount ||
                stop.length > _maxContextCount ||
                discard.length > _maxContextCount) {
              throw SabrProtocolException(
                'SABR context policy exceeded the type limit',
              );
            }
            activeContextTypes.addAll(start);
            activeContextTypes.removeAll(stop);
            for (final type in discard) {
              activeContextTypes.remove(type);
              final removed = contexts.remove(type);
              if (removed != null) retainedContextBytes -= removed.value.length;
            }
            if (activeContextTypes.length > _maxContextCount) {
              throw SabrProtocolException(
                'SABR active context count exceeded the memory limit',
              );
            }
          case SabrStreamProtectionStatusEvent(:final status, :final maxRetries):
            responseProtectionStatus = status;
            responseProtectionMaxRetries = maxRetries >= 0 ? maxRetries : null;
            if (status >= _protectionRequired) {
              terminalProtection = true;
            }
          case SabrErrorEvent(:final type, :final code):
            throw SabrProtocolException(
              'SABR error ${type ?? ''} ($code)',
            );
          case SabrReloadPlayerResponseEvent():
            throw SabrProtocolException(
              'SABR requested a fresh player response',
              kind: SabrFailureKind.reloadPlayer,
            );
          case SabrEndOfTrackEvent():
            ended = true;
        }
        if (event is SabrFormatInitializedEvent &&
            event.initialization != null &&
            event.initialization!.formatId.matches(_selectedFormat)) {
          initialization = event.initialization;
        }
      }

      final bodyDone = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      sub = response.stream.listen(
        (rawChunk) {
          if (terminalProtection || isCancelled()) {
            sub.cancel();
            if (!bodyDone.isCompleted) bodyDone.complete();
            return;
          }
          try {
            final bytes = rawChunk is Uint8List
                ? rawChunk
                : Uint8List.fromList(rawChunk);
            processor.feed(
              bytes,
              onEvent: (event) {
                if (terminalProtection) return;
                processEvent(event);
              },
            );
            if (terminalProtection) {
              sub.cancel();
              if (!bodyDone.isCompleted) bodyDone.complete();
            }
          } catch (e, s) {
            sub.cancel();
            if (!bodyDone.isCompleted) bodyDone.completeError(e, s);
          }
        },
        onError: (Object e, StackTrace s) {
          if (!bodyDone.isCompleted) bodyDone.completeError(e, s);
        },
        onDone: () {
          if (!bodyDone.isCompleted) bodyDone.complete();
        },
        cancelOnError: true,
      );
      registerActiveSub(sub);

      await bodyDone.future;
      registerActiveSub(null);
      if (isCancelled()) return;

      if (!terminalProtection) {
        if (!ended) {
          processor.finish();
        }
        emitReadyMediaSegments(establishFromMinimum: true);
        if (pendingMediaBySequence.isNotEmpty) {
          final minSeq = pendingMediaBySequence.keys.reduce(math.min);
          throw SabrProtocolException(
            'SABR segment sequence gap: expected ${lastSequenceNumber! + 1}, received $minSeq',
          );
        }
      }

      if (newSegmentCount > 0) {
        requestsWithoutProgress = 0;
        firstBufferedSegment ??= firstNewSegmentHeader;
        final first = firstBufferedSegment!;
        final last = lastNewSegmentHeader!;
        bufferedRanges = [
          SabrBufferedRange(
            formatId: _selectedFormat,
            startTimeMs: first.startMs,
            durationMs: math.max(0, last.startMs + last.durationMs - first.startMs),
            startSegmentIndex: first.sequenceNumber,
            endSegmentIndex: last.sequenceNumber,
          ),
        ];
      }

      if (responseProtectionStatus != null &&
          responseProtectionStatus! >= _protectionRequired) {
        protectionPending = true;
      } else if (responseProtectionStatus == _protectionPending) {
        protectionPending = true;
        omittedAllowancePending = responseProtectionMaxRetries == null;
        if (responseProtectionMaxRetries != null) {
          protectionRetryLimit = responseProtectionMaxRetries;
        }
      } else if (responseProtectionStatus == _protectionAccepted) {
        protectionPending = false;
        protectionRetryCount = 0;
        protectionRetryLimit = null;
        omittedAllowancePending = false;
      }

      if (protectionPending &&
          (responseProtectionStatus == null ||
              responseProtectionStatus! < _protectionRequired)) {
        protectionRetryCount++;
        if (omittedAllowancePending) omittedProtectionPendingCount++;
      }

      if ((protectionPending || (newSegmentCount == 0 && !ended)) &&
          poToken == null &&
          pendingTokenFuture != null) {
        final supplied = await pendingTokenFuture;
        if (supplied != null) {
          poToken = supplied;
          protectionPending = false;
          protectionRetryCount = 0;
          protectionRetryLimit = null;
          omittedProtectionPendingCount = 0;
          ended = false;
          retryWithToken = true;
          continue;
        }
      }

      final protectionRetriesExhausted =
          (protectionRetryLimit != null &&
              protectionRetryCount > protectionRetryLimit) ||
          omittedProtectionPendingCount > _maxOmittedProtectionPending;
      final protectionRequired =
          responseProtectionStatus != null &&
          responseProtectionStatus! >= _protectionRequired;
      if (protectionPending &&
          (protectionRequired ||
              newSegmentCount == 0 ||
              protectionRetriesExhausted)) {
        throw SabrProtocolException(
          'SABR stream protection requires attestation '
          '(status=${responseProtectionStatus ?? _protectionPending})',
          kind: SabrFailureKind.attestationRequired,
        );
      }

      if (newSegmentCount == 0 && !ended) {
        final playbackPos = playbackPositionMs?.call();
        final safePos = playbackPos != null ? math.max(0, playbackPos) : null;
        final hasSafeReadahead =
            safePos != null && (playerTimeMs - safePos) > _starvationToleranceMs;
        if (hasSafeReadahead) {
          requestsWithoutProgress = 0;
          await _awaitPlaybackProgress(
            safePos,
            _heartbeatDeadline(lastRequestStarted, maxTimeSinceLastRequestMs),
            isCancelled,
          );
        } else if (++requestsWithoutProgress >= maxRequestsWithoutProgress) {
          throw SabrProtocolException(
            'SABR made no ${mediaType.name} progress for $requestsWithoutProgress requests',
          );
        }
      }
    }

    if (isCancelled()) return;
    if (protectionPending) {
      throw SabrProtocolException(
        'SABR stream protection remains pending',
        kind: SabrFailureKind.attestationRequired,
      );
    }

    _validateCompleteStream(
      initialization: initialization,
      initSegmentEmitted: initSegmentEmitted,
      lastSequenceNumber: lastSequenceNumber,
      downloadedDurationMs: playerTimeMs,
      expectedDurationMs: expectedDurationMs(),
      emittedBytes: cumulativeStreamBytes,
    );
  }

  Future<Uint8List?> _fetchLateToken(
    Future<Uint8List?> Function() supplier,
  ) async {
    try {
      final token = await supplier().timeout(
        const Duration(milliseconds: _lateTokenTimeoutMs),
      );
      if (token == null ||
          token.isEmpty ||
          token.length > _maxPoTokenBytes) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }

  void _validateCompleteStream({
    required SabrFormatInitialization? initialization,
    required bool initSegmentEmitted,
    required int? lastSequenceNumber,
    required int downloadedDurationMs,
    required int expectedDurationMs,
    required int emittedBytes,
  }) {
    if (!initSegmentEmitted) {
      throw SabrProtocolException('SABR stream has no initialization segment');
    }
    final finalSeq = lastSequenceNumber;
    if (finalSeq == null) {
      throw SabrProtocolException('SABR stream has no media segments');
    }
    if (initialization?.endSegmentNumber != null &&
        finalSeq != initialization!.endSegmentNumber!) {
      throw SabrProtocolException(
        'Incomplete SABR stream: last segment is $finalSeq, expected ${initialization.endSegmentNumber}',
      );
    }
    final toleranceMs = math.max(
      _minDurationToleranceMs,
      expectedDurationMs ~/ 100,
    );
    if ((downloadedDurationMs - expectedDurationMs).abs() > toleranceMs) {
      throw SabrProtocolException(
        'Incomplete SABR stream duration: ${downloadedDurationMs}ms vs ${expectedDurationMs}ms',
      );
    }
    if (initialPlayerTimeMs == 0 &&
        _expectedContentLengthBytes != null &&
        _expectedContentLengthBytes > 0 &&
        emittedBytes != _expectedContentLengthBytes) {
      throw SabrProtocolException(
        'Incomplete SABR stream bytes: $emittedBytes vs $_expectedContentLengthBytes',
      );
    }
  }

  DateTime _heartbeatDeadline(
    DateTime requestStarted,
    int maxTimeSinceLastRequestMs,
  ) {
    final intervalMs = maxTimeSinceLastRequestMs > 0
        ? math.min(maxTimeSinceLastRequestMs, _maxHeartbeatIntervalMs)
        : _defaultHeartbeatIntervalMs;
    return requestStarted.add(Duration(milliseconds: intervalMs));
  }

  int _remainingWaitMs(DateTime deadline) =>
      math.max(0, deadline.difference(DateTime.now()).inMilliseconds);

  Future<void> _awaitPlaybackProgress(
    int previousPositionMs,
    DateTime deadline,
    bool Function() isCancelled,
  ) async {
    while (!isCancelled()) {
      final current = playbackPositionMs?.call();
      if (current == null || math.max(0, current) != previousPositionMs) return;
      final remaining = _remainingWaitMs(deadline);
      if (remaining == 0) return;
      await _retryDelay(
        Duration(milliseconds: math.min(_playbackPollIntervalMs, remaining)),
      );
    }
  }

  Future<void> _awaitReadaheadCapacity({
    required int downloadedPositionMs,
    required int targetAudioReadaheadMs,
    required DateTime deadline,
    required bool Function() isCancelled,
  }) async {
    while (!isCancelled()) {
      final current = playbackPositionMs?.call();
      if (current == null) return;
      final excessMs =
          downloadedPositionMs - math.max(0, current) - targetAudioReadaheadMs;
      if (excessMs <= 0) return;
      final remaining = _remainingWaitMs(deadline);
      if (remaining == 0) return;
      final pollMs = excessMs
          .clamp(_playbackPollIntervalMs, _maxReadaheadPollIntervalMs)
          .toInt();
      await _retryDelay(Duration(milliseconds: math.min(pollMs, remaining)));
    }
  }

  static String _withRequestNumber(String url, int requestNumber) =>
      Uri.parse(url).setQueryParam('rn', requestNumber.toString()).toString();

  static String _ensureCpn(String url) {
    final uri = Uri.parse(url);
    if (uri.queryParameters.containsKey('cpn')) return url;
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
    final rng = math.Random.secure();
    final cpn = List.generate(
      16,
      (_) => chars[rng.nextInt(chars.length)],
    ).join();
    return uri.setQueryParam('cpn', cpn).toString();
  }
}
