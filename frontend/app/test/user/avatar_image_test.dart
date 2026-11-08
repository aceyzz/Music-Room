import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/user/data/avatar_image.dart';

Uint8List bytes(List<int> head, [int length = 64]) =>
    Uint8List(length)..setRange(0, head.length, head);

void main() {
  test('PNG, JPEG and WebP are recognised by their first bytes', () {
    expect(avatarContentType(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), 'image/png');
    expect(avatarContentType(bytes([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    expect(
      avatarContentType(bytes([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50])),
      'image/webp',
    );
  });

  test('anything else is rejected before it reaches the server', () {
    // HEIC: what an iPhone photo is when the picker does not convert it.
    final heic = bytes([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);
    expect(() => avatarContentType(heic), throwsA(isA<AvatarRejectedError>()));
    expect(() => avatarContentType(Uint8List(0)), throwsA(isA<AvatarRejectedError>()));
    // RIFF without WEBP (a WAV file).
    expect(
      () => avatarContentType(bytes([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x41, 0x56, 0x45])),
      throwsA(isA<AvatarRejectedError>()),
    );
  });

  test('an image over the server limit (5 MiB) is rejected', () {
    final big = bytes([0xFF, 0xD8, 0xFF], maxAvatarBytes + 1);
    expect(() => avatarContentType(big), throwsA(isA<AvatarRejectedError>()));
    expect(avatarContentType(bytes([0xFF, 0xD8, 0xFF], maxAvatarBytes)), 'image/jpeg');
  });
}
