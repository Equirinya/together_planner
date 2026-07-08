import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kDefaultUnitId;
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart' show UnitsCache;
import 'package:couple_planner/features/ingredients/widgets/avatar.dart' show Avatar;
import 'package:couple_planner/features/ingredients/models/categories.dart' show categoryRank;

/// Immutable snapshot of a recipe ingredient used to (pre)load the shopping
/// list dialog: id, localised name, base quantities, default add flag and
/// category. Kept separate from [_IngRow] so cached preloads stay pristine
/// across repeated drags while each dialog gets its own mutable rows.
class IngPreload {
  final String id;
  final String name;
  final String description;
  final Map<String, num?> base;
  final bool added;
  final String category;
  final String unit; // default unit to seed a quantity from when there is none
  const IngPreload(this.id, this.name, this.description, this.base, this.added,
      this.category, this.unit);
}

class _IngRow {
  final String id;
  final String name;
  final String description;
  final Map<String, num?> base; // amounts at the recipe's base servings
  Map<String, num?> cur; // amounts scaled to the current servings selector
  bool added;
  final String category;
  final String unit; // default unit to seed a quantity from when there is none

  _IngRow(this.id, this.name, this.description, this.base, this.added,
      this.category, this.unit)
      : cur = Map.of(base);
}

class AddToShoppingListDialog extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> group;
  final String recipeId;
  final DocumentReference<Map<String, dynamic>> planRef;
  final int recipeServings;
  final List<IngPreload> preloadedRows;

  const AddToShoppingListDialog({
    super.key,
    required this.group,
    required this.recipeId,
    required this.planRef,
    required this.recipeServings,
    required this.preloadedRows,
  });

  @override
  State<AddToShoppingListDialog> createState() => AddToShoppingListDialogState();
}

class AddToShoppingListDialogState extends State<AddToShoppingListDialog> {
  bool saving = false;
  late int servings = widget.recipeServings < 1 ? 1 : widget.recipeServings;
  final List<_IngRow> rows = [];

  @override
  void initState() {
    super.initState();
    for (final p in widget.preloadedRows) {
      rows.add(_IngRow(
          p.id, p.name, p.description, p.base, p.added, p.category, p.unit));
    }
    _rescale();
  }

