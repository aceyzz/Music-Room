import 'package:flutter/widgets.dart';

/// Centralized dimension tokens for the app following a standard 4pt/8pt grid system.
abstract final class AppDimens {
  // ---------------------------------------------------------------------
  // Material 3 Responsive Breakpoints
  // (Compact < 600, Medium 600-839, Expanded 840+)
  // ---------------------------------------------------------------------
  static const double breakpointMobile = 600.0;
  static const double breakpointTablet = 840.0;
  static const double maxContentWidth = 1200.0; // Use with ConstrainedBox for ultra-wide monitors

  // ---------------------------------------------------------------------
  // Spacing Tokens (Paddings, Margins, and Gaps)
  // ---------------------------------------------------------------------
  static const double spacingXXS = 4.0;
  static const double spacingXS = 8.0;
  static const double spacingS = 12.0;
  static const double spacingM = 16.0; // Default safe screen padding
  static const double spacingL = 24.0;
  static const double spacingXL = 32.0;
  static const double spacingXXL = 48.0;
  static const double spacingXXXL = 64.0;

  // ---------------------------------------------------------------------
  // Border Radii
  // ---------------------------------------------------------------------
  static const double radiusS = 8.0;
  static const double radiusM = 12.0;
  static const double radiusL = 16.0;
  static const double radiusXL = 24.0; // Standard for cards, bottom sheets, or images
  static const Radius radiusCircular = Radius.circular(100.0);

  // ---------------------------------------------------------------------
  // Icon Sizes
  // ---------------------------------------------------------------------
  static const double iconS = 16.0;
  static const double iconM = 24.0; // Material Default
  static const double iconL = 32.0;
  static const double iconXL = 48.0;

  // ---------------------------------------------------------------------
  // Semantic Layout Insets & Component Sizes
  // ---------------------------------------------------------------------

  /// Standard screen edge insets (horizontal: 16, bottom: 24).
  static const EdgeInsets screenPadding =
      EdgeInsets.fromLTRB(spacingM, 0, spacingM, spacingL);

  /// Standard modal bottom sheet form insets (horizontal: 24, bottom: 24).
  static const EdgeInsets sheetPadding =
      EdgeInsets.fromLTRB(spacingL, 0, spacingL, spacingL);

  /// Standard section header insets (horizontal: 16, top: 20, bottom: 4).
  static const EdgeInsets sectionHeaderPadding =
      EdgeInsets.fromLTRB(spacingM, 20.0, spacingM, spacingXXS);

  /// Standard list tile horizontal padding (horizontal: 16).
  static const EdgeInsets tilePadding =
      EdgeInsets.symmetric(horizontal: spacingM);

  /// Standard vertical list trailing padding to clear bottom navigation.
  static const EdgeInsets listBottomPadding =
      EdgeInsets.only(bottom: spacingL);

  /// Standard settings page scroll padding (horizontal: 16, top: 8, bottom: 32).
  static const EdgeInsets settingsPagePadding =
      EdgeInsets.fromLTRB(spacingM, spacingXS, spacingM, spacingXL);

  /// Clearance height needed for lists with a floating action button (FAB).
  static const double fabClearance = 88.0;

  /// Standard vertical list trailing padding to clear a floating action button.
  static const EdgeInsets listWithFabBottomPadding =
      EdgeInsets.only(bottom: fabClearance);

  /// Standard track & cover art size (48x48).
  static const double trackCoverSize = 48.0;

  /// Standard button heights.
  static const double buttonHeightStandard = 48.0;
  static const double buttonHeightForm = 52.0;

  // ---------------------------------------------------------------------
  // Responsive Layout Helpers
  // ---------------------------------------------------------------------

  /// Calculates optimal horizontal page padding based on screen width.
  static double pagePadding(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= breakpointTablet) return spacingXXL; // 48.0
    if (width >= breakpointMobile) return spacingXL;  // 32.0
    return spacingM;                                  // 16.0
  }

  /// Returns true if the current viewport is Compact (Mobile).
  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < breakpointMobile;

  /// Returns true if the current viewport is Medium (Tablet/Small Desktop).
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= breakpointMobile && width < breakpointTablet;
  }

  /// Returns true if the current viewport is Expanded (Desktop/Web).
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= breakpointTablet;
}