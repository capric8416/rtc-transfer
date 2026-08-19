import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class TotpService {
  static const periodSeconds = 30;
  static const digits = 6;
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String generateSecret({int byteLength = 20}) {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(byteLength, (_) => random.nextInt(256)),
    );
    return _base32Encode(bytes);
  }

  static String code(String secret, {DateTime? time}) {
    final timestamp =
        (time ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final counter = timestamp ~/ periodSeconds;
    final message = Uint8List(8);
    var value = counter;
    for (var index = 7; index >= 0; index--) {
      message[index] = value & 0xff;
      value >>= 8;
    }
    final digest = Hmac(sha1, _base32Decode(secret)).convert(message).bytes;
    final offset = digest.last & 0x0f;
    final binary =
        ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);
    return (binary % 1000000).toString().padLeft(digits, '0');
  }

  static bool verify(
    String secret,
    String input, {
    DateTime? time,
    int window = 1,
  }) {
    if (!RegExp(r'^\d{6}$').hasMatch(input)) return false;
    final now = time ?? DateTime.now();
    for (var offset = -window; offset <= window; offset++) {
      final candidate = code(
        secret,
        time: now.add(Duration(seconds: offset * periodSeconds)),
      );
      var difference = 0;
      for (var index = 0; index < digits; index++) {
        difference |= candidate.codeUnitAt(index) ^ input.codeUnitAt(index);
      }
      if (difference == 0) return true;
    }
    return false;
  }

  static int secondsRemaining({DateTime? time}) {
    final seconds = (time ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return periodSeconds - (seconds % periodSeconds);
  }

  static String provisioningUriWithSecret({
    required String identifier,
    required String secret,
  }) => Uri(
    scheme: 'otpauth',
    host: 'totp',
    pathSegments: ['RTC Transfer:$identifier'],
    queryParameters: {
      'secret': secret,
      'issuer': 'RTC Transfer',
      'algorithm': 'SHA1',
      'digits': '$digits',
      'period': '$periodSeconds',
    },
  ).toString();

  static String _base32Encode(Uint8List bytes) {
    var buffer = 0;
    var bits = 0;
    final output = StringBuffer();
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        output.write(_alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) output.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return output.toString();
  }

  static Uint8List _base32Decode(String input) {
    var buffer = 0;
    var bits = 0;
    final output = <int>[];
    for (final rune in input.toUpperCase().replaceAll('=', '').runes) {
      final value = _alphabet.indexOf(String.fromCharCode(rune));
      if (value < 0) throw const FormatException('Invalid Base32 TOTP secret');
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((buffer >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(output);
  }
}
