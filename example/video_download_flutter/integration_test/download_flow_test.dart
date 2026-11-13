import 'package:download_video_flutter/download_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const testVideo = 'MSRcC626prw';

  testWidgets('download audio with PO token enabled', (tester) async {
    final result = await runExampleDownload(
      urlOrId: testVideo,
      poTokenEnabled: true,
    );

    expect(result.bytesDownloaded, greaterThanOrEqualTo(512 * 1024));
    expect(result.streamTag, greaterThan(0));
    expect(result.title, isNotEmpty);
  });

  testWidgets('download audio tier-1 only (PO disabled)', (tester) async {
    final result = await runExampleDownload(
      urlOrId: testVideo,
      poTokenEnabled: false,
    );

    expect(result.bytesDownloaded, greaterThanOrEqualTo(512 * 1024));
    expect(result.isSabr, isFalse);
  });
}
