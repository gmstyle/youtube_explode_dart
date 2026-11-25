import 'dart:convert';
import 'dart:typed_data';

import '../../../exceptions/youtube_explode_exception.dart';

const int _webPageLimit = 4 * 1024 * 1024;
const int _attestationLimit = 4 * 1024 * 1024;
const int _interpreterLimit = 8 * 1024 * 1024;
const int _integrityLimit = 1024 * 1024;
const int _decodedLimit = 64 * 1024;
const int _identifierLimit = 1024;
const int _jsonFieldLimit = 256;

final RegExp _ytConfigSetExp = RegExp(r'ytcfg\s*\.\s*set');
final RegExp _ytAtNExp = RegExp(r'window\s*\.\s*ytAtN');
final RegExp _ytAtRExp = RegExp(r'window\s*\.\s*ytAtR');
final RegExp _challengeKeyExp = RegExp(r'''(?:["']R["']|\bR)\s*:''');
final RegExp _eacrKeyExp = RegExp(r'''(?:["']T["']|\bT)\s*:''');
final RegExp _googleThPathExp = RegExp(r'^/js/th/[A-Za-z0-9_-]{20,256}\.js$');
const Set<String> _trustedInterpreterHosts = {
  'www.google.com',
  'www.gstatic.com',
};

/// Exception thrown when BotGuard attestation parsing or token minting fails.
class PoTokenException extends YoutubeExplodeException {
  PoTokenException(super.message);
}

/// Sensitive BotGuard page context extracted from a YouTube watch page.
class WebPageAttestationContext {
  /// JSON string `{"bgChallenge": ...}` when embedded inline, or `null` if only
  /// [eacrToken] was present (requiring `/youtubei/v1/att/get`).
  final String? challenge;

  /// `EVENT_ID` from `ytcfg.set(...)`.
  final String eventId;

  /// Optional `T` token from `window.ytAtN(..., {'T': '...'})` for `/att/get`.
  final String? eacrToken;

  /// Optional `VISITOR_DATA` extracted from `ytcfg.set(...)`.
  final String? visitorData;

  /// Optional `STS` (signatureTimestamp) extracted from `ytcfg.set(...)`.
  final String? signatureTimestamp;

  /// Optional `INNERTUBE_CLIENT_VERSION` extracted from `ytcfg.set(...)`.
  final String? clientVersion;

  /// Optional `INNERTUBE_API_KEY` extracted from `ytcfg.set(...)`.
  final String? apiKey;

  const WebPageAttestationContext({
    required this.challenge,
    required this.eventId,
    this.eacrToken,
    this.visitorData,
    this.signatureTimestamp,
    this.clientVersion,
    this.apiKey,
  });

  @override
  String toString() =>
      'WebPageAttestationContext(hasChallenge=${challenge != null}, '
      'hasEacr=${eacrToken != null}, eventIdLen=${eventId.length})';
}

/// Decoded `GenerateIT` response bytes and lifetime.
class IntegrityTokenData {
  final Uint8List tokenBytes;
  final int lifetimeSeconds;

  const IntegrityTokenData(this.tokenBytes, this.lifetimeSeconds);

  @override
  String toString() =>
      'IntegrityTokenData(bytes=${tokenBytes.length}, lifetimeSeconds=$lifetimeSeconds)';
}

/// Extracts paired BotGuard attestation data and `ytcfg` fields from [webPage].
WebPageAttestationContext? extractWebPageAttestationContext(String webPage) {
  _requireSize(webPage, _webPageLimit, 'web page');
  final cfg = _extractYtCfgMetadata(webPage);
  final eventId = cfg.eventId;
  if (eventId == null || eventId.isEmpty) return null;

  final ytAtN = _extractYtAtN(webPage);
  var challenge = ytAtN?.challenge;
  if (challenge == null) {
    final ytAtR = _extractYtAtR(webPage);
    if (ytAtR != null) {
      challenge = _validatedChallenge(ytAtR);
    }
  }
  final eacrToken = ytAtN?.eacrToken;
  if (challenge == null && (eacrToken == null || eacrToken.isEmpty)) {
    return null;
  }

  return WebPageAttestationContext(
    challenge: challenge,
    eventId: eventId,
    eacrToken: eacrToken,
    visitorData: cfg.visitorData,
    signatureTimestamp: cfg.sts,
    clientVersion: cfg.clientVersion,
    apiKey: cfg.apiKey,
  );
}

