import 'dart:convert';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/botguard/web_page_attestation.dart';

void main() {
  group('WebPageAttestation', () {
    test('extracts ytAtN challenge, eacrToken, and ytcfg metadata', () {
      const challengeObj = {
        'bgChallenge': {
          'interpreterUrl': {
            'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
                'https://www.google.com/js/th/AbCdEfGhIjKlMnOpQrStUvWxYz123456.js',
          },
          'interpreterHash': 'hash123',
          'program': 'prog-abc',
          'globalName': 'trayride',
        },
      };
      final html = '''
<!doctype html><html><head><script>
ytcfg.set({"EVENT_ID":"ev-123","VISITOR_DATA":"vd-999","STS":20800,"INNERTUBE_CLIENT_VERSION":"2.20260708.00.00"});
window.ytAtN(window.ytAtC, {'R': ${jsonEncode(jsonEncode(challengeObj))}, 'T': 'eacr-tok'});
</script></head><body></body></html>
''';

      final ctx = extractWebPageAttestationContext(html);
      expect(ctx, isNotNull);
      expect(ctx!.eventId, 'ev-123');
      expect(ctx.visitorData, 'vd-999');
      expect(ctx.signatureTimestamp, '20800');
      expect(ctx.eacrToken, 'eacr-tok');

      final interpUrl = parseAttestationInterpreterUrl(ctx.challenge!);
      expect(
        interpUrl,
        'https://www.google.com/js/th/AbCdEfGhIjKlMnOpQrStUvWxYz123456.js',
      );

      final dataJson = parseAttestationChallengeData(
        ctx.challenge!,
        'console.log(1);',
      );
      final decoded = jsonDecode(dataJson) as Map<String, dynamic>;
      expect(decoded['globalName'], 'trayride');
      expect(decoded['program'], 'prog-abc');
    });

    test('rejects untrusted interpreter URLs', () {
      expect(
        () => requireTrustedAttestationInterpreterUrl(
          'https://evil.example.com/botguard.js',
        ),
        throwsA(isA<PoTokenException>()),
      );
      expect(
        () => requireTrustedAttestationInterpreterUrl(
          'http://www.gstatic.com/botguard.js',
        ),
        throwsA(isA<PoTokenException>()),
      );
    });

    test('parses GenerateIT integrity response', () {
      final b64 = base64Url.encode([10, 20, 30, 40]);
      final data = parseIntegrityTokenData(jsonEncode([b64, 21600]));
      expect(data.tokenBytes, orderedEquals([10, 20, 30, 40]));
      expect(data.lifetimeSeconds, 21600);
    });
  });
}
