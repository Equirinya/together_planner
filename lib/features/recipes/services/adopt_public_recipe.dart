import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kPendingIngredient, kUnknownIngredient;

/// Base language of the public_recipes collection (see functions/src/lib/languages.ts).
const String _kBaseLanguage = 'en';

/// Largest public image we are willing to pull down and re-upload.
const int _kMaxImageBytes = 20 * 1024 * 1024;

/// Pre-fetched public recipe data, ready for instant adoption on drop.
/// [imageFuture] may still be in-flight when this object is returned, allowing
/// the recipe doc and ingredients to be written to Firestore immediately while
/// the image download continues in the background.
class PublicRecipePreload {
  final Map<String, dynamic> data;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> ingredients;

  /// Resolves to the downloaded image bytes (or null on failure / no image).
  final Future<Uint8List?> imageFuture;

  const PublicRecipePreload(this.data, this.ingredients, this.imageFuture);
}

/// Fetches the public recipe document and its ingredients concurrently, then
/// starts the image download in the background without blocking the returned
/// [Future]. Call when the user begins dragging a public recipe suggestion;
/// await the result on drop so that [adoptPublicRecipeFromPreload] can write to
/// Firestore immediately.
Future<PublicRecipePreload> preloadPublicRecipe(String publicRecipeId) async {
  final db = FirebaseFirestore.instance;
  final publicRef = db.doc('public_recipes/$publicRecipeId');

  // Start ingredient fetch before awaiting the recipe doc so both run in parallel.
  final ingFuture = publicRef.collection('ingredients').get();

  final snap = await publicRef.get();
  if (!snap.exists) throw StateError('Public recipe not found.');
  final p = snap.data()!;

  // Kick off image download — kept as a Future so it does not block the caller.
  final imagePath = p['image'];
  final Future<Uint8List?> imgFuture;
  if (imagePath is String && imagePath.isNotEmpty) {
    imgFuture = _fetchImageBytes(imagePath);
  } else {
    imgFuture = Future.value(null);
  }

  final ingSnap = await ingFuture;
  return PublicRecipePreload(p, ingSnap.docs, imgFuture);
}

/// Writes the recipe and its ingredients from [preload] to Firestore without
/// waiting for the image. Returns the new recipe id and an [imageUpload]
/// [Future] that chains on the preload's still-running image download and then
/// uploads the bytes; the recipe doc is updated with the storage path once
/// complete. Callers can create the cooking plan as soon as [recipeId] is
/// available.
Future<({String recipeId, Future<void> imageUpload})> adoptPublicRecipeFromPreload({
  required String groupId,
  required String publicRecipeId,
  required PublicRecipePreload preload,
  required String uid,
  required String lang,
}) async {
  final db = FirebaseFirestore.instance;
  final p = preload.data;

  final recipeRef = db.collection('groups/$groupId/recipes').doc();

  final batch = db.batch();
  batch.set(recipeRef, {
    // Group recipes always keep an English base plus a `translations` map
    // (see generateRecipeStaged in recipes.ts), same as public_recipes — so
    // this just carries the public recipe's base fields and translations
    // straight over, rather than "baking in" the currently-active language.
    'name': p['name'] ?? '',
    'description': p['description'] ?? '',
    'creator': uid,
    'createdAt': FieldValue.serverTimestamp(),
    'lastUsedAt': FieldValue.serverTimestamp(),
    'preparationTime': p['preparationTime'] ?? 0,
    'time': p['time'] ?? 0,
    // Kept null for recipes without a meaningful serving count (a cake, a loaf)
    // so the adopted copy hides the servings control too.
    'servings': p['servings'],
    'tags': List<dynamic>.from(p['tags'] ?? const []),
    'dietary': List<dynamic>.from(p['dietary'] ?? const []),
    if (p['languages'] != null) 'languages': List<dynamic>.from(p['languages']),
    if (p['translations'] != null) 'translations': p['translations'],
    'steps': List<dynamic>.from(p['steps'] ?? const []),
    'images': <String>[],
    'sourcePublicId': publicRecipeId,
    if (p['attribution'] != null) 'attribution': p['attribution'],
  });

  for (final d in preload.ingredients) {
    final data = d.data();
    final publicIngId = (data['ingredientId'] as String?) ?? '';
    final resolvedIngId = (publicIngId.isNotEmpty && publicIngId != kUnknownIngredient)
        ? publicIngId
        : kPendingIngredient;
    batch.set(recipeRef.collection('ingredients').doc(), {
      'ingredientId': resolvedIngId,
      // English base + translations, same convention as the recipe doc above.
      'displayName': data['displayName'] ?? '',
      'description': data['description'] ?? '',
      if (data['translations'] != null) 'translations': data['translations'],
      'quantity': Map<String, dynamic>.from(data['quantity'] ?? const {}),
      'doneAt': null,
      'category': '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  await batch.commit();

  // Chain image upload on the already-running download future so upload starts
  // as soon as the bytes are ready, without any additional waiting.
  final imageUpload = preload.imageFuture
      .then((bytes) => _uploadImageAndUpdate(recipeRef, groupId, bytes));
  return (recipeId: recipeRef.id, imageUpload: imageUpload);
}

Future<Uint8List?> _fetchImageBytes(String storagePath) async {
  try {
    return await FirebaseStorage.instance.ref(storagePath).getData(_kMaxImageBytes);
  } catch (_) {
    return null;
  }
}

Future<void> _uploadImageAndUpdate(
  DocumentReference<Map<String, dynamic>> recipeRef,
  String groupId,
  Uint8List? bytes,
) async {
  if (bytes == null) return;
  try {
    final dest =
        'groups/$groupId/recipes/${recipeRef.id}/ai_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await FirebaseStorage.instance
        .ref(dest)
        .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    await recipeRef.update({'images': [dest]});
  } catch (_) {
    // Non-fatal: recipe stays without image.
  }
}
