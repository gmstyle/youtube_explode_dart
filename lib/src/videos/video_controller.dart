import 'dart:convert';

import 'package:meta/meta.dart';

import '../../youtube_explode_dart.dart';
import '../reverse_engineering/pages/watch_page.dart';
import '../reverse_engineering/player/player_response.dart';

@internal
class VideoController {
  @protected
  final YoutubeHttpClient httpClient;

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

    final userAgent = payload['context']!['client']!['userAgent'] as String?;
    final ytCfg = watchPage?.ytCfg;

    final body = {
      'contentCheckOk': true,
      'racyCheckOk': true,
      ...payload,
      'videoId': videoId.value,
      if (ytCfg?.containsKey('STS') ?? false)
        'playbackContext': {
          'contentPlaybackContext': {
            'html5Preference': 'HTML5_PREF_WANTS',
            'signatureTimestamp': ytCfg!['STS'].toString(),
          },
        },
    };
    if (body['context']!['client']['clientName'] == 'IOS') {
      body['context']!['client']!['visitorData'] = await _extractVisitorData(
        httpClient,
        client,
      );
    }

    final visitorData =
        (ytCfg?['VISITOR_DATA'] as String?) ??
        ((ytCfg?['INNERTUBE_CONTEXT'] as Map?)?['client']
                as Map?)?['visitorData']
            as String?;

    final content = await httpClient.postString(
      client.apiUrl,
      body: body,
      headers: {
        'User-Agent': ?userAgent,
        'X-Youtube-Client-Name': payload['context']!['client']!['clientName'],
        'X-Youtube-Client-Version':
            payload['context']!['client']!['clientVersion'],
        if (visitorData != null && visitorData.isNotEmpty)
          'X-Goog-Visitor-Id': visitorData,
        'Origin': 'https://www.youtube.com',
        'Content-Type': 'application/json',
        if (watchPage != null) 'Cookie': watchPage.cookieString,
        ...client.headers,
      },
    );
    return PlayerResponse.parse(content);
  }

  String? _visitorData;

  Future<String> _extractVisitorData(
    YoutubeHttpClient http,
    YoutubeApiClient client,
  ) async {
    if (_visitorData != null) {
      return _visitorData!;
    }

    var response = await http.getString(
      'https://www.youtube.com/sw.js_data',
      headers: {
        'User-Agent': client.payload['context']['client']['userAgent']!,
        'Content-Type': 'application/json',
      },
    );

    if (response.startsWith(")]}'")) {
      response = response.substring(4);
    }

    final data = json.decode(response) as List<dynamic>;
    final value = data[0][2][0][0][13];

    return _visitorData = value;
  }
}
