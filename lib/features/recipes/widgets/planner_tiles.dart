import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:couple_planner/features/recipes/services/swipe_session_service.dart';
import 'package:couple_planner/features/recipes/widgets/meal_plan_mesh.dart';

/// The planning call-to-action shown on the carousel's trigger day: *Swipe to
/// Plan* above *Smart Meal Planner*.
///
/// Both halves sit on **one** [MealPlanMesh] rather than owning a gradient
/// each — two animated meshes stacked would be visually busy and would run two
/// animations where one will do. A hairline divider splits them, so the pair
/// reads as a single planner card with two doors.
///
/// Spans the full width of the day cell, flush with its edges, so it reads as
/// part of the carousel box rather than a floating card. Stays mounted (as
/// [visible]: false) for a moment after the trigger day moves elsewhere, so it
/// can fade out instead of just disappearing; see _RecipePageState's
/// cooking-plan listener.
class PlannerTiles extends StatefulWidget {
  const PlannerTiles({
    super.key,
    required this.crossAxisCount,
    required this.visible,
    required this.onTapMealPlanner,
    required this.onTapSwipe,
    this.swipeSession,
    this.uid,
    this.showSwipe = true,
    this.showMealPlanner = true,
  });

  final int crossAxisCount;
  final bool visible;
  final VoidCallback onTapMealPlanner;
  final VoidCallback onTapSwipe;

  /// The group's open swipe session, if any — drives the top tile's label and
  /// unread dot (see [_swipeState]).
  final SwipeSession? swipeSession;
  final String? uid;

  /// Either half can be hidden when its feature is switched off; the card then
  /// collapses to a single [_halfHeight] tile rather than leaving a gap.
  final bool showSwipe;
  final bool showMealPlanner;

  static const double _halfHeight = 100;

  /// Total height, so callers can reason about the day cell's growth.
  static double heightFor({bool swipe = true, bool mealPlanner = true}) =>
      (swipe ? _halfHeight : 0) + (mealPlanner ? _halfHeight : 0);

  @override
  State<PlannerTiles> createState() => _PlannerTilesState();
}

/// What the swipe half is currently inviting the user to do.
enum _SwipeTileState { start, swipe, waiting, results }

class _PlannerTilesState extends State<PlannerTiles> {
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

  _SwipeTileState get _swipeState {
    final session = widget.swipeSession;
    final uid = widget.uid;
    if (session == null || uid == null || !session.isParticipant(uid)) {
      return _SwipeTileState.start;
    }
    if (session.status == SwipeSessionStatus.ready) return _SwipeTileState.results;
    if (session.hasFinished(uid)) return _SwipeTileState.waiting;
    return _SwipeTileState.swipe;
  }

  String get _swipeLabel {
    final session = widget.swipeSession;
    switch (_swipeState) {
      case _SwipeTileState.start:
        return 'Swipe to Plan';
      case _SwipeTileState.swipe:
        // No tally here. How many others have finished is only useful once
        // you're waiting on them — while it's still your move it's noise in
        // front of the one thing you're being asked to do.
        return 'Your turn to swipe';
      case _SwipeTileState.waiting:
        final remaining = session?.remainingCount ?? 0;
        return remaining == 1 ? 'Waiting for 1 other' : 'Waiting for $remaining others';
      case _SwipeTileState.results:
        return 'Results are in';
    }
  }

  /// A dot for the two states that are actually asking something of the user.
  bool get _swipeDot =>
      _swipeState == _SwipeTileState.swipe || _swipeState == _SwipeTileState.results;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    // Full content size at this crossAxisCount, used below to keep the whole
    // card (background and labels alike) from shrinking as the carousel's
    // weighted widths change while scrolling — it just gets cropped instead,
    // like the recipe cards.
    final fullContentWidth = smallerdim / widget.crossAxisCount - 8;
    final meshForeground = MealPlanMesh.foregroundOf(colorScheme);
    final height = PlannerTiles.heightFor(
      swipe: widget.showSwipe,
      mealPlanner: widget.showMealPlanner,
    );
    if (height == 0) return const SizedBox.shrink();

    return SizedBox(
      width: double.infinity,
      height: height,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        opacity: _shown && widget.visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Fill the day cell's actual current width, but never shrink
              // below fullContentWidth: when the cell goes narrower than that
              // during scrolling, hold this size and let OverflowBox crop it
              // (centered) instead.
              final availWidth =
                  constraints.maxWidth.isFinite ? constraints.maxWidth : fullContentWidth;
              final contentWidth =
                  fullContentWidth > availWidth ? fullContentWidth : availWidth;
              return OverflowBox(
                minWidth: contentWidth,
                maxWidth: contentWidth,
                minHeight: height,
                maxHeight: height,
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
                      child: const MealPlanMesh(),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: Column(
                        children: [
                          if (widget.showSwipe)
                            _TileHalf(
                              height: PlannerTiles._halfHeight,
                              icon: MdiIcons.gestureSwipeHorizontal,
                              label: _swipeLabel,
                              foreground: meshForeground,
                              showDot: _swipeDot,
                              onTap: widget.onTapSwipe,
                            ),
                          if (widget.showSwipe && widget.showMealPlanner)
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: meshForeground.withOpacity(0.18),
                              indent: 24,
                              endIndent: 24,
                            ),
                          if (widget.showMealPlanner)
                            _TileHalf(
                              height: PlannerTiles._halfHeight -
                                  (widget.showSwipe ? 1 : 0),
                              icon: MdiIcons.chefHat,
                              label: 'Smart Meal Planner',
                              foreground: meshForeground,
                              onTap: widget.onTapMealPlanner,
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
    );
  }
}

class _TileHalf extends StatelessWidget {
  const _TileHalf({
    required this.height,
    required this.icon,
    required this.label,
    required this.foreground,
    required this.onTap,
    this.showDot = false,
  });

  final double height;
  final IconData icon;
  final String label;
  final Color foreground;
  final VoidCallback onTap;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: foreground),
                  if (showDot)
                    Positioned(
                      right: -3,
                      top: -2,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