/// Extracts the trusted BotGuard interpreter JS URL from [rawAttestation].
String parseAttestationInterpreterUrl(String rawAttestation) {
  _requireSize(rawAttestation, _attestationLimit, 'attestation response');
  try {
    final root = json.decode(rawAttestation);
    if (root is! Map<String, dynamic>) {
      throw PoTokenException('Invalid BotGuard attestation response');
    }
    _requireFieldCount(root);
    final challenge = root['bgChallenge'];
    if (challenge is! Map<String, dynamic>) {
      throw PoTokenException('Attestation response has no BotGuard challenge');
    }
    _requireFieldCount(challenge);
    return _attestationInterpreterUrl(challenge);
  } on PoTokenException {
    rethrow;
  } catch (_) {
    throw PoTokenException('Invalid BotGuard attestation response');
  }
}

/// Validates that [value] points to a trusted Google BotGuard interpreter URL.
String requireTrustedAttestationInterpreterUrl(String value) {
  _requireSize(value, 2048, 'interpreter URL');
  final rawUrl = value.startsWith('//') ? 'https:$value' : value;
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      (uri.hasPort && uri.port != 443) ||
      !_trustedInterpreterHosts.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      !_isTrustedInterpreterPath(uri.host, uri.path)) {
    throw PoTokenException('BotGuard returned an untrusted interpreter URL');
  }
  return uri.toString();
}

/// Builds the JSON challenge payload passed to JS `runBotGuard(challengeData)`.
String parseAttestationChallengeData(
  String rawAttestation,
  String interpreterJavascript,
) {
  _requireSize(rawAttestation, _attestationLimit, 'attestation response');
  _requireSize(interpreterJavascript, _interpreterLimit, 'interpreter');
  try {
    final root = json.decode(rawAttestation);
    if (root is! Map<String, dynamic>) {
      throw PoTokenException('Invalid BotGuard attestation response');
    }
    _requireFieldCount(root);
    final challenge = root['bgChallenge'];
    if (challenge is! Map<String, dynamic>) {
      throw PoTokenException('Attestation response has no BotGuard challenge');
    }
    _requireFieldCount(challenge);
    final interpreterUrl = _attestationInterpreterUrl(challenge);
    final interpreterHash = challenge['interpreterHash'];
    final program = challenge['program'];
    final globalName = challenge['globalName'];
    if (interpreterHash == null || program == null || globalName == null) {
      throw PoTokenException('Challenge is missing required BotGuard fields');
    }
    return json.encode({
      'interpreterJavascript': {
        'privateDoNotAccessOrElseSafeScriptWrappedValue':
            interpreterJavascript,
        'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
            interpreterUrl,
      },
      'interpreterHash': interpreterHash,
      'program': program,
      'globalName': globalName,
    });
  } on PoTokenException {
    rethrow;
  } catch (_) {
    throw PoTokenException('Invalid BotGuard attestation response');
  }
}

/// Parses the JSON array returned by `/api/jnn/v1/GenerateIT`.
IntegrityTokenData parseIntegrityTokenData(String rawIntegrityTokenData) {
  _requireSize(rawIntegrityTokenData, _integrityLimit, 'integrity response');
  try {
    final data = json.decode(rawIntegrityTokenData);
    if (data is! List || data.length < 2 || data.length > 4) {
      throw PoTokenException('Invalid BotGuard integrity response');
    }
    final rawToken = data[0];
    final rawLifetime = data[1];
    if (rawToken is! String || rawLifetime is! num) {
      throw PoTokenException('Invalid BotGuard integrity response');
    }
    final tokenBytes = _decodeBase64Url(rawToken);
    if (tokenBytes.length > _decodedLimit) {
      throw PoTokenException('BotGuard integrity token is too large');
    }
    return IntegrityTokenData(tokenBytes, rawLifetime.toInt());
  } on PoTokenException {
    rethrow;
  } catch (_) {
    throw PoTokenException('Cannot decode BotGuard integrity response');
  }
}

