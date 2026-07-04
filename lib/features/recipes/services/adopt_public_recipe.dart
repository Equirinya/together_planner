import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kPendingIngredient, kUnknownIngredient;

/// Base language of the public_recipes collection (see functions/src/lib/languages.ts).
const String _kBaseLanguage = 'en';

/// Largest public image we are willing to pull down and re-upload.
const int _kMaxImageBytes = 20 * 1024 * 1024;

/// Copies a public recipe into a group's own `recipes` collection, localized to
/// [lang] when a translation exists (else the English base). Replaces the former
/// `adoptPublicRecipe` Cloud Function: the recipe doc, its ingredients and a
/// private copy of the image are written client-side in a single batch. Returns
/// the id of the new group recipe.
Future<String> adoptPublicRecipe({
  required String groupId,
  required String publicRecipeId,
  required String uid,
  required String lang,
}) async {
  final db = FirebaseFirestore.instance;
  final publicRef = db.doc('public_recipes/$publicRecipeId');
  final publicSnap = await publicRef.get();
  if (!publicSnap.exists) throw StateError('Public recipe not found.');
  final p = publicSnap.data()!;

  // Public recipes store an English base plus a `translations` map. Prefer the
  // user's language when a translation exists, else fall back to the base.
  final localized = lang == _kBaseLanguage
      ? null
      : (p['translations'] as Map<String, dynamic>?)?[lang] as Map<String, dynamic>?;
  T localizedField<T>(String key, T fallback) =>
      (localized?[key] ?? p[key] ?? fallback) as T;

  final recipeRef = db.collection('groups/$groupId/recipes').doc();

  // Copy the public image into the group's own storage so editing or deleting
  // this recipe never touches the shared public asset (and vice-versa).
  final images = <String>[];
  final imagePath = p['image'];
  if (imagePath is String && imagePath.isNotEmpty) {
    try {
      final bytes = await FirebaseStorage.instance.ref(imagePath).getData(_kMaxImageBytes);
      if (bytes != null) {
        final dest =
            'groups/$groupId/recipes/${recipeRef.id}/ai_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await FirebaseStorage.instance
            .ref(dest)
            .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        images.add(dest);
      }
    } catch (_) {
      // Non-fatal: adopt the recipe without an image.
    }
  }

  final ingSnap = await publicRef.collection('ingredients').get();

  final batch = db.batch();
  batch.set(recipeRef, {
    'name': localizedField<String>('name', ''),
    'description': localizedField<String>('description', ''),
    'creator': uid,
    'createdAt': FieldValue.serverTimestamp(),
    'lastUsedAt': FieldValue.serverTimestamp(),
    'preparationTime': p['preparationTime'] ?? 0,
    'time': p['time'] ?? 0,
    'servings': p['servings'] ?? 2,
    'tags': localizedField<List<dynamic>>('tags', const []),
    'steps': localizedField<List<dynamic>>('steps', const []),
    'images': images,
    'sourcePublicId': publicRecipeId,
    if (p['attribution'] != null) 'attribution': p['attribution'],
  });

  for (final d in ingSnap.docs) {
    final data = d.data();
    final ingLocalized = lang == _kBaseLanguage
        ? null
        : (data['translations'] as Map<String, dynamic>?)?[lang] as Map<String, dynamic>?;
    final publicIngId = (data['ingredientId'] as String?) ?? '';
    final resolvedIngId = (publicIngId.isNotEmpty && publicIngId != kUnknownIngredient)
        ? publicIngId
        : kPendingIngredient;
    batch.set(recipeRef.collection('ingredients').doc(), {
      'ingredientId': resolvedIngId,
      'displayName': ingLocalized?['displayName'] ?? data['displayName'] ?? '',
      'description': ingLocalized?['description'] ?? data['description'] ?? '',
      'quantity': <String, dynamic>{},
      'doneAt': null,
      'category': '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();
  return recipeRef.id;
}
