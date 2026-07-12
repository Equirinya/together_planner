import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/recipes/pages/shared_recipes_page.dart';
import 'package:couple_planner/features/ai/ai_access.dart';

/// Shown as a full-bleed overlay behind the search bar once the recipes
/// stream has confirmed the group has no recipes and the user isn't
/// searching. Points at the two entry points that already live on the recipe
/// page (the Smart Meal Planner tile above and the + button below) with long
/// hand-drawn-style arrows rather than duplicating them as buttons, and only
/// adds a (deliberately understated) button for copying from another group,
/// since that has no other entry point here.
///
/// The message itself is one centered column — the meal-planner hint above
/// it, the + hint below it — with the two hints' and the + button's actual
/// on-screen positions (measured after layout) driving where the arrows start
/// and end, rather than guessed fractions of the screen. This is rendered
/// outside the recipe grid's CustomScrollView (as a Positioned.fill sibling)
/// so it shares the exact same coordinate space as the search bar and
/// + button.
///
/// [topInset] keeps the message clear of the suggested-recipes row when
/// that's showing above it. [plusButtonKey] is the recipe page's own + button,
/// used as the down-arrow's target.
class EmptyRecipesState extends StatefulWidget {
  const EmptyRecipesState({
    super.key,
    required this.access,
    required this.groupId,
    required this.topInset,
    required this.plusButtonKey,
  });

  final AiAccess access;
  final String groupId;
  final double topInset;
  final GlobalKey plusButtonKey;

  @override
  State<EmptyRecipesState> createState() => _EmptyRecipesStateState();
}

class _EmptyRecipesStateState extends State<EmptyRecipesState> {
  // The empty state's arrows are drawn to the real, measured positions of the
  // hint texts and the + button (rather than guessed fractions of the screen)
  // so they land accurately regardless of device size or which hints show.
  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _mealPlannerHintKey = GlobalKey();
  final GlobalKey _plusHintKey = GlobalKey();
  Offset? _mealPlannerHintAnchor;
  Offset? _plusHintAnchor;
  Offset? _plusButtonAnchor;

  /// Re-measures the hint/button anchors (in [_rootKey]'s local coordinate
  /// space, which the arrow CustomPaint shares) after the next frame, and
  /// repaints the arrows if anything moved.
  void _scheduleMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rootBox = _rootKey.currentContext?.findRenderObject() as RenderBox?;
      if (rootBox == null || !rootBox.attached) return;

