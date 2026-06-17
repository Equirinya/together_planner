import 'dart:async';

import 'package:couple_planner/pages/ingredient_search.dart';
import 'package:couple_planner/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Categories ───────────────────────────────────────────────────────────────
// Matches the `category` field stored on ingredient docs.
// Ordered to follow a typical supermarket walk: produce first, frozen last.
const List<String> kCategories = [
  'fruits_and_vegetables',
  'bread_and_bakery',
  'meat_and_fish',
  'dairy_and_eggs',
  'grains_and_pasta',
  'canned_and_packaged_goods',
  'baking_ingredients',
  'nuts_and_seeds',
  'snacks_and_sweets',
  'beverages',
  'frozen_foods',
  'condiments_and_sauces',
  'spices_and_herbs',
  'hygiene',
  'other',
];

/// Rank of [category] in shopping-walk order; uncategorised/unknown sorts last.
int categoryRank(String category) {
  final c = category.trim();
  final i = kCategories.indexOf(c.isEmpty ? 'other' : c);
  return i == -1 ? kCategories.length : i;
}

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

  /// Items created after this moment are highlighted as "new" for the session.
  DateTime? _lastSeen;

  CollectionReference<Map<String, dynamic>> get _listRef =>
      _db.collection('groups').doc(widget.groupId).collection('shopping_list');

  // ── lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _lang = sanitizeLang(
      WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
    UnitsCache.instance.ensureLoaded();
    _loadLastSeen();
    _startListSubscription(); // also resolves any pre-existing pending items
  }

  Future<void> _loadLastSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'shopping_last_seen_${widget.groupId}';
    final stored = prefs.getInt(key);
    if (mounted && stored != null) {
      setState(() => _lastSeen = DateTime.fromMillisecondsSinceEpoch(stored));
    }
    await prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
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
    });
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

  Future<void> _updateQuantity(String id, String unitId, num qty) =>
      _listRef.doc(id).update({'quantity': {unitId: qty.toDouble()}});

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

    final showHeaders = groups.length > 1;

    bool isNew(Map<String, dynamic> item) {
      final created = item['createdAt'] as Timestamp?;
      return _lastSeen != null &&
          created != null &&
          created.toDate().isAfter(_lastSeen!);
    }

    return Column(
      children: [
        Expanded(
          child: active.isEmpty
              ? const Center(child: Text('Your shopping list is empty.'))
              : ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final cat in sortedCats) ...[
                if (showHeaders)
                  _CategoryHeader(category: cat.isEmpty ? 'other' : cat),
                for (final item in groups[cat]!)
                  _ShoppingItem(
                    key: ValueKey(item['id']),
                    item: item,
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
        SafeArea(
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
class _AddItemBar extends StatelessWidget {
  const _AddItemBar({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: GestureDetector(
        onTap: onTap,
        child: AbsorbPointer(
          child: SearchBar(
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            hintText: 'Add item to shopping list',
            leading: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.search, color: cs.onSurfaceVariant),
            ),
          ),
        ),
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
    required this.lang,
    required this.isNew,
    required this.onMarkDone,
    required this.onQuantityChanged,
  });

  final Map<String, dynamic> item;
  final String lang;
  final bool isNew;
  final VoidCallback onMarkDone;
  final Future<void> Function(String unitId, num qty) onQuantityChanged;

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
                    cs.secondaryContainer.withValues(alpha: 0.55),
                  ],
                ),
              )
            : null,
        child: ListTile(
        // When there's no quantity, tap the tile itself to set one.
        onTap: q == null ? () => _openQuantityEditor(context, null, null) : null,
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
        trailing: q == null
            ? null
            : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openQuantityEditor(context, q.unitId, q.qty),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
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
        initialQty: qty ?? 1, // start at 1 when no quantity was set
        lang: lang,
        onChanged: onQuantityChanged,
      ),
    );
  }
}

// =============================================================================
// Quantity editor (bottom sheet, floats above the number keyboard)
// =============================================================================

class QuantityEditor extends StatefulWidget {
  const QuantityEditor({
    required this.initialUnitId,
    required this.initialQty,
    required this.lang,
    required this.onChanged,
  });

  final String initialUnitId;
  final num initialQty;
  final String lang;
  // Called immediately on every action so changes survive even if the sheet is
  // dismissed via the keyboard close gesture.
  final Future<void> Function(String unitId, num qty) onChanged;

  @override
  State<QuantityEditor> createState() => _QuantityEditorState();
}

class _QuantityEditorState extends State<QuantityEditor> {
  late final TextEditingController _ctrl;
  late String _unitId;

  StreamSubscription<bool>? _kbSub;
  bool _keyboardWasVisible = false;

  num get _qty => num.tryParse(_ctrl.text.replaceAll(',', '.')) ?? 0;

  @override
  void initState() {
    super.initState();
    _unitId = widget.initialUnitId;
    final text = fmtQty(widget.initialQty);
    _ctrl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);

    // Close the sheet when the keyboard is dismissed — only after it opened once.
    _kbSub = KeyboardVisibilityController().onChange.listen((visible) {
      if (visible) {
        _keyboardWasVisible = true;
      } else if (_keyboardWasVisible && mounted) {
        final animation = ModalRoute.of(context)?.animation;
        final closing = animation?.status == AnimationStatus.reverse
            || animation?.status == AnimationStatus.dismissed;
        if (!closing) Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _kbSub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _bump(num delta) {
    final next = (_qty + delta).clamp(0, 1 << 31);
    setState(() => _ctrl.text = fmtQty(next));
    _push();
  }

  void _push() => widget.onChanged(_unitId, _qty);

  @override
  Widget build(BuildContext context) {
    final units = UnitsCache.instance.all;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).viewInsets.bottom + 12),
      child: Row(
        children: [
          IconButton.filledTonal(
              icon: const Icon(Icons.remove), onPressed: () => _bump(-1)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration:
              const InputDecoration(border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                _push();
                Navigator.of(context).maybePop();
              },
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: units.any((u) => u.id == _unitId) ? _unitId : null,
            items: [
              for (final u in units)
                DropdownMenuItem(
                    value: u.id,
                    child: Text(u.display(widget.lang, _qty))),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _unitId = v);
              _push();
            },
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
              icon: const Icon(Icons.add), onPressed: () => _bump(1)),
        ],
      ),
    );
  }
}