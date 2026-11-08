import 'dart:typed_data';

import 'package:app/core/errors/app_error.dart';

/// Largest avatar the app will send: the server's limit
/// (media.MaxUploadBytes in backend/internal/media/client.go, which also sets
/// the gRPC message size and image-service's body limit). Checked here so a
/// too-large pick gets a clear message without a 5 MB round trip.
const maxAvatarBytes = 5 << 20;

/// The picked image cannot be sent. [message] is written for the user.
class AvatarRejectedError extends DomainError {
  const AvatarRejectedError(super.message);
}

/// The content type UploadAvatar expects for [image], read from its first
/// bytes. Throws [AvatarRejectedError] for anything the server would refuse.
///
/// Sniffed rather than taken from the file name or the picker: iOS hands out
/// HEIC behind a .jpg-looking path, desktop pickers return whatever was
/// chosen, and the server only checks the declared type against its list.
String avatarContentType(Uint8List image) {
  if (image.length > maxAvatarBytes) {
    throw const AvatarRejectedError('That image is too large. Pick one under 5 MB.');
  }
  final type = _sniff(image);
  if (type == null) {
    throw const AvatarRejectedError('Use a PNG, JPEG or WebP image.');
  }
  return type;
}

String? _sniff(Uint8List b) {
  bool startsWith(List<int> sig, [int offset = 0]) {
    if (b.length < offset + sig.length) {
      return false;
    }
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }
  // "RIFF" <4-byte size> "WEBP"
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
