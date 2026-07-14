import 'dart:async';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/models/categories.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/widgets/avatar.dart';
import 'package:couple_planner/features/ingredients/widgets/ingredient_search_sheet.dart';
import 'package:couple_planner/features/ingredients/widgets/quantity_editor.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// Page
// =============================================================================

class ShoppingListPage extends StatefulWidget {
  final String groupId;
  const ShoppingListPage({super.key, required this.groupId});

  @override
  State<ShoppingListPage> createState() => _ShoppingListPageState();
}

class _ShoppingListPageState extends State<ShoppingListPage> {
  final _db = FirebaseFirestore.instance;

  late final String _lang;

  /// Live copy of the shopping list — kept in sync by _listSub.
  List<Map<String, dynamic>> _currentItems = [];
  StreamSubscription? _listSub;

  final Set<String> _optimisticallyHidden = {};

  /// Items created before this session opened are not "new".
  /// Null until loaded — during the async gap nothing shows as new.
  DateTime? _lastSeen;

  CollectionReference<Map<String, dynamic>> get _listRef =>
      _db.collection('groups').doc(widget.groupId).collection('shopping_list');

  // ── lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _lang = LanguageService.instance.code.value;
    UnitsCache.instance.ensureLoaded();
    _initLastSeen();
    _startListSubscription(); // also resolves any pre-existing pending items
  }

  Future<void> _initLastSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt('shopping_last_seen_${widget.groupId}');
    if (mounted && stored != null) {
      setState(() => _lastSeen = DateTime.fromMillisecondsSinceEpoch(stored));
    }
  }

  /// Called after every Firestore snapshot so the saved timestamp is always
  /// >= any createdAt we've actually seen. Even if the app is killed, the next
  /// session won't treat already-visible items as new.
  Future<void> _persistSeenNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'shopping_last_seen_${widget.groupId}',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  void dispose() {
    _listSub?.cancel();
    super.dispose();
  }

  void _startListSubscription() {
    _listSub = _listRef.snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _currentItems = snap.docs
            .map((d) => <String, dynamic>{...d.data(), 'id': d.id})
            .toList();
        // Once the done state is confirmed (or the item is gone), drop the
        // optimistic hide — otherwise a later restore (doneAt → null) from the
        // search sheet would stay hidden.
        final byId = {for (final i in _currentItems) i['id'] as String: i};
        _optimisticallyHidden.removeWhere(
              (id) => byId[id] == null || byId[id]!['doneAt'] != null,
        );
      });
      // Persist "now" after each confirmed snapshot so the saved timestamp is
      // always >= any createdAt the user has actually seen on screen.
      _persistSeenNow();
      // Resolve any pending items (new arrivals and pre-existing ones).
      // De-duplication is handled inside resolvePendingItem.
      for (final item in _currentItems) {
        if (item['ingredientId'] == kPendingIngredient) {
          resolvePendingItem(
            _listRef.doc(item['id'] as String),
            (item['displayName'] ?? '').toString(),
            _lang,
          );
        }
      }
    }, onError: (Object e) => debugPrint('Shopping list listener error: $e'));
  }

  // ── item mutations ─────────────────────────────────────────────────────────

  Future<void> _markDone(Map<String, dynamic> item) async {
    final id = item['id'] as String;
    setState(() => _optimisticallyHidden.add(id));
    try {
      await _listRef.doc(id).update({'doneAt': FieldValue.serverTimestamp()});
    } catch (_) {
      if (mounted) setState(() => _optimisticallyHidden.remove(id));
    }
  }

  Future<void> _updateQuantity(String id, String unitId, num? qty) =>
      _listRef.doc(id).update(
          {'quantity': qty == null ? null : {unitId: qty.toDouble()}});

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final active = _currentItems
        .where((i) => i['doneAt'] == null && !_optimisticallyHidden.contains(i['id']))
        .toList();

    // ── group by category ──────────────────────────────────────────────────
    final Map<String, List<Map<String, dynamic>>> groups = {};
    for (final item in active) {
      final cat = (item['category'] as String?)?.trim() ?? '';
      (groups[cat] ??= []).add(item);
    }

    // Within each group: oldest at top, newest (null = optimistic add) at bottom.
    for (final list in groups.values) {
      list.sort((a, b) {
        final ta = a['createdAt'] as Timestamp?;
        final tb = b['createdAt'] as Timestamp?;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return ta.compareTo(tb);
      });
    }

    // Categories in supermarket-walk order; empty/uncategorised goes last.
    int catRank(String c) {
      final i = kCategories.indexOf(c.isEmpty ? 'other' : c);
      return i == -1 ? kCategories.length : i;
    }
    final sortedCats = groups.keys.toList()
      ..sort((a, b) => catRank(a).compareTo(catRank(b)));

    const showHeaders = true;

    bool isNew(Map<String, dynamic> item) {
      final created = item['createdAt'] as Timestamp?;
      return _lastSeen != null &&
          created != null &&
          created.toDate().isAfter(_lastSeen!);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: active.isEmpty
              ? const Center(child: Text('Your shopping list is empty.'))
              : ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final cat in sortedCats) ...[
                if (showHeaders)
                  _CategoryHeader(category: cat.isEmpty ? 'other' : cat),
                for (final item in groups[cat]!)
                  _ShoppingItem(
                    key: ValueKey(item['id']),
                    item: item,
                    groupId: widget.groupId,
                    lang: _lang,
                    isNew: isNew(item),
                    onMarkDone: () => _markDone(item),
                    onQuantityChanged: (u, q) =>
                        _updateQuantity(item['id'] as String, u, q),
                  ),
              ],
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: _AddItemBar(
              onTap: () => IngredientSearchSheet.show(
                context,
                targetRef: _listRef,
                lang: _lang,
                hintText: 'Add item to shopping list',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Section separator: a small category icon followed by a hairline divider.
class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category});
  final String category;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.primary,
            child: StorageImage(
              storagePath: 'categories/$category.png',
              fit: BoxFit.contain,
              memCacheWidth: 64,
              memCacheHeight: 64,
              errorWidget: const SizedBox.shrink(),
              placeholder: const SizedBox.shrink(),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1)),
        ],
      ),
    );
  }
}

