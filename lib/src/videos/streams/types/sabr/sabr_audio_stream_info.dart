import 'package:http_parser/http_parser.dart';

import '../../../../reverse_engineering/models/fragment.dart';
import '../../../video_id.dart';
import '../../mixins/stream_info.dart';
import '../../models/audio_track.dart';
import '../../streams.dart';

/// YouTube SABR stream that contains audio only.
class SabrAudioStreamInfo with StreamInfo, AudioStreamInfo, SabrStreamInfo {
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
  final String audioCodec;

  @override
  final String qualityLabel;

  @override
  final List<Fragment> fragments;

  @override
  final MediaType codec;

  @override
  final AudioTrack? audioTrack;

  @override
  final SabrBootstrap sabrBootstrap;

  @override
  final Duration duration;

  @override
  final SabrByteRange? initRange;

  @override
  final SabrByteRange? indexRange;

  /// Creates a [SabrAudioStreamInfo].
  SabrAudioStreamInfo(
    this.videoId,
    this.tag,
    this.url,
    this.container,
    this.size,
    this.bitrate,
    this.audioCodec,
    this.qualityLabel,
    this.fragments,
    this.codec,
    this.audioTrack,
    this.sabrBootstrap,
    this.duration, {
    this.initRange,
    this.indexRange,
  });

  @override
  String toString() =>
      'SABR Audio ($tag | $container | ${audioTrack?.displayName})';

  @override
  Map<String, dynamic> toJson() => {
    'videoId': videoId.value,
    'tag': tag,
    'url': url.toString(),
    'container': container.toJson(),
    'size': size.toJson(),
    'bitrate': bitrate.toJson(),
    'audioCodec': audioCodec,
    'qualityLabel': qualityLabel,
    'codec': mediaTypeToJson(codec),
    'audioTrack': audioTrack?.toJson(),
    'durationMs': duration.inMilliseconds,
  };
}
