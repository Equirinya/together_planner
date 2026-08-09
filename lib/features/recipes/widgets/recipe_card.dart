import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/services/recipe_localization.dart';
import 'package:couple_planner/features/ai/ai_access.dart';

// ─── RecipeOpenContainer ──────────────────────────────────────────────────────

/// Wraps a recipe card so tapping it expands the card into the full
/// [RecipeDetailPage] with a Material container transform.
class RecipeOpenContainer extends StatelessWidget {
  const RecipeOpenContainer({
    super.key,
    required this.recipeId,
    required this.groupId,
    required this.groupDoc,
    required this.access,
    required this.initialData,
    required this.child,
    this.onTagTap,
    this.planRef,
    this.planServings,
  });

  final String recipeId;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final AiAccess access;
  final Map<String, dynamic>? initialData;
  final Widget child;
  final void Function(String tag)? onTagTap;

  /// When this card represents a cooking-plan entry (not a plain recipe), the
  /// plan document. The opened detail page then shows the plan's own serving
  /// count and scales ingredients to it, persisting serving changes back to
  /// this plan instead of the shared recipe.
  final DocumentReference<Map<String, dynamic>>? planRef;

  /// The serving count stored on [planRef], used to open the detail page scaled
  /// to the plan (may be null on older plans that predate stored servings).
  final num? planServings;

  @override
  Widget build(BuildContext context) {
    return OpenContainer(
      tappable: false,
      transitionType: ContainerTransitionType.fade,
      transitionDuration: const Duration(milliseconds: 300),
      closedElevation: 0,
      closedColor: Colors.transparent,
      openColor: Theme.of(context).scaffoldBackgroundColor,
      closedShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      closedBuilder: (_, open) => GestureDetector(onTap: open, child: child),
      openBuilder: (context, __) => _EdgeSwipeToPop(
        child: RecipeDetailPage(
          groupId: groupId,
          recipeId: recipeId,
          access: access,
          initialData: initialData,
          onTagTap: onTagTap,
          planRef: planRef,
          planServings: planServings,
        ),
      ),
    );
  }
}

// ─── _EdgeSwipeToPop ──────────────────────────────────────────────────────────

/// Restores the iOS "swipe from the left edge to go back" gesture for pages
/// opened via [OpenContainer].
///
/// A normal [MaterialPageRoute] gets this gesture for free from Cupertino's
/// page transition (see the plain `Navigator.push` calls in
/// recipe_actions.dart, and the route the Siri shortcut pushes). [OpenContainer]
/// instead pushes its own private route for the container-transform effect,
/// which overrides `buildPage` but never `buildTransitions` — so it has no
/// gesture layer at all and can only be closed with the app-bar button. That
/// gap is a long-standing limitation of the animations package
/// (flutter/flutter#71839, still an open proposal).
///
/// Rather than approximating the gesture with a plain `Navigator.pop`, this
/// drives the route itself through [PredictiveBackRoute] — the public interface
/// [TransitionRoute] implements for Android's predictive back, and which any
/// [ModalRoute] therefore supports, [OpenContainer]'s included. Those methods
/// are exactly what the framework's own back-gesture detectors call: they move
/// the route's animation controller, bracket the drag in
/// `didStartUserGesture`/`didStopUserGesture` so the navigator knows a user
/// gesture owns the transition, and commit by popping through the navigator.
///
/// The result is a real interactive dismissal: the container transform plays in
/// reverse under the finger (the page shrinking back toward the card it grew
/// out of), a short drag springs it back open instead of closing, and a flick
/// completes it — the same shape as iOS's own zoom-transition dismissal.
///
/// [ModalRoute.popGestureEnabled] gates all of this, so the gesture
/// automatically stands down when the route isn't the top one, when a
/// transition is already running, or when a pop would be vetoed — including the
/// `PopScope(canPop: !edit)` in [RecipeDetailPage], so an unsaved edit can't be
/// swiped away.
class _EdgeSwipeToPop extends StatefulWidget {
  const _EdgeSwipeToPop({required this.child});

  final Widget child;

  /// Width of the strip along the left edge that starts the gesture. Matches
  /// the width Cupertino reserves for its own back gesture, so the touch target
  /// feels the same as everywhere else in the app.
  static const double edgeWidth = 20;

  /// Fraction of the page that must be dragged for a slow release to close it.
  static const double _commitFraction = 0.5;

