import 'package:http_parser/http_parser.dart';

import '../../../../reverse_engineering/models/fragment.dart';
import '../../../../reverse_engineering/sabr/sabr_stream_context.dart';
import '../../../video_id.dart';
import '../../streams.dart';

/// YouTube media stream delivered via SABR (video-only).
class SabrVideoStreamInfo with StreamInfo, VideoStreamInfo, SabrStreamInfo {
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
  final String videoCodec;

  /// Video quality label, as seen on YouTube.
  @Deprecated('Use qualityLabel')
  @override
  String get videoQualityLabel => qualityLabel;

  @override
  final VideoQuality videoQuality;

  @override
  final VideoResolution videoResolution;

  @override
  final Framerate framerate;

  @override
  final List<Fragment> fragments;

  @override
  final MediaType codec;

  @override
  final String qualityLabel;

  @override
  final SabrStreamContext sabrContext;

  SabrVideoStreamInfo({
    required this.videoId,
    required this.tag,
    required this.url,
    required this.container,
    required this.size,
    required this.bitrate,
    required this.videoCodec,
    required this.qualityLabel,
    required this.videoQuality,
    required this.videoResolution,
    required this.framerate,
    required this.fragments,
    required this.codec,
    required this.sabrContext,
  });

  @override
  String toString() =>
      '[SABR] Video-only ($tag | ${videoResolution}p${framerate.framesPerSecond} | $container)';

  @override
  Map<String, dynamic> toJson() => {
        'videoId': videoId.value,
        'tag': tag,
        'url': url.toString(),
        'container': container.name,
        'size': size.totalBytes,
        'bitrate': bitrate.bitsPerSecond,
        'videoCodec': videoCodec,
        'qualityLabel': qualityLabel,
        'sabr': true,
      };
}
