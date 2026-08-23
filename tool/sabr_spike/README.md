# SABR spike

Validates **PO token (Dart/Deno) + SABR download (googlevideo)** end-to-end
before porting the protocol into `youtube_explode_dart`.

## Run

```bash
export PATH="$HOME/.deno/bin:$PATH"
dart run tool/test_sabr_spike.dart [VIDEO_ID]
```

Default video: `MSRcC626prw` (fails with classic HTTPS manifest).

## What it does

1. Fetches watch page + PO token via existing Deno BotGuard script
2. POST `/player` with WEB client + `serviceIntegrityDimensions.poToken`
3. Reads `streamingData.serverAbrStreamingUrl` + `adaptiveFormats`
4. Deciphers `n` on SABR URL via `DenoEJSSolver`
5. Runs `tool/sabr_spike/sabr_spike.mjs` (`jsr:@luanrt/googlevideo`)
6. Downloads first **512 KiB** of audio (itag ~251, WebM/Opus) to `/tmp/`

## Expected success output

```json
{"success":true,"bytes":524288,"itag":251,"mimeType":"audio/webm; codecs=\"opus\"","file":"/tmp/sabr_spike_....bin"}
```

Verify: `file /tmp/sabr_spike_*.bin` → `WebM`

## Next step

Port `SabrStream` flow into the library (`StreamClient` + new `SabrStreamDownloader`).
