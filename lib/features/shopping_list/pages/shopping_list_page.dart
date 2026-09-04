import 'dart:async';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/models/categories.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/widgets/avatar.dart';
import 'package:couple_planner/features/ingredients/widgets/ingredient_search_sheet.dart';
import 'package:couple_planner/features/ingredients/widgets/quantity_editor.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/core/widgets/undo_snackbar.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/services/recipe_localization.dart';
import 'package:couple_planner/features/shopping_list/widgets/empty_shopping_list.dart';
import 'package:couple_planner/features/shopping_list/manual_contributions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

class _ShoppingListPageState extends State<ShoppingListPage>
    with WidgetsBindingObserver {
  final _db = FirebaseFirestore.instance;

  late final String _lang;

  /// Live copy of the shopping list — kept in sync by _listSub.
  List<Map<String, dynamic>> _currentItems = [];
  StreamSubscription? _listSub;

  final Set<String> _optimisticallyHidden = {};

  /// Items that just left the active set on the *remote* end (deleted, or
  /// marked done by someone else) and are still shrinking away. Keyed by id,
  /// dropped once the shrink animation finishes (see _AnimatedShoppingItem).
  final Map<String, Map<String, dynamic>> _removingItems = {};

  /// How often a mark-done on an item has failed and put it back. It is part
  /// of the row's key, so a restored row is a *new* row: its Dismissible would
  /// otherwise still be sitting in its dismissed state, off-screen, leaving
  /// nothing but the green background behind.
  final Map<String, int> _restoreCount = {};

  /// False until the first snapshot has been rendered. Rows built after that
  /// are genuine arrivals and expand in (see _AnimatedShoppingItem); the ones
  /// from the initial load just appear.
  bool _seenFirstSnapshot = false;

  /// Every row this page has built so far, by row id. Membership — not the
  /// mere fact of being mounted — is what makes a row old news: the list sliver
  /// drops rows that scroll out of view and rebuilds them on the way back, and
  /// those must not expand in a second time.
  final Set<String> _knownRows = {};

  /// True only the first time a row is built, and never for the initial load.
  /// Rows that appear off-screen are recorded here too, so scrolling down to
  /// them finds them already in place — which is right, nobody watched them
  /// arrive.
  bool _isArrival(String rowId) {
    final firstBuild = _knownRows.add(rowId);
    return firstBuild && _seenFirstSnapshot;
  }

  /// Badge cutoff for this session: an item counts as new when its createdAt
  /// is after this. Held fixed for the whole session so a badge doesn't vanish
  /// from under the user while they're looking at it.
  ///
  /// This lives in the *server* clock's domain, because that is what createdAt
  /// is (FieldValue.serverTimestamp()). It must never be set from
  /// DateTime.now(): the device clock is typically a few seconds off from the
  /// server's, and when it runs behind, a "now" written at the end of a session
  /// is still older than the createdAt of an item seen during it — so the badge
  /// survived the next start too, and only disappeared on the one after that.
  DateTime? _lastSeen;

  /// The highest createdAt that has actually been on screen with the app in the
  /// foreground. This — not "now" — is what gets persisted as the next
  /// session's [_lastSeen]. Items that arrive while the app is backgrounded or
  /// closed never reach it, so they are still badged on the next launch.
  DateTime? _seenWatermark;

  /// Prefs aren't written before the stored value has been read back, so a
  /// snapshot landing during the initial load can't clobber the cutoff.
  bool _lastSeenLoaded = false;

  bool _foreground = true;

  /// How long a swipe-away is held back before it is actually written to
  /// Firestore. Short enough that the partner's list stays in step, long enough
  /// that a swipe which was really the tail of a system "close the app" gesture
  /// never reaches the server at all — see [_cancelUncommittedRemovals].
  static const Duration _undoCommitDelay = Duration(milliseconds: 500);

  /// Items swiped away and not yet safely gone: either still inside the commit
  /// delay, or written but still undoable from the prompt.
  final Map<String, _PendingRemoval> _pendingRemovals = {};

  /// The removals the prompt currently on screen would undo. A run of quick
  /// swipes collects into one batch rather than one prompt per item.
  final List<String> _undoBatch = [];

  /// Non-null while the prompt is in the tree. It deliberately outlives
  /// [_undoBatch]: after "Undo" is tapped the batch is empty immediately, but
  /// the prompt stays mounted until it has finished animating out.
  String? _undoMessage;

  /// Bumped on every swipe so the prompt restarts its countdown instead of
  /// timing out from when the first item of the batch was removed.
  int _undoToken = 0;

  String get _seenKey => 'shopping_seen_upto_${widget.groupId}';

  CollectionReference<Map<String, dynamic>> get _listRef =>
      _db.collection('groups').doc(widget.groupId).collection('shopping_list');

  // ── lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _lang = LanguageService.instance.code.value;
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    UnitsCache.instance.ensureLoaded();
    _initLastSeen();
    _startListSubscription(); // also resolves any pre-existing pending items
  }

  Future<void> _initLastSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_seenKey);
    if (!mounted) return;
    setState(() {
      if (stored != null) {
        _lastSeen = DateTime.fromMillisecondsSinceEpoch(stored);
      }
      _lastSeenLoaded = true;
    });
    // A snapshot may already have arrived while this read was in flight.
    _flushSeenWatermark();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    // Leaving the foreground undoes anything swiped away in the last
    // [_undoCommitDelay]. On both platforms closing the app is itself an
    // edge swipe, and a list row that goes away in the same breath was almost
    // certainly caught by that gesture rather than checked off on purpose.
    if (!foreground) _cancelUncommittedRemovals();
    // Coming back to the app: whatever is on the list now is being looked at,
    // so it stops counting as new for *future* sessions. Snapshots that landed
    // while we were away didn't advance the watermark themselves, and this is
    // the only chance to record them — no further snapshot is guaranteed.
    // _lastSeen is deliberately left alone, so items the partner added while
    // the app was in the background keep their badge for this session.
    if (foreground) _recordSeen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listSub?.cancel();
    // Uncommitted removals die with the page — which is the point: nothing was
    // written, so they are undone by never having happened.
    for (final pending in _pendingRemovals.values) {
      pending.timer?.cancel();
    }
    super.dispose();
  }

  /// Advances the watermark to the newest createdAt currently on the list.
  /// Only counts while the app is in the foreground — items delivered to a
  /// backgrounded listener have not been seen by anyone.
  void _recordSeen() {
    if (!_foreground) return;
    DateTime? max = _seenWatermark;
    for (final item in _currentItems) {
      final created = (item['createdAt'] as Timestamp?)?.toDate();
      if (created == null) continue; // pending server timestamp, not yet real
      if (max == null || created.isAfter(max)) max = created;
    }
    if (max == null || (_seenWatermark != null && !max.isAfter(_seenWatermark!))) {
      return;
    }
    _seenWatermark = max;
    _flushSeenWatermark();
  }

  Future<void> _flushSeenWatermark() async {
    final watermark = _seenWatermark;
    if (!_lastSeenLoaded || watermark == null) return;
    final stored = _lastSeen;
    if (stored != null && !watermark.isAfter(stored)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seenKey, watermark.millisecondsSinceEpoch);
    await prefs.remove('shopping_last_seen_${widget.groupId}'); // legacy key
  }

  /// Items that should currently be counted as "on the list". The query only
  /// ever returns undone items, so the only thing left to filter out is a
  /// local mark-done that hasn't confirmed yet.
  List<Map<String, dynamic>> _activeItems() => _currentItems
      .where((i) => !_optimisticallyHidden.contains(i['id']))
      .toList();

  void _startListSubscription() {
    // Active items only. Done items accumulate forever and the page never
    // renders them, so listening to the whole collection meant every cold
    // start paid a read for the list's entire history. A doc being marked
    // done now simply leaves the snapshot, which the removal handling below
    // already treats the same as "fell out of the active set". The search
    // sheet loads the recent done ones it needs on its own.
    _listSub = _listRef.where('doneAt', isNull: true).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        final previouslyActive = _activeItems();

        _currentItems = snap.docs
            .map((d) => <String, dynamic>{...d.data(), 'id': d.id})
            .toList();
        // Once the done state is confirmed the doc leaves this query, so an
        // id that's no longer present means the mark-done landed (or the item
        // was deleted) — either way the optimistic hide has done its job and
        // must be dropped, otherwise a later restore (doneAt → null) from the
        // search sheet would bring the item back but leave it hidden.
        final currentIds = {for (final i in _currentItems) i['id'] as String};
        _optimisticallyHidden.removeWhere((id) => !currentIds.contains(id));

        // Items that fell out of the active set on this snapshot (and
        // weren't already hidden locally) start shrinking away; items that
        // came back cancel any pending shrink.
        final newActiveIds = _activeItems().map((i) => i['id'] as String).toSet();
        for (final item in previouslyActive) {
          final id = item['id'] as String;
          if (!newActiveIds.contains(id)) _removingItems[id] = item;
        }
        _removingItems.removeWhere((id, _) => newActiveIds.contains(id));
      });
      // Flipped only after the first snapshot has actually been laid out, so
      // the rows it mounts don't count as arrivals.
      if (!_seenFirstSnapshot) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _seenFirstSnapshot = true);
      }
      // Record what is now on screen as seen — but only if the app is actually
      // in front of the user (see _recordSeen).
      _recordSeen();
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

  /// A swipe-away. The row leaves the screen at once, but the write is held
  /// back by [_undoCommitDelay] so that the two cheap ways out of a mistake —
  /// tapping Undo, or the app going away — cost nothing at all.
  void _markDone(Map<String, dynamic> item) {
    final id = item['id'] as String;
    // Hiding it locally takes it straight out of _activeItems(), so it has to
    // be handed to _removingItems in the same breath — otherwise our own
    // mark-done pops instead of shrinking away like a partner's does.
    setState(() {
      _optimisticallyHidden.add(id);
      _removingItems[id] = item;
      _pendingRemovals[id] = _PendingRemoval(
        timer: Timer(_undoCommitDelay, () => _commitRemoval(id)),
      );
      _undoBatch.add(id);
      _undoToken++;
      _undoMessage = _undoBatch.length == 1
          ? '${(item['displayName'] ?? 'Item').toString()} removed'
          : '${_undoBatch.length} items removed';
    });
    HapticFeedback.lightImpact();
  }

  /// Writes the held-back mark-done. The item stays in [_pendingRemovals]
  /// afterwards, flagged as committed, because the prompt is usually still up
  /// and undoing then means writing the item back rather than dropping a timer.
  Future<void> _commitRemoval(String id) async {
    final pending = _pendingRemovals[id];
    if (pending == null) return;
    pending.timer = null;
    pending.committed = true;
    try {
      // Use a concrete client timestamp rather than a server one: a pending
      // FieldValue.serverTimestamp() reads back as null (and stays null when a
      // snapshot is served from the offline cache) until the server acks the
      // write, which makes a just-removed item invisible to the search sheet's
      // "recently done" restore list. A client timestamp is present in every
      // snapshot immediately, so recently removed items surface right away.
      await _listRef.doc(id).update({'doneAt': Timestamp.now()});
    } catch (_) {
      // Write failed: put it back, as a fresh row that grows in again.
      _pendingRemovals.remove(id);
      _undoBatch.remove(id);
      _restoreRow(id);
    }
  }

  /// Puts a row back on the list locally, as a *new* row (see [_restoreCount])
  /// so it grows in rather than reappearing mid-swipe.
  void _restoreRow(String id) {
    if (!mounted) return;
    setState(() {
      _optimisticallyHidden.remove(id);
      _removingItems.remove(id);
      _restoreCount.update(id, (n) => n + 1, ifAbsent: () => 1);
    });
  }

  /// "Undo" on the prompt: rolls back everything it covers. Items still inside
  /// the commit delay simply never get written; ones already committed are
  /// written back by clearing doneAt, which Firestore reflects locally on the
  /// spot, so the row returns immediately either way.
  void _undoRemovals() {
    final ids = List<String>.of(_undoBatch);
    _undoBatch.clear();
    for (final id in ids) {
      final pending = _pendingRemovals.remove(id);
      if (pending == null) continue;
      pending.timer?.cancel();
      if (pending.committed) {
        _listRef.doc(id).update({'doneAt': null}).catchError((Object e) {
          debugPrint('Undo failed for $id: $e');
        });
      }
      _restoreRow(id);
    }
  }

  /// Rolls back only the removals that haven't been written yet. Called when
  /// the app leaves the foreground: those writes can be cancelled outright,
  /// with nothing to compensate for and no dependence on the process living
  /// long enough to send anything.
  void _cancelUncommittedRemovals() {
    final ids = _pendingRemovals.entries
        .where((e) => !e.value.committed)
        .map((e) => e.key)
        .toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      _pendingRemovals.remove(id)!.timer?.cancel();
      _undoBatch.remove(id);
      _restoreRow(id);
    }
    // No exit animation here — nobody is watching the app any more.
    if (_undoBatch.isEmpty && mounted) setState(() => _undoMessage = null);
  }

  /// The prompt has finished animating out: drop it, and let go of the
  /// removals it was covering.
  void _dismissUndoPrompt() {
    if (!mounted) return;
    _undoBatch.clear();
    _pendingRemovals.removeWhere((_, pending) => pending.committed);
    setState(() => _undoMessage = null);
  }

  /// Hand edits from the quantity editor. The *change* is attributed to
  /// whoever made it: bumping 200 g to 300 g credits them with 100 g, dialling
  /// it back down debits them again. Changing the unit moves the whole amount
  /// over, since a delta across units would be meaningless.
  Future<void> _updateQuantity(
      Map<String, dynamic> item, String unitId, num? qty) {
    final before = readQuantity(item['quantity']);
    final after = qty == null || qty <= 0 ? null : qty;

    final Map<String, dynamic> attribution;
    if (before?.unitId == unitId) {
      attribution = manualDelta(unitId, (after ?? 0) - before!.qty);
    } else {
      attribution = manualUnitSwitch(
        fromUnitId: before?.unitId,
        fromQty: before?.qty ?? 0,
        toUnitId: unitId,
        toQty: after ?? 0,
      );
    }

    return _listRef.doc(item['id'] as String).update({
      'quantity': qty == null ? null : {unitId: qty.toDouble()},
      ...attribution,
    });
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final active = _activeItems();

    // Items still on the list, plus any remotely-removed ones still
    // shrinking away — both need to be rendered.
    final activeIds = active.map((i) => i['id'] as String).toSet();
    final display = [
      ...active,
      for (final entry in _removingItems.entries)
        if (!activeIds.contains(entry.key)) entry.value,
    ];

    // ── group by category ──────────────────────────────────────────────────
    final Map<String, List<Map<String, dynamic>>> groups = {};
    for (final item in display) {
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

    return Stack(
      children: [
        Positioned.fill(
          child: display.isEmpty
              ? const EmptyShoppingList()
              : ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final cat in sortedCats) ...[
                if (showHeaders) _headerRow(cat, groups[cat]!),
                for (final item in groups[cat]!) _itemRow(item),
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
                trackContributions: true,
                windowDoneItems: true,
              ),
            ),
          ),
        ),
        // Sits above the add-item bar, and last in the stack so its button is
        // the one that gets the taps.
        if (_undoMessage != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 72),
                child: UndoSnackbar(
                  message: _undoMessage!,
                  restartToken: _undoToken,
                  onUndo: _undoRemovals,
                  onDismissed: _dismissUndoPrompt,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A category header, which shrinks away in step with its last item: it
  /// stays "present" only while the category still holds an item that isn't
  /// itself shrinking out.
  Widget _headerRow(String cat, List<Map<String, dynamic>> items) {
    final rowId = 'header_$cat';
    return _AnimatedShoppingItem(
      key: ValueKey(rowId),
      present: items.any((i) => !_removingItems.containsKey(i['id'])),
      animateIn: _isArrival(rowId),
      // Forgotten once gone, so the header expands back in if the category
      // is later repopulated.
      onRemoved: () => _knownRows.remove(rowId),
      child: _CategoryHeader(category: cat.isEmpty ? 'other' : cat),
    );
  }

  Widget _itemRow(Map<String, dynamic> item) {
    final id = item['id'] as String;
    // A row restored after a failed mark-done is deliberately a different row
    // (see _restoreCount), so it gets a fresh Dismissible and expands in again.
    final rowId = '$id#${_restoreCount[id] ?? 0}';
    return _AnimatedShoppingItem(
      key: ValueKey(rowId),
      present: !_removingItems.containsKey(id),
      animateIn: _isArrival(rowId),
      onRemoved: () => setState(() {
        _removingItems.remove(id);
        _knownRows.remove(rowId);
      }),
      child: _ShoppingItem(
        item: item,
        groupId: widget.groupId,
        lang: _lang,
        isNew: _isNew(item),
        onMarkDone: () => _markDone(item),
        onQuantityChanged: (u, q) => _updateQuantity(item, u, q),
      ),
    );
  }

  /// Whether the item was put on the list after this session's badge cutoff.
  bool _isNew(Map<String, dynamic> item) {
    final created = (item['createdAt'] as Timestamp?)?.toDate();
    return _lastSeen != null && created != null && created.isAfter(_lastSeen!);
  }
}

/// A swipe-away that hasn't settled yet: either still waiting out the commit
/// delay ([timer] alive, [committed] false), or written and merely still
/// undoable from the prompt ([timer] null, [committed] true).
class _PendingRemoval {
  _PendingRemoval({required this.timer});

  Timer? timer;
  bool committed = false;
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

/// Wraps a shopping-list row so that it grows in when it joins the list and
/// shrinks away when it leaves (marked done or deleted, by anyone) instead of
/// popping in and out. Built entirely from Flutter's implicit animations.
class _AnimatedShoppingItem extends StatefulWidget {
  const _AnimatedShoppingItem({
    super.key,
    required this.present,
    required this.animateIn,
    required this.onRemoved,
    required this.child,
  });

  /// Whether the item is still on the (active) list.
  final bool present;

  /// Whether this row should expand on first mount. False for the rows of the
  /// initial load, which are simply there from the start.
  final bool animateIn;

  /// Called once the shrink-away animation finishes, so the caller can drop
  /// the item from its bookkeeping.
  final VoidCallback onRemoved;

  final Widget child;

  @override
  State<_AnimatedShoppingItem> createState() => _AnimatedShoppingItemState();
}

class _AnimatedShoppingItemState extends State<_AnimatedShoppingItem>
    with SingleTickerProviderStateMixin {
  /// One controller drives both the height and the fade, in both directions:
  /// 0 = collapsed and invisible, 1 = fully open. Rows from the initial load
  /// start at 1, so they are simply there rather than animating in.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.animateIn ? 0 : 1,
  )..addStatusListener((status) {
      if (status == AnimationStatus.dismissed) widget.onRemoved();
    });

  late final Animation<double> _progress =
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void initState() {
    super.initState();
    // A row is always mounted while it is still on the list; leaving only ever
    // happens later, via didUpdateWidget.
    _controller.forward();
  }

  @override
  void didUpdateWidget(_AnimatedShoppingItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.present != oldWidget.present) {
      widget.present ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _progress,
      axisAlignment: -1, // collapse towards the top, like a list row should
      child: FadeTransition(opacity: _progress, child: widget.child),
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
      // Let the swipe run to completion and leave it there. A dismissed
      // Dismissible that isn't taken out of the tree stays slid off-screen
      // with its background filling the row, which is exactly the state we
      // want to hold while the row collapses. resizeDuration is null because
      // the collapsing is _AnimatedShoppingItem's job, not Dismissible's —
      // otherwise both would animate the height and fight each other.
      resizeDuration: null,
      onDismissed: (_) => onMarkDone(),
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
        manual: readManualQuantities(item[kManualQuantitiesField]),
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

/// A group member who put part of this item on the list by hand, with the
/// amount they contributed (empty when they added it without a quantity).
class _ManualSource {
  _ManualSource({required this.uid, required this.name, required this.quantity});

  final String uid;
  final String name;
  final Map<String, num> quantity;
}

/// Dialog listing where a shopping-list item came from: the recipes that
/// contributed to it, each with the amount it added, followed by the members
/// who added the rest by hand. Tapping a recipe row opens the recipe.
class _RecipeSourcesDialog extends StatelessWidget {
  const _RecipeSourcesDialog({
    required this.groupId,
    required this.itemId,
    required this.manual,
    required this.lang,
    required this.onOpenRecipe,
  });

  final String groupId;
  final String itemId;

  /// Hand-added amounts per uid, straight off the item document.
  final Map<String, Map<String, num>> manual;

  final String lang;
  final void Function(String recipeId) onOpenRecipe;

  /// Resolves each contributing uid to its public username. The signed-in user
  /// is shown as "You" without a lookup.
  Future<List<_ManualSource>> _loadManual() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    final db = FirebaseFirestore.instance;
    final entries = manual.entries.toList();
    return Future.wait(entries.map((e) async {
      if (e.key == me) {
        return _ManualSource(uid: e.key, name: 'You', quantity: e.value);
      }
      String name = 'Member';
      try {
        final snap = await db.collection('users_public').doc(e.key).get();
        final username = snap.data()?['username']?.toString();
        if (username != null && username.isNotEmpty) name = username;
      } catch (_) {}
      return _ManualSource(uid: e.key, name: name, quantity: e.value);
    }));
  }

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
      // Same convention as everywhere else recipes are displayed: the doc
      // stores an English base plus a `translations` map, so swap in the
      // user's language before showing the title (see localizeRecipeData).
      final rd = localizeRecipeData(snap.data()!, lang);
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

  Future<(List<_RecipeSource>, List<_ManualSource>)> _loadAll() async {
    final recipesFuture = _load();
    final manualFuture = _loadManual();
    return (await recipesFuture, await manualFuture);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Where this came from'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<(List<_RecipeSource>, List<_ManualSource>)>(
          future: _loadAll(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final (sources, manualSources) = snap.data!;
            if (sources.isEmpty && manualSources.isEmpty) {
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
                // Whatever wasn't put there by a cooking plan: the amounts
                // members added (or edited in) by hand.
                for (final m in manualSources)
                  ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircleAvatar(
                        backgroundColor: cs.secondaryContainer,
                        child: Icon(Icons.person_outline,
                            color: cs.onSecondaryContainer),
                      ),
                    ),
                    title: Text(sources.isEmpty
                        ? 'Added by ${m.name}'
                        : 'Rest added by ${m.name}'),
                    subtitle:
                        m.quantity.isEmpty ? null : Text(_amountLabel(m.quantity)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