  /// Loads the shopping-list rows for [recipeId]: each recipe ingredient with
  /// its base quantity, localised name, category and a default add/skip flag.
  /// Extracted so it can be kicked off as soon as a recipe drag starts and
  /// reused when the dialog opens. Returns an empty list when there are none.
  static Future<List<IngPreload>> loadRows(
      DocumentReference<Map<String, dynamic>> group,
      String recipeId,
      ) async {
    // Kick off the independent reads concurrently: the units cache, the
    // recipe's ingredients, and the recipe's past cooking plans.
    final unitsFuture = UnitsCache.instance.ensureLoaded();
    final ingFuture = group
        .collection('recipes')
        .doc(recipeId)
        .collection('ingredients')
        .get();
    final pastFuture = group
        .collection('cooking_plan')
        .where('recipe', isEqualTo: recipeId)
        .get();

    final ingSnap = await ingFuture;
    if (ingSnap.docs.isEmpty) return const <IngPreload>[];

    // Determine per-ingredient add/skip preference from up to 5 past plans.
    // Only plans that actually went through the ingredient-adding flow carry a
    // signal: those have an itemIds field (an empty array when nothing was
    // added). Plans from older app versions — and plans where the add dialog
    // was skipped — have no itemIds field at all and are excluded, so they
    // don't dilute the majority calculation.
    final pastSnap = await pastFuture;
    final past = pastSnap.docs
        .where((d) => d.data().containsKey('itemIds'))
        .toList()
      ..sort((a, b) =>
          (b['plannedFor'] as Timestamp).compareTo(a['plannedFor'] as Timestamp));
    final recent = past.take(5).toList();

    // Past plans record the shopping-list item ids they contributed to
    // (itemIds), so resolve each item back to its ingredientId. Items removed
    // since are simply skipped.
    final allItemIds = <String>{
      for (final p in recent)
        ...List<String>.from(p.data()['itemIds'] ?? const []),
    };
    final itemToIng = <String, String>{};
    await Future.wait(allItemIds.map((itemId) async {
      final snap = await group.collection('shopping_list').doc(itemId).get();
      final ingId = snap.data()?['ingredientId'];
      if (ingId != null) itemToIng[itemId] = ingId.toString();
    }));
    final recentAdded = <Set<String>>[
      for (final p in recent)
        {
          for (final itemId in List<String>.from(p.data()['itemIds'] ?? const []))
            if (itemToIng.containsKey(itemId)) itemToIng[itemId]!,
        },
    ];

    // Fetch every ingredient's master document in parallel rather than one at a
    // time. Future.wait preserves order, so the rows stay in recipe order.
    final preload = await Future.wait(ingSnap.docs.map((ing) async {
      final id = ing['ingredientId'].toString();
      final description = (ing.data()['description'] ?? '').toString();

      final ingDoc =
      await FirebaseFirestore.instance.collection('ingredients').doc(id).get();
      final ingData = ingDoc.data();
      final category = (ingData?['category'] ?? '').toString();
      final rawUnit = (ingData?['defaultUnit'] ?? '').toString();
      final unit = rawUnit.isEmpty ? kDefaultUnitId : rawUnit;
      final name = (ing.data()['displayName'] ?? ingData?['name']?['en'] ?? id).toString();

      // A quantity map with a real amount is used as-is (a null amount for a
      // present unit is treated as 1). A missing, empty, or zero quantity is
      // kept as no quantity — the ingredient is still added to the shopping
      // list, just without an amount.
      final base = <String, num?>{};
      final rawQuantity = ing.data()['quantity'] as Map?;
      if (rawQuantity != null && rawQuantity.isNotEmpty) {
        rawQuantity.forEach(
              (k, v) => base[k.toString()] = v == null ? 1 : v as num,
        );
      }

      final bool added;
      if (recent.isEmpty) {
        // First time: add everything except spices/herbs and condiments/sauces.
        added = category != 'spices_and_herbs' &&
            category != 'condiments_and_sauces';
      } else {
        // Majority of the last 5 plans; ties favour adding.
        final addCount = recentAdded.where((s) => s.contains(id)).length;
        added = addCount * 2 >= recent.length;
      }
      return IngPreload(id, name, description, base, added, category, unit);
    }).toList());

    await unitsFuture;
    return preload;
  }

  void _rescale() {
    final base = widget.recipeServings < 1 ? 1 : widget.recipeServings;
    final ratio = servings / base;
    for (final row in rows) {
      row.cur = row.base.map(
            (k, v) => MapEntry(k, v == null ? null : ((v * ratio) * 100).round() / 100.0),
      );
    }
  }

