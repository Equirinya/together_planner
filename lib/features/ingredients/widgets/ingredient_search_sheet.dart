import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/ingredient_parser.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/services/item_writer.dart';
import 'package:couple_planner/features/ingredients/widgets/avatar.dart';

/// Debounce before the typed text is taken to the server to look through done
/// items. Much shorter than the cloud-function debounce — it's a plain indexed
/// read — but long enough that a burst of keystrokes costs one query.
const Duration _kDoneQueryDebounce = Duration(milliseconds: 400);

/// How far back done items are considered, and how many are held at once.
const Duration _kDoneWindow = Duration(days: 7);
const int _kDoneLimit = 50;

/// How many done items the empty-query "Done" list shows, out of the
/// [_kDoneLimit] held.
const int _kDoneShown = 20;

/// Identity of a suggestion for dedupe purposes: ingredient + display name +
/// description, so the typed phrase, the canonical version and each existing
/// list variant can coexist without any one of them appearing twice.
String _suggestionKey(Suggestion s) =>
    '${s.ingredientId}|${s.displayName.trim().toLowerCase()}|${s.description}';

// =============================================================================
// Search sheet — reusable: pass any collection where items should be created
// =============================================================================

/// Bottom-sheet ingredient search. Adds documents of the shape
/// `{ingredientId, displayName, description, quantity, doneAt, createdAt}`
/// to [targetRef]. Works for the shopping list, recipe ingredient lists, etc.
///
///  * same display name + same description (in a matching unit) → quantities
///    merge; differently named/described entries for one ingredient stay
///    distinct and are each offered as their own top-up option,
///  * unmatched input is added as `kPendingIngredient` and resolved afterwards
///    (the host's snapshot listener should call [resolvePendingItem] so
///    pre-existing pending items are covered too),
///  * docs with a non-null `doneAt` are offered for restore on empty query,
///    and while typing as a source of names for a new item.
class IngredientSearchSheet extends StatefulWidget {
  const IngredientSearchSheet({
    super.key,
    required this.targetRef,
    required this.lang,
    this.hintText = 'Add item…',
    this.trackContributions = false,
    this.windowDoneItems = false,
  });

  final CollectionReference<Map<String, dynamic>> targetRef;
  final String lang;
  final String hintText;

  /// Whether adds should record who made them, in the item's
  /// `manualQuantities` map (see manual_contributions.dart). On for the
  /// shopping list, off for recipe ingredient lists, where the recipe — not a
  /// person — owns the amounts.
  final bool trackContributions;

  /// Whether done items should be loaded through their own windowed query
  /// instead of coming along with the rest of the collection.
  ///
  /// On for the shopping list, whose done items accumulate without bound —
  /// there, reading the whole collection would mean paying for the list's
  /// entire history on every open. Off for small, bounded collections like a
  /// recipe's ingredient list: splitting the listener there would buy nothing
  /// and relies on every doc actually carrying a `doneAt` field, since
  /// Firestore's `isNull: true` does not match docs where the field is absent.
  final bool windowDoneItems;

  /// Convenience: opens the sheet with the standard modal configuration.
  static Future<void> show(
      BuildContext context, {
        required CollectionReference<Map<String, dynamic>> targetRef,
        required String lang,
        String hintText = 'Add item…',
        bool trackContributions = false,
        bool windowDoneItems = false,
      }) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => IngredientSearchSheet(
          targetRef: targetRef,
          lang: lang,
          hintText: hintText,
          trackContributions: trackContributions,
          windowDoneItems: windowDoneItems,
        ),
      );

  @override
  State<IngredientSearchSheet> createState() => _IngredientSearchSheetState();
}