  /// Horizontal fling speed (px/s) that closes the page regardless of distance.
  static const double _commitVelocity = 700;

  @override
  State<_EdgeSwipeToPop> createState() => _EdgeSwipeToPopState();
}

class _EdgeSwipeToPopState extends State<_EdgeSwipeToPop> {
  /// The route being dragged. Held for the duration of one gesture so every
  /// update and the end land on the same route even if the stack changes.
  ModalRoute<dynamic>? _route;

  /// Progress of the current drag, 0 (untouched) → 1 (dragged a full width).
  double _progress = 0;

  double get _width => MediaQuery.of(context).size.width;

  void _onDragStart(DragStartDetails _) {
    final route = ModalRoute.of(context);
    // popGestureEnabled is documented as "between frames, not during build" —
    // a gesture callback is exactly that. It covers the veto/first-route/
    // mid-transition cases but not the two that handleStartBackGesture asserts
    // on, so those are checked here: the route must still be the top one, and
    // no other back gesture may already own the transition.
    if (route == null ||
        !route.popGestureEnabled ||
        !route.isCurrent ||
        route.popGestureInProgress) {
      return;
    }
    _route = route;
    _progress = 0;
    // The parameter is the route's animation value (1 = fully open), not the
    // Android-style gesture progress: the framework's own detector passes
    // `1 - event.progress` here.
    route.handleStartBackGesture(progress: 1.0);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final route = _route;
    if (route == null) return;
    _progress = (_progress + details.delta.dx / _width).clamp(0.0, 1.0);
    route.handleUpdateBackGestureProgress(progress: 1.0 - _progress);
  }

  void _onDragEnd(DragEndDetails details) {
    final route = _route;
    if (route == null) return;
    _route = null;
    final velocity = details.primaryVelocity ?? 0;
    // A fast flick closes even from a short drag; otherwise the page has to be
    // more than half dismissed. A leftward flick always cancels, so flicking
    // back re-opens even from past the distance threshold.
    final close = velocity > _EdgeSwipeToPop._commitVelocity ||
        (velocity >= 0 && _progress > _EdgeSwipeToPop._commitFraction);
    if (close) {
      route.handleCommitBackGesture();
    } else {
      route.handleCancelBackGesture();
    }
    _progress = 0;
  }

  void _onDragCancel() {
    final route = _route;
    if (route == null) return;
    _route = null;
    _progress = 0;
    route.handleCancelBackGesture();
  }

  @override
  Widget build(BuildContext context) {
    // Android drives this natively through predictive back; the gesture is only
    // missing on iOS. Read from the theme rather than dart:io so this matches
    // whatever platform the app is emulating (and keeps the web build valid).
    if (Theme.of(context).platform != TargetPlatform.iOS) return widget.child;
    return Stack(
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width: _EdgeSwipeToPop.edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // Drags are claimed eagerly so the edge strip wins the arena over
            // anything scrollable underneath it (the image carousel reaches the
            // edge on this page), matching how Cupertino's own detector works.
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
          ),
        ),
      ],
    );
  }
}

