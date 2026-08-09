import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';
import 'package:couple_planner/features/recipes/services/recipe_localization.dart';
import 'package:couple_planner/features/recipes/widgets/meal_plan_widgets.dart';

/// Read-only recipe preview, shown from a proposed meal-plan day or a swipe
/// card so people can check what a dish actually is before deciding. Shared by
/// public-recipe slots (a one-shot preload, wrapped as a single-event stream)
/// and own/new-idea slots (a live Firestore stream, so a still-generating
/// recipe's fields pop in as they land) — see [openPublicRecipePreview] and
/// [openOwnRecipePreview] for how each wires up [dataStream].
class RecipePreviewSheet extends StatelessWidget {
  const RecipePreviewSheet({
    super.key,
    required this.name,
    required this.image,
    required this.dataStream,
    required this.alwaysShowImage,
  });

  /// Fallback name/image shown immediately, before the first [dataStream]
  /// event arrives (or if a field isn't present yet).
  final String name;
  final String? image;
  final Stream<Map<String, dynamic>?> dataStream;

  /// Whether to render a persistent shimmer placeholder when no image is
  /// available yet (own/new-idea slots, whose image may still be generating)
  /// vs. simply omitting the image block (public slots, which always already
  /// have one).
  final bool alwaysShowImage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => StreamBuilder<Map<String, dynamic>?>(
        stream: dataStream,
        builder: (context, snap) {
          final data = snap.data;
          final loading = data == null;
          final images = data?['images'] is List
              ? List<String>.from(data!['images'])
              : ((data?['image'] as String?)?.isNotEmpty == true
                  ? [data!['image'] as String]
                  : const <String>[]);
          final displayImage = images.isNotEmpty ? images.first : image;
          final steps = List<String>.from(data?['steps'] ?? const []);
          final description = (data?['description'] ?? '').toString();
          final time = (data?['time'] as num?)?.toInt() ?? 0;
          final pending = data?['pending'] as List?;
          final stepsDone = pending == null || !pending.contains('steps');
          final displayName =
              (data?['name'] as String?)?.isNotEmpty == true ? data!['name'] as String : name;
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              if (displayImage != null && displayImage.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: StorageImage(storagePath: displayImage, fit: BoxFit.cover),
                  ),
                )
              else if (alwaysShowImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Shimmer(child: Container(color: colorScheme.surfaceContainerHighest)),
                  ),
                ),
              if ((displayImage != null && displayImage.isNotEmpty) || alwaysShowImage)
                const SizedBox(height: 16),
              Text(displayName, style: Theme.of(context).textTheme.headlineSmall),
              if (time > 0) ...[
                const SizedBox(height: 8),
                SheetTimeRow(minutes: time),
              ],
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 20),
              if (loading || !stepsDone)
                for (int i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Shimmer(
                      child: Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  )
              else if (steps.isEmpty)
                Text('No steps available.', style: TextStyle(color: colorScheme.onSurfaceVariant))
              else
                for (int i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(fontSize: 12, color: colorScheme.onPrimaryContainer),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(steps[i], style: Theme.of(context).textTheme.bodyMedium)),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

void _showSheet(BuildContext context, Widget child) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => child,
  );
}

/// Preview for a public recipe, fed by a one-shot [preloadPublicRecipe] future
/// wrapped as a single-event stream.
void openPublicRecipePreview(
  BuildContext context, {
  required String publicRecipeId,
  required String name,
  String? image,
  required Future<PublicRecipePreload> Function(String publicRecipeId) publicPreload,
}) {
  _showSheet(
    context,
    RecipePreviewSheet(
      name: name,
      image: image,
      alwaysShowImage: false,
      dataStream: Stream.fromFuture(publicPreload(publicRecipeId))
          .map((p) => localizeRecipeData(p.data, LanguageService.instance.code.value)),
    ),
  );
}

/// Preview for a recipe the group owns (or a `new idea` still being generated
/// in `public_recipes`), fed by a live Firestore stream so fields pop in as
/// they land.
void openOwnRecipePreview(
  BuildContext context, {
  required String recipeId,
  required MealPlanSource source,
  required DocumentReference<Map<String, dynamic>> groupDoc,
  required String name,
  String? image,
}) {
  final recipeDoc = source == MealPlanSource.newIdea
      ? FirebaseFirestore.instance.collection('public_recipes').doc(recipeId)
      : groupDoc.collection('recipes').doc(recipeId);
  _showSheet(
    context,
    RecipePreviewSheet(
      name: name,
      image: image,
      alwaysShowImage: true,
      dataStream: recipeDoc.snapshots().map((s) {
        final d = s.data();
        return d == null ? null : localizeRecipeData(d, LanguageService.instance.code.value);
      }),
    ),
  );
}
