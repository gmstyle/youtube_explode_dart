# video_download_flutter

Example Flutter app for `youtube_explode_dart` with **PO token** and optional **SABR** support.

## Platforms

| Platform | PO token | n-sig | SABR |
|----------|----------|-------|------|
| Android / iOS | Headless WebView (`WebViewPoTokenProvider`) | WebView EJS | Not wired (tier 1 HTTPS usually enough) |
| Linux / macOS / Windows | Deno (`YoutubeExplodeFactory.openDesktop`) | Deno EJS | Deno + `@luanrt/googlevideo` if needed |

Requires **Deno** on desktop when the PO Token switch is enabled: https://deno.land

## Assets

Bundled under `assets/`:

- `po_token.html` — BotGuard / PO minting in WebView (mobile)
- `po_token_deno.mjs` — same flow via Deno (desktop)
- `deno_sabr_download.mjs` — SABR downloader for desktop

On Flutter desktop, scripts are copied from assets to a temp path because `Isolate.resolvePackageUri` is unavailable.

## Run

```bash
# Linux
flutter run -d linux

# Android
flutter run -d <device>
```

Toggle **Abilita PO Token** in the UI:

- **On**: full 2025+ stack for that platform (WebView or `openDesktop`)
- **Off**: `YoutubeExplode()` only — visionos tier 1, no Deno/WebView

## Integration tests

```bash
flutter test integration_test/download_flow_test.dart -d linux
flutter test integration_test/download_flow_test.dart -d emulator-5554
```

Shared logic lives in `lib/download_runner.dart`.

## Library usage (from this example)

```dart
// Desktop
final yt = await YoutubeExplodeFactory.openDesktop(
  poTokenScriptPath: await preparePoScriptFromAsset(),
  sabrScriptPath: await prepareSabrScriptFromAsset(),
);

// Mobile
final yt = YoutubeExplode(
  poTokenProvider: await WebViewPoTokenProvider.create(),
  jsSolver: await WebViewEJSSolver.create(),
);

final manifest = await yt.videos.streamsClient.getManifest(videoId);
final stream = manifest.bestDownloadableAudio!; // HTTPS first, SABR last
```

See the root [README](../../README.md#po-tokens-clients-and-sabr-2025) for the full client cascade.
