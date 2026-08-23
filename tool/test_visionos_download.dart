import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'MSRcC626prw';
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final stream = manifest.audioOnly.isNotEmpty
        ? manifest.audioOnly.withHighestBitrate()
        : manifest.muxed.withHighestBitrate();
    print('Downloading itag ${stream.tag} (${stream.container.name})…');
    var bytes = 0;
    await for (final chunk in yt.videos.streamsClient.get(stream)) {
      bytes += chunk.length;
      if (bytes >= 512 * 1024) break;
    }
    print('OK: $bytes bytes');
    exit(bytes >= 1024 ? 0 : 1);
  } finally {
    yt.close();
  }
}
