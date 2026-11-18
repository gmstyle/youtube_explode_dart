import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Minimal cookie-injecting client mirroring Sonora's YtmSessionHttpClient.
class CookieClient extends http.BaseClient {
  CookieClient(this._cookies, [http.Client? inner])
    : _inner = inner ?? http.Client();

  final Map<String, String> _cookies;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_cookies.isNotEmpty) {
      final existing = request.headers['cookie'];
      final jar = _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      request.headers['cookie'] = existing == null || existing.isEmpty
          ? jar
          : '$jar; $existing';
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'FeelsLikeLovePlaceholder';
  final sessionPath =
      '${Platform.environment['HOME']}/.local/share/com.gmstyle.sonora/youtube_session.json';
  final raw =
      jsonDecode(await File(sessionPath).readAsString()) as Map<String, dynamic>;
  final cookies = <String, String>{};
  for (final c in (raw['cookies'] as List).cast<Map>()) {
    final n = c['name'] as String?;
    final v = c['value'] as String?;
    if (n != null && v != null && v.isNotEmpty) cookies[n] = v;
  }
  cookies.putIfAbsent('SOCS', () => 'CAI');
  print('cookies=${cookies.length} hasSAPISID=${cookies.containsKey('SAPISID')}');

  // Resolve a real video id via search if placeholder
  var id = videoId;
  if (id.length != 11) {
    // Use a known approach: call youtube search - skip, require id
    print('Pass an 11-char videoId as argv[0]');
    // Try common - we'll get id from music via separate step
  }

  Future<void> tryClients(String label, List<YoutubeApiClient> clients) async {
    final yt = YoutubeExplode(
      httpClient: YoutubeHttpClient(CookieClient(cookies)),
    );
    try {
      final m = await yt.videos.streamsClient.getManifest(
        id,
        ytClients: clients,
        requireWatchPage: false,
      );
      print(
        '$label OK audio=${m.audioOnly.length} muxed=${m.muxed.length} '
        'video=${m.videoOnly.length}',
      );
    } catch (e) {
      print('$label FAIL ${e.runtimeType}: $e');
    } finally {
      yt.close();
    }
  }

  if (id.length != 11) {
    print('Need videoId');
    return;
  }
  await tryClients('visionos+androidVr', [
    YoutubeApiClient.visionos,
    YoutubeApiClient.androidVr,
  ]);
  await tryClients('tv', [YoutubeApiClient.tv]);
  await tryClients('android', [YoutubeApiClient.android]);
  await tryClients('safari', [YoutubeApiClient.safari]);
}
