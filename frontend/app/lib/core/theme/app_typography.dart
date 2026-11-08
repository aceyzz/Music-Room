import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Centralized, platform-aware, and scale-ready Material 3 TextTheme.
abstract class AppTypography {
  static const String _fontFamily = 'Roboto'; // Replace with your app's font family

  /// Generates a fully compliant Material 3 [TextTheme].
  /// Automatically adjusts base font sizes for desktop/web vs. mobile platforms.
  static TextTheme textTheme([TargetPlatform? platform]) {
    final target = platform ?? defaultTargetPlatform;
    
    // Desktop screens require higher density (smaller body text) 
    // but can accommodate larger display titles.
    final isDesktop = target == TargetPlatform.macOS ||
        target == TargetPlatform.windows ||
        target == TargetPlatform.linux;

    return TextTheme(
      // ---------------------------------------------------------------------
      // Display (Largest text on the screen, reserved for short, important text)
      // ---------------------------------------------------------------------
      displayLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 64 : 57,
        fontWeight: FontWeight.w400, // Normal
        height: 1.12,
        letterSpacing: -0.25,
      ),
      displayMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 52 : 45,
        fontWeight: FontWeight.w400,
        height: 1.16,
        letterSpacing: 0.0,
      ),
      displaySmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 40 : 36,
        fontWeight: FontWeight.w400,
        height: 1.22,
        letterSpacing: 0.0,
      ),

      // ---------------------------------------------------------------------
      // Headlines (Slightly smaller than display, used for primary page titles)
      // ---------------------------------------------------------------------
      headlineLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 36 : 32,
        fontWeight: FontWeight.w700, // Bold
        height: 1.25,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 30 : 28,
        fontWeight: FontWeight.w600, // Semi-bold
        height: 1.29,
        letterSpacing: 0.0,
      ),
      headlineSmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 26 : 24,
        fontWeight: FontWeight.w700,
        height: 1.33,
        letterSpacing: 0.0,
      ),

      // ---------------------------------------------------------------------
      // Titles (AppBars, Cards, Dialog Headers, Medium-emphasis text)
      // ---------------------------------------------------------------------
      titleLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 24 : 22,
        fontWeight: FontWeight.w600,
        height: 1.27,
        letterSpacing: 0.0,
      ),
      titleMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 17 : 16,
        fontWeight: FontWeight.w600,
        height: 1.50,
        letterSpacing: 0.15,
      ),
      titleSmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 15 : 14,
        fontWeight: FontWeight.w500, // Medium
        height: 1.43,
        letterSpacing: 0.1,
      ),

      // ---------------------------------------------------------------------
      // Body (Longer passages of text, paragraphs, list descriptions)
      // ---------------------------------------------------------------------
      bodyLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 15 : 16,
        fontWeight: FontWeight.w400,
        height: 1.50,
        letterSpacing: 0.5,
      ),
      bodyMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 13.5 : 14,
        fontWeight: FontWeight.w400,
        height: 1.43,
        letterSpacing: 0.25,
      ),
      bodySmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 11.5 : 12,
        fontWeight: FontWeight.w400,
        height: 1.33,
        letterSpacing: 0.4,
      ),

      // ---------------------------------------------------------------------
      // Labels (Buttons, Chips, Captions, Nav Bars, Overlines)
      // ---------------------------------------------------------------------
      labelLarge: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 13 : 14,
        fontWeight: FontWeight.w500,
        height: 1.43,
        letterSpacing: 0.1,
      ),
      labelMedium: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 11 : 12,
        fontWeight: FontWeight.w500,
        height: 1.33,
        letterSpacing: 0.5,
      ),
      labelSmall: TextStyle(
        fontFamily: _fontFamily,
        fontSize: isDesktop ? 10 : 11,
        fontWeight: FontWeight.w500,
        height: 1.45,
        letterSpacing: 0.5,
      ),
    );
  }
}