/// JavaScript runtime helper injected into the anchored YouTube origin page.
const String kBotGuardRuntimeScript = r'''
(function() {
  if (globalThis.__ytBgRuntimeLoaded) return 'ok';
  globalThis.__ytBgRuntimeLoaded = true;
  globalThis.__ytBgSignalOutput = null;
  globalThis.__ytBgMinter = null;

  function loadBotGuard(globalName, program) {
    var bgVm = window[globalName];
    var vmFunctions = null;
    if (!bgVm || !bgVm.a) {
      throw new Error('BotGuard VM is unavailable for ' + globalName);
    }
    var vmLoad = bgVm.a(
      program,
      function(asyncSnapshotFunction, shutdownFunction, passEventFunction, checkCameraFunction) {
        vmFunctions = {
          asyncSnapshotFunction: asyncSnapshotFunction,
          shutdownFunction: shutdownFunction,
          passEventFunction: passEventFunction,
          checkCameraFunction: checkCameraFunction
        };
      },
      true,
      undefined,
      function() {},
      [[], []],
      undefined,
      false,
      [function() {}, function() {}, function() {}, function() {}, function() {}]
    );
    return Promise.resolve(vmLoad).then(function() {
      return new Promise(function(resolve, reject) {
        var attempts = 0;
        var interval = setInterval(function() {
          if (vmFunctions && vmFunctions.asyncSnapshotFunction) {
            clearInterval(interval);
            resolve(vmFunctions);
          } else if (++attempts >= 10000) {
            clearInterval(interval);
            reject(new Error('Timed out waiting for BotGuard snapshot'));
          }
        }, 1);
      });
    });
  }

  function takeSnapshot(vmFunctions, webPoSignalOutput) {
    return new Promise(function(resolve, reject) {
      try {
        vmFunctions.asyncSnapshotFunction(
          function(response) { resolve(response); },
          [undefined, undefined, webPoSignalOutput, undefined]
        );
      } catch (err) {
        reject(err);
      }
    });
  }

  globalThis.__ytBgRun = function(challengeData) {
    var script = challengeData.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
    if (!script) throw new Error('BotGuard interpreter is unavailable');
    new Function(script)();
    var webPoSignalOutput = [];
    globalThis.__ytBgSignalOutput = webPoSignalOutput;
    return loadBotGuard(challengeData.globalName, challengeData.program)
      .then(function(vmFunctions) { return takeSnapshot(vmFunctions, webPoSignalOutput); });
  };

  globalThis.__ytBgCreateMinter = async function(tokenByteList) {
    var sig = globalThis.__ytBgSignalOutput;
    var getMinter = sig && sig[0];
    if (typeof getMinter !== 'function') {
      throw new Error('BotGuard minter factory is unavailable');
    }
    var minter = await getMinter(new Uint8Array(tokenByteList));
    if (typeof minter !== 'function') {
      throw new Error('BotGuard minter is unavailable');
    }
    globalThis.__ytBgMinter = minter;
    return 'ok';
  };

  globalThis.__ytBgMintToken = async function(identifier) {
    var minter = globalThis.__ytBgMinter;
    if (typeof minter !== 'function') {
      throw new Error('BotGuard minter has not been initialized');
    }
    var bytes = await minter(new TextEncoder().encode(identifier));
    if (!(bytes instanceof Uint8Array)) {
      throw new Error('BotGuard returned an invalid token');
    }
    var bin = '';
    for (var i = 0; i < bytes.length; i++) {
      bin += String.fromCharCode(bytes[i]);
    }
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  return 'ok';
})();
''';

String _attestationInterpreterUrl(Map<String, dynamic> challenge) {
  final interpreterUrl = challenge['interpreterUrl'];
  if (interpreterUrl is! Map<String, dynamic>) {
    throw PoTokenException('Attestation response has no BotGuard interpreter URL');
  }
  _requireFieldCount(interpreterUrl);
  final value =
      interpreterUrl['privateDoNotAccessOrElseTrustedResourceUrlWrappedValue'];
  if (value is! String) {
    throw PoTokenException('Attestation response has no BotGuard interpreter URL');
  }
  _requireSize(value, _interpreterLimit, 'interpreter URL');
  return requireTrustedAttestationInterpreterUrl(value);
}

