import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/date_utils.dart';
import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/services/swipe_session_service.dart';

/// Minimum height for a result row, so the list reads as a steady column of
/// similar cards. Deliberately a *minimum*, not a fixed height: a two-line
/// recipe name plus the vote row doesn't fit in it, and clipping the title of a
/// meal the group just voted for is worse than an uneven column.
const double kSwipeResultTileMinHeight = 96;

/// Fixed width for the score bar.
///
/// It used to be `Expanded`, which meant its length depended on how much space
/// the tally and avatars left over — so a recipe with no votes got a *longer*
/// bar than one with three. A score bar whose length encodes anything other
/// than the score is worse than no bar at all.
const double _kScoreBarWidth = 76;

/// Above this many participants the avatars are dropped and the tally carries
/// the result on its own.
///
/// In a couple or a family, *who* liked something is the interesting part and
/// two or three faces say it instantly. In a group of ten it stops being
/// legible — the row can't fit the faces without shrinking them to confetti,
/// and "7/10" was the useful part anyway.
const int _kMaxParticipantsForAvatars = 6;

/// A stable colour for [name], so two people aren't told apart by an initial
/// alone.
///
/// Hashes the **whole** name rather than the letter shown: "Anna" and "Alex"
/// both render an A, and giving them the same swatch defeats the point of
/// showing faces at all. Saturation and lightness are fixed so every swatch
/// carries the same visual weight and the on-colour text stays legible; only
/// the hue varies, and it's nudged brighter in dark mode.
Color avatarColorFor(String name, Brightness brightness) {
  var hash = 0;
  for (final unit in name.trim().toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(
    1,
    hue,
    brightness == Brightness.dark ? 0.45 : 0.55,
    brightness == Brightness.dark ? 0.45 : 0.72,
  ).toColor();
}

/// One recipe in the results, wherever it currently sits.
///
/// Knows nothing about days: the date lives on the [SwipeDaySlot] this may be
/// dropped into. That separation is the point — recipes move, days don't.
class SwipeResultTile extends StatelessWidget {
  const SwipeResultTile({
    super.key,
    required this.ranked,
    required this.maxScore,
    required this.participantCount,
    this.onTap,
    this.dragHandle,
    this.dimmed = false,
    this.elevated = false,
    this.borderRadius,
  });

  final SwipeRanked ranked;

  /// The top score in this session, so bars are relative to the winner rather
  /// than to a theoretical maximum nobody reaches.
  final double maxScore;
  final int participantCount;
  final VoidCallback? onTap;

  /// The drag affordance, built by the caller so it can carry the right payload
  /// for where this tile currently lives. Null in the read-only view.
  final Widget? dragHandle;

  /// True for recipes not currently on a day — legible, but receding so the
  /// plan reads as the primary content.
  final bool dimmed;

  /// True while this tile is the thing being dragged.
  final bool elevated;

  /// Overridden for a card sitting flush inside a [SwipeDaySlot], whose corners
  /// have to follow the slot's frame rather than float inside it.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final card = ranked.card;
    final image = card.image;

    // A Stack, not a Row inside IntrinsicHeight.
    //
    // IntrinsicHeight asks every child how tall it wants to be and takes the
    // largest — and an Image's intrinsic height is its natural height at the
    // given width. So a portrait photo made its whole card taller than a
    // landscape one, for no reason the user could see. Here the image is a
    // *positioned* child, which is excluded from the Stack's sizing entirely:
    // the text column alone decides the height, and the image stretches to fill
    // whatever that turns out to be.
    return Opacity(
      opacity: dimmed ? 0.75 : 1,
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        elevation: elevated ? 8 : 0,
        borderRadius: borderRadius ?? BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              // A plain square crop, not the deck card's extended-edge
              // treatment. That exists because a tall card crops a landscape
              // photo down to a corner of the plate; a small square thumbnail
              // doesn't have that problem, and the stretched bands just read as
              // smudges at this size. Centred vertically so a two-line title
              // grows the row without stretching the photo out of square.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: kSwipeResultTileMinHeight,
                child: Center(
                  child: SizedBox.square(
                    dimension: kSwipeResultTileMinHeight,
                    child: image != null && image.isNotEmpty
                        ? StorageImage(
                            storagePath: image,
                            fit: BoxFit.cover,
                            memCacheWidth: 256,
                          )
                        : Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.restaurant_menu,
                              color: colorScheme.onSurfaceVariant.withOpacity(0.5),
                            ),
                          ),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kSwipeResultTileMinHeight),
                child: Padding(
                  padding: const EdgeInsets.only(left: kSwipeResultTileMinHeight),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                card.name,
                                style: Theme.of(context).textTheme.titleMedium,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              _VoteRow(
                                ranked: ranked,
                                maxScore: maxScore,
                                participantCount: participantCount,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (dragHandle != null) dragHandle!,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The standard drag affordance: a grab handle sized for a thumb.
class SwipeDragHandle extends StatelessWidget {
  const SwipeDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Center(
        child: Icon(
          Icons.drag_indicator,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A day in the plan: a fixed, outlined frame that stays put while recipes are
/// dragged in and out of it.
///
/// The days are the stable thing here. An earlier version made the *rows*
/// reorderable, which meant dragging shuffled the dates along with the recipes
/// and every drop had to be reasoned about positionally. Pinning the days as
/// background frames and moving only the recipes makes the whole interaction
/// literal: this recipe, that day.
class SwipeDaySlot extends StatelessWidget {
  const SwipeDaySlot({
    super.key,
    required this.date,
    required this.child,
    this.highlighted = false,
  });

  final DateTime date;
  final Widget child;

  /// True while a recipe is hovering over this slot.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primaryContainer.withOpacity(0.35)
            : colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlighted ? colorScheme.primary : colorScheme.outlineVariant,
          width: highlighted ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // Only the label is inset; the card below runs flush to the frame's
            // left, right and bottom edges.
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text(
              getRelativeDateString(date),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: highlighted ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Placeholder inside a day nobody is planned for.
class SwipeEmptySlot extends StatelessWidget {
  const SwipeEmptySlot({super.key, required this.canDrag});
  final bool canDrag;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: kSwipeResultTileMinHeight - 24,
      alignment: Alignment.center,
      child: Text(
        canDrag ? 'Drag a recipe here' : 'Nothing planned',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

/// The score bar, a plain-language tally, and who liked it — identical on every
/// tile so two recipes can actually be compared.
class _VoteRow extends StatelessWidget {
  const _VoteRow({
    required this.ranked,
    required this.maxScore,
    required this.participantCount,
  });

  final SwipeRanked ranked;
  final double maxScore;
  final int participantCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final loves = ranked.lovedBy.length;
    final likes = ranked.likedBy.length;

    return Row(
      children: [
        // Fixed width, never Expanded: the bar's length must mean the score and
        // nothing else.
        SizedBox(
          width: _kScoreBarWidth,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: maxScore <= 0 ? 0 : (ranked.score / maxScore).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                loves > 0 ? colorScheme.tertiary : colorScheme.primary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          likes == 0 ? '0/$participantCount' : '$likes/$participantCount',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        if (loves > 0) ...[
          const SizedBox(width: 6),
          Icon(Icons.favorite, size: 12, color: colorScheme.tertiary),
          const SizedBox(width: 2),
          Text(
            '$loves',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
        // Scales down rather than overflowing. With a big group the tally
        // ("6/12") already carries the number, so shrinking the faces — or, at
        // the extreme, letting the "+N" do the talking — costs nothing. An
        // unbounded Row here would throw a layout overflow on a narrow phone
        // the moment enough people voted.
        if (participantCount <= _kMaxParticipantsForAvatars)
          // FittedBox as a backstop: even under the threshold, a long recipe
          // name column on a narrow phone shouldn't be able to throw an
          // overflow. It scales down rather than complaining.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: _LikedByAvatars(ranked: ranked),
              ),
            ),
          )
        else
          const Spacer(),
      ],
    );
  }
}

/// Small stack of avatars for everyone who liked this recipe. A love gets a
/// ring, so "we both loved this" is readable at a glance rather than needing
/// the score bar decoded twice.
class _LikedByAvatars extends StatelessWidget {
  const _LikedByAvatars({required this.ranked});
  final SwipeRanked ranked;

  @override
  Widget build(BuildContext context) {
    if (ranked.likedBy.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final shown = ranked.likedBy.take(3).toList();
    final overflow = ranked.likedBy.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final uid in shown)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: _MemberAvatar(uid: uid, loved: ranked.lovedBy.contains(uid)),
          ),
        if (overflow > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '+$overflow',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
      ],
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.uid, required this.loved});
  final String uid;
  final bool loved;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LoadDocumentBuilder(
      docRef: FirebaseFirestore.instance.collection('users_public').doc(uid),
      builder: (data) {
        final name = (data['username'] ?? '?').toString();
        final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
        final background = avatarColorFor(name, colorScheme.brightness);
        // Contrast against the generated swatch rather than a theme pair, since
        // the hue is arbitrary.
        final foreground = ThemeData.estimateBrightnessForColor(background) ==
                Brightness.dark
            ? Colors.white
            : Colors.black87;
        return Tooltip(
          message: loved ? '$name loved this' : '$name liked this',
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: loved ? Border.all(color: colorScheme.tertiary, width: 2) : null,
            ),
            child: CircleAvatar(
              radius: loved ? 10 : 11,
              backgroundColor: background,
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
