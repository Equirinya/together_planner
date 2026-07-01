import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/ingredients/models/ingredients.dart';

// =============================================================================
// Avatar (shared by list rows and suggestion tiles)
// =============================================================================

/// Listens to the ingredient doc so the icon refreshes the moment the
/// icon-generation function finishes (avatarVersion bumps 0 → timestamp).
/// With persistence on, the snapshot listener serves the cached doc instantly.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.ingredientId,
    this.radius = 20,
    this.backgroundColor,
  });

  final String ingredientId;
  final double radius;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultBg = isDark ? cs.primaryContainer : cs.primary;

    if (ingredientId == kPendingIngredient) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.surfaceContainerHighest,
        child: const CupertinoActivityIndicator(),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ingredients')
          .doc(ingredientId)
          .snapshots(),
      builder: (context, snap) {
        final version = (snap.data?.data()?['avatarVersion'] ?? 0).toString();
        // avatarVersion 0 means the icon is still being (re)generated.
        if (version == '0') {
          return CircleAvatar(
            radius: radius,
            backgroundColor: backgroundColor ?? defaultBg,
            child: const CupertinoActivityIndicator(),
          );
        }
        return CircleAvatar(
          radius: radius,
          backgroundColor: backgroundColor ?? defaultBg,
          child: StorageImage(
            key: ValueKey('$ingredientId#$version'),
            cacheKey: version,
            storagePath: 'ingredients/$ingredientId.png',
            fit: BoxFit.contain,
            memCacheWidth: 128,
            memCacheHeight: 128,
            errorWidget: Text('?', style: Theme.of(context).textTheme.labelMedium),
            placeholder: Text('?', style: Theme.of(context).textTheme.labelMedium),
          ),
        );
      },
    );
  }
}
