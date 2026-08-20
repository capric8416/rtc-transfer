import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rtc_transfer/src/services/receive_storage.dart';

void main() {
  test('creates empty directories whose names contain spaces', () async {
    final root = await Directory.systemTemp.createTemp(
      'rtc-transfer-empty-directory-',
    );
    addTearDown(() => root.delete(recursive: true));

    await ReceiveStorage.createDirectory(
      relativePath: 'New Folder/Nested Empty Folder',
      configuredDirectory: root.path,
    );

    expect(
      Directory('${root.path}/New Folder/Nested Empty Folder').existsSync(),
      isTrue,
    );
  });
}
