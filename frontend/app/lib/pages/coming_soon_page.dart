import 'package:flutter/material.dart';

import 'package:app/core/widgets/coming_soon.dart';

/// Stands in for a page that is not built yet, so links to it already work
/// (the routes are in globals/app_router.dart).
class ComingSoonPage extends StatelessWidget {
  final String title;
  final IconData icon;

  const ComingSoonPage({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ComingSoon(icon: icon, title: title),
    );
  }
}
