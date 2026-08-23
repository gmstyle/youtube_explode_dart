import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'po_token_policy.dart';
import 'po_token_provider.dart';

/// Desktop PO token provider using Deno to run BotGuard JS headlessly.
///
/// Requires [deno] on PATH or at `~/.deno/bin/deno`.
/// On Flutter, pass [scriptPath] from a bundled asset (see example app).
class DenoPoTokenProvider extends BasePoTokenProvider {
  DenoPoTokenProvider._(this._denoExe, this._scriptPath);

  final String _denoExe;
  final String _scriptPath;

  /// Resolves a Deno executable, preferring `~/.deno/bin/deno`.
  static Future<String> resolveDenoExe() async {
    final home = Platform.environment['HOME'];
    if (home != null) {
      final homeDeno = File('$home/.deno/bin/deno');
      if (homeDeno.existsSync()) return homeDeno.path;
    }

    final denoInstall = Platform.environment['DENO_INSTALL'];
    if (denoInstall != null) {
      final installed = File('$denoInstall/bin/deno');
      if (installed.existsSync()) return installed.path;
    }

    final check = await Process.run('deno', ['--version']);
    if (check.exitCode == 0) return 'deno';

    throw StateError(
      'Deno not found. Install from https://deno.land to generate PO tokens.',
    );
  }

  static Future<String?> tryResolveBundledScriptPath() async {
    try {
      final libUri = await Isolate.resolvePackageUri(
        Uri.parse('package:youtube_explode_dart/youtube_explode_dart.dart'),
      );
      if (libUri == null) return null;
      final path = libUri
          .resolve('src/reverse_engineering/po_token/po_token_deno.mjs')
          .toFilePath();
      return File(path).existsSync() ? path : null;
    } on UnsupportedError {
      return null;
    }
  }

  /// Initializes a [DenoPoTokenProvider].
  ///
  /// On Flutter, [scriptPath] must be provided (bundle `po_token_deno.mjs`).
  static Future<DenoPoTokenProvider> init({
    String? denoExe,
    String? scriptPath,
  }) async {
    final exe = denoExe ?? await resolveDenoExe();
    final script = scriptPath ?? await tryResolveBundledScriptPath();
    if (script == null) {
      throw StateError(
        'PO token Deno script not found. On Flutter, bundle '
        'po_token_deno.mjs as an asset and pass scriptPath to init().',
      );
    }
    if (!File(script).existsSync()) {
      throw StateError('PO token Deno script not found at $script');
    }
    return DenoPoTokenProvider._(exe, script);
  }

  @override
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  }) async {
    if (context.initialAttestationDataSource == null) {
      throw StateError(
        'initialAttestationData not found on watch page; cannot mint PO token',
      );
    }

    final proc = await Process.start(
      _denoExe,
      ['run', '--allow-net', '--allow-read', _scriptPath],
      environment: Platform.environment,
    );

    proc.stdin.writeln(jsonEncode({
      'videoId': videoId,
      'context': context.innertubeContext,
      'initialAttestationDataSource': context.initialAttestationDataSource,
      'ytConfig': context.ytConfig,
    }));
    await proc.stdin.close();

    final stdout = await proc.stdout.transform(utf8.decoder).join();
    final stderr = await proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode;

    Map<String, dynamic>? result;
    for (final line in stdout.split('\n').reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        result = jsonDecode(trimmed) as Map<String, dynamic>;
        break;
      } catch (_) {}
    }

    if (result == null) {
      throw StateError(
        'Deno PO token script failed (exit $exitCode): '
        '${stderr.isEmpty ? stdout : stderr}',
      );
    }

    if (result['success'] == true) {
      return result['token'] as String;
    }
    throw StateError('PO Token generation failed: ${result['error']}');
  }

  @override
  void dispose() {}
}
