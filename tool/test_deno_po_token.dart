import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<String> resolveDenoExe() async {
  final home = Platform.environment['HOME'];
  if (home != null) {
    final homeDeno = File('$home/.deno/bin/deno');
    if (homeDeno.existsSync()) return homeDeno.path;
  }
  final check = await Process.run('deno', ['--version']);
  if (check.exitCode == 0) return 'deno';
  throw Exception('Deno not found');
}

Future<void> main(List<String> args) async {
  Logger.root.level = Level.FINER;
  Logger.root.onRecord.listen((r) {
    stdout.writeln('[${r.level.name}] ${r.loggerName}: ${r.message}');
  });

  final videoId = args.isNotEmpty ? args.first : 'dQw4w9WgXcQ';
  final denoExe = await resolveDenoExe();
  final scriptPath = Platform.script
      .resolve('../example/video_download_flutter/assets/po_token_deno.mjs')
      .toFilePath();

  stdout.writeln('Using Deno: $denoExe');
  stdout.writeln('Script: $scriptPath');

  final jsSolver = await DenoEJSSolver.init(denoExe: denoExe);
  final yt = YoutubeExplode(
    poTokenProvider: _DenoTestProvider(denoExe, scriptPath),
    jsSolver: jsSolver,
  );

  try {
    stdout.writeln('Fetching manifest for $videoId…');
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    stdout.writeln(
        'Muxed: ${manifest.muxed.length}, audio: ${manifest.audioOnly.length}, video: ${manifest.videoOnly.length}');

    if (manifest.muxed.isEmpty && manifest.audioOnly.isEmpty) {
      stderr.writeln(
          'No streams in manifest — PO token or player response may have failed.');
      exit(1);
    }

    final stream = manifest.muxed.isNotEmpty
        ? manifest.muxed.withHighestBitrate()
        : manifest.audioOnly.withHighestBitrate();
    final pot = stream.url.queryParameters['pot'];
    stdout.writeln('itag ${stream.tag}, pot prefix: ${pot?.substring(0, 24)}…');

    final client = HttpClient();
    final request = await client.getUrl(stream.url);
    request.headers.set('User-Agent', 'Mozilla/5.0');
    final response = await request.close().timeout(const Duration(seconds: 15));
    stdout.writeln('GET status: ${response.statusCode}');
    client.close(force: true);
  } finally {
    yt.close();
    jsSolver.dispose();
  }
}

class _DenoTestProvider extends BasePoTokenProvider {
  _DenoTestProvider(this._denoExe, this._scriptPath);

  final String _denoExe;
  final String _scriptPath;

  @override
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  }) async {
    stderr.writeln('Generating PO token via Deno for $videoId…');
    final proc =
        await Process.start(_denoExe, ['run', '--allow-net', _scriptPath]);
    proc.stdin.writeln(jsonEncode({
      'videoId': videoId,
      'context': context.innertubeContext,
      'initialAttestationDataSource': context.initialAttestationDataSource,
      'ytConfig': context.ytConfig,
    }));
    await proc.stdin.close();

    final stdoutText = await proc.stdout.transform(utf8.decoder).join();
    final stderrText = await proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode;

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
      throw Exception(
          'Deno failed ($exitCode): ${stderrText.isEmpty ? stdoutText : stderrText}');
    }
    if (result['success'] == true) {
      stderr
          .writeln('PO token OK (${(result['token'] as String).length} chars)');
      return result['token'] as String;
    }
    throw Exception(result['error']);
  }

  @override
  void dispose() {}
}
