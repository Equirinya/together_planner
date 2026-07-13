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
    final bool isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final color = HSVColor.fromAHSV(
      1.0,
      (suggestion.title.hashCode % 360).toDouble(),
      primaryColor.saturation,
      primaryColor.value,
    );
    final double midValue = (primaryContainerColor.value + primaryColor.value) / 2;
    // Match the recipe card: dark mode keeps the mid-value tonal fill with white
    // content; light mode uses a soft, bright pastel of the hue with a dark
    // hue-matched title so it stays clean and readable.
    final containerColor = isDark
        ? color.withValue(midValue)
        : color.withSaturation(color.saturation * 0.35).withValue(0.95);
    final hasImage =
        suggestion.kind == SuggestionKind.public && (suggestion.publicImage?.isNotEmpty ?? false);
    // Dark mode keeps white text over a dark scrim; light mode uses one
    // consistent dark title over a light scrim (see below) instead.
    final Color titleColor =
        isDark ? Colors.white : Theme.of(context).colorScheme.onSurface;
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
                  final dpr = MediaQuery.of(context).devicePixelRatio;
                  final String title = suggestion.title.isNotEmpty
                      ? suggestion.title
                      : (suggestion.kind == SuggestionKind.url ? 'Reading link…' : '');
                  final TextStyle? titleStyle = Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: titleColor, height: 1.2);
                  // A light scrim sized to the title itself (not the tile): the
                  // text block sits on solid white with a soft fade above it,
                  // taller for a two-line title so its top line stays legible.
                  Widget lightImageScrim() {
                    final tp = TextPainter(
                      text: TextSpan(text: title, style: titleStyle),
                      maxLines: 2,
                      textDirection: TextDirection.ltr,
                    )..layout(maxWidth: constraints.maxWidth - 12);
                    final bool twoLines = tp.computeLineMetrics().length >= 2;
                    final double fade = twoLines ? 32 : 22;
                    // 60% plateau behind the text, a few pixels shorter than it,
                    // then a smooth fade-out above.
                    final double plateau =
                        (tp.height - 6).clamp(0.0, double.infinity);
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
                      if (hasImage) ...[
                        SizedBox.expand(
                          child: StorageImage(
                            storagePath: suggestion.publicImage!,
                            fit: BoxFit.cover,
                            memCacheHeight: (constraints.maxHeight * dpr).toInt(),
                          ),
                        ),
                        if (isDark)
                          Container(color: Colors.black26)
                        else
                          lightImageScrim(),
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
                      if (hasImage)
                        Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(icon, size: 16, color: titleColor),
                          ),
                        ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
