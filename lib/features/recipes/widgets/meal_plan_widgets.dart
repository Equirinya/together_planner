import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Small building blocks shared by the Smart Meal Planner and Swipe to Plan
/// flows. Lifted verbatim out of `meal_plan_flow.dart`, where they were
/// private, so the swipe flow can present the same settings rows, error state
/// and blocking dialog rather than growing near-identical copies.

/// Section heading above a settings control.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

/// Rounded "− value +" row used for the day and people counts.
class StepperRow extends StatelessWidget {
  const StepperRow({
    super.key,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.footer,
  });

  final IconData icon;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Optional content rendered inside the same rounded card, below the stepper
  /// and a hairline divider. For settings that belong to the count above rather
  /// than deserving a section of their own — see the side-recipe switch on
  /// [MealPlanSettingsPage].
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final stepper = Row(
      children: [
        Icon(icon, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text('$value', style: Theme.of(context).textTheme.titleLarge)),
        IconButton.filledTonal(
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: footer == null
          ? stepper
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                stepper,
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                footer!,
              ],
            ),
    );
  }
}

/// A standalone switch in the same rounded card as [StepperRow], for a setting
/// that belongs to no count above it and so can't ride along as a `footer`.
///
/// When [notice] is set the card turns error-coloured and shows the message
/// *above* the switch. Above rather than below because the message is about a
/// consequence of the current setting, and anything below the last control on a
/// scrolling settings page can sit off-screen at the moment it matters most.
class SettingSwitchCard extends StatelessWidget {
  const SettingSwitchCard({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
    this.icon,
    this.notice,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;
  final IconData? icon;

  /// Optional warning about the setting's current state. Its presence is what
  /// puts the whole card into the error colours — a red card with no
  /// explanation would be worse than none.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final alert = notice != null;

    // Material 3 has no "muted error" role — `errorContainer` is the only error
    // surface, and at full strength it reads as a failure rather than a heads-up
    // about a setting the user chose on purpose. So the card keeps its normal
    // surface and takes a wash of `error` over it: the same family as every
    // other card on the page, tinted. Blending rather than using a translucent
    // colour keeps it opaque, so it looks the same whatever sits behind it, and
    // deriving it from the scheme means it darkens by itself in dark mode.
    final background = alert
        ? Color.alphaBlend(colorScheme.error.withValues(alpha: 0.12),
            colorScheme.surfaceContainerHighest)
        : colorScheme.surfaceContainerHighest;

    // Only the notice line is error-coloured; the switch keeps normal text
    // colours so the warning reads as one clear point rather than the whole
    // control shouting. `error` works as the accent in both brightnesses — dark
    // red on the light tint, light red on the dark one.
    final tile = SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      secondary: icon == null ? null : Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: Text(subtitle),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: alert
            ? Border.all(color: colorScheme.error.withValues(alpha: 0.35))
            : null,
      ),
      child: !alert
          ? tile
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 20, color: colorScheme.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          notice!,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colorScheme.error.withValues(alpha: 0.25),
                ),
                tile,
              ],
            ),
    );
  }
}

/// Centred error message with a retry action.
class MealPlanErrorState extends StatelessWidget {
  const MealPlanErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// Short non-dismissible wait shown while a plan is being written.
class MealPlanBlockingDialog extends StatelessWidget {
  const MealPlanBlockingDialog({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 16),
            Flexible(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

/// Small "Xh Ym" row with a clock icon.
class SheetTimeRow extends StatelessWidget {
  const SheetTimeRow({super.key, required this.minutes});
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule, size: 18, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          hours > 0 ? '${hours}h ${mins}m' : '${mins}m',
          style:
              Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Shimmer standing in for an image while it generates, filling whatever space
/// the parent gives it.
class ImageShimmer extends StatelessWidget {
  const ImageShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
}

/// A sliding-gradient shader over its child.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            cs.surfaceContainerHighest,
            cs.surfaceContainerLow,
            cs.surfaceContainerHighest,
          ],
          stops: const [0.1, 0.5, 0.9],
          transform: _SlidingGradient(_c.value),
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}

class _SlidingGradient extends GradientTransform {
  const _SlidingGradient(this.t);
  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
}
