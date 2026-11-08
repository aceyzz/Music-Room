import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app/core/theme/app_theme.dart';

/// A [ChangeNotifier] managing global application state, including the active visual theme.
class AppState extends ChangeNotifier {
  /// Creates an [AppState] instance.
  AppState();

  /// Obtains the [AppState] instance from the nearest [Provider] ancestor in [context].
  ///
  /// Pass `listen: false` when calling from outside widget `build` methods,
  /// such as inside button callbacks or lifecycle handlers.
  factory AppState.of(BuildContext context, {bool listen = true}) {
    return Provider.of<AppState>(context, listen: listen);
  }

  ThemeData _theme = AppTheme.lightTheme();

  /// The active [ThemeData] applied across the application.
  ThemeData get theme => _theme;

  /// Updates the application theme to [theme] and notifies dependent widgets.
  void changeTheme(ThemeData theme) {
    _theme = theme;
    notifyListeners();
  }
}