bool _isTrustedInterpreterPath(String host, String path) =>
    path == '/botguard.js' ||
    (host == 'www.google.com' && _googleThPathExp.hasMatch(path));

Uint8List _decodeBase64Url(String base64Str) {
  _requireSize(base64Str, _decodedLimit, 'integrity token');
  final normalized = base64Str
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('.', '=');
  final trimmed = normalized.replaceFirst(RegExp(r'=+$'), '');
  if (normalized.length % 4 == 1 || trimmed.contains('=')) {
    throw PoTokenException('Cannot decode BotGuard base64 payload');
  }
  final padded = normalized.padRight(
    normalized.length + (4 - normalized.length % 4) % 4,
    '=',
  );
  try {
    return Uint8List.fromList(base64Url.decode(padded));
  } catch (_) {
    throw PoTokenException('Cannot decode BotGuard base64 payload');
  }
}

({
  String? eventId,
  String? visitorData,
  String? sts,
  String? clientVersion,
  String? apiKey,
})
_extractYtCfgMetadata(String webPage) {
  String? eventId;
  String? visitorData;
  String? sts;
  String? clientVersion;
  String? apiKey;

  var pos = 0;
  while (pos < webPage.length) {
    final match = _ytConfigSetExp.firstMatch(webPage.substring(pos));
    if (match == null) break;
    final absEnd = pos + match.end;
    final openParen = webPage.indexOf('(', absEnd);
    if (openParen < 0) break;
    final scan = _extractJavaScriptObject(webPage, openParen + 1);
    pos = scan.end;
    final raw = scan.value;
    if (raw == null) continue;
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      _requireFieldCount(decoded);
      final eid = decoded['EVENT_ID'];
      if (eid is String &&
          eid.isNotEmpty &&
          eid.length <= _identifierLimit) {
        eventId ??= eid;
      }
      final vd = decoded['VISITOR_DATA'];
      if (vd is String && vd.isNotEmpty) {
        visitorData ??= vd;
      }
      final rawSts = decoded['STS'];
      if (rawSts != null) {
        sts ??= rawSts.toString();
      }
      final cv = decoded['INNERTUBE_CLIENT_VERSION'];
      if (cv is String && cv.isNotEmpty) {
        clientVersion ??= cv;
      }
      final key = decoded['INNERTUBE_API_KEY'];
      if (key is String && key.isNotEmpty) {
        apiKey ??= key;
      }
    } catch (_) {
      continue;
    }
  }
  return (
    eventId: eventId,
    visitorData: visitorData,
    sts: sts,
    clientVersion: clientVersion,
    apiKey: apiKey,
  );
}

({String? challenge, String? eacrToken})? _extractYtAtN(String webPage) {
  var pos = 0;
  while (pos < webPage.length) {
    final match = _ytAtNExp.firstMatch(webPage.substring(pos));
    if (match == null) break;
    final absEnd = pos + match.end;
    final scan = _extractYtAtNCall(webPage, absEnd);
    pos = scan.end;
    if (scan.challenge != null || scan.eacrToken != null) {
      final validated = scan.challenge != null
          ? _validatedChallenge(scan.challenge!)
          : null;
      if (validated != null || scan.eacrToken != null) {
        return (challenge: validated, eacrToken: scan.eacrToken);
      }
    }
  }
  return null;
}

({String? challenge, String? eacrToken, int end}) _extractYtAtNCall(
  String webPage,
  int callEnd,
) {
  final openParen = webPage.indexOf('(', callEnd);
  if (openParen < 0) {
    return (challenge: null, eacrToken: null, end: webPage.length);
  }
  var pos = openParen + 1;
  String? quote;
  var escaped = false;
  while (pos < webPage.length) {
    final ch = webPage[pos];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == quote) {
        quote = null;
      }
    } else {
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '{') {
        break;
      } else if (ch == ')') {
        return (challenge: null, eacrToken: null, end: pos + 1);
      }
    }
    pos++;
  }
  if (pos >= webPage.length) {
    return (challenge: null, eacrToken: null, end: webPage.length);
  }
  final scan = _extractJavaScriptObject(webPage, pos);
  final wrapper = scan.value;
  if (wrapper == null) {
    return (challenge: null, eacrToken: null, end: scan.end);
  }
  return (
    challenge: _extractFieldValue(wrapper, _challengeKeyExp),
    eacrToken: _extractFieldString(wrapper, _eacrKeyExp),
    end: scan.end,
  );
}

