import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'po_token_provider.dart';

/// Result of [runExampleDownload].
class DownloadResult {
  const DownloadResult({
    required this.videoId,
    required this.title,
    required this.streamTag,
    required this.container,
    required this.isSabr,
    required this.bytesDownloaded,
    required this.filePath,
  });

  final String videoId;
  final String title;
  final int streamTag;
  final String container;
  final bool isSabr;
  final int bytesDownloaded;
  final String filePath;
}

/// Core download flow shared by the UI and integration tests.
Future<DownloadResult> runExampleDownload({
  required String urlOrId,
  bool poTokenEnabled = true,
  int minBytes = 512 * 1024,
}) async {
  YoutubeExplode? yt;

  try {
    if (poTokenEnabled) {
      if (Platform.isAndroid || Platform.isIOS) {
        final provider = await WebViewPoTokenProvider.create();
        final jsSolver = await WebViewEJSSolver.create();
        yt = YoutubeExplode(
          poTokenProvider: provider,
          jsSolver: jsSolver,
        );
      } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        final poScript = await preparePoScriptFromAsset();
        final sabrScript = await prepareSabrScriptFromAsset();
        yt = await YoutubeExplodeFactory.openDesktop(
          poTokenScriptPath: poScript,
          sabrScriptPath: sabrScript,
        );
      } else {
        yt = YoutubeExplode();
      }
    } else {
      yt = YoutubeExplode();
    }

    final videoId = VideoId.fromString(urlOrId);
    final video = await yt.videos.get(videoId);
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final stream = manifest.bestDownloadableAudio;
    if (stream == null) {
      throw StateError('No downloadable audio stream in manifest.');
    }

    if (Platform.isAndroid) {
      await Permission.storage.request();
    }

    final dir =
        await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final filePath = path.join(
      dir.path,
      '${videoId.value}.${stream.container.name}',
    );
    final file = File(filePath);
    final sink = file.openWrite();

    var downloaded = 0;
    await for (final chunk in yt.videos.streamsClient.get(stream)) {
      sink.add(chunk);
      downloaded += chunk.length;
      if (downloaded >= minBytes) break;
    }
    await sink.flush();
    await sink.close();

    if (downloaded < 1024) {
      throw StateError('Download too small ($downloaded bytes).');
    }

    // MP4 / WebM magic check
    final head = await file.openRead(0, 12).fold<List<int>>(
          [],
          (prev, next) => prev.length >= 12 ? prev : [...prev, ...next],
        );
    final isWebM = head.length >= 4 &&
        head[0] == 0x1a &&
        head[1] == 0x45 &&
        head[2] == 0xdf &&
        head[3] == 0xa3;
    final isMp4 = head.length >= 8 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70;
    if (!isWebM && !isMp4) {
      throw StateError('Downloaded file is not valid media (header=$head).');
    }

    return DownloadResult(
      videoId: videoId.value,
      title: video.title,
      streamTag: stream.tag,
      container: stream.container.name,
      isSabr: stream is SabrStreamInfo,
      bytesDownloaded: downloaded,
      filePath: filePath,
    );
  } finally {
    yt?.close();
  }
}
