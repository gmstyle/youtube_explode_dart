import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:logging/logging.dart';

import '../../../videos/video_id.dart';
import '../../../videos/youtube_api_client.dart';
import '../../pages/watch_page.dart';
import '../../youtube_http_client.dart';
import '../po_token_policy.dart';
import '../po_token_provider.dart';
import '../web_js_runner.dart';
import 'web_page_attestation.dart';

class _CachedMinterState {
  final String sessionKey;
  final String? visitorData;
  final String? sessionPoToken;
  final String? signatureTimestamp;
  final DateTime expiresAt;
  final int contextGeneration;

  const _CachedMinterState({
    required this.sessionKey,
    required this.visitorData,
    required this.sessionPoToken,
    required this.signatureTimestamp,
    required this.expiresAt,
    required this.contextGeneration,
  });

  bool get isValid => DateTime.now().isBefore(expiresAt);
}

/// Pure-Dart BotGuard PO token orchestrator backed by a [BaseWebJsRunner].
///
/// All HTTP calls (`/watch`, `/youtubei/v1/att/get`, `interpreterUrl`,
/// `/api/jnn/v1/GenerateIT`) run through [httpClient] so cookies, `SAPISIDHASH`,
/// `visitorData`, and `User-Agent` stay aligned with the caller session, while
/// only BotGuard VM execution and fast local token minting run in the anchored
/// JS runner.
class BotGuardPoTokenProvider extends BasePoTokenProvider {
  static final _logger = Logger('YoutubeExplode.BotGuardPoToken');

  static const String _generateItUrl =
      'https://www.youtube.com/api/jnn/v1/GenerateIT';
  static const String _attGetUrl =
      'https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false&alt=json';
  static const String _waaApiKey = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
  static const String _requestKey = 'O43z0dpjhgX20SCx4KAo';
  static const String _defaultBrowserUa =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';
  static final Uri _youtubeOriginUri = Uri.parse(
    'https://www.youtube.com/robots.txt',
  );
  static const int _maxLifetimeSeconds = 6 * 3600;

  final BaseWebJsRunner _runner;
  final YoutubeHttpClient _httpClient;
  final String _userAgent;
  final String? Function()? _visitorDataProvider;
  final String? Function()? _sessionKeyProvider;
  final bool _ownsRunner;

  final Map<String, String> _interpreterCache = {};
  _CachedMinterState? _cachedMinter;
  Future<void> _serial = Future<void>.value();

  BotGuardPoTokenProvider({
    required this._runner,
    required this._httpClient,
    String? userAgent,
    this._visitorDataProvider,
    this._sessionKeyProvider,
    this._ownsRunner = false,
  }) : _userAgent = (userAgent != null && userAgent.isNotEmpty)
           ? userAgent
           : _defaultBrowserUa;

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  Future<PoTokenResult?> getPoToken({
    required YoutubeApiClient client,
    required VideoId videoId,
    String? visitorData,
    WatchPage? watchPage,
    bool forceRefresh = false,
  }) {
    final policy = YoutubeClientPoPolicy.forClient(client);
    if (!policy.requiresPlayerPoToken && !policy.usesGvsPoToken) {
      return Future.value(null);
    }

    return _serialized(() async {
      final sessionKey = _sessionKeyProvider?.call() ?? '';
      final requestedVd =
          (visitorData != null && visitorData.isNotEmpty)
          ? visitorData
          : _visitorDataProvider?.call();

      final cached = _cachedMinter;
      final canReuseMinter =
          !forceRefresh &&
          cached != null &&
          cached.isValid &&
          cached.sessionKey == sessionKey &&
          cached.contextGeneration == _runner.contextGeneration &&
          (requestedVd == null ||
              requestedVd.isEmpty ||
              cached.visitorData == requestedVd);

      if (canReuseMinter) {
        try {
          final contentToken = await _mintToken(videoId.value);
          return PoTokenResult(
            sessionPoToken: cached.sessionPoToken,
            streamingDataPoToken: contentToken,
            visitorData: cached.visitorData,
            signatureTimestamp: cached.signatureTimestamp,
            expiresAt: cached.expiresAt,
          );
        } catch (e) {
          _logger.warning(
            'Cached BotGuard minter failed ($e); rebootstrapping session',
          );
          _cachedMinter = null;
        }
      }

      return _bootstrapAndMint(
        videoId: videoId,
        sessionKey: sessionKey,
        requestedVisitorData: requestedVd,
        watchPage: watchPage,
      );
    });
  }

