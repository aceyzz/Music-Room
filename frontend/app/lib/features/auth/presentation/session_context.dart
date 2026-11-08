import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';

/// Convenient access to the active authenticated session from the widget tree.
extension SessionContext on BuildContext {
  /// The currently signed-in user.
  ///
  /// Only below the routes the router keeps for signed-in users: it throws
  /// when signed out.
  AuthUser get currentUser => read<SessionStore>().currentUser!;

  /// The public ID of the currently signed-in user.
  String get currentUserId => currentUser.publicId;
}
