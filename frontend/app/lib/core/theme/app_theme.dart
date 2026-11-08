import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_typography.dart';

/// Configures light and dark [ThemeData] instances using Material 3 color schemes
/// and platform-aware typography.
abstract final class AppTheme {
  
  /// Returns the complete Light Theme for the application.
  static ThemeData lightTheme([TargetPlatform? platform]) {
    return _buildTheme(AppColors.lightScheme, platform);
  }

  /// Returns the complete Dark Theme for the application.
  static ThemeData darkTheme([TargetPlatform? platform]) {
    return _buildTheme(AppColors.darkScheme, platform);
  }

  /// Internal builder method to construct the [ThemeData] systematically.
  static ThemeData _buildTheme(ColorScheme colorScheme, TargetPlatform? platform) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      
      // Inject our platform-aware typography system
      textTheme: AppTypography.textTheme(platform),

      // -------------------------------------------------------------------
      // Global Component Themes
      // -------------------------------------------------------------------
      
      // Standardizes AppBars to match modern, flat design patterns
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0, // Prevents color shifting on scroll in M3
        centerTitle: true,
      ),

      // Global list tile styling
      listTileTheme: const ListTileThemeData(
        contentPadding: AppDimens.tilePadding,
      ),

      // Global bottom sheet styling
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        showDragHandle: true,
      ),

      // Global text field styling
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppDimens.spacingM,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusL),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusL),
          borderSide: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusL),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),

      // Global Card styling (flattens cards and adds subtle borders)
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusL),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        margin: EdgeInsets.zero,
      ),

      // Standardizes filled buttons globally
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(AppDimens.buttonHeightStandard),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusL),
          ),
        ),
      ),
    );
  }
}