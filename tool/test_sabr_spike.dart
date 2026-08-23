import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/src/extensions/helpers_extension.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/pages/watch_page.dart';
import 'package:youtube_explode_dart/src/videos/video_controller.dart';
import 'package:youtube_explode_dart/src/videos/youtube_api_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<String> resolveDenoExe() async {
  final home = Platform.environment['HOME'];
  if (home != null) {
    final homeDeno = File('$home/.deno/bin/deno');
    if (homeDeno.existsSync()) return homeDeno.path;
  }
  final check = await Process.run('deno', ['--version']);
  if (check.exitCode == 0) return 'deno';
  throw Exception('Deno not found. Install from https://deno.land');
}

YoutubeApiClient webClientFromWatchPage(WatchPage watchPage) {
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
    headers: {if (userAgent != null) 'User-Agent': userAgent},
  );
}

Future<Map<String, dynamic>> fetchPlayerJson({
  required YoutubeHttpClient httpClient,
  required VideoController controller,
  required WatchPage watchPage,
  required VideoId videoId,
  required String poToken,
}) async {
  final client = webClientFromWatchPage(watchPage);
  final response = await controller.getPlayerResponse(
    videoId,
    client,
    watchPage: watchPage,
    poToken: poToken,
  );
  return response.root;
}

Future<String?> decipherUrlIfNeeded(
  String url,
  WatchPage watchPage,
  BaseJSChallengeSolver solver,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || watchPage.sourceUrl == null) return url;

  var resolved = uri;
  if (uri.queryParameters.containsKey('n')) {
    final n = uri.queryParameters['n']!;
    final decoded = await solver.solve(watchPage.sourceUrl!, JSChallengeType.n, n);
    resolved = resolved.setQueryParam('n', decoded);
  }
  return resolved.toString();
}

