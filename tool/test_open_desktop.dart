import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'MSRcC626prw';
  final yt = await YoutubeExplodeFactory.openDesktop();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    stdout.writeln('total: ${manifest.streams.length}');
    stdout.writeln('audioOnly: ${manifest.audioOnly.length}');
    stdout.writeln('muxed: ${manifest.muxed.length}');
    stdout.writeln('sabr: ${manifest.sabr.length}');
    final best = manifest.bestDownloadableAudio;
    stdout.writeln(
      'best: itag ${best?.tag} ${best?.container.name} (${best.runtimeType})',
    );
    if (best != null && best is! SabrStreamInfo) {
      var bytes = 0;
      await for (final chunk in yt.videos.streamsClient.get(best)) {
        bytes += chunk.length;
        if (bytes >= 512 * 1024) break;
      }
      stdout.writeln('download OK: $bytes bytes');
    }
  } finally {
    yt.close();
  }
}
