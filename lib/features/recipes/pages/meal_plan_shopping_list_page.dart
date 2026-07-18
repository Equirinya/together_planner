import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/models/categories.dart' show categoryRank;
import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';
import 'package:couple_planner/features/recipes/widgets/ingredient_row_tile.dart';

/// Multi-recipe version of the single-recipe "add to shopping list" dialog:
/// a single servings control for the whole batch, plus a single merged
/// ingredient list combining rows that share an ingredient across the
/// meal-plan's recipes — each still backed by the same, unchanged
/// AddToShoppingListDialogState.loadRows. Add/skip and quantity edits on a
/// merged row apply to every contributing recipe's own row at once, so
/// submitting still records each plan's own contribution separately via
/// [applyIngredientContributions].
class MealPlanShoppingListPage extends StatefulWidget {
  const MealPlanShoppingListPage({
    super.key,
    required this.groupDoc,
    required this.committed,
    required this.people,
  });

  final DocumentReference<Map<String, dynamic>> groupDoc;
  final List<MealPlanCommittedSlot> committed;
  final int people;

  @override
  State<MealPlanShoppingListPage> createState() => _MealPlanShoppingListPageState();
}

class _MealPlanShoppingListPageState extends State<MealPlanShoppingListPage> {
  List<MealPlanRecipeSection>? _sections;
  bool _saving = false;
  late int _people = widget.people;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sections = await loadShoppingSections(
      group: widget.groupDoc,
      committed: widget.committed,
      people: widget.people,
    );
    if (!mounted) return;
    setState(() => _sections = sections);
  }

  void _finish() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Skipping the shopping list still has to keep a servings change: the plans
  /// were committed with [widget.people], so leaving without saving would show
  /// the wrong count on the cooking plans. Fire-and-forget — the user is on
  /// their way out and a failed write only leaves the original count.
  void _skip() {
    final sections = _sections;
    if (sections != null && _people != widget.people) {
      saveSectionServings(sections).ignore();
    }
    _finish();
  }

  void _setPeople(int people) {
    final sections = _sections;
    if (sections == null || people < 1) return;
    _people = people;
    for (final section in sections) {
      section.servings = people;
      section.rescale();
    }
    setState(() {});
  }

  Future<void> _submit() async {
    final sections = _sections;
    if (sections == null) return;
    setState(() => _saving = true);
    try {
      await applyIngredientContributions(group: widget.groupDoc, sections: sections);
      if (mounted) _finish();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the shopping list.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final nonEmpty = sections?.where((s) => s.rows.isNotEmpty).toList();
    final merged = nonEmpty == null ? null : _mergeRows(nonEmpty);

    return Scaffold(
      appBar: AppBar(title: const Text('Add to shopping list')),
      body: sections == null
          ? const Center(child: CircularProgressIndicator())
          : nonEmpty!.isEmpty
              ? const Center(child: Text('Nothing to add — these recipes have no ingredients.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _ServingsHeader(people: _people, onChanged: _setPeople),
                    const SizedBox(height: 4),
                    _MergedIngredientsCard(rows: merged!, onChanged: () => setState(() {})),
                  ],
                ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _saving ? null : _skip,
                child: const Text('Skip'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: (sections == null || _saving) ? null : _submit,
                child: _saving
                    ? const SizedBox(
                        width: 18, height: 18, child: CupertinoActivityIndicator())
                    : const Text('Add to shopping list'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single servings control for the whole batch, scaling every recipe's
/// ingredients together now that they're merged into one list below.
class _ServingsHeader extends StatelessWidget {
  const _ServingsHeader({required this.people, required this.onChanged});
  final int people;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            const Expanded(child: Text('Servings')),
            IconButton(
              onPressed: people > 1 ? () => onChanged(people - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            Text('$people'),
            IconButton(
              onPressed: () => onChanged(people + 1),
              icon: const Icon(Icons.add),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.people_outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ingredient in the merged list: the same ingredient contributed by one
/// or more [MealPlanRecipeSection]s. Add/skip and quantity edits are applied
/// to every contributing row at once, so [applyIngredientContributions]
/// still sees each recipe's own, separate contribution when submitting.
class _MergedRow {
  _MergedRow({required this.id, required this.name, required this.description,
      required this.category, required this.contributors});

  final String id;
  final String name;
  final String description;
  final String category;
  final List<MealPlanIngredientRow> contributors;

  bool get added => contributors.any((r) => r.added);

  Map<String, num?> get cur {
    final out = <String, num?>{};
    for (final r in contributors) {
      r.cur.forEach((k, v) {
        if (v == null) return;
        out[k] = (out[k] ?? 0) + v;
      });
    }
    return out;
  }

  void toggle() {
    final next = !added;
    for (final r in contributors) {
      r.added = next;
    }
  }
}

/// Groups every non-skipped-from-display ingredient row across [sections] by
/// ingredientId, in first-seen order.
List<_MergedRow> _mergeRows(List<MealPlanRecipeSection> sections) {
  final byId = <String, _MergedRow>{};
  for (final section in sections) {
    for (final row in section.rows) {
      final existing = byId[row.id];
      if (existing != null) {
        existing.contributors.add(row);
      } else {
        byId[row.id] = _MergedRow(
          id: row.id,
          name: row.name,
          description: row.description,
          category: row.category,
          contributors: [row],
        );
      }
    }
  }
  return byId.values.toList();
}

class _MergedIngredientsCard extends StatelessWidget {
  const _MergedIngredientsCard({required this.rows, required this.onChanged});
  final List<_MergedRow> rows;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lang = LanguageService.instance.code.value;

    int cmp(_MergedRow a, _MergedRow b) {
      final c = categoryRank(a.category).compareTo(categoryRank(b.category));
      return c != 0 ? c : rows.indexOf(a).compareTo(rows.indexOf(b));
    }

    final ordered = [
      ...rows.where((r) => r.added).toList()..sort(cmp),
      ...rows.where((r) => !r.added).toList()..sort(cmp),
    ];

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in ordered)
            // Different units are kept on separate lines rather than joined
            // inline — for a merged row they usually come from different
            // recipes, so showing them run together (e.g. "6 pcs, 800g")
            // reads as one combined amount when they're really separate
            // quantities. No onIncrease/onDecrease: adjusting a merged
            // row's quantity is ambiguous across its contributing recipes.
            IngredientRowTile(
              key: ValueKey(row.id),
              id: row.id,
              name: row.name,
              description: row.description,
              added: row.added,
              cur: row.cur,
              lang: lang,
              onToggle: () {
                row.toggle();
                onChanged();
              },
              quantitySeparator: '\n',
            ),
        ],
      ),
    );
  }
}