Future<void> patchServerAbrUrl(
  Map<String, dynamic> playerJson,
  WatchPage watchPage,
  BaseJSChallengeSolver solver,
) async {
  final streaming = playerJson['streamingData'] as Map<String, dynamic>?;
  if (streaming == null) return;

  final rawUrl = streaming['serverAbrStreamingUrl'] as String?;
  if (rawUrl == null || rawUrl.isEmpty) return;

  final deciphered = await decipherUrlIfNeeded(rawUrl, watchPage, solver);
  if (deciphered != null) {
    streaming['serverAbrStreamingUrl'] = deciphered;
  }
}

Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    stdout.writeln('[${r.level.name}] ${r.loggerName}: ${r.message}');
  });

  final videoId = args.isNotEmpty ? args.first : 'MSRcC626prw';
  final denoExe = await resolveDenoExe();
  final poScript = Platform.script
      .resolve('../example/video_download_flutter/assets/po_token_deno.mjs')
      .toFilePath();
  final sabrScript = Platform.script
      .resolve('sabr_spike/sabr_spike.mjs')
      .toFilePath();

  stdout.writeln('Video: $videoId');
  stdout.writeln('Deno: $denoExe');
  stdout.writeln('SABR script: $sabrScript');

  final jsSolver = await DenoEJSSolver.init(denoExe: denoExe);
  final httpClient = YoutubeHttpClient();
  final poProvider = _PoProvider(denoExe, poScript);

  try {
    final controller = VideoController(httpClient);

    stdout.writeln('Fetching watch page…');
    final watchPage = await WatchPage.get(httpClient, videoId);

    stdout.writeln('Generating PO token…');
    final innertubeCtx =
        watchPage.ytCfg['INNERTUBE_CONTEXT'] as Map<String, dynamic>? ?? {};
    final clientCtx = innertubeCtx['client'] as Map<String, dynamic>? ?? {};
    final poContext = PoTokenContext(
      visitorData: clientCtx['visitorData'] as String? ?? '',
      clientVersion: clientCtx['clientVersion'] as String? ?? '',
      innertubeContext: innertubeCtx,
      ytConfig: watchPage.ytCfg,
      initialAttestationDataSource: watchPage.initialAttestationDataSource,
    );
    final poToken = await poProvider.generatePoToken(videoId, poContext);

    stdout.writeln('Fetching /player (WEB + PO token)…');
    final playerJson = await fetchPlayerJson(
      httpClient: httpClient,
      controller: controller,
      watchPage: watchPage,
      videoId: VideoId(videoId),
      poToken: poToken,
    );

    final streaming = playerJson['streamingData'] as Map<String, dynamic>?;
    final adaptive = streaming?['adaptiveFormats'] as List<dynamic>? ?? [];
    final sabrUrl = streaming?['serverAbrStreamingUrl'] as String?;
    stdout.writeln('adaptiveFormats: ${adaptive.length}');
    stdout.writeln('serverAbrStreamingUrl present: ${sabrUrl != null}');

    if (sabrUrl == null) {
      stderr.writeln('No SABR URL in player response — cannot run spike.');
      exit(1);
    }

    stdout.writeln('Deciphering serverAbrStreamingUrl if needed…');
    await patchServerAbrUrl(playerJson, watchPage, jsSolver);

    final clientName = _webClientNameId(
      clientCtx['clientName'] as String? ?? 'WEB',
    );

    stdout.writeln('Running SABR spike (first audio segment)…');
    final proc = await Process.start(denoExe, [
      'run',
      '--allow-net',
      '--allow-write=/tmp',
      sabrScript,
    ]);
    proc.stdin.writeln(jsonEncode({
      'videoId': videoId,
      'poToken': poToken,
      'clientName': clientName,
      'clientVersion': clientCtx['clientVersion'],
      'playerResponse': playerJson,
    }));
    await proc.stdin.close();

    final stdoutText = await proc.stdout.transform(utf8.decoder).join();
    final stderrText = await proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode;

    if (stderrText.trim().isNotEmpty) {
      stderr.writeln('Deno stderr:\n$stderrText');
    }

    Map<String, dynamic>? result;
    for (final line in stdoutText.split('\n').reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        result = jsonDecode(trimmed) as Map<String, dynamic>;
        break;
      } catch (_) {}
    }

    if (result == null) {
      stderr.writeln('SABR spike produced no JSON (exit $exitCode):\n$stdoutText');
      exit(1);
    }

    stdout.writeln(jsonEncode(result));

    if (result['success'] != true) {
      exit(1);
    }

    final file = result['file'] as String?;
    if (file != null) {
      final size = await File(file).length();
      stdout.writeln('Saved $size bytes to $file');
    }
  } finally {
    httpClient.close();
    jsSolver.dispose();
    poProvider.dispose();
  }
}

int _webClientNameId(String clientName) {
  // Innertube client name IDs (WEB = 1).
  const ids = {
    'WEB': 1,
    'MWEB': 2,
    'ANDROID': 3,
    'IOS': 5,
    'TVHTML5': 7,
  };
  return ids[clientName.toUpperCase()] ?? 1;
}

class _PoProvider extends BasePoTokenProvider {
  _PoProvider(this._denoExe, this._scriptPath);
  final String _denoExe;
  final String _scriptPath;

  @override
  Future<String> generatePoToken(String videoId, PoTokenContext context) async {
    final proc = await Process.start(_denoExe, ['run', '--allow-net', _scriptPath]);
    proc.stdin.writeln(jsonEncode({
      'videoId': videoId,
      'context': context.innertubeContext,
      'initialAttestationDataSource': context.initialAttestationDataSource,
      'ytConfig': context.ytConfig,
    }));
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    await proc.exitCode;
    for (final line in out.split('\n').reversed) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final j = jsonDecode(t) as Map<String, dynamic>;
        if (j['success'] == true) return j['token'] as String;
        throw Exception(j['error']);
      } catch (_) {}
    }
    throw Exception('PO token failed: $out');
  }

  @override
  void dispose() {}
}
