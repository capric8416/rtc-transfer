import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ReceiveDirectory {
  const ReceiveDirectory({required this.value, required this.label});

  final String value;
  final String label;
}

abstract class ReceiveFileWriter {
  Future<void> write(Uint8List bytes);
  Future<void> close();
  Future<void> abort();
}

class ReceiveStorage {
  static const _channel = MethodChannel('dev.rtctransfer/storage');

  static Future<ReceiveDirectory?> pickDirectory() async {
    if (!Platform.isAndroid) {
      final path = await FilePicker.platform.getDirectoryPath();
      return path == null ? null : ReceiveDirectory(value: path, label: path);
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'pickDirectory',
    );
    final uri = result?['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    return ReceiveDirectory(
      value: uri,
      label: result?['label'] as String? ?? uri,
    );
  }

  static Future<ReceiveFileWriter> openFile({
    required String transferId,
    required String relativePath,
    String? configuredDirectory,
  }) async {
    if (Platform.isAndroid &&
        configuredDirectory != null &&
        configuredDirectory.startsWith('content://')) {
      await _channel.invokeMethod<void>('openFile', {
        'transferId': transferId,
        'treeUri': configuredDirectory,
        'relativePath': relativePath,
      });
      return _AndroidReceiveFileWriter(transferId);
    }

    if (configuredDirectory != null && configuredDirectory.isNotEmpty) {
      final destination = File(p.join(configuredDirectory, relativePath));
      await destination.parent.create(recursive: true);
      return _IoReceiveFileWriter(
        await destination.open(mode: FileMode.writeOnly),
      );
    }
    final base =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final destination = File(p.join(base.path, 'RTC Transfer', relativePath));
    await destination.parent.create(recursive: true);
    return _IoReceiveFileWriter(
      await destination.open(mode: FileMode.writeOnly),
    );
  }

  static bool isAndroidSafDirectory(String? value) =>
      Platform.isAndroid && value != null && value.startsWith('content://');

  static Future<void> createDirectory({
    required String relativePath,
    String? configuredDirectory,
  }) async {
    if (Platform.isAndroid &&
        configuredDirectory != null &&
        configuredDirectory.startsWith('content://')) {
      await _channel.invokeMethod<void>('createDirectory', {
        'treeUri': configuredDirectory,
        'relativePath': relativePath,
      });
      return;
    }
    final root = await resolveReceiveDirectory(configuredDirectory);
    await Directory(p.join(root, relativePath)).create(recursive: true);
  }

  static Future<String> resolveReceiveDirectory(
    String? configuredDirectory,
  ) async {
    if (configuredDirectory != null && configuredDirectory.isNotEmpty) {
      return configuredDirectory;
    }
    final base =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(base.path, 'RTC Transfer'));
    await directory.create(recursive: true);
    return directory.path;
  }

  static Future<List<Map<String, dynamic>>> listSharedDirectory({
    required String treeUri,
    required String relativePath,
  }) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
    return (result ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  static Future<List<String>> listSharedFilesRecursive({
    required String treeUri,
    required String relativePath,
  }) async {
    final result = await _channel.invokeListMethod<String>(
      'listFilesRecursive',
      {'treeUri': treeUri, 'relativePath': relativePath},
    );
    return result ?? const [];
  }

  static Future<List<String>> listSharedDirectoriesRecursive({
    required String treeUri,
    required String relativePath,
  }) async {
    final result = await _channel.invokeListMethod<String>(
      'listDirectoriesRecursive',
      {'treeUri': treeUri, 'relativePath': relativePath},
    );
    return result ?? const [];
  }

  static Future<int> sharedPathSize({
    required String treeUri,
    required String relativePath,
  }) async {
    return await _channel.invokeMethod<int>('pathSize', {
          'treeUri': treeUri,
          'relativePath': relativePath,
        }) ??
        0;
  }

  static Future<int> openSharedFile({
    required String handle,
    required String treeUri,
    required String relativePath,
  }) async {
    final size = await _channel.invokeMethod<int>('openReadFile', {
      'handle': handle,
      'treeUri': treeUri,
      'relativePath': relativePath,
    });
    return size ?? 0;
  }

  static Future<Uint8List> readSharedFile({
    required String handle,
    required int maxBytes,
  }) async {
    return await _channel.invokeMethod<Uint8List>('readFile', {
          'handle': handle,
          'maxBytes': maxBytes,
        }) ??
        Uint8List(0);
  }

  static Future<void> closeSharedFile(String handle) =>
      _channel.invokeMethod<void>('closeReadFile', {'handle': handle});
}

class _IoReceiveFileWriter implements ReceiveFileWriter {
  _IoReceiveFileWriter(this._file);

  final RandomAccessFile _file;
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes) => _file.writeFrom(bytes);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.flush();
    await _file.close();
  }

  @override
  Future<void> abort() => close();
}

class _AndroidReceiveFileWriter implements ReceiveFileWriter {
  _AndroidReceiveFileWriter(this._transferId);

  static const _flushBytes = 256 * 1024;
  final String _transferId;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw StateError('接收文件已经关闭');
    _buffer.add(bytes);
    if (_buffer.length >= _flushBytes) await _flush();
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final bytes = _buffer.takeBytes();
    await ReceiveStorage._channel.invokeMethod<void>('writeFile', {
      'transferId': _transferId,
      'bytes': bytes,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await _flush();
    _closed = true;
    await ReceiveStorage._channel.invokeMethod<void>('closeFile', {
      'transferId': _transferId,
    });
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    _buffer.clear();
    await ReceiveStorage._channel.invokeMethod<void>('abortFile', {
      'transferId': _transferId,
    });
  }
}
