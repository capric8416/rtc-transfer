import 'package:flutter_test/flutter_test.dart';
import 'package:rtc_transfer/src/models/file_entry.dart';
import 'package:rtc_transfer/src/models/transfer_task.dart';
import 'package:rtc_transfer/src/services/app_settings.dart';
import 'package:rtc_transfer/src/services/totp_service.dart';
import 'package:rtc_transfer/src/utils/formatters.dart';

void main() {
  test('generated identifiers and TOTP secrets have valid alphabets', () {
    expect(
      AppSettings.randomIdentifier(),
      matches(RegExp(r'^[A-Za-z0-9]{16}$')),
    );
    expect(TotpService.generateSecret(), matches(RegExp(r'^[A-Z2-7]{32}$')));
  });

  test('TOTP matches the RFC 6238 SHA1 test secret at 59 seconds', () {
    const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    final time = DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true);
    expect(TotpService.code(secret, time: time), '287082');
    expect(TotpService.verify(secret, '287082', time: time), isTrue);
  });

  test('file entry survives JSON round trip', () {
    const entry = FileEntry(
      name: 'video.mp4',
      relativePath: 'media/video.mp4',
      isDirectory: false,
      size: 4096,
      modifiedMillis: 123,
    );
    final decoded = FileEntry.fromJson(entry.toJson());
    expect(decoded.name, entry.name);
    expect(decoded.relativePath, entry.relativePath);
    expect(decoded.size, entry.size);
  });

  test('transfer progress and byte formatter are bounded', () {
    final task = TransferTask(
      id: '1',
      name: 'archive.zip',
      totalBytes: 1024,
      direction: TransferDirection.sending,
    )..transferredBytes = 512;
    expect(task.progress, .5);
    expect(formatBytes(1536), '1.50 KB');
  });
}
