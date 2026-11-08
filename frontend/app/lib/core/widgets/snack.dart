import 'package:flutter/material.dart';

/// Shows [text] in a snack bar, unless the same text is already on screen or
/// waiting its turn: a refused action tapped four times (a vote from outside
/// the venue, a playlist not yet open again) says so once, not four times in
/// a row. [error] colours it as one; [replace] closes the snack bar showing
/// instead of queueing behind it.
void showSnack(BuildContext context, String text, {bool error = false, bool replace = false}) {
  final messenger = ScaffoldMessenger.of(context);
  final shown = _shown[messenger] ??= <String>{};
  if (shown.contains(text)) {
    return;
  }
  if (replace) {
    messenger.hideCurrentSnackBar();
  }
  shown.add(text);
  messenger
      .showSnackBar(SnackBar(
        content: Text(text),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ))
      .closed
      .whenComplete(() => shown.remove(text));
}

/// The texts on screen or queued, per messenger (one for the whole app).
final _shown = Expando<Set<String>>();
