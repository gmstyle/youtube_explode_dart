import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'MSRcC626prw';
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    print('Total: ${manifest.streams.length}');
    print('audioOnly: ${manifest.audioOnly.length}');
    print('muxed: ${manifest.muxed.length}');
    print('videoOnly: ${manifest.videoOnly.length}');
    print('sabr: ${manifest.sabr.length}');
    if (manifest.audioOnly.isNotEmpty) {
      final s = manifest.audioOnly.withHighestBitrate();
      print('Best audio: itag ${s.tag} ${s.container.name}');
    }
    if (manifest.muxed.isNotEmpty) {
      final s = manifest.muxed.withHighestBitrate();
      print(
          'Best muxed: itag ${s.tag} ${s.container.name} url=${s.url.host.isNotEmpty}');
    }
  } finally {
    yt.close();
  }
}