/// Tappable bar at the bottom of the list that opens the search sheet.
class _AddItemBar extends StatefulWidget {
  const _AddItemBar({required this.onTap});
  final Future<void> Function() onTap;

  @override
  State<_AddItemBar> createState() => _AddItemBarState();
}

class _AddItemBarState extends State<_AddItemBar> {
  // Keep the bar acting as a button: tapping fires onTap and shows the ink
  // ripple, but never focuses the field or raises the keyboard.
  final _focusNode = FocusNode(canRequestFocus: false);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    await widget.onTap();
    // The closing sheet restores focus to this bar on the next frame; clear it
    // afterwards so the keyboard doesn't reopen here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      // The bar is purely a button: absorbing pointers stops the underlying
      // field from focusing or showing the selection toolbar on long press.
      // The InkWell overlay restores the tap ripple on top of the bar.
      child: Stack(
        children: [
          AbsorbPointer(
            child: SearchBar(
              focusNode: _focusNode,
              constraints: const BoxConstraints(minWidth: double.infinity, minHeight: 56),
              elevation: const WidgetStatePropertyAll(0),
              shape: const WidgetStatePropertyAll(StadiumBorder()),
              hintText: 'Add item to shopping list',
              leading: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.search, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: _handleTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Shopping item row
// =============================================================================

class _ShoppingItem extends StatelessWidget {
  const _ShoppingItem({
    super.key,
    required this.item,
    required this.groupId,
    required this.lang,
    required this.isNew,
    required this.onMarkDone,
    required this.onQuantityChanged,
  });

  final Map<String, dynamic> item;
  final String groupId;
  final String lang;
  final bool isNew;
  final VoidCallback onMarkDone;
  final Future<void> Function(String unitId, num? qty) onQuantityChanged;

  @override
  Widget build(BuildContext context) {
    final q = readQuantity(item['quantity']);
    final cs = Theme.of(context).colorScheme;

    return Dismissible(
      key: ValueKey('dismiss_${item['id']}'),
      direction: DismissDirection.horizontal,
      background: _doneBg(Alignment.centerLeft),
      secondaryBackground: _doneBg(Alignment.centerRight),
      confirmDismiss: (_) async {
        onMarkDone();
        return false;
      },
      child: Container(
        decoration: isNew
            ? BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              cs.secondaryContainer.withValues(alpha: 0.0),
              cs.secondaryContainer.withValues(alpha: 0.3),
            ],
          ),
        )
            : null,
        child: ListTile(
          onLongPress: () => _showRecipeSources(context),
          leading: Avatar(
            ingredientId: (item['ingredientId'] ?? kUnknownIngredient).toString(),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text((item['displayName'] ?? item['id'] ?? '').toString()),
              ),
              if (isNew) ...[
                const SizedBox(width: 8),
                Text('new', style: TextStyle(color: cs.secondary)),
              ],
            ],
          ),
          subtitle: (item['description'] as String?)?.isNotEmpty == true
              ? Text(item['description'] as String)
              : null,
          // The quantity/unit editor is opened from the right end whether or
          // not there is a quantity yet.
          trailing: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openQuantityEditor(context, q?.unitId, q?.qty),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: q == null
                  ? const SizedBox(width: 32, height: 32)
                  : Text(
                '${fmtQty(q.qty)} '
                    '${UnitsCache.instance.display(q.unitId, lang, q.qty)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _doneBg(Alignment align) => Container(
    color: Colors.green.shade600,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Align(
      alignment: align,
      child: const Icon(Icons.check, color: Colors.white),
    ),
  );

  void _openQuantityEditor(BuildContext context, String? unitId, num? qty) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => QuantityEditor(
        initialUnitId: unitId ?? kDefaultUnitId,
        initialQty: qty ?? 0, // start at 0 when no quantity was set
        lang: lang,
        onChanged: onQuantityChanged,
      ),
    );
  }

  void _showRecipeSources(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => _RecipeSourcesDialog(
        groupId: groupId,
        itemId: item['id'] as String,
        lang: lang,
        onOpenRecipe: (recipeId) {
          Navigator.of(dialogCtx).pop();
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                RecipeDetailPage(groupId: groupId, recipeId: recipeId),
          ));
        },
      ),
    );
  }
}