class _IngredientSearchSheetState extends State<IngredientSearchSheet> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  List<Suggestion> _suggestions = [];
  Suggestion? _fallback;

  int _searchSeq = 0;

  /// Active (not done) items — powers instant combining and the per-ingredient
  /// variant suggestions.
  List<Map<String, dynamic>> _currentItems = [];
  StreamSubscription? _listSub;

  /// The most recent done items, newest first. Source of the restore list on
  /// an empty query, and of name suggestions while typing.
  List<Map<String, dynamic>> _doneItems = [];
  StreamSubscription? _doneSub;

  /// Done items found on the server by display-name prefix — older than the
  /// window [_doneItems] covers. Rebuilt per search, appended to the results.
  List<Suggestion> _remoteDone = [];
  Timer? _doneQueryTimer;

  StreamSubscription<bool>? _kbSub;
  bool _keyboardWasVisible = false;

  String get _lang => widget.lang;

  @override
  void initState() {
    super.initState();
    UnitsCache.instance.ensureLoaded();

    _startItemSubscriptions();
    _onSearchChanged(''); // initial "done" suggestions

    // When a debounced server refresh changed the result set, rebuild.
    IngredientIndex.instance.addListener(_onIndexUpdated);

    // Closing the keyboard (e.g. Android back gesture) dismisses the sheet —
    // but only after it has actually opened, so the initial frame doesn't pop it.
    // iOS reports a transient hide during the open animation, so this is
    // Android-only to avoid the sheet popping itself the moment it opens.
    if (defaultTargetPlatform == TargetPlatform.android) {
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
  }

  @override
  void dispose() {
    IngredientIndex.instance.removeListener(_onIndexUpdated);
    _doneQueryTimer?.cancel();
    _listSub?.cancel();
    _doneSub?.cancel();
    _kbSub?.cancel();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Fills [_currentItems] (active) and [_doneItems] (recently done).
  ///
  /// With [IngredientSearchSheet.windowDoneItems] the two come from separate
  /// queries so the done half stays bounded; otherwise one listener covers the
  /// whole collection and the split happens in memory.
  void _startItemSubscriptions() {
    List<Map<String, dynamic>> rows(QuerySnapshot<Map<String, dynamic>> s) =>
        s.docs.map((d) => <String, dynamic>{...d.data(), 'id': d.id}).toList();

    void refreshEmptyQuery() {
      if (_searchCtrl.text.trim().isEmpty) _suggestions = _doneItemSuggestions();
    }

    if (!widget.windowDoneItems) {
      _listSub = widget.targetRef.snapshots().listen((snap) {
        if (!mounted) return;
        setState(() {
          final all = rows(snap);
          _currentItems = all.where((i) => i['doneAt'] == null).toList();
          _doneItems = all.where((i) => i['doneAt'] != null).toList()
            ..sort((a, b) => (b['doneAt'] as Timestamp)
                .compareTo(a['doneAt'] as Timestamp)); // newest first
          refreshEmptyQuery();
        });
      }, onError: (Object e) => debugPrint('Ingredient list listener error: $e'));
      return;
    }

    // Active items: powers instant combining and the variant suggestions.
    _listSub =
        widget.targetRef.where('doneAt', isNull: true).snapshots().listen((snap) {
      if (!mounted) return;
      setState(() => _currentItems = rows(snap));
    }, onError: (Object e) => debugPrint('Ingredient list listener error: $e'));

    // Recently done items, newest first and capped, so a long-lived list
    // doesn't drag its whole history along on every open.
    _doneSub = widget.targetRef
        .where('doneAt',
            isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(_kDoneWindow)))
        .orderBy('doneAt', descending: true)
        .limit(_kDoneLimit)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _doneItems = rows(snap);
        refreshEmptyQuery();
      });
    }, onError: (Object e) => debugPrint('Done items listener error: $e'));
  }

  void _onIndexUpdated() {
    if (mounted && _searchCtrl.text.trim().isNotEmpty) {
      _onSearchChanged(_searchCtrl.text);
    }
  }

  // ── search / suggestions ───────────────────────────────────────────────────

  /// No debounce here: matching is served from memory / the offline cache, so
  /// every keystroke updates the list immediately. Only the server refresh
  /// (inside IngredientIndex) and the done-item lookup are debounced.
  ///
  /// Unmatched input isn't resolved while typing — it's offered as the "?"
  /// fallback and only resolved once the user actually picks it, in [_afterUse].
  void _onSearchChanged(String text) {
    _doneQueryTimer?.cancel();
    final seq = ++_searchSeq;

    if (text.trim().isEmpty) {
      setState(() {
        _fallback = null;
        _remoteDone = const [];
        _suggestions = _doneItemSuggestions();
      });
      return;
    }

    // Results from the previous query are for a different word — drop them
    // rather than let them linger under the new one.
    _remoteDone = const [];

    () async {
      final local = await _buildLocalSuggestions(text);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _suggestions = local;
        _fallback = _buildFallback(text);
      });

      // Older done items, looked up on the server by name prefix. Debounced
      // and folded in by re-running the local build once they land, so they
      // slot into the normal ordering and dedupe.
      // Only worthwhile when the done half is windowed — otherwise _doneItems
      // already holds every done item there is.
      final typedForDone = parseInput(text).remaining.join(' ').trim();
      if (widget.windowDoneItems && typedForDone.length >= 2) {
        _doneQueryTimer = Timer(_kDoneQueryDebounce, () async {
          final found = await _queryRemoteDone(typedForDone);
          if (!mounted || seq != _searchSeq || found.isEmpty) return;
          _remoteDone = found;
          final rebuilt = await _buildLocalSuggestions(text);
          if (!mounted || seq != _searchSeq) return;
          setState(() {
            // The cloud function normally lands well after this, but if it
            // got in first its entries are kept ahead of the rebuild rather
            // than overwritten.
            final keys = rebuilt.map(_suggestionKey).toSet();
            _suggestions = [
              ..._suggestions.where((s) => !keys.contains(_suggestionKey(s))),
              ...rebuilt,
            ];
          });
        });
      }

    }();
  }

  /// The restore list shown on an empty query. [_doneItems] already arrives
  /// windowed and newest-first from the query, so this only trims it to what
  /// is worth showing.
  List<Suggestion> _doneItemSuggestions() => _doneItems
      .take(_kDoneShown)
      .map((i) => Suggestion.fromMap(i, isRestoreDone: true))
      .toList();

  Future<List<Suggestion>> _buildLocalSuggestions(String input) async {
    final parsed = parseInput(input);
    final qty = parsed.quantity; // null when the user didn't type a number
    final fullName = parsed.remaining.join(' ');
    final out = <Suggestion>[];
    final seen = <String>{};

    void add(Suggestion s) {
      if (seen.add(_suggestionKey(s))) out.add(s);
    }

    for (final c in nameDescCandidates(parsed.remaining)) {
      final matches = await IngredientIndex.instance.match(c.name, _lang);
      for (final m in matches) {
        final unitId = parsed.unitId ?? m.defaultUnit;
        final canonical = m.displayName(_lang);
        final category = m.category(_lang);

        // When the typed text isn't just a prefix of the canonical name — i.e.
        // it matched via a synonym ("grüne Bohnen" → Prinzessbohne) or carries
        // extra words ("veganer Speck" → Speck) — offer the literal typed name
        // first, linked to the matched ingredient and without a description.
        if (!canonical.toLowerCase().startsWith(fullName.toLowerCase())) {
          add(Suggestion(
            ingredientId: m.id,
            displayName: fullName,
            description: '',
            unitId: unitId,
            quantity: qty,
            category: category,
          ));
        }

        // The standard version: canonical name so the user sees "Orange" when
        // they typed "oran".
        add(Suggestion(
          ingredientId: m.id,
          displayName: canonical,
          description: c.description,
          unitId: unitId,
          quantity: qty,
          category: category,
        ));

        // Each shopping-list entry that already exists for this ingredient —
        // including ones with a non-standard display name or a description —
        // is offered as its own option, so the user can add to a specific
        // existing item instead of always merging into (or recreating) the
        // canonical one. Its unit follows the existing item so a bare tap
        // lands in the same unit and combines. The dedupe above drops any
        // variant that coincides with the typed/standard entries.
        //
        // Done items count too: they aren't offered for revival here (that's
        // the empty-query "Done" list) but as a source of names — tapping one
        // copies its display name and ingredient id into a *new* item.
        for (final item in [..._currentItems, ..._doneItems]) {
          if ((item['ingredientId'] ?? '').toString() != m.id) continue;
          final vName = (item['displayName'] ?? '').toString();
          if (vName.trim().isEmpty) continue;
          add(Suggestion(
            ingredientId: m.id,
            displayName: vName,
            description: (item['description'] ?? '').toString(),
            unitId: parsed.unitId ??
                readQuantity(item['quantity'])?.unitId ??
                unitId,
            quantity: qty,
            category: category,
          ));
        }
      }
    }

    // Done items matched by their own display name. Covers entries the index
    // can't reach from the typed text — a custom name ("veganer Speck" typed
    // as "vegan") or an item that never resolved to an ingredient. Again these
    // are name sources, not revivals: tapping creates a new item carrying the
    // done item's display name and ingredient id.
    final needle = fullName.trim().toLowerCase();
    if (needle.isNotEmpty) {
      for (final item in _doneItems) {
        final vName = (item['displayName'] ?? '').toString();
        if (vName.trim().isEmpty) continue;
        final lower = vName.toLowerCase();
        final hit = lower.startsWith(needle) ||
            lower.split(RegExp(r'\s+')).any((w) => w.startsWith(needle));
        if (!hit) continue;
        add(_doneNameSuggestion(item, parsed.unitId, qty));
      }
    }

    // Older done items the server turned up by name prefix. Merged in last so
    // they rank below everything the index and the recent window produced.
    for (final s in _remoteDone) {
      add(qty == null && parsed.unitId == null
          ? s
          : Suggestion(
              ingredientId: s.ingredientId,
              displayName: s.displayName,
              description: s.description,
              unitId: parsed.unitId ?? s.unitId,
              quantity: qty,
              category: s.category,
            ));
    }
    return out;
  }

  /// A done item offered as a *name source*: same display name, ingredient id,
  /// description and category, but no doc id and no restore flag — tapping it
  /// creates a new item rather than reviving the old one.
  Suggestion _doneNameSuggestion(
      Map<String, dynamic> item, String? typedUnitId, num? qty) =>
      Suggestion(
        ingredientId: (item['ingredientId'] ?? kPendingIngredient).toString(),
        displayName: (item['displayName'] ?? '').toString(),
        description: (item['description'] ?? '').toString(),
        unitId: typedUnitId ??
            readQuantity(item['quantity'])?.unitId ??
            kDefaultUnitId,
        quantity: qty,
        category: (item['category'] ?? '').toString(),
      );

  /// Looks through *all* done items on the server for display names starting
  /// with the typed text, reaching past the recent window [_doneItems] holds.
  ///
  /// Firestore range queries are byte-ordered and case-sensitive, so the typed
  /// text is tried in a few capitalisations ("speck" also as "Speck") — that
  /// covers the normal case of a lowercase query against a capitalised name,
  /// though not a match starting mid-name. The query deliberately doesn't
  /// filter on `doneAt`, which would force a composite index; active items
  /// come back too and are dropped here, and would be duplicates anyway.
  Future<List<Suggestion>> _queryRemoteDone(String name) async {
    final trimmed = name.trim();
    if (trimmed.length < 2) return const [];

    final lower = trimmed.toLowerCase();
    final prefixes = <String>{
      trimmed,
      lower,
      lower[0].toUpperCase() + lower.substring(1),
    };

    final out = <Suggestion>[];
    final seenIds = <String>{};
    final knownIds = {
      for (final i in [..._currentItems, ..._doneItems]) i['id'] as String,
    };

    for (final p in prefixes) {
      try {
        final snap = await widget.targetRef
            .where('displayName', isGreaterThanOrEqualTo: p)
            .where('displayName', isLessThan: '$p\uf8ff')
            .limit(_kDoneLimit)
            .get();
        for (final d in snap.docs) {
          final data = d.data();
          if (data['doneAt'] == null) continue; // active — already covered
          if (knownIds.contains(d.id)) continue; // inside the recent window
          if (!seenIds.add(d.id)) continue;
          out.add(_doneNameSuggestion(data, null, null));
        }
      } catch (e) {
        debugPrint('Done name query failed for "$p": $e');
      }
    }
    return out;
  }

  Suggestion _buildFallback(String input) {
    final parsed = parseInput(input);
    final name = parsed.remaining.join(' ').trim();
    return Suggestion(
      ingredientId: kPendingIngredient,
      displayName: name.isNotEmpty ? name : input.trim(),
      description: '',
      unitId: parsed.unitId ?? kDefaultUnitId,
      quantity: parsed.quantity, // null when user didn't type a number
      isFallback: true,
    );
  }

  // ── adding / restoring ─────────────────────────────────────────────────────

  void _tapSuggestion(Suggestion s) {
    if (s.isRestoreDone && s.docId != null) {
      _restore(s.docId!);
    } else {
      _addSuggestion(s);
    }
  }

  Future<void> _restore(String id) async {
    _clearAndKeepFocus();
    try {
      await widget.targetRef.doc(id).update({'doneAt': null});
    } catch (_) {}
  }

  Future<void> _addSuggestion(Suggestion s) async {
    if (s.displayName.trim().isEmpty) return;

    // Snapshot the list *before* clearing, so the merge is resolved against
    // exactly what the user was looking at when they tapped.
    final items = List<Map<String, dynamic>>.of(_currentItems);

    // Clear first, synchronously: Firestore applies writes to the local cache
    // immediately, so the list listener fires before any await here resumes. If
    // the tapped tile were still on screen it would flip to its "+1" additive
    // badge for a frame before the list reset.
    _clearAndKeepFocus();

    final result = await addSuggestionToList(
      s,
      listRef: widget.targetRef,
      lang: _lang,
      currentItems: items,
      trackContributions: widget.trackContributions,
      // Detached, so the field is usable again immediately rather than waiting
      // on an ingredient lookup.
      resolveInBackground: true,
    );

    if (!result.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error adding item')),
      );
    }
  }

  void _clearAndKeepFocus() {
    _searchCtrl.clear();
    _onSearchChanged('');
    if (!_searchFocus.hasFocus) _searchFocus.requestFocus(); // keep keyboard up, sheet open
  }

  void _submitFirst() {
    final first = _suggestions.isNotEmpty ? _suggestions.first : _fallback;
    if (first != null) _tapSuggestion(first);
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    final isEmptyQuery = _searchCtrl.text.trim().isEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SizedBox(
        // Stable visual height: the list area shrinks while the keyboard is up.
        height: (maxHeight - insets).clamp(0.0, maxHeight),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SearchBar(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                autoFocus: true,
                hintText: widget.hintText,
                elevation: const WidgetStatePropertyAll(0),
                leading: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.search),
                ),
                textInputAction: TextInputAction.done,
                onChanged: _onSearchChanged,
                onSubmitted: (_) => _submitFirst(),
              ),
            ),
            Expanded(
              child: _SuggestionsList(
                suggestions: _suggestions,
                fallback: isEmptyQuery ? null : _fallback,
                headerLabel:
                isEmptyQuery && _suggestions.isNotEmpty
                    ? 'Last marked done'
                    : null,
                lang: _lang,
                onTap: _tapSuggestion,
                currentItems: _currentItems,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Suggestions list
// =============================================================================

bool _wouldCombine(Suggestion s, List<Map<String, dynamic>> currentItems) =>
    combineTarget(s, currentItems) != null;

class _SuggestionsList extends StatelessWidget {
  const _SuggestionsList({
    required this.suggestions,
    required this.fallback,
    required this.lang,
    required this.onTap,
    this.headerLabel,
    this.currentItems = const [],
  });

  final List<Suggestion> suggestions;
  final Suggestion? fallback;
  final String lang;
  final String? headerLabel;
  final ValueChanged<Suggestion> onTap;
  final List<Map<String, dynamic>> currentItems;

  @override
  Widget build(BuildContext context) {
    // Suppress the fallback (?) tile when a matched suggestion already shows
    // the same ingredient name.
    final effectiveFallback = (fallback == null ||
        suggestions.any((s) =>
        s.displayName.toLowerCase() == fallback!.displayName.toLowerCase()))
        ? null
        : fallback;

    final isEmpty = suggestions.isEmpty && effectiveFallback == null;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (headerLabel != null && suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(headerLabel!, style: Theme.of(context).textTheme.labelMedium),
          ),
        for (final s in suggestions)
          _SuggestionTile(
            // Identity-based key: without it the tile's ink highlight stays
            // with the element at that index, so after a tap replaces the
            // result set the fading splash appears on whatever suggestion
            // moved into that slot.
            key: ValueKey('s|${s.docId ?? ''}|${_suggestionKey(s)}'),
            suggestion: s,
            lang: lang,
            onTap: () => onTap(s),
            isAdditive: _wouldCombine(s, currentItems),
          ),
        if (effectiveFallback != null)
          _SuggestionTile(
            key: ValueKey('f|${_suggestionKey(effectiveFallback)}'),
            suggestion: effectiveFallback,
            lang: lang,
            onTap: () => onTap(effectiveFallback),
            isAdditive: _wouldCombine(effectiveFallback, currentItems),
          ),
        if (isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Start typing to add an item.')),
          ),
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    super.key,
    required this.suggestion,
    required this.lang,
    required this.onTap,
    this.isAdditive = false,
  });

  final Suggestion suggestion;
  final String lang;
  final VoidCallback onTap;
  final bool isAdditive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDone = suggestion.isRestoreDone;

    return ListTile(
      onTap: onTap,
      leading: suggestion.isFallback
          ? CircleAvatar(
        radius: 20,
        backgroundColor: cs.surfaceContainerHighest,
        child: const Text('?'),
      )
          : Avatar(
        ingredientId: suggestion.ingredientId,
        backgroundColor: isDone && Theme.of(context).brightness == Brightness.dark
            ? cs.surfaceContainerHighest
            : null,
      ),
      title: Text(
        suggestion.displayName.isEmpty ? '?' : suggestion.displayName,
        style: isDone
            ? TextStyle(
          color: cs.onSurface.withOpacity(0.5),
          decoration: TextDecoration.lineThrough,
        )
            : null,
      ),
      subtitle:
      suggestion.description.isNotEmpty ? Text(suggestion.description) : null,
      trailing: () {
        final qty = suggestion.quantity;
        if (qty == null && !isAdditive) return null;
        final effectiveQty = qty ?? 1;
        final qtyText =
            '${isAdditive ? '+' : ''}${fmtQty(effectiveQty)} '
            '${UnitsCache.instance.display(suggestion.unitId, lang, effectiveQty)}';
        final textWidget = Text(qtyText, style: Theme.of(context).textTheme.bodyMedium);
        if (!isAdditive) return textWidget;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: textWidget,
        );
      }(),
    );
  }
}
