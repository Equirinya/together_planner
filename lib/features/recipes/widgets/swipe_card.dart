import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_material_design_icons/flutter_material_design_icons.dart';

import 'package:couple_planner/features/recipes/widgets/recipe_photo.dart';
import 'package:couple_planner/features/settings/dietary_preferences.dart';
import 'package:couple_planner/features/recipes/services/swipe_session_service.dart';

/// Turns the card's drag offset into a verdict.
///
/// The offset is in **pixels**, which is the whole reason this is finally
/// reliable. The previous swiper reported each axis as a percentage of its own
/// threshold — horizontal measured against the card's width, vertical against
/// its height — so on a tall card the two numbers were on different scales and
/// a drag that looked 60° off horizontal was nearly a tie internally. Four
/// attempts to predict that resolution all disagreed with it somewhere.
///
/// In pixel space there is nothing to reconcile: 45° on screen is 45° here, and
/// it is also where [AxisDirection] puts the boundary, so the badge, the
/// direction the card flies, and the vote recorded are the same decision.
SwipeChoice? swipeChoiceForOffset(Offset offset) {
  if (offset.distance < kSwipeMinTravel) return null;
  if (offset.dy < 0 && offset.dy.abs() > offset.dx.abs()) return SwipeChoice.love;
  if (offset.dx > 0) return SwipeChoice.like;
  if (offset.dx < 0) return SwipeChoice.dislike;
  return null;
}

/// Maps the swiper's resolved direction — the authoritative one, handed over
/// when the swipe actually begins — onto a verdict. Down is unreachable: it
/// isn't an allowed direction, and there is no fourth answer anyway.
SwipeChoice? swipeChoiceForAxis(AxisDirection direction) => switch (direction) {
      AxisDirection.up => SwipeChoice.love,
      AxisDirection.right => SwipeChoice.like,
      AxisDirection.left => SwipeChoice.dislike,
      AxisDirection.down => null,
    };

/// How far the card must move, in logical pixels, before a badge appears.
const double kSwipeMinTravel = 20;

/// Pixel distance at which a swipe commits. Must match the `threshold` given to
/// the swiper, since the badge's opacity is a fraction of it.
const double kSwipeThresholdPx = 100;

/// What the deck is currently doing, published on every drag frame.
///
/// Kept as a value object behind a [ValueNotifier] so a drag repaints only the
/// badge. Driving this through `setState` rebuilt the entire deck screen —
/// scaffold, app bar, progress bar, buttons and every card — on every pointer
/// move, which is what made dragging stutter.
class SwipeDragState {
  const SwipeDragState({this.choice, this.strength = 0, this.index = -1});

  final SwipeChoice? choice;
  final double strength;

  /// Which card the drag belongs to, so background cards stay clean.
  final int index;
}

/// One card in the Swipe to Plan deck: a big photo with the name, cook time and
/// dietary tags over a scrim at the bottom.
///
/// The overlay is driven by how far the card has been dragged, so the verdict
/// is legible before you let go — the point of a swipe deck is that you can go
/// fast without second-guessing what a gesture did.
class SwipeCardView extends StatelessWidget {
  const SwipeCardView({
    super.key,
    required this.card,
    required this.index,
    required this.drag,
    this.onTap,
  });

  final SwipeCard card;

  /// This card's index in the deck, matched against [SwipeDragState.index].
  final int index;

  /// Live drag state. Only the badge listens, so the photo and text below it
  /// are laid out once and left alone for the whole gesture.
  final ValueListenable<SwipeDragState> drag;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final image = card.image;

    // Everything except the badge is fixed for the life of the card, so it is
    // rasterised once and then merely translated by the swiper. Without this
    // boundary the photo, scrim, title and chips are all repainted on every
    // frame of a drag.
    final content = RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null && image.isNotEmpty)
            RecipePhoto(storagePath: image)
          else
            Container(
              color: colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Icon(
                Icons.restaurant_menu,
                size: 72,
                color: colorScheme.onSurfaceVariant.withOpacity(0.4),
              ),
            ),
          // Scrim, so the text below stays readable over any photo.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 22,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  card.name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (card.time != null && card.time! > 0)
                      _CardChip(icon: Icons.schedule, label: '${card.time} min'),
                    if (card.usageHint != null)
                      _CardChip(icon: MdiIcons.silverwareForkKnife, label: card.usageHint!),
                    // Collapsed first: a vegan recipe is tagged vegan,
                    // vegetarian and pescatarian, and showing all three would
                    // spend the card's three chip slots saying one thing.
                    for (final d in collapseDietaryLabels(card.dietary).take(3))
                      _CardChip(icon: dietaryTagIcon(d), label: d),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      onTap: onTap,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 3,
        clipBehavior: Clip.antiAlias,
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            ValueListenableBuilder<SwipeDragState>(
              valueListenable: drag,
              builder: (context, state, _) {
                final choice = state.index == index ? state.choice : null;
                if (choice == null) return const SizedBox.shrink();
                final up = choice == SwipeChoice.love;
                final right = choice == SwipeChoice.like;
                return _VerdictOverlay(
                  color: up
                      ? colorScheme.tertiary
                      : (right ? Colors.green.shade600 : colorScheme.error),
                  icon: up
                      ? Icons.favorite
                      : (right ? Icons.check_rounded : Icons.close_rounded),
                  label: up ? 'Love it' : (right ? 'Yes' : 'No'),
                  strength: state.strength.clamp(0.3, 1.0),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CardChip extends StatelessWidget {
  const _CardChip({this.icon, required this.label});
  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

/// Colour wash plus a big glyph that fades in as the card is dragged.
class _VerdictOverlay extends StatelessWidget {
  const _VerdictOverlay({
    required this.color,
    required this.icon,
    required this.label,
    required this.strength,
  });

  final Color color;
  final IconData icon;
  final String label;
  final double strength;

  @override
  Widget build(BuildContext context) {
    // Alpha is folded into the colours rather than wrapped in an Opacity
    // widget: Opacity forces a saveLayer, and this rebuilds on every frame of
    // a drag.
    return IgnorePointer(
      child: Container(
        color: color.withOpacity(0.32 * strength),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withOpacity(strength),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: Colors.white.withOpacity(strength)),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(strength),
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
