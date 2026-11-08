import 'package:flutter/material.dart';

/// Centralized color palette and Material 3 ColorSchemes for the app.
/// Declared as [abstract final] to prevent instantiation and subclassing.
abstract final class AppColors {
  // ---------------------------------------------------------------------
  // Raw Color Tokens (Light)
  // ---------------------------------------------------------------------
  static const Color _primaryLight = Color(0xFF1E6091);
  static const Color _onPrimaryLight = Color(0xFFFFFFFF);
  static const Color _primaryContainerLight = Color(0xFFD0E4FF);
  static const Color _onPrimaryContainerLight = Color(0xFF001D36);

  static const Color _secondaryLight = Color(0xFF535F70);
  static const Color _onSecondaryLight = Color(0xFFFFFFFF);
  static const Color _secondaryContainerLight = Color(0xFFD6E3F8); // Added for completeness
  static const Color _onSecondaryContainerLight = Color(0xFF101C2B); // Added for completeness

  static const Color _surfaceLight = Color(0xFFF8F9FC);
  static const Color _onSurfaceLight = Color(0xFF191C1E);
  static const Color _surfaceContainerLowLight = Color(0xFFF2F3F7);
  static const Color _outlineVariantLight = Color(0xFFC3C7CE);
  static const Color _outlineLight = Color(0xFF73777F); // Required by text fields

  // ---------------------------------------------------------------------
  // Raw Color Tokens (Dark)
  // ---------------------------------------------------------------------
  static const Color _primaryDark = Color(0xFF9ECEFF);
  static const Color _onPrimaryDark = Color(0xFF003258);
  static const Color _primaryContainerDark = Color(0xFF00497D);
  static const Color _onPrimaryContainerDark = Color(0xFFD0E4FF);

  static const Color _secondaryDark = Color(0xFFBBC7DB);
  static const Color _onSecondaryDark = Color(0xFF253140);
  static const Color _secondaryContainerDark = Color(0xFF3B4858); // Added for completeness
  static const Color _onSecondaryContainerDark = Color(0xFFD6E3F8); // Added for completeness

  static const Color _surfaceDark = Color(0xFF111315);
  static const Color _onSurfaceDark = Color(0xFFC4C6C0);
  static const Color _surfaceContainerLowDark = Color(0xFF1D2024);
  static const Color _outlineVariantDark = Color(0xFF43474E);
  static const Color _outlineDark = Color(0xFF8C9199); // Required by text fields

  // ---------------------------------------------------------------------
  // Semantic Colors (Shared or Adaptive)
  // ---------------------------------------------------------------------
  static const Color _error = Color(0xFFBA1A1A);
  static const Color _onError = Color(0xFFFFFFFF);
  static const Color _errorContainer = Color(0xFFFFDAD6);
  static const Color _onErrorContainer = Color(0xFF410002);

  static const Color _errorDark = Color(0xFFFFB4AB);
  static const Color _onErrorDark = Color(0xFF690005);
  static const Color _errorContainerDark = Color(0xFF93000A);
  static const Color _onErrorContainerDark = Color(0xFFFFDAD6);

  // ---------------------------------------------------------------------
  // Exported Color Schemes
  // ---------------------------------------------------------------------

  /// The complete Light ColorScheme for the MaterialApp theme.
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: _primaryLight,
    onPrimary: _onPrimaryLight,
    primaryContainer: _primaryContainerLight,
    onPrimaryContainer: _onPrimaryContainerLight,
    secondary: _secondaryLight,
    onSecondary: _onSecondaryLight,
    secondaryContainer: _secondaryContainerLight,
    onSecondaryContainer: _onSecondaryContainerLight,
    error: _error,
    onError: _onError,
    errorContainer: _errorContainer,
    onErrorContainer: _onErrorContainer,
    surface: _surfaceLight,
    onSurface: _onSurfaceLight,
    surfaceContainerLow: _surfaceContainerLowLight,
    outline: _outlineLight,
    outlineVariant: _outlineVariantLight,
  );

  /// The complete Dark ColorScheme for the MaterialApp theme.
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: _primaryDark,
    onPrimary: _onPrimaryDark,
    primaryContainer: _primaryContainerDark,
    onPrimaryContainer: _onPrimaryContainerDark,
    secondary: _secondaryDark,
    onSecondary: _onSecondaryDark,
    secondaryContainer: _secondaryContainerDark,
    onSecondaryContainer: _onSecondaryContainerDark,
    error: _errorDark,
    onError: _onErrorDark,
    errorContainer: _errorContainerDark,
    onErrorContainer: _onErrorContainerDark,
    surface: _surfaceDark,
    onSurface: _onSurfaceDark,
    surfaceContainerLow: _surfaceContainerLowDark,
    outline: _outlineDark,
    outlineVariant: _outlineVariantDark,
  );
}