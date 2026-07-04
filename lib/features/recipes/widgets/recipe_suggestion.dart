import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';

/// The kind of AI recipe suggestion shown as a tile in the recipe search grid.
enum SuggestionKind {
  /// A fresh AI-generated recipe name idea.
  name,

  /// A recipe read from a pasted web link.
  url,

  /// An existing recipe from the global public_recipes collection.
  public,
}

/// A single search suggestion. Mutable because a link's title and loading flag
/// are filled in asynchronously after the tile first appears.
class RecipeSuggestion {
  RecipeSuggestion({
    required this.kind,
    required this.title,
    this.url,
    this.publicId,
    this.publicImage,
    this.loading = false,
  });

  final SuggestionKind kind;
  String title;
  final String? url;
  final String? publicId;
  final String? publicImage;
  bool loading;
}

/// A recipe-card-shaped tile for an AI suggestion. Mirrors the sizing of
/// [RecipeCard] but shows a sparkle (idea/link) icon instead of the cutlery
/// placeholder, or the public recipe's image when it has one.
class RecipeSuggestionCard extends StatelessWidget {
  const RecipeSuggestionCard({
    super.key,
    required this.suggestion,
    this.crossAxisCount = 3,
  });

  final RecipeSuggestion suggestion;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    final primaryColor = HSVColor.fromColor(Theme.of(context).colorScheme.primary);
    final primaryContainerColor =
        HSVColor.fromColor(Theme.of(context).colorScheme.primaryContainer);
    final color = HSVColor.fromAHSV(
      1.0,
      (suggestion.title.hashCode % 360).toDouble(),
      primaryColor.saturation,
      primaryColor.value,
    );
    final containerColor =
        color.withValue((primaryContainerColor.value + primaryColor.value) / 2);
    final hasImage =
        suggestion.kind == SuggestionKind.public && (suggestion.publicImage?.isNotEmpty ?? false);
    final icon =
        suggestion.kind == SuggestionKind.url ? Icons.public : MdiIcons.creation;

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
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: containerColor.toColor(),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sd = constraints.maxWidth < constraints.maxHeight
                      ? constraints.maxWidth
                      : constraints.maxHeight;
                  return Stack(
                    children: [
                      if (hasImage) ...[
                        SizedBox.expand(
                          child: StorageImage(
                            storagePath: suggestion.publicImage!,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Container(color: Colors.black26),
                      ] else
                        Align(
                          alignment: const Alignment(0, -0.3),
                          child: Icon(icon, size: sd / 2, color: color.toColor()),
                        ),
                      if (suggestion.loading)
                        const Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CupertinoActivityIndicator(),
                            ),
                          ),
                        ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Icon(icon, size: 12, color: Colors.white70),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  suggestion.title.isNotEmpty
                                      ? suggestion.title
                                      : (suggestion.kind == SuggestionKind.url
                                          ? 'Reading link…'
                                          : ''),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(color: Colors.white, height: 1.2),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
