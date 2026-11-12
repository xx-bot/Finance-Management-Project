import 'package:flutter/material.dart';

import '../models/expense.dart';

abstract final class PocketColors {
  static const canvas = Color(0xFFF6F7F3);
  static const ink = Color(0xFF203A30);
  static const muted = Color(0xFF7B8980);
  static const green = Color(0xFF28674F);
  static const lime = Color(0xFFE1EECF);
  static const line = Color(0xFFE6EAE2);
  static const peach = Color(0xFFFBE8D4);
  static const amber = Color(0xFF9C621F);
  static const red = Color(0xFFB4483B);
}

ThemeData pocketTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: PocketColors.green,
      brightness: Brightness.light, surface: Colors.white);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: PocketColors.canvas,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 36, fontWeight: FontWeight.w700, letterSpacing: -1.5, color: PocketColors.ink),
      headlineMedium: TextStyle(fontSize: 29, fontWeight: FontWeight.w700, letterSpacing: -1, color: PocketColors.ink),
      headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w600, letterSpacing: -.7, color: PocketColors.ink),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -.4, color: PocketColors.ink),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: PocketColors.ink),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: PocketColors.ink),
      bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: PocketColors.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: PocketColors.ink),
      bodySmall: TextStyle(fontSize: 12, height: 1.4, color: PocketColors.muted),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: PocketColors.canvas,
        foregroundColor: PocketColors.ink, surfaceTintColor: Colors.transparent, elevation: 0),
    dividerTheme: const DividerThemeData(color: PocketColors.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: PocketColors.ink, foregroundColor: Colors.white,
      minimumSize: const Size(48, 54),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: PocketColors.ink, minimumSize: const Size(48, 52),
      side: const BorderSide(color: PocketColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    )),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: PocketColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: PocketColors.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: PocketColors.green, width: 1.5)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: PocketColors.canvas,
        showDragHandle: true, surfaceTintColor: Colors.transparent),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: PocketColors.lime,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 11, fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
        color: states.contains(WidgetState.selected) ? PocketColors.ink : PocketColors.muted,
      )),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
        backgroundColor: PocketColors.ink, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}

extension CategoryAppearance on ExpenseCategory {
  Color get color => switch (this) {
    ExpenseCategory.groceries => const Color(0xFF789866),
    ExpenseCategory.dining => const Color(0xFFD19B70),
    ExpenseCategory.transport => const Color(0xFF82A3B6),
    ExpenseCategory.shopping => const Color(0xFFAD92BE),
    ExpenseCategory.household => const Color(0xFF8B9987),
    ExpenseCategory.health => const Color(0xFFC38686),
    ExpenseCategory.education => const Color(0xFFB1A064),
    ExpenseCategory.other => const Color(0xFFA3ABA6),
  };
  IconData get icon => switch (this) {
    ExpenseCategory.groceries => Icons.shopping_basket_outlined,
    ExpenseCategory.dining => Icons.restaurant_rounded,
    ExpenseCategory.transport => Icons.directions_car_outlined,
    ExpenseCategory.shopping => Icons.shopping_bag_outlined,
    ExpenseCategory.household => Icons.chair_outlined,
    ExpenseCategory.health => Icons.favorite_border_rounded,
    ExpenseCategory.education => Icons.auto_stories_outlined,
    ExpenseCategory.other => Icons.category_outlined,
  };
}
