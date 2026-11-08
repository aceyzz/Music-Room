import 'package:flutter/material.dart';

/// A round avatar: the picture at [url] when there is one and it loads, the
/// initials of [name] otherwise (no picture, or the server is unreachable).
class UserAvatar extends StatelessWidget {
  final String? url;
  final String name;
  final double radius;

  const UserAvatar({super.key, required this.url, required this.name, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = this.url;
    return CircleAvatar(
      radius: radius,
      backgroundColor: colorScheme.primaryContainer,
      foregroundColor: colorScheme.onPrimaryContainer,
      // Drawn over the initials; if it fails to load, the initials show.
      foregroundImage: url == null ? null : NetworkImage(url),
      onForegroundImageError: url == null ? null : (_, __) {},
      child: Text(
        _initials(name),
        style: TextStyle(fontSize: radius * 0.7, fontWeight: FontWeight.bold),
      ),
    );
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.take(2).map((w) => w.characters.first.toUpperCase()).join();
  }
}