// =============================================================================
// Recipe sources popup
// =============================================================================

/// A single recipe that contributed this shopping-list item, with the summed
/// amount it added (across all its cooking plans).
class _RecipeSource {
  _RecipeSource({
    required this.recipeId,
    required this.name,
    required this.image,
    required this.quantity,
  });

  final String recipeId;
  final String name;
  final String? image;
  final Map<String, num> quantity;
}

/// Dialog listing the recipes a shopping-list item was added from. Each row
/// shows the recipe's cropped square image, its name and the amount it
/// contributed; tapping a row opens the recipe.
class _RecipeSourcesDialog extends StatelessWidget {
  const _RecipeSourcesDialog({
    required this.groupId,
    required this.itemId,
    required this.lang,
    required this.onOpenRecipe,
  });

  final String groupId;
  final String itemId;
  final String lang;
  final void Function(String recipeId) onOpenRecipe;

  Future<List<_RecipeSource>> _load() async {
    final db = FirebaseFirestore.instance;
    final group = db.collection('groups').doc(groupId);
    final plansSnap = await group
        .collection('cooking_plan')
        .where('itemIds', arrayContains: itemId)
        .get();

    // Sum the contributed amounts per recipe across all matching plans.
    final byRecipe = <String, Map<String, num>>{};
    for (final plan in plansSnap.docs) {
      final data = plan.data();
      final recipeId = (data['recipe'] ?? '').toString();
      if (recipeId.isEmpty) continue;
      final itemIds = List<String>.from(data['itemIds'] ?? const []);
      final quantities = List<dynamic>.from(data['quantities'] ?? const []);
      final idx = itemIds.indexOf(itemId);
      final agg = byRecipe.putIfAbsent(recipeId, () => <String, num>{});
      if (idx >= 0 && idx < quantities.length && quantities[idx] is Map) {
        (quantities[idx] as Map).forEach((k, v) {
          if (v is num) agg[k.toString()] = (agg[k.toString()] ?? 0) + v;
        });
      }
    }

    final sources = <_RecipeSource>[];
    await Future.wait(byRecipe.entries.map((e) async {
      final snap = await group.collection('recipes').doc(e.key).get();
      if (!snap.exists) return;
      final rd = snap.data()!;
      final imgs = List<String>.from(rd['images'] ?? const []);
      sources.add(_RecipeSource(
        recipeId: e.key,
        name: (rd['name'] ?? 'Unnamed Recipe').toString(),
        image: imgs.isNotEmpty ? imgs.first : null,
        quantity: e.value,
      ));
    }));
    return sources;
  }

  String _amountLabel(Map<String, num> q) => q.entries
      .map((e) =>
          '${fmtQty(e.value)} ${UnitsCache.instance.display(e.key, lang, e.value)}')
      .join(', ');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('From recipes'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<List<_RecipeSource>>(
          future: _load(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final sources = snap.data!;
            if (sources.isEmpty) {
              return const SizedBox(
                height: 80,
                child: Center(child: Text('This item is not from any recipe.')),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final s in sources)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: s.image == null
                            ? Icon(Icons.restaurant_menu,
                                color: Theme.of(context).colorScheme.onSurfaceVariant)
                            : StorageImage(
                                storagePath: s.image!,
                                fit: BoxFit.cover,
                                memCacheWidth: 96,
                              ),
                      ),
                    ),
                    title: Text(s.name),
                    subtitle: s.quantity.isEmpty ? null : Text(_amountLabel(s.quantity)),
                    onTap: () => onOpenRecipe(s.recipeId),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

