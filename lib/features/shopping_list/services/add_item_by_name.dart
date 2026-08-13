// "Put this on the shopping list", given nothing but a line of free text.
//
// This is the Siri / Shortcuts entry point: there is no BuildContext and no
// tapped suggestion, only a spoken phrase like "2 litres of milk". So all this
// does is get from that text to a [Suggestion] — the same object the search
// sheet hands over when a row is tapped — and pass it to [addSuggestionToList],
// which owns the write itself. Nothing about the merge rule, the document
// shape or the contribution attribution is restated here.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/features/ingredients/ingredient_parser.dart';
import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/services/item_writer.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';

export 'package:couple_planner/features/ingredients/services/item_writer.dart'
    show AddItemOutcome, AddItemResult;

/// Adds [text] to [groupId]'s shopping list, parsing a leading/trailing amount
/// and unit out of it the same way the search field does.
///
/// [lang] is the two-letter code the ingredient index should match against —
/// pass `LanguageService.instance.code.value`.
///
/// Never throws: a Firestore failure comes back as [AddItemOutcome.failed], so
/// an intent handler can answer Siri rather than crash out of a background
/// launch.
Future<AddItemResult> addShoppingItemByName(
  String text, {
  required String groupId,
  required String lang,
  FirebaseFirestore? firestore,
}) async {
  final raw = text.trim();
  if (raw.isEmpty) return const AddItemResult(AddItemOutcome.failed);

  final db = firestore ?? FirebaseFirestore.instance;
  final listRef =
      db.collection('groups').doc(groupId).collection('shopping_list');

  // parseInput consults the units cache to recognise "g", "litres", "Dose" …
  // On a cold launch from an intent nothing has warmed it yet.
  await UnitsCache.instance.ensureLoaded();

  final parsed = parseInput(raw);
  final name = parsed.remaining.join(' ').trim();
  if (name.isEmpty) return const AddItemResult(AddItemOutcome.failed);

  // Match against the ingredient index so the item lands in the right category
  // with the right icon. An unmatched name is stored as pending and resolved
  // after the write, exactly as a typed one would be.
  // The whole phrase was spoken/shared deliberately, so this identifies rather
  // than suggests: `suggest: false` ingredients stay eligible, they just rank
  // behind anything shoppable or named outright (same rule as resolveByName).
  final matches =
      await IngredientIndex.instance.match(name, lang, includeUnsuggested: true);
  MatchedIngredient? matched;
  for (final m in matches) {
    if (m.suggest || m.matchesExactly(name)) {
      matched = m;
      break;
    }
  }
  matched ??= matches.isEmpty ? null : matches.first;
  final matchedName = matched?.displayName(lang).trim() ?? '';

  final suggestion = Suggestion(
    ingredientId: matched?.id ?? kPendingIngredient,
    // Voice input carries no description — the whole phrase is the name.
    description: '',
    displayName: matchedName.isNotEmpty ? matchedName : capitalize(name),
    unitId: parsed.unitId ?? matched?.defaultUnit ?? kDefaultUnitId,
    quantity: parsed.quantity,
    category: matched?.category(lang) ?? '',
  );

  // The sheet resolves the merge against the snapshot it already holds; here
  // there is no such view, so the active items are read first. Done items are
  // irrelevant to the merge rule and the collection's history can be large.
  List<Map<String, dynamic>> active;
  try {
    final snap = await listRef.where('doneAt', isNull: true).get();
    active = snap.docs
        .map((d) => <String, dynamic>{...d.data(), 'id': d.id})
        .toList();
  } catch (_) {
    active = const [];
  }

  return addSuggestionToList(
    suggestion,
    listRef: listRef,
    lang: lang,
    currentItems: active,
    // The shopping list records who added what; an item added by voice is
    // attributed like any other.
    trackContributions: true,
    // Awaited: the engine this runs on can be torn down as soon as the intent
    // returns, which would strand a detached resolution.
    resolveInBackground: false,
  );
}
