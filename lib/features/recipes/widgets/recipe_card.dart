import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';

// ─── RecipeOpenContainer ──────────────────────────────────────────────────────

/// Wraps a recipe card so tapping it expands the card into the full
/// [RecipeDetailPage] with a Material container transform.
class RecipeOpenContainer extends StatelessWidget {
  const RecipeOpenContainer({
    super.key,
    required this.recipeId,
    required this.groupId,
    required this.groupDoc,
    required this.aiEnabled,
    required this.initialData,
    required this.child,
    this.onTagTap,
  });

  final String recipeId;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final bool aiEnabled;
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
        aiEnabled: aiEnabled,
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
  });

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;
  final Map<String, dynamic>? data;

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
    final color = HSVColor.fromAHSV(
      1.0,
      (recipeId.hashCode % 360).toDouble(),
      primaryColor.saturation,
      primaryColor.value,
    );
    final containerColor =
    color.withValue((primaryContainerColor.value + primaryColor.value) / 2);

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
    Widget buildContent(Map<String, dynamic> recipeData) {
        final images = List<String>.from(recipeData['images'] ?? []);
        return LayoutBuilder(
          builder: (context, constraints) {
            final double sd =
            constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
            final dpr = MediaQuery.of(context).devicePixelRatio;
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
                  Container(color: Colors.black26),
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
                      recipeData['name'] ?? 'Unnamed Recipe',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                          color: Colors.white, height: 1.2),
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
    return LoadDocumentBuilder(
      docRef: groupCollection!.collection('recipes').doc(recipeId),
      builder: buildContent,
    );
  }
}