  Future<PoTokenResult> _bootstrapAndMint({
    required VideoId videoId,
    required String sessionKey,
    String? requestedVisitorData,
    WatchPage? watchPage,
  }) async {
    WebPageAttestationContext? ctx;
    if (watchPage != null) {
      ctx = extractWebPageAttestationContext(watchPage.root.outerHtml);
    }
    if (ctx == null) {
      final html = await _fetchWatchHtml(videoId.value, requestedVisitorData);
      ctx = extractWebPageAttestationContext(html);
    }
    if (ctx == null) {
      throw PoTokenException(
        'Watch page has no paired BotGuard challenge and event ID',
      );
    }

    var rawChallenge = ctx.challenge;
    if (rawChallenge == null && ctx.eacrToken != null) {
      rawChallenge = await _fetchChallengeViaAttGet(
        eacrToken: ctx.eacrToken!,
        visitorData: requestedVisitorData ?? ctx.visitorData,
        clientVersion: ctx.clientVersion ?? '2.20260708.00.00',
      );
    }
    if (rawChallenge == null) {
      throw PoTokenException('Could not obtain BotGuard challenge');
    }

    final interpreterUrl = parseAttestationInterpreterUrl(rawChallenge);
    final interpreterJs = await _fetchInterpreterJs(interpreterUrl);
    final challengeDataJson = parseAttestationChallengeData(
      rawChallenge,
      interpreterJs,
    );

    await _runner.resetContext(originUrl: _youtubeOriginUri);
    await _runner.evaluateAsync(kBotGuardRuntimeScript);
    final eventIdJson = json.encode(ctx.eventId);
    final setupRes = await _runner.evaluateAsync(
      'window.yt = globalThis.yt = { config_: { EVENT_ID: $eventIdJson } }; '
      'globalThis.__ytBgRun($challengeDataJson);',
    );
    if (setupRes == null || setupRes.isEmpty) {
      throw PoTokenException('BotGuard VM returned an empty snapshot');
    }

    final generateResp = await _httpClient.post(
      Uri.parse(_generateItUrl),
      headers: {
        'Content-Type': 'application/json+protobuf',
        'Accept': 'application/json',
        'x-user-agent': 'grpc-web-javascript/0.1',
        'x-goog-api-key': _waaApiKey,
        'User-Agent': _userAgent,
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/',
      },
      body: json.encode([_requestKey, setupRes]),
      validate: true,
    );

    final integrity = parseIntegrityTokenData(generateResp.body);
    final tokenListJson = json.encode(integrity.tokenBytes);
    await _runner.evaluateAsync(
      'globalThis.__ytBgCreateMinter($tokenListJson);',
    );

    final resolvedVd = (requestedVisitorData != null &&
            requestedVisitorData.isNotEmpty)
        ? requestedVisitorData
        : ctx.visitorData;
    String? sessionToken;
    if (resolvedVd != null && resolvedVd.isNotEmpty) {
      sessionToken = await _mintToken(resolvedVd);
    }
    final contentToken = await _mintToken(videoId.value);

    final boundedLifetime = math.min(
      math.max(60, integrity.lifetimeSeconds),
      _maxLifetimeSeconds,
    );
    final margin = math.min(600, boundedLifetime ~/ 10);
    final ttlSeconds = math.max(60, boundedLifetime - margin);
    final expiresAt = DateTime.now().add(Duration(seconds: ttlSeconds));

    _cachedMinter = _CachedMinterState(
      sessionKey: sessionKey,
      visitorData: resolvedVd,
      sessionPoToken: sessionToken,
      signatureTimestamp: ctx.signatureTimestamp,
      expiresAt: expiresAt,
      contextGeneration: _runner.contextGeneration,
    );

    _logger.fine('BotGuard session minter initialized (ttl=${ttlSeconds}s)');
    return PoTokenResult(
      sessionPoToken: sessionToken,
      streamingDataPoToken: contentToken,
      visitorData: resolvedVd,
      signatureTimestamp: ctx.signatureTimestamp,
      expiresAt: expiresAt,
    );
  }

  Future<String> _mintToken(String identifier) async {
    final encodedId = json.encode(identifier);
    final token = await _runner.evaluateAsync(
      'globalThis.__ytBgMintToken($encodedId);',
    );
    if (token == null || token.isEmpty) {
      throw PoTokenException('BotGuard minter returned an empty PO token');
    }
    return token;
  }

  Future<String> _fetchWatchHtml(String videoId, String? visitorData) async {
    final url = Uri.parse(
      'https://www.youtube.com/watch?v=$videoId&bpctr=9999999999&has_verified=1&hl=en',
    );
    final resp = await _httpClient.get(
      url,
      headers: {
        'User-Agent': _userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'PREF=hl=en&tz=UTC; SOCS=CAI; GPS=1',
        if (visitorData != null && visitorData.isNotEmpty)
          'X-Goog-Visitor-Id': visitorData,
      },
      validate: true,
    );
    return resp.body;
  }

  Future<String> _fetchChallengeViaAttGet({
    required String eacrToken,
    required String? visitorData,
    required String clientVersion,
  }) async {
    final resp = await _httpClient.post(
      Uri.parse(_attGetUrl),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
        'Origin': 'https://www.youtube.com',
        'Referer': 'https://www.youtube.com/',
        'X-Youtube-Client-Name': '1',
        'X-Youtube-Client-Version': clientVersion,
        if (visitorData != null && visitorData.isNotEmpty)
          'X-Goog-Visitor-Id': visitorData,
      },
      body: json.encode({
        'engagementType': 'ENGAGEMENT_TYPE_UNBOUND',
        'eacrToken': eacrToken,
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': clientVersion,
            'hl': 'en',
            'gl': 'US',
          },
        },
      }),
      validate: true,
    );
    return resp.body;
  }

  Future<String> _fetchInterpreterJs(String url) async {
    final cached = _interpreterCache[url];
    if (cached != null) return cached;
    final body = await _httpClient.getString(
      url,
      headers: {'User-Agent': _userAgent},
      validate: true,
    );
    if (_interpreterCache.length >= 4) _interpreterCache.clear();
    _interpreterCache[url] = body;
    return body;
  }

  @override
  void invalidateSession() {
    _cachedMinter = null;
  }

  @override
  void dispose() {
    invalidateSession();
    _interpreterCache.clear();
    if (_ownsRunner) {
      _runner.dispose();
    }
  }
}
