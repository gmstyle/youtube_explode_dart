import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';

import '../../exceptions/exceptions.dart';
import '../../videos/streams/mixins/audio_stream_info.dart';
import '../../videos/streams/mixins/sabr_stream_info.dart';
import '../../videos/streams/mixins/video_stream_info.dart';

/// Downloads SABR streams (Server Adaptive Bitrate) from YouTube.
abstract class BaseSabrDownloader {
  /// Downloads the bytes of the given [SabrStreamInfo].
  Stream<List<int>> download(SabrStreamInfo streamInfo);

  /// Releases resources held by this downloader.
  void dispose();
}

/// Downloads SABR streams using Deno and [@luanrt/googlevideo](https://jsr.io/@luanrt/googlevideo).
class DenoSabrDownloader extends BaseSabrDownloader {
  static final _logger = Logger('YoutubeExplode.DenoSabrDownloader');

  final String _denoExe;
  final String _scriptPath;

  DenoSabrDownloader._(this._denoExe, this._scriptPath);

  /// Resolves a Deno executable, preferring `~/.deno/bin/deno`.
  static Future<String> resolveDenoExe() async {
    final home = Platform.environment['HOME'];
    if (home != null) {
      final homeDeno = File('$home/.deno/bin/deno');
      if (homeDeno.existsSync()) return homeDeno.path;
    }
    final check = await Process.run('deno', ['--version']);
    if (check.exitCode == 0) return 'deno';
    throw Exception('Deno not found. Install from https://deno.land');
  }

  /// Resolves the bundled Deno script when running on the Dart VM (`dart run`).
  /// Returns null on Flutter and other embedders that don't support
  /// [Isolate.resolvePackageUri].
  static Future<String?> tryResolveBundledScriptPath() async {
    try {
      final libUri = await Isolate.resolvePackageUri(
        Uri.parse('package:youtube_explode_dart/youtube_explode_dart.dart'),
      );
      if (libUri == null) return null;
      final path = libUri
          .resolve('src/reverse_engineering/sabr/deno_sabr_download.mjs')
          .toFilePath();
      return File(path).existsSync() ? path : null;
    } on UnsupportedError {
      return null;
    }
  }

  /// Initializes a [DenoSabrDownloader].
  ///
  /// On Flutter, [scriptPath] must be provided (bundle
  /// `deno_sabr_download.mjs` as an asset and write it to a temp file first).
  static Future<DenoSabrDownloader> init({
    String? denoExe,
    String? scriptPath,
  }) async {
    final exe = denoExe ?? await resolveDenoExe();
    final script = scriptPath ?? await tryResolveBundledScriptPath();
    if (script == null) {
      throw StateError(
        'SABR Deno script not found. On Flutter, bundle '
        'deno_sabr_download.mjs as an asset and pass scriptPath to init().',
      );
    }
    if (!File(script).existsSync()) {
      throw StateError('SABR Deno script not found at $script');
    }
    return DenoSabrDownloader._(exe, script);
  }

  @override
  Stream<List<int>> download(SabrStreamInfo streamInfo) async* {
    final track = switch (streamInfo) {
      VideoStreamInfo() => 'video',
      AudioStreamInfo() => 'audio',
      _ => throw YoutubeExplodeException(
          'Unsupported SABR stream type: ${streamInfo.runtimeType}',
        ),
    };

    _logger.fine(
      'Starting SABR download for itag ${streamInfo.tag} ($track)',
    );

    final proc = await Process.start(
      _denoExe,
      [
        'run',
        '--allow-net',
        '--allow-read',
        '--allow-write=/tmp',
        _scriptPath,
      ],
      environment: Platform.environment,
    );

    final payload = jsonEncode({
      'mode': 'stream',
      'track': track,
      'itag': streamInfo.tag,
      'videoId': streamInfo.videoId.value,
      'poToken': streamInfo.sabrContext.poToken,
      'clientName': streamInfo.sabrContext.clientName,
      'clientVersion': streamInfo.sabrContext.clientVersion,
      'playerResponse': streamInfo.sabrContext.playerResponse,
    });
    proc.stdin.add(utf8.encode(payload));
    await proc.stdin.flush();
    await proc.stdin.close();

    final stderrFuture = proc.stderr.transform(utf8.decoder).join();

    yield* proc.stdout;

    final exitCode = await proc.exitCode;
    final err = (await stderrFuture).trim();
    if (exitCode != 0) {
      Map<String, dynamic>? parsed;
      for (final line in err.split('\n').reversed) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          parsed = jsonDecode(trimmed) as Map<String, dynamic>;
          break;
        } catch (_) {}
      }
      final message = parsed?['error'] as String? ?? err;
      throw YoutubeExplodeException(
        'SABR download failed for itag ${streamInfo.tag}: $message',
      );
    }
  }

  @override
  void dispose() {}
}
