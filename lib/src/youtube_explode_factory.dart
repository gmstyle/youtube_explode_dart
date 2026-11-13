import 'dart:io';

import 'reverse_engineering/challenges/ejs/deno_ejs_solver.dart';
import 'reverse_engineering/po_token/caching_po_token_provider.dart';
import 'reverse_engineering/po_token/deno_po_token_provider.dart';
import 'reverse_engineering/sabr/sabr_downloader.dart';
import 'youtube_explode_base.dart';

/// Factory helpers for [YoutubeExplode].
abstract final class YoutubeExplodeFactory {
  /// Creates a [YoutubeExplode] instance configured for desktop/server use
  /// with Deno-based PO tokens, n-sig decoding, and SABR downloads.
  ///
  /// This is the recommended entry point for Linux/macOS/Windows CLI apps and
  /// for Flutter desktop when Deno is available. It enables the full
  /// 2025+ YouTube stack:
  ///
  /// 1. [YoutubeApiClient.visionos] for direct HTTPS streams (yt-dlp tier 1)
  /// 2. WEB + PO token ([safari]) for content-bound `/player` sessions
  /// 3. SABR adaptive delivery only when tier 1 has no direct HTTPS URLs
  ///
  /// Dynamic fallbacks: [webEmbedded], [tvDowngraded] for made-for-kids / age-gated.
  /// PO tokens are LRU-cached via [CachingPoTokenProvider].
  ///
  /// Requires Deno: https://deno.land
  ///
  /// ```dart
  /// final yt = await YoutubeExplodeFactory.openDesktop();
  /// try {
  ///   final manifest = await yt.videos.streamsClient.getManifest(videoId);
  ///   final stream = manifest.bestDownloadableAudio!;
  ///   await for (final chunk in yt.videos.streamsClient.get(stream)) { ... }
  /// } finally {
  ///   yt.close();
  /// }
  /// ```
  static Future<YoutubeExplode> openDesktop({
    String? denoExe,
    String? poTokenScriptPath,
    String? sabrScriptPath,
  }) async {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      throw UnsupportedError(
        'openDesktop() is only supported on Linux, macOS, and Windows.',
      );
    }

    final exe = denoExe ?? await DenoSabrDownloader.resolveDenoExe();
    final jsSolver = await DenoEJSSolver.init(denoExe: exe);
    final poTokenInner = await DenoPoTokenProvider.init(
      denoExe: exe,
      scriptPath: poTokenScriptPath,
    );
    final poTokenProvider = CachingPoTokenProvider(poTokenInner);
    final sabrDownloader = await DenoSabrDownloader.init(
      denoExe: exe,
      scriptPath: sabrScriptPath,
    );

    return YoutubeExplode(
      jsSolver: jsSolver,
      poTokenProvider: poTokenProvider,
      sabrDownloader: sabrDownloader,
    );
  }
}
