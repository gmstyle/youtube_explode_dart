class YoutubeApiClient {
  final Map<String, dynamic> payload;
  final String apiUrl;
  final Map<String, dynamic> headers;

  const YoutubeApiClient(this.payload, this.apiUrl, {this.headers = const {}});

  YoutubeApiClient.fromJson(Map<String, dynamic> json)
    : payload = json['payload'],
      apiUrl = json['apiUrl'],
      headers = json['headers'];

  Map<String, dynamic> toJson() => {
    'payload': payload,
    'apiUrl': apiUrl,
    'headers': headers,
  };

  // from https://github.com/yt-dlp/yt-dlp/blob/7794374de8afb20499b023107e2abfd4e6b93ee4/yt_dlp/extractor/youtube/_base.py#L136
  /// Has limited streams but doesn't require signature deciphering.
  static final ios = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'IOS',
          'clientVersion': '20.10.4',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'userAgent': 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
          'hl': 'en',
          "platform": "MOBILE",
          'osName': 'IOS',
          'osVersion': '18.1.0.22B83',
          'timeZone': 'UTC',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://www.youtube.com/youtubei/v1/player?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc&prettyPrint=false',
  );

  /// This provides also muxed streams but seems less reliable than [ios].
  /// Prefer [androidVr] — CDN often rejects adaptive URLs from this client with HTTP 403.
  /// Note: This client includes androidSdkVersion which may require PO Token.
  static const android = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'androidSdkVersion': 30,
        'userAgent':
            'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
        'osName': 'Android',
        'osVersion': '11',
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Based on yt-dlp's android_sdkless client.
  /// Note: This client has stopped working for non-muxed streams as of 2026-08.
  /// Prefer [visionos] or [androidVr].
  @Deprecated('No longer works for non-muxed streams')
  static const androidSdkless = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'userAgent':
            'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
        'osName': 'Android',
        'osVersion': '11',
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Has limited streams but doesn't require signature deciphering.
  /// As opposed to [android], this works only for music.
  static const androidMusic = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'ANDROID_MUSIC',
          'clientVersion': '8.05.50',
          'androidSdkVersion': 33,
          'osName': 'Android',
          'osVersion': '13',
          'userAgent': 'com.google.android.apps.youtube.music/8.05.50 (Linux; U; Android 13) gzip',
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://music.youtube.com/youtubei/v1/player?key=AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI&prettyPrint=false',
  );

  /// Default client for stream manifests. Provides muxed and adaptive streams
  /// without requiring a JS challenge solver. Prefer this over [android] /
  /// [androidSdkless], whose adaptive URLs are frequently rejected with 403.
  static const androidVr = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID_VR',
        'clientVersion': '1.65.10',
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'osVersion': '12',
        'osName': 'Android',
        'androidSdkVersion': 32,
        'userAgent': 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
    'contentCheckOk': true,
    'racyCheckOk': true,
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// This client also provide high quality muxed stream in the HLS manifest.
  /// The streams are in m3u8 format.
  static const safari = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20250312.04.00',
        'userAgent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Used to bypass same restriction on videos.
  static const tv = YoutubeApiClient(
    {
      'context': {
        'client': {
          "deviceMake": "",
          "deviceModel": "",
          "userAgent":
              "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)",
          'clientName': 'TVHTML5',
          "clientVersion": "7.20261118.10.00",
          'hl': 'en',
          'timeZone': 'UTC',
          'gl': 'US',
          'utcOffsetMinutes': 0,
          "originalUrl": "https://www.youtube.com/tv",
          "theme": "CLASSIC",
          "platform": "DESKTOP",
          "clientFormFactor": "UNKNOWN_FORM_FACTOR",
          "webpSupport": false,
          "configInfo": {},
          "tvAppInfo": {"appQuality": "TV_APP_QUALITY_FULL_ANIMATION"},
          "acceptHeader":
              "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        "user": {"lockedSafetyMode": false},
        "request": {"useSsl": true},
      },
      "contentCheckOk": true,
      "racyCheckOk": true,
    },
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: {
      'Content-Type': 'application/json',
      'Origin': 'https://www.youtube.com',
    },
  );

  static const mediaConnect = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'MEDIA_CONNECT_FRONTEND',
        'clientVersion': '0.1',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Sometimes includes low quality streams (eg. 144p12).
  static const mweb = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'MWEB',
        'clientVersion': '2.20240726.01.00',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Currently the most reliable client for logged-out streaming.
  /// Does not require PO Tokens or JavaScript challenge solving.
  static const visionos = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
    'contentCheckOk': true,
    'racyCheckOk': true,
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// YouTube Music endpoint for VISIONOS; returns tokenless, cipher-free SABR
  /// audio and video streams suitable for unauthenticated playback.
  static const visionosSabr = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'userAgent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
    'contentCheckOk': true,
    'racyCheckOk': true,
  }, 'https://music.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// YouTube Music web client supporting both cookie-authenticated and
  /// anonymous sessions, SABR, and GVS PO Tokens.
  static const webRemix = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': '1.20260707.12.00',
          'userAgent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36',
          'hl': 'en',
          'gl': 'US',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: {
      'Origin': 'https://music.youtube.com',
    },
  );

  /// Standard desktop Web client supporting SABR, cookies, and GVS PO Tokens.
  static const web = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'WEB',
          'clientVersion': '2.20260708.00.00',
          'userAgent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36',
          'hl': 'en',
          'gl': 'US',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: {
      'Origin': 'https://www.youtube.com',
    },
  );

  /// Cookieless TVHTML5_SIMPLY client requiring both player and GVS PO Tokens.
  static const tvHtml5Simply = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'TVHTML5_SIMPLY',
          'clientVersion': '1.0',
          'hl': 'en',
          'gl': 'US',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: {
      'Origin': 'https://www.youtube.com',
    },
  );

  @Deprecated('Youtube always requires authentication for this client')
  static const webCreator = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'WEB_CREATOR',
        'clientVersion': '1.20240723.03.00',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  /// Work even of restricted videos and provides low quality muxed streams, but requires signature deciphering.
  /// Does not work if the video has the embedding disabled.
  @Deprecated('Youtube always requires authentication for this client')
  static const tvSimplyEmbedded = YoutubeApiClient(
    {
      'context': {
        'client': {
          'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          'clientVersion': '2.0',
          'hl': 'en',
          'timeZone': 'UTC',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
      },
      'thirdParty': {'embedUrl': 'https://www.youtube.com/'},
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
    headers: {
      'Content-Type': 'application/json',
      'Origin': 'https://www.youtube.com',
    },
  );

  /// Returns the User-Agent associated with [clientName] (`c=` parameter),
  /// or `null` when unknown or unspecified.
  static String? userAgentForClientName(String? clientName) {
    if (clientName == null) return null;
    final client = switch (clientName.trim().toUpperCase()) {
      'VISIONOS' => visionos,
      'ANDROID_VR' => androidVr,
      'IOS' => ios,
      'ANDROID' => android,
      'ANDROID_MUSIC' => androidMusic,
      'TVHTML5' => tv,
      'TVHTML5_SIMPLY' => tvHtml5Simply,
      'WEB_REMIX' => webRemix,
      'WEB' => web,
      'MWEB' => mweb,
      _ => null,
    };
    if (client == null) return null;
    final context = client.payload['context'] as Map<String, dynamic>?;
    final clientMap = context?['client'] as Map<String, dynamic>?;
    final ua = clientMap?['userAgent'] as String?;
    return (ua != null && ua.isNotEmpty) ? ua : null;
  }

  /// Returns the numeric InnerTube client ID for [clientName], or `null` if unknown.
  static int? clientIdForClientName(String? clientName) {
    if (clientName == null) return null;
    return switch (clientName.trim().toUpperCase()) {
      'WEB' => 1,
      'MWEB' => 2,
      'ANDROID' => 3,
      'IOS' => 5,
      'TVHTML5' => 7,
      'ANDROID_MUSIC' => 21,
      'ANDROID_VR' => 28,
      'WEB_CREATOR' => 62,
      'WEB_REMIX' => 67,
      'TVHTML5_SIMPLY' => 75,
      'VISIONOS' => 101,
      _ => null,
    };
  }
}
