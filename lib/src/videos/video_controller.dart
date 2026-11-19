import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../youtube_explode_dart.dart';
import '../reverse_engineering/pages/watch_page.dart';
import '../reverse_engineering/player/player_response.dart';

@internal
class VideoController {
  static final _logger = Logger('YoutubeExplode.VideoController');
  static const Duration _visitorDataTtl = Duration(minutes: 30);
  static const Set<String> _visitorDataClients = {
    'VISIONOS',
    'ANDROID_VR',
    'IOS',
  };

  @protected
  final YoutubeHttpClient httpClient;

  final Map<String, ({String value, DateTime fetchedAt})> _visitorDataCache =
      {};

  VideoController(this.httpClient);

  Future<PlayerResponse> getPlayerResponse(
    VideoId videoId,
    YoutubeApiClient client, {
    WatchPage? watchPage,
  }) async {
    final payload = client.payload;
    assert(payload['context'] != null, 'client must contain a context');
    assert(
      payload['context']!['client'] != null,
      'client must contain a context.client',
    );

    final rawContext = payload['context'] as Map<String, dynamic>;
    final rawClient = rawContext['client'] as Map<String, dynamic>;
    final userAgent = rawClient['userAgent'] as String?;
    final clientName = rawClient['clientName'] as String;
    final clientVersion = rawClient['clientVersion'] as String?;
    final ytCfg = watchPage?.ytCfg;

    var visitorData =
        (ytCfg?['VISITOR_DATA'] as String?) ??
        ((ytCfg?['INNERTUBE_CONTEXT'] as Map?)?['client']
                as Map?)?['visitorData']
            as String? ??
        (rawClient['visitorData'] as String?);
    if (visitorData != null && visitorData.isEmpty) {
      visitorData = null;
    }

    var usedCachedVisitorData = false;
    if (visitorData == null && _visitorDataClients.contains(clientName)) {
      final resolved = await _getVisitorData(
        httpClient,
        client,
        clientName,
        forceRefresh: false,
      );
      visitorData = resolved.value;
      usedCachedVisitorData = resolved.fromCache;
    }

    const nativeClients = {
      'VISIONOS',
      'ANDROID_VR',
      'IOS',
      'ANDROID',
      'ANDROID_MUSIC',
    };
    final isNativeClient = nativeClients.contains(clientName);

    Future<PlayerResponse> postPlayer(String? vd) async {
      final clonedClient = Map<String, dynamic>.from(rawClient);
      if (vd != null && vd.isNotEmpty) {
        clonedClient['visitorData'] = vd;
      }
      final clonedContext = Map<String, dynamic>.from(rawContext);
      clonedContext['client'] = clonedClient;

      final body = <String, dynamic>{
        'contentCheckOk': true,
        'racyCheckOk': true,
        ...payload,
        'context': clonedContext,
        'videoId': videoId.value,
        if (ytCfg?.containsKey('STS') ?? false)
          'playbackContext': {
            'contentPlaybackContext': {
              'html5Preference': 'HTML5_PREF_WANTS',
              'signatureTimestamp': ytCfg!['STS'].toString(),
            },
          },
      };

      final content = await httpClient.postString(
        client.apiUrl,
        body: body,
        headers: {
          'User-Agent': ?userAgent,
          'X-Youtube-Client-Name': clientName,
          'X-Youtube-Client-Version': ?clientVersion,
          if (vd != null && vd.isNotEmpty) 'X-Goog-Visitor-Id': vd,
          if (!isNativeClient) 'Origin': 'https://www.youtube.com',
          'Content-Type': 'application/json',
          if (watchPage != null) 'Cookie': watchPage.cookieString,
          ...client.headers,
        },
      );
      return PlayerResponse.parse(content);
    }

    final response = await postPlayer(visitorData);
    if (response.playabilityStatus.toUpperCase() == 'LOGIN_REQUIRED' &&
        usedCachedVisitorData) {
      final refreshed = await _getVisitorData(
        httpClient,
        client,
        clientName,
        forceRefresh: true,
      );
      final freshValue = refreshed.value;
      if (freshValue != null && freshValue.isNotEmpty) {
        return postPlayer(freshValue);
      }
    }
    return response;
  }

  Future<({String? value, bool fromCache})> _getVisitorData(
    YoutubeHttpClient http,
    YoutubeApiClient client,
    String clientName, {
    required bool forceRefresh,
  }) async {
    if (!forceRefresh) {
      final cached = _visitorDataCache[clientName];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _visitorDataTtl) {
        return (value: cached.value, fromCache: true);
      }
    }

    final clientMap =
        (client.payload['context'] as Map<String, dynamic>)['client']
            as Map<String, dynamic>;
    final clientVersion = clientMap['clientVersion'] as String?;
    final userAgent = clientMap['userAgent'] as String?;

    try {
      final response = await http.postString(
        'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false',
        body: {
          'context': {
            'client': {
              'clientName': clientName,
              'clientVersion': ?clientVersion,
              'hl': 'en',
              'gl': 'US',
            },
          },
        },
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': ?userAgent,
          'X-Youtube-Client-Name': clientName,
          'X-Youtube-Client-Version': ?clientVersion,
        },
      );
      final decoded = json.decode(response);
      if (decoded is Map<String, dynamic>) {
        final responseContext =
            decoded['responseContext'] as Map<String, dynamic>?;
        final value = responseContext?['visitorData'] as String?;
        if (value != null && value.isNotEmpty) {
          _visitorDataCache[clientName] = (
            value: value,
            fetchedAt: DateTime.now(),
          );
          return (value: value, fromCache: false);
        }
      }
    } on HttpClientClosedException {
      rethrow;
    } catch (e) {
      _logger.fine(
        'Failed to fetch visitorData from /visitor_id for $clientName: $e',
      );
    }

    final fallback = await _extractVisitorData(http, client, clientName);
    if (fallback != null && fallback.isNotEmpty) {
      _visitorDataCache[clientName] = (
        value: fallback,
        fetchedAt: DateTime.now(),
      );
      return (value: fallback, fromCache: false);
    }
    return (value: null, fromCache: false);
  }

  Future<String?> _extractVisitorData(
    YoutubeHttpClient http,
    YoutubeApiClient client,
    String clientName,
  ) async {
    try {
      final clientMap =
          (client.payload['context'] as Map<String, dynamic>)['client']
              as Map<String, dynamic>;
      final userAgent = clientMap['userAgent'] as String?;
      var response = await http.getString(
        'https://www.youtube.com/sw.js_data',
        headers: {
          'User-Agent': ?userAgent,
          'Content-Type': 'application/json',
          'X-Youtube-Client-Name': clientName,
        },
      );

      if (response.startsWith(")]}'")) {
        response = response.substring(4);
      }

      final data = json.decode(response) as List<dynamic>;
      final value = data[0][2][0][0][13] as String?;
      return (value != null && value.isNotEmpty) ? value : null;
    } on HttpClientClosedException {
      rethrow;
    } catch (e) {
      _logger.fine(
        'Failed to fetch visitorData from sw.js_data for $clientName: $e',
      );
      return null;
    }
  }
}
