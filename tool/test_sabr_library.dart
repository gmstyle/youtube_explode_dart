import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'test_deno_po_token.dart' show resolveDenoExe;

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

  final jsSolver = await DenoEJSSolver.init(denoExe: denoExe);
  final sabrDownloader = await DenoSabrDownloader.init(denoExe: denoExe);
  final poProvider = _PoProvider(denoExe, poScript);
  final yt = YoutubeExplode(
    poTokenProvider: poProvider,
    jsSolver: jsSolver,
    sabrDownloader: sabrDownloader,
  );

  try {
    stdout.writeln('Fetching manifest for $videoId…');
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    stdout.writeln('Streams: ${manifest.streams.length}');
    stdout.writeln('SABR: ${manifest.sabr.length}');
    stdout.writeln('audioOnly: ${manifest.audioOnly.length}');
    stdout.writeln('muxed: ${manifest.muxed.length}');

    final SabrStreamInfo stream;
    if (manifest.sabr.whereType<SabrAudioStreamInfo>().isNotEmpty) {
      stream =
          manifest.sabr.whereType<SabrAudioStreamInfo>().withHighestBitrate();
    } else if (manifest.sabr.isNotEmpty) {
      stream = manifest.sabr.first;
    } else {
      stderr.writeln('No SABR streams in manifest');
      exit(1);
    }

    stdout.writeln(
        'Downloading SABR itag ${stream.tag} (${stream.container.name})…');
    final outFile = File('/tmp/sabr_lib_${videoId}_${stream.tag}.webm');
    final sink = outFile.openWrite();
    var bytes = 0;
    const maxBytes = 512 * 1024;

    await for (final chunk in yt.videos.streamsClient.get(stream)) {
      sink.add(chunk);
      bytes += chunk.length;
      if (bytes >= maxBytes) break;
    }
    await sink.close();

    stdout.writeln('Saved $bytes bytes to ${outFile.path}');
    if (bytes < 1024) exit(1);
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
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  }) async {
    final proc =
        await Process.start(_denoExe, ['run', '--allow-net', _scriptPath]);
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
