import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/recipe_localization.dart';
import 'package:couple_planner/features/recipes/widgets/add_to_shopping_list_dialog.dart'
    show AddToShoppingListDialogState, IngPreload;

/// Where a meal-plan day's recipe comes from.
enum MealPlanSource { own, public, newIdea }

MealPlanSource _sourceFromString(String s) {
  switch (s) {
    case 'own':
      return MealPlanSource.own;
    case 'public':
      return MealPlanSource.public;
    default:
      return MealPlanSource.newIdea;
  }
}

String _sourceToString(MealPlanSource s) {
  switch (s) {
    case MealPlanSource.own:
      return 'own';
    case MealPlanSource.public:
      return 'public';
    case MealPlanSource.newIdea:
      return 'new';
  }
}

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

/// One proposed (or already-committed) day in a generated meal plan.
class MealPlanSlot {
  final DateTime date;
  MealPlanSource source;
  String? recipeId; // set for `own`; also set for `newIdea` once generation starts
  String? publicRecipeId;
  String? publicImage;
  String name;
  String? description;
  String reason;
  List<String> dietary;

  /// Client-only: excluded from the batch when true, kept around (not
  /// deleted) so the overview can offer an undo before confirm.
  bool removed = false;

  /// Client-only: true while a swap for this single day is in flight.
  bool regenerating = false;

  MealPlanSlot({
    required this.date,
    required this.source,
    this.recipeId,
    this.publicRecipeId,
    this.publicImage,
    required this.name,
    this.description,
    required this.reason,
    this.dietary = const [],
  });

  factory MealPlanSlot.fromJson(DateTime date, Map<String, dynamic> json) {
    final rawDescription = (json['description'] as String?)?.trim();
    return MealPlanSlot(
      date: date,
      source: _sourceFromString((json['source'] ?? '').toString()),
      recipeId: json['recipeId'] as String?,
      publicRecipeId: json['publicRecipeId'] as String?,
      publicImage: json['image'] as String?,
      name: (json['name'] ?? '').toString(),
      description: (rawDescription != null && rawDescription.isNotEmpty) ? rawDescription : null,
      reason: (json['reason'] ?? '').toString(),
      dietary: List<String>.from(json['dietary'] ?? const []),
    );
  }
}

/// A day already written to Firestore (recipe + cooking_plan created).
class MealPlanCommittedSlot {
  final DateTime date;
  final String recipeId;
  final DocumentReference<Map<String, dynamic>> planRef;
  const MealPlanCommittedSlot(this.date, this.recipeId, this.planRef);
}

/// Calls `recipes-generateMealPlan`. Reused for the initial proposal, a
/// single-day swap and a full regenerate — callers just vary
/// [regenerateDates]/[lockedSlots]/[avoidNames]. The server re-derives which
/// dates are actually empty, so the returned slots may cover fewer dates than
/// requested (e.g. another group member filled one in the meantime).
Future<List<MealPlanSlot>> generateMealPlan({
  required String groupId,
  required DateTime startDate,
  required int days,
  required int people,
  required List<String> dietary,
  required List<String> styles,
  String notes = '',
  required List<DateTime> regenerateDates,
  List<MealPlanSlot> lockedSlots = const [],
  List<String> avoidNames = const [],
  required String lang,
}) async {
  final res = await _functions.httpsCallable('recipes-generateMealPlan').call(<String, dynamic>{
    'groupId': groupId,
    'startDate': _dateKey(startDate),
    'days': days,
    'people': people,
    'dietary': dietary,
    'styles': styles,
    'notes': notes,
    'regenerateDates': regenerateDates.map(_dateKey).toList(),
    'lockedSlots': [
      for (final s in lockedSlots) {'source': _sourceToString(s.source), 'name': s.name},
    ],
    'avoidNames': avoidNames,
    'lang': lang,
  });
  final data = Map<String, dynamic>.from(res.data as Map);
  final rawSlots = List<dynamic>.from(data['slots'] ?? const []);
  final dates = List<String>.from(data['generatedDates'] ?? const []);

  final slots = <MealPlanSlot>[];
  for (int i = 0; i < dates.length && i < rawSlots.length; i++) {
    final parts = dates[i].split('-').map(int.parse).toList();
    final date = DateTime(parts[0], parts[1], parts[2]);
    slots.add(MealPlanSlot.fromJson(date, Map<String, dynamic>.from(rawSlots[i] as Map)));
  }
  return slots;
}

