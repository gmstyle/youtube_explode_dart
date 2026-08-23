import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'test_deno_po_token.dart' show resolveDenoExe;

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'MSRcC626prw';
  final denoExe = await resolveDenoExe();
  final poScript = Platform.script
      .resolve('../example/video_download_flutter/assets/po_token_deno.mjs')
      .toFilePath();

  final jsSolver = await DenoEJSSolver.init(denoExe: denoExe);
  final sabrDownloader = await DenoSabrDownloader.init(denoExe: denoExe);
  final poProvider = _PoProvider(denoExe, poScript);
  final yt = YoutubeExplode(
    poTokenProvider: poProvider,
    jsSolver: jsSolver,
    sabrDownloader: sabrDownloader,
  );

  try {
    // Mimic Flutter example: metadata first, then manifest, then download.
    stdout.writeln('1. videos.get()…');
    await yt.videos.get(videoId);

    stdout.writeln('2. getManifest()…');
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final stream = manifest.sabr.whereType<SabrAudioStreamInfo>().withHighestBitrate();
    stdout.writeln('   SABR itag ${stream.tag}');

    stdout.writeln('3. download…');
    var bytes = 0;
    await for (final chunk in yt.videos.streamsClient.get(stream)) {
      bytes += chunk.length;
      if (bytes >= 512 * 1024) break;
    }
    stdout.writeln('Saved $bytes bytes');
    exit(bytes >= 1024 ? 0 : 1);
  } finally {
    yt.close();
    jsSolver.dispose();
    poProvider.dispose();
    sabrDownloader.dispose();
  }
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
