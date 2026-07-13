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
  });

  final String recipeId;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final AiAccess access;
  final Map<String, dynamic>? initialData;
  final Widget child;
  final void Function(String tag)? onTagTap;

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
      openBuilder: (_, __) => RecipeDetailPage(
        groupId: groupId,
        recipeId: recipeId,
        access: access,
        initialData: initialData,
        onTagTap: onTagTap,
      ),
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
                .titleMedium
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
