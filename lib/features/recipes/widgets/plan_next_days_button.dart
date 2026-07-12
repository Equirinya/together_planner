import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';

/// The "Plan next days" call-to-action shown on the carousel's trigger day.
/// Spans the full width of the day cell, flush with its edges, so it reads
/// as part of the carousel box rather than a floating card.
///
/// Stays mounted (as [visible]: false) for a moment after the trigger day
/// moves elsewhere, so it can fade out instead of just disappearing; see
/// _RecipePageState's fade-out timer around the cooking-plan listener.
class PlanNextDaysButton extends StatefulWidget {
  const PlanNextDaysButton({
    super.key,
    required this.crossAxisCount,
    required this.visible,
    required this.onTap,
  });

  final int crossAxisCount;
  final bool visible;
  final VoidCallback onTap;

  // Fixed height for the button, given directly via a SizedBox so it holds
  // a stable size instead of reflowing as the carousel's weighted widths
  // change while scrolling.
  static const double _height = 140;

  @override
  State<PlanNextDaysButton> createState() => _PlanNextDaysButtonState();
}

class _PlanNextDaysButtonState extends State<PlanNextDaysButton> {
  // False until the first frame after this instance mounts, so it fades in
  // rather than popping in at full opacity.
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    // Full content size at this crossAxisCount, used below to keep the whole
    // card (background and label alike) from shrinking as the carousel's
    // weighted widths change while scrolling — it just gets cropped instead,
    // like the recipe cards.
    final fullContentWidth = smallerdim / widget.crossAxisCount - 8;
    // Gentle, on-brand hues for the mesh: the theme's key colours pulled just
    // partway off the surface, so the card shifts subtly instead of clashing
    // with the rest of the recipe grid.
    final meshColors = [
      Color.lerp(colorScheme.surface, colorScheme.primary, 0.35)!,
      Color.lerp(colorScheme.surface, colorScheme.tertiary, 0.4)!,
      Color.lerp(colorScheme.surface, colorScheme.secondary, 0.35)!,
      Color.lerp(colorScheme.surface, colorScheme.primaryContainer, 0.75)!,
    ];

    return SizedBox(
      width: double.infinity,
      height: PlanNextDaysButton._height,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        opacity: _shown && widget.visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Fill the day cell's actual current width, but never
                  // shrink below fullContentWidth: when the cell goes
                  // narrower than that during scrolling, hold this size and
                  // let OverflowBox crop it (centered) instead.
                  final availWidth =
                      constraints.maxWidth.isFinite ? constraints.maxWidth : fullContentWidth;
                  final contentWidth =
                      fullContentWidth > availWidth ? fullContentWidth : availWidth;
                  return OverflowBox(
                    minWidth: contentWidth,
                    maxWidth: contentWidth,
                    minHeight: PlanNextDaysButton._height,
                    maxHeight: PlanNextDaysButton._height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                    // Fades in from the scrollable plan list above so the card
                    // reads as an extension of it instead of a hard-edged strip.
                    ShaderMask(
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.center,
                        colors: [Colors.transparent, Colors.white],
                      ).createShader(rect),
                      blendMode: BlendMode.dstIn,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AnimatedMeshGradient(
                            colors: meshColors,
                            options: AnimatedMeshGradientOptions(speed: 0.15),
                          ),
                          Container(color: Colors.black.withOpacity(0.1)),
                        ],
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_awesome, color: Colors.white),
                          const SizedBox(height: 4),
                          Text(
                            'Smart Meal\nPlanner',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