/// Creates a bare recipe doc and fires the staged-generation callable for a
/// brand-new idea, mirroring RecipePage's own AI-suggestion flow
/// (`_createRecipeDoc` + `recipes-generateRecipeStaged`). Returns the new
/// recipe id immediately — the id is generated client-side and the write is
/// fire-and-forget, matching how RecipePage already does this for suggestion
/// taps/drags. Generation continues in the background; await
/// [_awaitIngredientsReady] before the recipe's ingredients are needed.
String startNewIdeaGeneration({
  required DocumentReference<Map<String, dynamic>> group,
  required String uid,
  required String name,
  required int servings,
  required String lang,
}) {
  final ref = group.collection('recipes').doc();
  ref.set({
    'name': name,
    'description': '',
    'creator': uid,
    'createdAt': FieldValue.serverTimestamp(),
    'lastUsedAt': null,
    'preparationTime': 0,
    'time': 0,
    'servings': servings,
    'tags': <String>[],
    'images': <String>[],
    'steps': <String>[],
  });
  _functions.httpsCallable('recipes-generateRecipeStaged').call(<String, dynamic>{
    'groupId': group.id,
    'recipeId': ref.id,
    'source': 'name',
    'prompt': name,
    'lang': lang,
    'targetServings': servings,
  }).ignore();
  return ref.id;
}

/// Waits until [recipeRef]'s ingredients have finished generating, resolving
/// immediately if they already have (or were never staged, e.g. own/public
/// recipes). Mirrors RecipePage's `_awaitIngredientsStage`.
Future<void> _awaitIngredientsReady(DocumentReference<Map<String, dynamic>> recipeRef) async {
  final snap = await recipeRef.get();
  final pending = List<String>.from(snap.data()?['pending'] ?? const []);
  if (!pending.contains('ingredients')) return;

  final ready = Completer<void>();
  late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
  sub = recipeRef.snapshots().listen((snap) {
    final data = snap.data();
    if (data == null || ready.isCompleted) return;
    if (data['generationError'] == true) {
      ready.completeError(Exception('Recipe generation failed'));
      return;
    }
    if (!data.containsKey('pending')) return;
    final p = List<String>.from(data['pending'] ?? const []);
    if (!p.contains('ingredients')) ready.complete();
  });
  try {
    await ready.future;
  } finally {
    sub.cancel();
  }
}

/// Writes every (non-removed) slot to Firestore: an existing own recipe just
/// gets a new cooking_plan doc; a public recipe is adopted (reusing
/// [adoptPublicRecipeFromPreload] verbatim) and then planned; a new idea's
/// recipe already exists from an earlier [startNewIdeaGeneration] call (fired
/// as soon as the overview showed the proposal) — this just waits for its
/// ingredients if they aren't ready yet, then plans it. Every created plan's
/// `servings` is [people], regardless of the recipe's own stored default.
Future<List<MealPlanCommittedSlot>> commitMealPlan({
  required DocumentReference<Map<String, dynamic>> group,
  required String uid,
  required String lang,
  required int people,
  required List<MealPlanSlot> slots,
  Map<String, Future<PublicRecipePreload>>? publicPreloads,
}) async {
  return Future.wait(slots.map((slot) async {
    final ts =
        Timestamp.fromDate(DateTime(slot.date.year, slot.date.month, slot.date.day, 12));
    String recipeId;
    switch (slot.source) {
      case MealPlanSource.own:
        recipeId = slot.recipeId!;
        break;
      case MealPlanSource.public:
        final preloadFuture =
            publicPreloads?[slot.publicRecipeId] ?? preloadPublicRecipe(slot.publicRecipeId!);
        final preload = await preloadFuture;
        final result = await adoptPublicRecipeFromPreload(
          groupId: group.id,
          publicRecipeId: slot.publicRecipeId!,
          preload: preload,
          uid: uid,
          lang: lang,
        );
        result.imageUpload.ignore();
        recipeId = result.recipeId;
        break;
      case MealPlanSource.newIdea:
        recipeId = slot.recipeId ??
            startNewIdeaGeneration(
                group: group, uid: uid, name: slot.name, servings: people, lang: lang);
        await _awaitIngredientsReady(group.collection('recipes').doc(recipeId));
        break;
    }
    final planRef = group.collection('cooking_plan').doc();
    await planRef.set({'recipe': recipeId, 'plannedFor': ts, 'servings': people});
    return MealPlanCommittedSlot(slot.date, recipeId, planRef);
  }));
}

/// One ingredient row in the multi-recipe shopping-list review, scaled to the
/// section's current [MealPlanRecipeSection.servings].
class MealPlanIngredientRow {
  final String id; // ingredientId
  final String name;
  final String description;
  final String category;
  final String unit;
  final Map<String, num?> base; // amounts at the recipe's own base servings
  Map<String, num?> cur; // amounts scaled to the section's current servings
  bool added;

  MealPlanIngredientRow({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.unit,
    required this.base,
    required this.added,
  }) : cur = Map.of(base);
}

/// One committed day's ingredient rows in the shopping-list review page.
class MealPlanRecipeSection {
  final DateTime date;
  final String recipeId;
  final String recipeName;
  final List<String> images;
  final DocumentReference<Map<String, dynamic>> planRef;
  final int baseServings; // servings the recipe's own ingredient quantities correspond to
  int servings;
  final List<MealPlanIngredientRow> rows;

  MealPlanRecipeSection({
    required this.date,
    required this.recipeId,
    required this.recipeName,
    required this.images,
    required this.planRef,
    required this.baseServings,
    required this.servings,
    required this.rows,
  });