      Offset? anchorOf(GlobalKey key, Alignment alignment) {
        final box = key.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) return null;
        final local = alignment.withinRect(Offset.zero & box.size);
        return rootBox.globalToLocal(box.localToGlobal(local));
      }

      final meal = widget.access.canUseMealPlanner ? anchorOf(_mealPlannerHintKey, Alignment.topLeft) : null;
      final plus = anchorOf(_plusHintKey, Alignment.centerRight);
      final button = anchorOf(widget.plusButtonKey, Alignment.topCenter);

      if (meal == _mealPlannerHintAnchor &&
          plus == _plusHintAnchor &&
          button == _plusButtonAnchor) {
        return;
      }
      setState(() {
        _mealPlannerHintAnchor = meal;
        _plusHintAnchor = plus;
        _plusButtonAnchor = button;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasurement();
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hintColor = colorScheme.outline.withOpacity(0.85);
    final hintStyle = textTheme.bodyMedium?.copyWith(
      color: hintColor,
      fontStyle: FontStyle.italic,
    );
    final uid = FirebaseAuth.instance.currentUser?.uid;
    // Reserve space at the bottom for the search bar/+ button row so the
    // message and arrow never sit underneath it.
    const bottomReserved = 76.0;
    // Uniform vertical rhythm for the message: one gap between sections, a
    // tighter one between a line and its directly-related caption below it.
    const sectionGap = 8.0;
    const captionGap = 4.0;
    // First appearing hint reads as a full sentence opener; the ones after
    // it read as continuations, so only it is capitalized, only the very
    // last one ends with a period, and "or" introduces only that last one.
    final plusHintText = widget.access.canUseMealPlanner
        ? 'tap + for your own'
        : 'Tap + to add your own recipe';

    return Stack(
      key: _rootKey,
      children: [
        Positioned.fill(
          // Purely decorative — and, spanning the whole body (including the
          // suggested-recipes row up top, which isn't clipped to topInset
          // like the message below), it would otherwise sit on top of and
          // swallow drags meant for that row.
          child: IgnorePointer(
            child: CustomPaint(
              painter: _EmptyStateArrowPainter(
                color: colorScheme.primary.withOpacity(0.6),
                mealPlannerAnchor: _mealPlannerHintAnchor,
                plusHintAnchor: _plusHintAnchor,
                plusButtonAnchor: _plusButtonAnchor,
              ),
            ),
          ),
        ),
        Positioned(
          top: widget.topInset,
          bottom: bottomReserved,
          left: 0,
          right: 0,
          // Scrollable so the message can never get clipped at the bottom
          // on shorter screens instead of just overflowing silently.
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined, size: 48, color: colorScheme.outline),
                  const SizedBox(height: sectionGap),
                  Text('Looks so empty here!', style: textTheme.titleLarge),
                  const SizedBox(height: captionGap),
                  Text(
                    'This group has no recipes yet.',
                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
                    textAlign: TextAlign.center,
                  ),
                  if (widget.access.canUseMealPlanner) ...[
                    const SizedBox(height: sectionGap),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        key: _mealPlannerHintKey,
                        'Try the Smart Meal Planner above',
                        style: hintStyle,
                      ),
                    ),
                  ],
                  if (uid != null)
                    FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .collection('groups')
                          .get(),
                      builder: (context, snapshot) {
                        final otherGroupIds = (snapshot.data?.docs ?? const [])
                            .map((d) => d.id)
                            .where((id) => id != widget.groupId)
                            .toList();
                        if (otherGroupIds.isEmpty) return const SizedBox.shrink();
                        // An outlined button so it reads clearly as tappable,
                        // set in the same hint text style as the rest of the
                        // message so it doesn't look like a mismatched import.
                        // Capitalized only when it's the first hint on screen
                        // (i.e. the Smart Meal Planner hint above it isn't
                        // showing); otherwise it reads as a continuation.
                        return Padding(
                          padding: const EdgeInsets.only(top: sectionGap),
                          child: OutlinedButton(
                            onPressed: () => _openCopyFromGroupPicker(otherGroupIds),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: hintColor,
                              textStyle: hintStyle,
                            ),
                            child: Text(
                              widget.access.canUseMealPlanner
                                  ? 'copy recipes from another group'
                                  : 'Copy recipes from another group',
                            ),
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: sectionGap),
                  Text(
                    key: _plusHintKey,
                    plusHintText,
                    style: hintStyle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: sectionGap),
                  Text(
                    'or share a link, image, or video from social media\nto the app.',
                    style: hintStyle,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Opens [SharedRecipesPage] for one of [otherGroupIds], letting the user
  /// pick which group to browse when they belong to more than one.
  Future<void> _openCopyFromGroupPicker(List<String> otherGroupIds) async {
    if (otherGroupIds.length == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SharedRecipesPage(sourceGroupId: otherGroupIds.first),
        ),
      );
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in otherGroupIds)
              ListTile(
                leading: const Icon(Icons.group_outlined),
                title: LoadDocumentBuilder(
                  docRef: FirebaseFirestore.instance.collection('groups').doc(id),
                  builder: (data) => Text((data['name'] ?? 'Group').toString()),
                ),
                onTap: () => Navigator.pop(context, id),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SharedRecipesPage(sourceGroupId: chosen)),
      );
    }
  }
}

/// Small info line shown after the last row of the recipe grid (once the
/// group has recipes, so the empty state above no longer applies), nudging
/// toward the same sharing feature the empty state mentions.
class ShareTip extends StatelessWidget {
  const ShareTip({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.outline);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: colorScheme.outline),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Did you know? You can also add recipes by sharing a link, image or social media video to the app.',
              style: style,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty-recipes arrows ───────────────────────────────────────────────────

/// Draws the long, hand-drawn-style curved arrows used by [EmptyRecipesState]:
/// one from the "try the Smart Meal Planner above" hint sweeping up toward the
/// carousel, and one from the "tap +" hint sweeping down toward the actual
/// + button. Anchors are the real, measured positions of those texts/the
/// button rather than guessed fractions of the screen, so the arrows land
/// accurately and the down arrow can stop short of the button instead of
/// running under it.
class _EmptyStateArrowPainter extends CustomPainter {
  const _EmptyStateArrowPainter({
    required this.color,
    required this.mealPlannerAnchor,
    required this.plusHintAnchor,
    required this.plusButtonAnchor,
  });

