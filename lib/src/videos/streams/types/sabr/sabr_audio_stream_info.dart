import 'package:http_parser/http_parser.dart';

import '../../../../reverse_engineering/models/fragment.dart';
import '../../../../reverse_engineering/sabr/sabr_stream_context.dart';
import '../../../video_id.dart';
import '../../mixins/audio_stream_info.dart';
import '../../mixins/sabr_stream_info.dart';
import '../../mixins/stream_info.dart';
import '../../models/audio_track.dart';
import '../../streams.dart';

/// YouTube media stream delivered via SABR (audio-only).
class SabrAudioStreamInfo with StreamInfo, AudioStreamInfo, SabrStreamInfo {
  @override
  final VideoId videoId;

  @override
  final int tag;

  /// Placeholder URL (server ABR endpoint); actual bytes come from [SabrStreamInfo].
  @override
  final Uri url;

  @override
  final StreamContainer container;

  /// Approximate size from adaptive format metadata.
  @override
  final FileSize size;

  @override
  final Bitrate bitrate;

  @override
  final String audioCodec;

  @override
  final List<Fragment> fragments;

  @override
  final MediaType codec;

  @override
  final String qualityLabel;

  @override
  final AudioTrack? audioTrack;

  @override
  final SabrStreamContext sabrContext;

  SabrAudioStreamInfo({
    required this.videoId,
    required this.tag,
    required this.url,
    required this.container,
    required this.size,
    required this.bitrate,
    required this.audioCodec,
    required this.fragments,
    required this.codec,
    required this.qualityLabel,
    required this.audioTrack,
    required this.sabrContext,
  });

  @override
  String toString() => '[SABR] Audio-only ($tag | $container)';

  @override
  Map<String, dynamic> toJson() => {
        'videoId': videoId.value,
        'tag': tag,
        'url': url.toString(),
        'container': container.name,
        'size': size.totalBytes,
        'bitrate': bitrate.bitsPerSecond,
        'audioCodec': audioCodec,
        'qualityLabel': qualityLabel,
        'sabr': true,
      };
}