// ─── RecipeCard ───────────────────────────────────────────────────────────────

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.recipeId,
    required this.groupCollection,
    this.data,
    this.cropContent = false,
    this.crossAxisCount = 3,
    this.onMissing,
  });

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;
  final Map<String, dynamic>? data;

  /// Called when the streamed recipe document no longer exists (e.g. it was
  /// deleted while this tile was showing), so the parent can drop the tile.
  final VoidCallback? onMissing;

  /// When true, the inner content is laid out at the card's full size and
  /// cropped by the rounded frame instead of shrinking with the available
  /// width (used inside the calendar carousel).
  final bool cropContent;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    // Full inner size of the card at its unconstrained width, used to keep the
    // content at a fixed size and crop it when [cropContent] is set.
    final fullContentWidth = smallerdim / crossAxisCount - 8;
    final fullContentHeight = smallerdim / crossAxisCount * 3 / 4 - 8;
    final primaryColor = HSVColor.fromColor(Theme.of(context).colorScheme.primary);
    final primaryContainerColor =
    HSVColor.fromColor(Theme.of(context).colorScheme.primaryContainer);
    final bool isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final color = HSVColor.fromAHSV(
      1.0,
      (recipeId.hashCode % 360).toDouble(),
      primaryColor.saturation,
      primaryColor.value,
    );
    final double midValue = (primaryContainerColor.value + primaryColor.value) / 2;
    // Dark mode keeps the mid-value tonal fill with white content. Light mode
    // uses a soft, bright pastel of the same hue instead of the loud fill, with
    // dark hue-matched content (see _content) so it stays clean and readable.
    final containerColor = isDark
        ? color.withValue(midValue)
        : color.withSaturation(color.saturation * 0.35).withValue(0.95);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: smallerdim / crossAxisCount,
        minHeight: smallerdim / crossAxisCount * 3 / 4,
        minWidth: smallerdim / crossAxisCount,
      ),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            elevation: (recipeId != null && groupCollection != null) ? 2 : 0,
            borderRadius: BorderRadius.circular(16),
            color: Colors.transparent,
            shadowColor: Colors.black.withValues(alpha: 1 / 3),
            child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: (recipeId != null && groupCollection != null)
                  ? BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: containerColor.toColor(),
              )
                  : BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  width: 2,
                ),
              ),
              child: !cropContent
                  ? _content(context, color)
                  : OverflowBox(
                minWidth: fullContentWidth,
                maxWidth: fullContentWidth,
                minHeight: fullContentHeight,
                maxHeight: fullContentHeight,
                alignment: Alignment.center,
                child: _content(context, color),
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  Widget? _content(BuildContext context, HSVColor color) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    if (recipeId == null || groupCollection == null) return null;
    Widget buildContent(Map<String, dynamic> rawData) {
        final recipeData =
            localizeRecipeData(rawData, LanguageService.instance.code.value);
        final images = List<String>.from(recipeData['images'] ?? []);
        // Dark mode keeps white text over a dark scrim; light mode uses one
        // consistent dark title over a light scrim (see below) instead.
        final bool isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
        final Color titleColor =
            isDark ? Colors.white : Theme.of(context).colorScheme.onSurface;
        return LayoutBuilder(
          builder: (context, constraints) {
            final double sd =
            constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
            final dpr = MediaQuery.of(context).devicePixelRatio;
            final String title = (recipeData['name'] ?? 'Unnamed Recipe').toString();
            final TextStyle? titleStyle = Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: titleColor, height: 1.2);
            // A light scrim sized to the title itself (not the tile): the text
            // block sits on solid white with a soft fade above it, and the fade
            // is taller for a two-line title so its top line stays legible.
            Widget lightImageScrim() {
              final tp = TextPainter(
                text: TextSpan(text: title, style: titleStyle),
                maxLines: 2,
                textDirection: TextDirection.ltr,
              )..layout(maxWidth: constraints.maxWidth - 12);
              final bool twoLines = tp.computeLineMetrics().length >= 2;
              final double fade = twoLines ? 32 : 22;
              // 60% plateau behind the text, a few pixels shorter than it, then
              // a smooth fade-out above.
              final double plateau = (tp.height - 6).clamp(0.0, double.infinity);
              final double scrimHeight = plateau + fade;
              return Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  height: scrimHeight,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [Color(0x00FFFFFF), Color(0x99FFFFFF)],
                      stops: [0.0, (fade / scrimHeight).clamp(0.0, 1.0)],
                    ),
                  ),
                ),
              );
            }
            return Stack(
              children: [
                if (images.isNotEmpty) ...[
                  SizedBox.expand(
                    child: StorageImage(
                      storagePath: images.first,
                      fit: BoxFit.cover,
                      memCacheHeight:
                      (constraints.maxHeight * dpr).toInt(),
                    ),
                  ),
                  if (isDark)
                    Container(color: Colors.black26)
                  else
                    lightImageScrim(),
                ] else
                  Align(
                    alignment: const Alignment(0, -0.3),
                    child: Icon(
                      Icons.restaurant_menu,
                      size: sd / 2,
                      color: color.toColor(),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical:4, horizontal: 6),
                    child: Text(
                      title,
                      style: titleStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          },
        );
    }
    if (data != null) return buildContent(data!);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: groupCollection!.collection('recipes').doc(recipeId).snapshots(),
      builder: (context, snapshot) {
        final snap = snapshot.data;
        if (snap == null) return const SizedBox.shrink();
        final docData = snap.data();
        if (docData == null) {
          if (onMissing != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onMissing!());
          }
          return const SizedBox.shrink();
        }
        return buildContent(docData);
      },
    );
  }
}
