import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';

/// The gentle, on-brand animated mesh shared by every meal-planning surface:
/// the planner tiles on the recipe page, the Smart Meal Planner's loading
/// state and the Swipe to Plan flow. Previously copy-pasted between
/// `plan_next_days_button.dart` and `meal_plan_flow.dart`'s loading state;
/// extracted so the three stay in sync (and so the planner tiles can share a
/// single animation between their two halves).
class MealPlanMesh extends StatelessWidget {
  const MealPlanMesh({super.key, this.speed = 0.15});

  final double speed;

  /// Foreground colour that reads on the mesh at the current brightness. The
  /// pale light-mode mesh can't carry white text, so this is white on the deep
  /// dark-mode mesh and an on-brand dark tone on the pale light-mode one.
  static Color foregroundOf(ColorScheme colorScheme) =>
      colorScheme.brightness == Brightness.dark ? Colors.white : colorScheme.onPrimaryContainer;

  /// The theme's key colours pulled just partway off the surface, so the mesh
  /// shifts subtly instead of clashing with the rest of the recipe grid.
  static List<Color> colorsOf(ColorScheme colorScheme) => [
        Color.lerp(colorScheme.surface, colorScheme.primary, 0.35)!,
        Color.lerp(colorScheme.surface, colorScheme.tertiary, 0.4)!,
        Color.lerp(colorScheme.surface, colorScheme.tertiaryContainer, 0.6)!,
        Color.lerp(colorScheme.surface, colorScheme.primaryContainer, 0.75)!,
      ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedMeshGradient(
          colors: colorsOf(colorScheme),
          options: AnimatedMeshGradientOptions(speed: speed),
        ),
        if (isDark) Container(color: Colors.black.withOpacity(0.1)),
      ],
    );
  }
}
