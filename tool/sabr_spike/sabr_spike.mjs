// SABR spike: download first audio bytes using googlevideo + PO token from Dart.
//
// Input (stdin JSON):
// {
//   "videoId": "...",
//   "poToken": "...",
//   "clientName": 1,
//   "clientVersion": "2.20260817.01.00",
//   "playerResponse": { ... raw /player JSON ... }
// }
//
// Output (stdout JSON):
// { "success": true, "bytes": N, "itag": 140, "file": "/tmp/..." }

import { SabrStream } from 'jsr:@luanrt/googlevideo/sabr-stream';
import { buildSabrFormat, EnabledTrackTypes } from 'jsr:@luanrt/googlevideo/utils';

const MAX_BYTES = 512 * 1024;

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

async function main() {
  const input = JSON.parse((await readStdin()).trim());
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

  const sabrFormats = adaptiveFormats.map(buildSabrFormat);
  const audioFormats = sabrFormats.filter((f) =>
    (f.mimeType ?? '').includes('audio')
  );
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

  const bytes = await readLimitedBytes(audioStream, MAX_BYTES);
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

main().catch((e) => {
  console.log(JSON.stringify({ success: false, error: e?.message ?? String(e) }));
  Deno.exit(1);
});
