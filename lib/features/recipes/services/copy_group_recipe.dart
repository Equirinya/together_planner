import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Largest recipe image we are willing to pull down and re-upload.
const int _kMaxImageBytes = 20 * 1024 * 1024;

/// Copies a recipe from another group's `recipes` collection into [groupId]'s
/// own collection, the same way [adoptPublicRecipe] copies a public recipe:
/// the recipe doc, its ingredients and private copies of its images are written
/// client-side in a single batch. Tagged with `sourceGroupId`/`sourceRecipeId`
/// so the copy can be matched back to its origin (for the added/checked state).
/// Returns the id of the new group recipe.
Future<String> copyGroupRecipe({
  required String groupId,
  required String sourceGroupId,
  required String sourceRecipeId,
  required String uid,
}) async {
  final db = FirebaseFirestore.instance;
  final sourceRef = db.doc('groups/$sourceGroupId/recipes/$sourceRecipeId');
  final sourceSnap = await sourceRef.get();
  if (!sourceSnap.exists) throw StateError('Recipe not found.');
  final s = sourceSnap.data()!;

  final recipeRef = db.collection('groups/$groupId/recipes').doc();

  // Copy each image into the destination group's own storage so editing or
  // deleting this recipe never touches the source group's asset.
  final images = <String>[];
  for (final path in List<String>.from(s['images'] ?? const [])) {
    if (path.isEmpty) continue;
    try {
      final bytes = await FirebaseStorage.instance.ref(path).getData(_kMaxImageBytes);
      if (bytes == null) continue;
      final dest =
          'groups/$groupId/recipes/${recipeRef.id}/${DateTime.now().millisecondsSinceEpoch}_${images.length}.jpg';
      await FirebaseStorage.instance
          .ref(dest)
          .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      images.add(dest);
    } catch (_) {
      // Non-fatal: keep copying the rest without this image.
    }
  }

  final ingSnap = await sourceRef.collection('ingredients').get();

  final batch = db.batch();
  batch.set(recipeRef, {
    'name': s['name'] ?? '',
    'description': s['description'] ?? '',
    'creator': uid,
    'createdAt': FieldValue.serverTimestamp(),
    'lastUsedAt': FieldValue.serverTimestamp(),
    'preparationTime': s['preparationTime'] ?? 0,
    'time': s['time'] ?? 0,
    'servings': s['servings'] ?? 2,
    'tags': List<dynamic>.from(s['tags'] ?? const []),
    'dietary': List<dynamic>.from(s['dietary'] ?? const []),
    if (s['languages'] != null) 'languages': List<dynamic>.from(s['languages']),
    if (s['translations'] != null) 'translations': s['translations'],
    'steps': List<dynamic>.from(s['steps'] ?? const []),
    'images': images,
    'sourceGroupId': sourceGroupId,
    'sourceRecipeId': sourceRecipeId,
    if (s['attribution'] != null) 'attribution': s['attribution'],
  });

  for (final d in ingSnap.docs) {
    final data = d.data();
    batch.set(recipeRef.collection('ingredients').doc(), {
      'ingredientId': data['ingredientId'] ?? '',
      'displayName': data['displayName'] ?? '',
      'description': data['description'] ?? '',
      'quantity': Map<String, dynamic>.from(data['quantity'] ?? const {}),
      'doneAt': null,
      'category': data['category'] ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();
  return recipeRef.id;
}
