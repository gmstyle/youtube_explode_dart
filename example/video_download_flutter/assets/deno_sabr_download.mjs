// SABR downloader for youtube_explode_dart.
//
// Modes (stdin JSON):
// - mode "spike": first 512 KiB to /tmp (tool/testing)
// - mode "stream": full track bytes to stdout (library download)
//
// Stream input:
// {
//   "mode": "stream",
//   "track": "audio" | "video",
//   "itag": 251,
//   "videoId": "...",
//   "poToken": "...",
//   "clientName": 1,
//   "clientVersion": "2.20260817.01.00",
//   "playerResponse": { ... }
// }

import { SabrStream } from 'jsr:@luanrt/googlevideo/sabr-stream';
import { buildSabrFormat, EnabledTrackTypes } from 'jsr:@luanrt/googlevideo/utils';

const MAX_SPIKE_BYTES = 512 * 1024;

function readStdin() {
  return new Response(Deno.stdin.readable).text();
}

async function readLimitedBytes(readable, maxBytes) {
  const reader = readable.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (total < maxBytes) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      const slice = value.byteLength > maxBytes - total
        ? value.subarray(0, maxBytes - total)
        : value;
      chunks.push(slice);
      total += slice.byteLength;
      if (total >= maxBytes) break;
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

async function pipeReadableToStdout(readable) {
  const reader = readable.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;
      await Deno.stdout.write(value);
    }
  } finally {
    reader.releaseLock();
  }
}

function parsePlayer(input) {
  const player = input.playerResponse;
  if (!player) throw new Error('playerResponse missing');

  const streamingData = player.streamingData ?? player.streaming_data;
  const playerConfig = player.playerConfig ?? player.player_config;

  const serverAbrStreamingUrl =
    streamingData?.serverAbrStreamingUrl ?? streamingData?.server_abr_streaming_url;
  const ustreamerConfig =
    playerConfig?.mediaCommonConfig?.mediaUstreamerRequestConfig?.videoPlaybackUstreamerConfig ??
    playerConfig?.media_common_config?.media_ustreamer_request_config?.video_playback_ustreamer_config;

  const adaptiveFormats =
    streamingData?.adaptiveFormats ?? streamingData?.adaptive_formats ?? [];

  if (!serverAbrStreamingUrl) {
    throw new Error('serverAbrStreamingUrl not found in player response');
  }
  if (!ustreamerConfig) {
    throw new Error('videoPlaybackUstreamerConfig not found in player response');
  }
  if (!adaptiveFormats.length) {
    throw new Error('adaptiveFormats empty');
  }

  return { serverAbrStreamingUrl, ustreamerConfig, adaptiveFormats };
}

function formatsForTrack(formats, track) {
  return formats.filter((f) => {
    const mime = (f.mimeType ?? '').toLowerCase();
    return track === 'video' ? mime.includes('video') : mime.includes('audio');
  });
}

async function runStream(input) {
  const track = input.track === 'video' ? 'video' : 'audio';
  const itag = typeof input.itag === 'number' ? input.itag : null;

  try {
    await runStreamOnce(input, track, itag, {});
  } catch (firstError) {
    if (track === 'audio' && itag != null) {
      await runStreamOnce(input, track, null, {
        audioQuality: 'AUDIO_QUALITY_MEDIUM',
      });
      return;
    }
    throw firstError;
  }
}

async function runStreamOnce(input, track, itag, extraStartOptions) {
  const { serverAbrStreamingUrl, ustreamerConfig, adaptiveFormats } = parsePlayer(input);

  const sabrFormats = adaptiveFormats.map(buildSabrFormat);
  const formats = formatsForTrack(sabrFormats, track);
  if (!formats.length) {
    throw new Error(`No ${track} SABR formats found`);
  }

  const sabrStream = new SabrStream({
    formats: sabrFormats,
    serverAbrStreamingUrl,
    videoPlaybackUstreamerConfig: ustreamerConfig,
    poToken: input.poToken,
    clientInfo: {
      clientName: input.clientName ?? 1,
      clientVersion: input.clientVersion ?? '2.20260817.01.00',
    },
  });

  const enabledTrackTypes = track === 'video'
    ? EnabledTrackTypes.VIDEO_ONLY
    : EnabledTrackTypes.AUDIO_ONLY;

  const startOptions = { enabledTrackTypes, ...extraStartOptions };
  if (itag != null) {
    if (track === 'video') {
      startOptions.videoFormat = itag;
    } else {
      startOptions.audioFormat = itag;
    }
  }

  const { audioStream, videoStream } = await sabrStream.start(startOptions);

  const readable = track === 'video' ? videoStream : audioStream;
  if (!readable) {
    throw new Error(`No ${track} stream returned by SabrStream`);
  }

  await pipeReadableToStdout(readable);
}

async function runSpike(input) {
  const { serverAbrStreamingUrl, ustreamerConfig, adaptiveFormats } = parsePlayer(input);

  const sabrFormats = adaptiveFormats.map(buildSabrFormat);
  const audioFormats = sabrFormats.filter((f) => (f.mimeType ?? '').includes('audio'));
  if (!audioFormats.length) {
    throw new Error('No audio SABR formats found');
  }

  const sabrStream = new SabrStream({
    formats: sabrFormats,
    serverAbrStreamingUrl,
    videoPlaybackUstreamerConfig: ustreamerConfig,
    poToken: input.poToken,
    clientInfo: {
      clientName: input.clientName ?? 1,
      clientVersion: input.clientVersion ?? '2.20260817.01.00',
    },
  });

  const { audioStream, selectedFormats } = await sabrStream.start({
    enabledTrackTypes: EnabledTrackTypes.AUDIO_ONLY,
    audioQuality: 'AUDIO_QUALITY_MEDIUM',
  });

  const bytes = await readLimitedBytes(audioStream, MAX_SPIKE_BYTES);
  const outFile = `/tmp/sabr_spike_${input.videoId}_${Date.now()}.bin`;
  await Deno.writeFile(outFile, bytes);

  console.log(JSON.stringify({
    success: true,
    bytes: bytes.byteLength,
    itag: selectedFormats.audioFormat.itag,
    mimeType: selectedFormats.audioFormat.mimeType,
    serverAbrUrlPrefix: serverAbrStreamingUrl.slice(0, 120),
    adaptiveCount: adaptiveFormats.length,
    file: outFile,
  }));
}

async function main() {
  const input = JSON.parse((await readStdin()).trim());
  if (input.mode === 'stream') {
    await runStream(input);
    return;
  }
  await runSpike(input);
}

main().catch((e) => {
  console.error(JSON.stringify({ success: false, error: e?.message ?? String(e) }));
  Deno.exit(1);
});
