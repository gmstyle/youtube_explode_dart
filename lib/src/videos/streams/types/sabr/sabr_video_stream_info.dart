import 'package:http_parser/http_parser.dart';

import '../../../../reverse_engineering/models/fragment.dart';
import '../../../video_id.dart';
import '../../mixins/stream_info.dart';
import '../../streams.dart';

/// YouTube SABR stream that contains video only.
class SabrVideoStreamInfo with StreamInfo, VideoStreamInfo, SabrStreamInfo {
  @override
  final VideoId videoId;

  @override
  final int tag;

  @override
  final Uri url;

  @override
  final StreamContainer container;

  @override
  final FileSize size;

  @override
  final Bitrate bitrate;

  @override
  final String videoCodec;

  @override
  final String qualityLabel;

  @override
  @Deprecated('Use qualityLabel')
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
  final SabrBootstrap sabrBootstrap;

  @override
  final Duration duration;

  @override
  final SabrByteRange? initRange;

  @override
  final SabrByteRange? indexRange;

  /// Creates a [SabrVideoStreamInfo].
  SabrVideoStreamInfo(
    this.videoId,
    this.tag,
    this.url,
    this.container,
    this.size,
    this.bitrate,
    this.videoCodec,
    this.qualityLabel,
    this.videoQuality,
    this.videoResolution,
    this.framerate,
    this.fragments,
    this.codec,
    this.sabrBootstrap,
    this.duration, {
    this.initRange,
    this.indexRange,
  });

  @override
  String toString() =>
      'SABR Video ($tag | ${videoResolution}p${framerate.framesPerSecond} | $container)';

  @override
  Map<String, dynamic> toJson() => {
    'videoId': videoId.value,
    'tag': tag,
    'url': url.toString(),
    'container': container.toJson(),
    'size': size.toJson(),
    'bitrate': bitrate.toJson(),
    'videoCodec': videoCodec,
    'qualityLabel': qualityLabel,
    'videoQuality': videoQuality.name,
    'videoResolution': videoResolution.toJson(),
    'framerate': framerate.toJson(),
    'codec': mediaTypeToJson(codec),
    'durationMs': duration.inMilliseconds,
  };
}
