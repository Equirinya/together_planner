// The single place an ingredient item is written to a list.
//
// Both entry points that can put something on a list go through
// [addSuggestionToList]: the search sheet when a suggestion is tapped, and the
// Siri / Shortcuts path in features/shopping_list/services/add_item_by_name.dart.
// They differ only in how they arrive at a [Suggestion] — a tap already has
// one, voice input has to parse and match its way to it — so everything from
// that point on (the merge rule, the document shape, the contribution
// attribution, the after-write ingredient resolution) lives here rather than
// being restated per caller.
//
// Deliberately free of widget imports: the callers include an intent handler
// that runs with no widget tree and no BuildContext to show anything on.
// Failures come back as [AddItemOutcome.failed] for the caller to present, and
// are logged here so the reason isn't lost on the way.

import 'package:flutter/foundation.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/shopping_list/manual_contributions.dart';

/// Finds the active list item that adding [s] should merge into, or null when
/// it should create a fresh item. An item matches when it shares the
/// suggestion's display name and description (so differently-named or described
/// entries for the same ingredient stay distinct). A stated amount only merges
/// into an item already in that unit; a bare "+1" merges into a match in
/// whatever unit it uses.
Map<String, dynamic>? combineTarget(
    Suggestion s, List<Map<String, dynamic>> currentItems) {
  if (s.isRestoreDone) return null;
  for (final data in currentItems) {
    if (data['doneAt'] != null) continue;
    if ((data['displayName'] ?? '').toString().toLowerCase() !=
        s.displayName.toLowerCase()) continue;
    if ((data['description'] ?? '').toString() != s.description) continue;
    if (s.quantity != null) {
      final existingUnitId =
          readQuantity(data['quantity'])?.unitId ?? kDefaultUnitId;
      if (existingUnitId != s.unitId) continue;
    }
    return data;
  }
  return null;
}

/// What [addSuggestionToList] did, so a caller can phrase a confirmation
/// ("Added milk" vs "Milk is already on the list, now 3").
enum AddItemOutcome {
  /// A new item document was created.
  added,

  /// An existing active item with the same name/unit had its amount raised.
  combined,

  /// Nothing was written — empty name, or the write threw.
  failed,
}

class AddItemResult {
  const AddItemResult(this.outcome, {this.displayName = '', this.itemId});

  final AddItemOutcome outcome;

  /// The name as it now reads on the list, for use in a confirmation.
  final String displayName;

  /// The item document, absent only when [outcome] is [AddItemOutcome.failed].
  final String? itemId;

  bool get ok => outcome != AddItemOutcome.failed;
}

/// Adds [s] to [listRef], merging into an existing item where [combineTarget]
/// says it should.
///
/// [currentItems] is the caller's view of the list's active items, each a
/// document map carrying its own `id`. It is passed in rather than read here
/// because the search sheet already holds a live snapshot and must resolve the
/// merge against exactly what the user was looking at when they tapped —
/// re-reading would both cost a round-trip and risk merging into an item that
/// appeared in between. Callers with no such view (the intent handler) read it
/// themselves first.
///
/// [trackContributions] mirrors `IngredientSearchSheet.trackContributions`:
/// the shopping list records who added what, recipe ingredient lists don't.
///
/// [resolveInBackground] controls whether the post-write ingredient resolution
/// is awaited. The sheet wants it detached so the field is usable immediately;
/// an intent handler must await it, because the isolate can be torn down the
/// moment it returns and would strand the future.
///
/// Never throws — a Firestore failure comes back as [AddItemOutcome.failed].
Future<AddItemResult> addSuggestionToList(
  Suggestion s, {
  required CollectionReference<Map<String, dynamic>> listRef,
  required String lang,
  required List<Map<String, dynamic>> currentItems,
  bool trackContributions = false,
  bool resolveInBackground = true,
}) async {
  if (s.displayName.trim().isEmpty) {
    return const AddItemResult(AddItemOutcome.failed);
  }

  final target = combineTarget(s, currentItems);
  if (target != null) {
    final existing = readQuantity(target['quantity']);
    final existingQty = existing?.qty ?? 1;
    final existingUnitId = existing?.unitId ?? kDefaultUnitId;
    // A bare add (no stated amount) adds one in whatever unit the item already
    // uses; a stated amount adds in its own unit, which combineTarget has
    // already matched against the item.
    final addUnitId = s.quantity == null ? existingUnitId : s.unitId;
    final addQty = s.quantity ?? 1;

    try {
      await listRef.doc(target['id'] as String).update({
        'quantity': {addUnitId: (existingQty + addQty).toDouble()},
        // Only the amount this add contributed is attributed — whatever was
        // already on the item keeps its existing owner (a plan, or the other
        // partner).
        if (trackContributions) ...manualDelta(addUnitId, addQty),
      });
      return AddItemResult(
        AddItemOutcome.combined,
        displayName: (target['displayName'] ?? s.displayName).toString(),
        itemId: target['id'] as String,
      );
    } catch (e) {
      // Deliberately *not* falling through to creating a new document: a failed
      // merge that silently became a second identical row would be worse than
      // the caller reporting that nothing happened.
      debugPrint('Combining "${s.displayName}" into an existing item failed: $e');
      return const AddItemResult(AddItemOutcome.failed);
    }
  }

  try {
    final ref = await listRef.add({
      'ingredientId': s.ingredientId,
      'displayName': s.displayName,
      'description': s.description,
      'doneAt': null,
      'createdAt': FieldValue.serverTimestamp(),
      'quantity': s.quantityMap,
      'category': s.category,
      if (trackContributions)
        if (manualQuantitiesSeed(s.unitId, s.quantity) case final seed?)
          kManualQuantitiesField: seed,
    });

    final resolution = _resolveAfterUse(ref, s, lang);
    if (!resolveInBackground) await resolution;

    return AddItemResult(
      AddItemOutcome.added,
      displayName: s.displayName,
      itemId: ref.id,
    );
  } catch (e) {
    debugPrint('Adding "${s.displayName}" to the list failed: $e');
    return const AddItemResult(AddItemOutcome.failed);
  }
}

/// After an item was written: resolve a pending ingredient id, and for matched
/// ones pull the ingredient doc from the server (new synonyms land in the
/// cache); if the doc was deleted meanwhile, re-resolve and fix the item.
Future<void> _resolveAfterUse(
  DocumentReference<Map<String, dynamic>> ref,
  Suggestion s,
  String lang,
) async {
  if (s.ingredientId == kPendingIngredient) {
    await resolvePendingItem(ref, s.displayName, lang);
    return;
  }
  final id = await IngredientIndex.instance
      .refreshAfterUse(s.ingredientId, s.displayName, lang);
  if (id == s.ingredientId) return;
  // ingredientId changed (doc was deleted + re-resolved) — also update category.
  final updates = <String, dynamic>{'ingredientId': id};
  if (id != kPendingIngredient && id != kUnknownIngredient) {
    // Looking up a known id's category, not offering suggestions — the
    // `suggest` filter would only hide the very doc we're after.
    final candidates = await IngredientIndex.instance
        .match(s.displayName, lang, includeUnsuggested: true);
    final matched = candidates.where((m) => m.id == id).firstOrNull;
    if (matched != null) updates['category'] = matched.category(lang);
  }
  try {
    await ref.update(updates);
  } catch (_) {}
}
