import 'package:cloud_firestore/cloud_firestore.dart';

/// Deleting a recipe and everything hanging off it.
///
/// Firestore does **not** cascade: deleting a recipe document leaves its
/// `ingredients` subcollection behind as orphaned docs that no query will ever
/// surface again (but that still cost storage). Every path that removes a
/// recipe must therefore delete the subcollection explicitly — which is why
/// this lives in one place rather than being repeated at each call site.
///
/// Images are *not* handled here: the `deleteRecipeImages` Cloud Function
/// (onDocumentDeleted) clears `groups/{groupId}/recipes/{recipeId}/` from
/// Storage on its own.

/// Firestore's hard cap on writes in a single [WriteBatch].
const int _kMaxBatchWrites = 500;

/// Commits [refs] as deletes, splitting across batches so the 500-write cap
/// can't be hit by a recipe with many ingredients and cooking plans.
Future<void> _deleteAll(
  FirebaseFirestore db,
  List<DocumentReference<Map<String, dynamic>>> refs,
) async {
  for (var i = 0; i < refs.length; i += _kMaxBatchWrites) {
    final batch = db.batch();
    for (final ref in refs.skip(i).take(_kMaxBatchWrites)) {
      batch.delete(ref);
    }
    await batch.commit();
  }
}

/// Deletes a group recipe: its `ingredients` subcollection, any cooking plans
/// referencing it, and the recipe document itself.
///
/// The recipe doc is deleted **last** so that a failure partway through leaves
/// the recipe visible (and re-deletable) rather than stranding its ingredients
/// under a doc the user can no longer see.
Future<void> deleteGroupRecipe({
  required String groupId,
  required String recipeId,
  FirebaseFirestore? firestore,
}) async {
  final db = firestore ?? FirebaseFirestore.instance;
  final groupRef = db.collection('groups').doc(groupId);
  final recipeRef = groupRef.collection('recipes').doc(recipeId);

  final results = await Future.wait([
    recipeRef.collection('ingredients').get(),
    groupRef
        .collection('cooking_plan')
        .where('recipe', isEqualTo: recipeId)
        .get(),
  ]);

  await _deleteAll(db, [
    for (final snap in results) ...snap.docs.map((d) => d.reference),
  ]);
  await recipeRef.delete();
}

/// Deletes a public recipe together with its `ingredients` subcollection.
/// Requires the caller to have `editPublicRecipes`.
Future<void> deletePublicRecipe({
  required String publicRecipeId,
  FirebaseFirestore? firestore,
}) async {
  final db = firestore ?? FirebaseFirestore.instance;
  final publicRef = db.collection('public_recipes').doc(publicRecipeId);

  final ings = await publicRef.collection('ingredients').get();
  await _deleteAll(db, ings.docs.map((d) => d.reference).toList());
  await publicRef.delete();
}