  String _fmt(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Future<void> _submit() async {
    setState(() => saving = true);
    // Record which shopping-list items this plan contributed to, and how much,
    // as parallel arrays on the plan document (replaces the old
    // added_ingredients subcollection). The arrays are always written here —
    // empty when nothing was added — so the plan is marked as having gone
    // through the add flow. Skipped plans (and plans from older app versions)
    // keep these fields absent instead, and are ignored by the heuristic.
    // Collect the kept rows (with their positive amounts, if any), then look up
    // their existing shopping-list entries in parallel (reads can't go in a
    // batch). A kept row with no positive amount is added without a quantity.
    final pending = <(_IngRow, Map<String, num>)>[];
    for (final row in rows.where((r) => r.added)) {
      final q = <String, num>{};
      row.cur.forEach((k, v) {
        if (v != null && v > 0) q[k] = v;
      });
      pending.add((row, q));
    }
    final existing = await Future.wait([
      for (final p in pending)
        widget.group
            .collection('shopping_list')
            .where('ingredientId', isEqualTo: p.$1.id)
            .get(),
    ]);

    // Apply every shopping-list write and the plan update as one atomic batch.
    final batch = FirebaseFirestore.instance.batch();
    final itemIds = <String>[];
    final quantities = <Map<String, num>>[];
    for (int i = 0; i < pending.length; i++) {
      final row = pending[i].$1;
      final q = pending[i].$2;
      // Ignore completed entries: merge only into an active one, otherwise
      // create a fresh item so the ingredient reappears on the list.
      final active =
      existing[i].docs.where((d) => d.data()['doneAt'] == null).toList();
      final DocumentReference<Map<String, dynamic>> itemRef;
      if (active.isNotEmpty) {
        itemRef = active.first.reference;
        final cur = Map<String, dynamic>.from(active.first['quantity'] ?? {});
        q.forEach((k, v) => cur[k] = ((cur[k] ?? 0) as num) + v);
        batch.update(itemRef, {'quantity': cur.isEmpty ? null : cur});
      } else {
        itemRef = widget.group.collection('shopping_list').doc();
        batch.set(itemRef, {
          'ingredientId': row.id,
          'displayName': row.name,
          'description': '',
          'createdAt': FieldValue.serverTimestamp(),
          'quantity': q.isEmpty ? null : q,
          'doneAt': null,
          'category': row.category,
        });
      }
      itemIds.add(itemRef.id);
      quantities.add(q);
    }
    batch.update(widget.planRef, {'itemIds': itemIds, 'quantities': quantities});
    await batch.commit();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lang = LanguageService.instance.code.value;
    int cmp(_IngRow a, _IngRow b) {
      final c = categoryRank(a.category).compareTo(categoryRank(b.category));
      return c != 0 ? c : rows.indexOf(a).compareTo(rows.indexOf(b));
    }
    // Added first, then skipped; each group ordered by category.
    final ordered = [
      ...rows.where((r) => r.added).toList()..sort(cmp),
      ...rows.where((r) => !r.added).toList()..sort(cmp),
    ];
    final orderKey = ValueKey(ordered.map((r) => r.id).join('|'));

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Servings selector ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Add to shopping list',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: servings > 1
                      ? () => setState(() {
                    servings--;
                    _rescale();
                  })
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Text('$servings'),
                IconButton(
                  onPressed: () => setState(() {
                    servings++;
                    _rescale();
                  }),
                  icon: const Icon(Icons.add),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.people_outline),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Ingredient list ─────────────────────────────────────
          Flexible(
            child: ListView(
              key: orderKey,
              shrinkWrap: true,
              children: ordered.map((row) {
                final toggleIcon = Icon(
                  row.added
                      ? Icons.remove_shopping_cart
                      : Icons.add_shopping_cart,
                );
                final quantityText = row.cur.entries
                    .where((e) => e.value != null && e.value! > 0)
                    .map((e) =>
                '${_fmt(e.value!)} ${UnitsCache.instance.display(e.key, lang, e.value!)}')
                    .join(', ');
                return Dismissible(
                  key: ValueKey(row.id),
                  // Swiping toggles add/skip without removing the item.
                  confirmDismiss: (_) async {
                    setState(() => row.added = !row.added);
                    return false;
                  },
                  background: Container(
                    color: colorScheme.primaryContainer,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: toggleIcon,
                  ),
                  secondaryBackground: Container(
                    color: colorScheme.primaryContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: toggleIcon,
                  ),
                  child: Container(
                    color: row.added
                        ? null
                        : colorScheme.errorContainer.withAlpha(80),
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      minVerticalPadding: 8,
                      minTileHeight: 64,
                      leading: Avatar(ingredientId: row.id),
                      title: Text(row.name),
                      subtitle: row.description.isNotEmpty
                          ? Text(row.description)
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (quantityText.isNotEmpty)
                            IconButton(
                              iconSize: 18,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                              icon: const Icon(Icons.remove),
                              onPressed: () => setState(() {
                                row.cur = row.cur.map(
                                      (k, v) => MapEntry(
                                    k,
                                    v == null
                                        ? null
                                        : (v - UnitsCache.instance.increment(k))
                                        .clamp(0.0, double.infinity),
                                  ),
                                );
                              }),
                            ),
                          quantityText.isNotEmpty
                              ? Text(quantityText, style: Theme.of(context).textTheme.bodyLarge)
                              : Text('—', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: colorScheme.outline)),
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            icon: const Icon(Icons.add),
                            onPressed: () => setState(() {
                              // Seed a quantity for a no-amount row from the
                              // ingredient's default unit, so + works on items
                              // that were added without a quantity.
                              if (!row.cur.values.any((v) => v != null && v > 0)) {
                                row.cur = {
                                  row.unit: UnitsCache.instance.increment(row.unit)
                                };
                              } else {
                                row.cur = row.cur.map(
                                      (k, v) => MapEntry(
                                    k,
                                    v == null
                                        ? null
                                        : v + UnitsCache.instance.increment(k),
                                  ),
                                );
                              }
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(height: 1),
          // ── Actions ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: const Text('Skip'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: saving ? null : _submit,
                  child: saving
                      ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CupertinoActivityIndicator(),
                  )
                      : const Text('Add'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