  final Color color;
  final Offset? mealPlannerAnchor;
  final Offset? plusHintAnchor;
  final Offset? plusButtonAnchor;

  // How far short of the + button's measured anchor the arrow tip stops, so
  // the button itself stays fully visible instead of being drawn over.
  static const double _buttonClearance = 26.0;

  // How far the plus-hint arrow starts clear of the hint text itself, so it
  // doesn't hug the letters before curving away.
  static const double _plusHintClearance = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    if (mealPlannerAnchor != null) {
      // Lift the start a bit above and to the right of the text's corner,
      // so the arrow visibly launches off the top of the hint rather than
      // starting flush with its letters.
      final start = mealPlannerAnchor! + const Offset(22, -8);
      // Aim straight up toward the carousel above, drifting only slightly
      // right of the hint's own position and clamped to the canvas bounds,
      // so the curve can never end up off-canvas to the left regardless of
      // exactly where the (left-aligned) hint text lands.
      final end = Offset(
        (start.dx + size.width * 0.12).clamp(24.0, size.width - 24.0),
        4,
      );
      // Pull the control point further out for a more pronounced bow near
      // the start instead of a nearly-straight line.
      final control = Offset(start.dx + (end.dx - start.dx) * 0.3, start.dy * 0.25);
      _drawCurvedArrow(canvas, paint, start, control, end);
    }

    if (plusHintAnchor != null && plusButtonAnchor != null) {
      // Start a little clear of the hint text itself rather than hugging it.
      final start = plusHintAnchor! + const Offset(_plusHintClearance, 0);
      // Stop a little short of the button so it stays fully visible instead
      // of being drawn over.
      final end = plusButtonAnchor! - const Offset(0, _buttonClearance);
      _drawRightThenDownArrow(canvas, paint, start, end);
    }
  }

  void _drawCurvedArrow(Canvas canvas, Paint paint, Offset start, Offset control, Offset end) {
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);
    _drawArrowhead(canvas, paint, end, end - control);
  }

  // Moves sideways from [start] at a constant height, rounds a corner, then
  // drops straight down into [end]. Unlike a single sweeping curve, the last
  // leg is always a plain vertical line, so the arrowhead always ends up
  // pointing straight down into the target no matter where [start] and [end]
  // happen to land.
  void _drawRightThenDownArrow(Canvas canvas, Paint paint, Offset start, Offset end) {
    const cornerRadius = 14.0;
    final cornerX = end.dx;
    final cornerY = start.dy;
    final path = Path()..moveTo(start.dx, start.dy);
    if ((cornerX - start.dx).abs() > cornerRadius && (end.dy - cornerY).abs() > cornerRadius) {
      path.lineTo(cornerX - cornerRadius, cornerY);
      path.quadraticBezierTo(cornerX, cornerY, cornerX, cornerY + cornerRadius);
    } else {
      path.lineTo(cornerX, cornerY);
    }
    path.lineTo(end.dx, end.dy);
    canvas.drawPath(path, paint);
    _drawArrowhead(canvas, paint, end, const Offset(0, 1));
  }

  void _drawArrowhead(Canvas canvas, Paint paint, Offset end, Offset direction) {
    final angle = math.atan2(direction.dy, direction.dx);
    const headLength = 9.0;
    for (final delta in [-0.5, 0.5]) {
      final headAngle = angle + math.pi + delta;
      canvas.drawLine(
        end,
        end + Offset(math.cos(headAngle), math.sin(headAngle)) * headLength,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EmptyStateArrowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.mealPlannerAnchor != mealPlannerAnchor ||
      oldDelegate.plusHintAnchor != plusHintAnchor ||
      oldDelegate.plusButtonAnchor != plusButtonAnchor;
}