String? _extractFieldValue(String wrapper, RegExp keyExp) {
  final match = keyExp.firstMatch(wrapper);
  if (match == null) return null;
  var pos = match.end;
  while (pos < wrapper.length && _isWhitespace(wrapper.codeUnitAt(pos))) {
    pos++;
  }
  if (pos >= wrapper.length) return null;
  final ch = wrapper[pos];
  if (ch == "'" || ch == '"') return _decodeJavaScriptString(wrapper, pos);
  if (ch == '{') return _extractJavaScriptObject(wrapper, pos).value;
  return null;
}

String? _extractFieldString(String wrapper, RegExp keyExp) {
  final match = keyExp.firstMatch(wrapper);
  if (match == null) return null;
  var pos = match.end;
  while (pos < wrapper.length && _isWhitespace(wrapper.codeUnitAt(pos))) {
    pos++;
  }
  if (pos >= wrapper.length) return null;
  final ch = wrapper[pos];
  if (ch == "'" || ch == '"') return _decodeJavaScriptString(wrapper, pos);
  return null;
}

String? _extractYtAtR(String webPage) {
  final match = _ytAtRExp.firstMatch(webPage);
  if (match == null) return null;
  final equals = webPage.indexOf('=', match.end);
  if (equals < 0) return null;
  var pos = equals + 1;
  while (pos < webPage.length && _isWhitespace(webPage.codeUnitAt(pos))) {
    pos++;
  }
  return _decodeJavaScriptString(webPage, pos);
}

String? _validatedChallenge(String rawChallengeData) {
  try {
    final root = json.decode(rawChallengeData);
    if (root is! Map<String, dynamic>) return null;
    _requireFieldCount(root);
    final bgChallenge = root['bgChallenge'];
    if (bgChallenge == null) return null;
    return json.encode({'bgChallenge': bgChallenge});
  } catch (_) {
    return null;
  }
}

({String? value, int end}) _extractJavaScriptObject(String source, int start) {
  var pos = start;
  while (pos < source.length && _isWhitespace(source.codeUnitAt(pos))) {
    pos++;
  }
  if (pos >= source.length || source[pos] != '{') {
    return (value: null, end: pos);
  }
  final objectStart = pos;
  var depth = 0;
  String? quote;
  var escaped = false;
  while (pos < source.length) {
    final ch = source[pos++];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return (value: source.substring(objectStart, pos), end: pos);
      }
    }
  }
  return (value: null, end: source.length);
}

String? _decodeJavaScriptString(String source, int start) {
  var pos = start;
  if (pos >= source.length || (source[pos] != "'" && source[pos] != '"')) {
    return null;
  }
  final quote = source[pos++];
  final out = StringBuffer();
  while (pos < source.length) {
    final ch = source[pos++];
    if (ch == quote) return out.toString();
    if (ch != r'\') {
      out.write(ch);
      continue;
    }
    if (pos >= source.length) return null;
    final esc = source[pos++];
    switch (esc) {
      case "'":
      case '"':
      case r'\':
      case '/':
        out.write(esc);
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 't':
        out.write('\t');
      case 'u':
      case 'x':
        final digits = esc == 'u' ? 4 : 2;
        if (pos + digits > source.length) return null;
        final cp = int.tryParse(
          source.substring(pos, pos + digits),
          radix: 16,
        );
        if (cp == null) return null;
        out.writeCharCode(cp);
        pos += digits;
      case '\n':
        continue;
      default:
        out.write(esc);
    }
  }
  return null;
}

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

void _requireSize(String value, int limit, String name) {
  if (value.length > limit) {
    throw PoTokenException('$name exceeds its size limit');
  }
}

void _requireFieldCount(Map<String, dynamic> obj) {
  if (obj.length > _jsonFieldLimit) {
    throw PoTokenException('JSON object has too many fields');
  }
}