  /// Rescales every row's [MealPlanIngredientRow.cur] from [base] to
  /// [servings], mirroring AddToShoppingListDialogState's `_rescale`.
  void rescale() {
    final base = baseServings < 1 ? 1 : baseServings;
    final ratio = servings / base;
    for (final row in rows) {
      row.cur = row.base.map(
        (k, v) => MapEntry(k, v == null ? null : ((v * ratio) * 100).round() / 100.0),
      );
    }
  }
}

/// Loads one [MealPlanRecipeSection] per committed slot in parallel, reusing
/// the existing, unchanged [AddToShoppingListDialogState.loadRows]. Each
/// section starts scaled to [people] (the batch's requested serving count),
/// not the recipe's own stored default.
Future<List<MealPlanRecipeSection>> loadShoppingSections({
  required DocumentReference<Map<String, dynamic>> group,
  required List<MealPlanCommittedSlot> committed,
  required int people,
}) {
  return Future.wait(committed.map((c) async {
    final recipeRef = group.collection('recipes').doc(c.recipeId);
    final recipeFuture = recipeRef.get();
    final rowsFuture = AddToShoppingListDialogState.loadRows(group, c.recipeId);
    final recipeSnap = await recipeFuture;
    final List<IngPreload> preload = await rowsFuture;

    final data = localizeRecipeData(
        recipeSnap.data() ?? {}, LanguageService.instance.code.value);
    final section = MealPlanRecipeSection(
      date: c.date,
      recipeId: c.recipeId,
      recipeName: (data['name'] ?? '').toString(),
      images: List<String>.from(data['images'] ?? const []),
      planRef: c.planRef,
      baseServings: (data['servings'] as num?)?.toInt() ?? 2,
      servings: people,
      rows: [
        for (final p in preload)
          MealPlanIngredientRow(
            id: p.id,
            name: p.name,
            description: p.description,
            category: p.category,
            unit: p.unit,
            base: p.base,
            added: p.added,
          ),
      ],
    );
    section.rescale();
    return section;
  }));
}

/// Merges ingredient contributions from every entry in [sections] into the
/// group's shopping list and records each plan's own contribution on its
/// cooking_plan doc. Rows across recipes that share an `ingredientId` are
/// summed into a single shared shopping-list doc, while each plan's own
/// `itemIds`/`quantities` still reflects only what THAT recipe contributed —
/// so a later single-plan removal (RecipePage._removePlan) subtracts the
/// right amount rather than the merged total.
Future<void> applyIngredientContributions({
  required DocumentReference<Map<String, dynamic>> group,
  required List<MealPlanRecipeSection> sections,
}) async {
  final totals = <String, Map<String, num>>{};
  final meta = <String, (String name, String category)>{};
  final perSectionRows = <List<(String id, Map<String, num> q)>>[];

  for (final section in sections) {
    final rows = <(String, Map<String, num>)>[];
    for (final row in section.rows.where((r) => r.added)) {
      final q = <String, num>{};
      row.cur.forEach((k, v) {
        if (v != null && v > 0) q[k] = v;
      });
      rows.add((row.id, q));
      final total = totals.putIfAbsent(row.id, () => <String, num>{});
      q.forEach((k, v) => total[k] = (total[k] ?? 0) + v);
      meta.putIfAbsent(row.id, () => (row.name, row.category));
    }
    perSectionRows.add(rows);
  }

  final ids = totals.keys.toList();
  final existing = await Future.wait([
    for (final id in ids) group.collection('shopping_list').where('ingredientId', isEqualTo: id).get(),
  ]);

  final batch = FirebaseFirestore.instance.batch();
  final itemRefFor = <String, DocumentReference<Map<String, dynamic>>>{};
  for (int i = 0; i < ids.length; i++) {
    final id = ids[i];
    final total = totals[id]!;
    final active = existing[i].docs.where((d) => d.data()['doneAt'] == null).toList();
    final DocumentReference<Map<String, dynamic>> itemRef;
    if (active.isNotEmpty) {
      itemRef = active.first.reference;
      final cur = Map<String, dynamic>.from(active.first['quantity'] ?? {});
      total.forEach((k, v) => cur[k] = ((cur[k] ?? 0) as num) + v);
      batch.update(itemRef, {'quantity': cur.isEmpty ? null : cur});
    } else {
      itemRef = group.collection('shopping_list').doc();
      batch.set(itemRef, {
        'ingredientId': id,
        'displayName': meta[id]!.$1,
        'description': '',
        'createdAt': FieldValue.serverTimestamp(),
        'quantity': total.isEmpty ? null : total,
        'doneAt': null,
        'category': meta[id]!.$2,
      });
    }
    itemRefFor[id] = itemRef;
  }

  for (int i = 0; i < sections.length; i++) {
    final itemIds = <String>[];
    final quantities = <Map<String, num>>[];
    for (final row in perSectionRows[i]) {
      itemIds.add(itemRefFor[row.$1]!.id);
      quantities.add(row.$2);
    }
    batch.update(sections[i].planRef, {'itemIds': itemIds, 'quantities': quantities});
  }
  await batch.commit();
}
