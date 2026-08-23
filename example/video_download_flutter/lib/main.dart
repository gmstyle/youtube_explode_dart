import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'po_token_provider.dart';

void main() {
  Logger.root.level = Level.FINER;
  Logger.root.onRecord.listen((record) {
    // Print library logs in the debug console for easier diagnosis.
    debugPrint(
        '[${record.level.name}] ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      debugPrint('error: ${record.error}');
    }
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YT Explode – PO Token Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum _Status {
  idle,
  initProvider,
  fetchInfo,
  fetchManifest,
  downloading,
  done,
  error
}

class _HomePageState extends State<HomePage> {
  final _urlController = TextEditingController(
      text: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');

  _Status _status = _Status.idle;
  String _statusMessage = '';
  double? _progress;

  // Video info
  String? _videoTitle;
  String? _videoDuration;
  String? _videoAuthor;
  String? _savedPath;
  String? _currentDownloadPath;

  // PO token state
  bool _poTokenEnabled = true;
  String? _lastPoToken;
  String? _lastError;

  YoutubeExplode? _yt;
  bool get _supportsWebViewPoToken => Platform.isAndroid || Platform.isIOS;
  bool get _usesDenoPoToken => !Platform.isAndroid && !Platform.isIOS;

  Future<void> _assertStreamReachable(StreamInfo stream) async {
    if (stream is SabrStreamInfo) return;
    final client = HttpClient();
    try {
      final request = await client.getUrl(stream.url);
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close();

      if (response.statusCode >= 400) {
        throw StateError(
          'Stream non accessibile (HTTP ${response.statusCode}) per itag ${stream.tag}.',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _validateDownloadedFile(File file, StreamInfo stream) async {
    final fileSize = await file.length();
    if (fileSize < 1024) {
      throw StateError(
          'File troppo piccolo ($fileSize bytes), download non valido.');
    }

    // Basic MP4 sanity check: "ftyp" box should be present near the start.
    if (stream.container.name.toLowerCase() == 'mp4') {
      final raf = await file.open();
      try {
        final bytes = await raf.read(32);
        final header = String.fromCharCodes(bytes);
        if (!header.contains('ftyp')) {
          throw StateError('File MP4 non valido: header ftyp non trovato.');
        }
      } finally {
        await raf.close();
      }
    }

    // Basic WebM sanity check: EBML header.
    if (stream.container.name.toLowerCase() == 'webm') {
      final raf = await file.open();
      try {
        final bytes = await raf.read(4);
        if (bytes.length < 4 ||
            bytes[0] != 0x1A ||
            bytes[1] != 0x45 ||
            bytes[2] != 0xDF ||
            bytes[3] != 0xA3) {
          throw StateError('File WebM non valido: header EBML non trovato.');
        }
      } finally {
        await raf.close();
      }
    }
  }

  Future<void> _testPlayback() async {
    final savedPath = _savedPath;
    if (savedPath == null) return;

    final exists = await File(savedPath).exists();
    if (!exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File non trovato sul dispositivo.')),
      );
      return;
    }

    final result = await OpenFilex.open(savedPath);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Impossibile aprire il file: ${result.message.isEmpty ? result.type.name : result.message}',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _yt?.close();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _status = _Status.initProvider;
      _statusMessage = 'Inizializzazione PO Token provider…';
      _progress = null;
      _videoTitle = null;
      _videoDuration = null;
      _videoAuthor = null;
      _savedPath = null;
      _lastPoToken = null;
      _lastError = null;
    });

    try {
      _yt?.close();
      _yt = null;

      if (_poTokenEnabled) {
        if (_supportsWebViewPoToken) {
          final provider = await WebViewPoTokenProvider.create();
          final jsSolver = await WebViewEJSSolver.create();
          _yt = YoutubeExplode(
            poTokenProvider: provider,
            jsSolver: jsSolver,
          );
        } else if (_usesDenoPoToken) {
          final poScript = await preparePoScriptFromAsset();
          final sabrScript = await prepareSabrScriptFromAsset();
          _yt = await YoutubeExplodeFactory.openDesktop(
            poTokenScriptPath: poScript,
            sabrScriptPath: sabrScript,
          );
        } else {
          _yt = YoutubeExplode();
        }
      } else {
        // Tier 1 only: visionos / androidVr direct HTTPS (no Deno/WebView).
        _yt = YoutubeExplode();
      }

      // Resolve video ID
      final videoId = VideoId.fromString(_urlController.text.trim());

      // Fetch video metadata
      setState(() {
        _status = _Status.fetchInfo;
        _statusMessage = 'Recupero informazioni video…';
      });

      final video = await _yt!.videos.get(videoId);
      setState(() {
        _videoTitle = video.title;
        _videoDuration = video.duration?.toString().split('.').first;
        _videoAuthor = video.author;
      });

      // Fetch stream manifest
      setState(() {
        _status = _Status.fetchManifest;
        _statusMessage = 'Recupero stream manifest…';
      });

      final manifest = await _yt!.videos.streamsClient.getManifest(videoId);

      final stream = manifest.bestDownloadableAudio;
      if (stream == null) {
        throw StateError(
          'No downloadable streams available (audioOnly, muxed and SABR are empty).',
        );
      }
      final totalBytes = stream.size.totalBytes;
      final isSabr = stream is SabrStreamInfo;

      setState(() {
        _statusMessage =
            'Stream trovato: itag ${stream.tag} – ${stream.container.name.toUpperCase()} '
            '${isSabr ? '(SABR) ' : ''}'
            '– ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB\n'
            'URL: ${stream.url.toString().substring(0, stream.url.toString().length.clamp(0, 80))}${stream.url.toString().length > 80 ? '…' : ''}';
      });

      // Request storage permission (Android)
      if (Platform.isAndroid) {
        await Permission.storage.request();
      }

      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final filePath = path.join(
        dir.path,
        '${videoId.value}.${stream.container.name}',
      );
      _currentDownloadPath = filePath;

      final file = File(filePath);
      final fileStream = file.openWrite();

      setState(() {
        _status = _Status.downloading;
        _statusMessage = 'Download in corso…';
        _progress = 0;
      });

      int downloaded = 0;
      await _assertStreamReachable(stream);
      await for (final chunk in _yt!.videos.streamsClient.get(stream)) {
        fileStream.add(chunk);
        downloaded += chunk.length;
        setState(() {
          _progress = isSabr ? null : downloaded / totalBytes;
          _statusMessage = isSabr
              ? 'Download SABR: ${(downloaded / 1024 / 1024).toStringAsFixed(1)} MB'
              : 'Download: ${(downloaded / 1024 / 1024).toStringAsFixed(1)} /'
                  ' ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB'
                  ' (${(_progress! * 100).toStringAsFixed(0)}%)';
        });
      }

      await fileStream.flush();
      await fileStream.close();
      await _validateDownloadedFile(file, stream);

      setState(() {
        _status = _Status.done;
        _savedPath = filePath;
        _statusMessage = 'Download completato!';
        _progress = 1.0;
      });
      _currentDownloadPath = null;
    } catch (e, st) {
      final filePath = _currentDownloadPath;
      if (filePath != null) {
        final maybeFile = File(filePath);
        if (await maybeFile.exists()) {
          await maybeFile.delete();
        }
      }
      _currentDownloadPath = null;
      debugPrint('Error: $e\n$st');
      setState(() {
        _status = _Status.error;
        _lastError = e.toString();
        _statusMessage = 'Errore: $e';
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRunning = _status != _Status.idle &&
        _status != _Status.done &&
        _status != _Status.error;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.colorScheme.inversePrimary,
        title: const Text('YT Explode – PO Token Test'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // PO Token toggle
            Card(
              child: SwitchListTile(
                title: const Text('Abilita PO Token (BotGuard)'),
                subtitle: Text(
                  _poTokenEnabled
                      ? (_supportsWebViewPoToken
                          ? 'WebView + cascade visionos → WEB/PO → SABR.'
                          : 'Deno (openDesktop) + cascade visionos → WEB/PO → SABR.\nRichiede `deno` installato.')
                      : 'Solo tier 1: client visionos/androidVr (HTTPS diretto, senza Deno).',
                ),
                value: _poTokenEnabled,
                onChanged: isRunning
                    ? null
                    : (v) => setState(() => _poTokenEnabled = v),
              ),
            ),
            const SizedBox(height: 12),

            // URL input
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'YouTube URL o Video ID',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              enabled: !isRunning,
            ),
            const SizedBox(height: 12),

            // Start button
            FilledButton.icon(
              onPressed: isRunning ? null : _run,
              icon: const Icon(Icons.download),
              label: Text(isRunning ? 'In corso…' : 'Scarica audio'),
            ),
            const SizedBox(height: 16),

            // Progress
            if (_progress != null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
            ] else if (isRunning) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
            ],

            // Status card
            if (_statusMessage.isNotEmpty)
              Card(
                color: _status == _Status.error
                    ? theme.colorScheme.errorContainer
                    : _status == _Status.done
                        ? Colors.green.shade50
                        : theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _status == _Status.error
                                ? Icons.error_outline
                                : _status == _Status.done
                                    ? Icons.check_circle_outline
                                    : Icons.info_outline,
                            color: _status == _Status.error
                                ? theme.colorScheme.error
                                : _status == _Status.done
                                    ? Colors.green
                                    : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _stepLabel(_status),
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _statusMessage,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),

            // Video info
            if (_videoTitle != null) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.video_library),
                  title: Text(_videoTitle!),
                  subtitle: Text('$_videoAuthor · $_videoDuration'),
                ),
              ),
            ],

            // Saved path
            if (_savedPath != null) ...[
              const SizedBox(height: 8),
              Card(
                color: Colors.green.shade50,
                child: ListTile(
                  leading: const Icon(Icons.save_alt, color: Colors.green),
                  title: const Text('File salvato in:'),
                  subtitle:
                      Text(_savedPath!, style: const TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testPlayback,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Test riproduzione file'),
              ),
            ],

            // Error detail
            if (_lastError != null && _status == _Status.error) ...[
              const SizedBox(height: 8),
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _lastError!,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _stepLabel(_Status s) {
    switch (s) {
      case _Status.idle:
        return 'In attesa';
      case _Status.initProvider:
        return 'Inizializzazione PO Token provider';
      case _Status.fetchInfo:
        return 'Recupero info video';
      case _Status.fetchManifest:
        return 'Recupero stream manifest';
      case _Status.downloading:
        return 'Download';
      case _Status.done:
        return 'Completato';
      case _Status.error:
        return 'Errore';
    }
  }
}
