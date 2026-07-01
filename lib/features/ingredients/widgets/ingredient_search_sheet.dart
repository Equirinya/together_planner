import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/ingredient_parser.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/widgets/avatar.dart';

const Duration _kFunctionDebounce = Duration(seconds: 2);

// =============================================================================
// Search sheet — reusable: pass any collection where items should be created
// =============================================================================

/// Bottom-sheet ingredient search. Adds documents of the shape
/// `{ingredientId, displayName, description, quantity, doneAt, createdAt}`
/// to [targetRef]. Works for the shopping list, recipe ingredient lists, etc.
///
///  * same display name + same single unit + no description → quantities merge,
///  * unmatched input is added as `kPendingIngredient` and resolved afterwards
///    (the host's snapshot listener should call [resolvePendingItem] so
///    pre-existing pending items are covered too),
///  * docs with a non-null `doneAt` are offered for restore on empty query.
class IngredientSearchSheet extends StatefulWidget {
  const IngredientSearchSheet({
    super.key,
    required this.targetRef,
    required this.lang,
    this.hintText = 'Add item…',
  });

  final CollectionReference<Map<String, dynamic>> targetRef;
  final String lang;
  final String hintText;

  /// Convenience: opens the sheet with the standard modal configuration.
  static Future<void> show(
      BuildContext context, {
        required CollectionReference<Map<String, dynamic>> targetRef,
        required String lang,
        String hintText = 'Add item…',
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
  bool _functionRunning = false;

  Timer? _functionTimer;
  int _searchSeq = 0;

  List<Map<String, dynamic>> _currentItems = [];
  StreamSubscription? _listSub;

  StreamSubscription<bool>? _kbSub;
  bool _keyboardWasVisible = false;

  String get _lang => widget.lang;

  @override
  void initState() {
    super.initState();
    UnitsCache.instance.ensureLoaded();

    // Live items: powers the restore-done suggestions and instant combining.
    _listSub = widget.targetRef.snapshots().listen((snap) {
      if (!mounted) return;
      _currentItems =
          snap.docs.map((d) => <String, dynamic>{...d.data(), 'id': d.id}).toList();
      if (_searchCtrl.text.trim().isEmpty) {
        setState(() => _suggestions = _doneItemSuggestions());
      }
    });
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
    _functionTimer?.cancel();
    _listSub?.cancel();
    _kbSub?.cancel();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onIndexUpdated() {
    if (mounted && _searchCtrl.text.trim().isNotEmpty) {
      _onSearchChanged(_searchCtrl.text);
    }
  }

  // ── search / suggestions ───────────────────────────────────────────────────

  /// No debounce here: matching is served from memory / the offline cache, so
  /// every keystroke updates the list immediately. Only the server refresh
  /// (inside IngredientIndex) and the cloud function are debounced.
  void _onSearchChanged(String text) {
    _functionTimer?.cancel();
    final seq = ++_searchSeq;

    if (text.trim().isEmpty) {
      setState(() {
        _functionRunning = false;
        _fallback = null;
        _suggestions = _doneItemSuggestions();
      });
      return;
    }

    () async {
      final local = await _buildLocalSuggestions(text);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _suggestions = local;
        _fallback = _buildFallback(text);
        _functionRunning = false;
      });

      // A prefix match like "Olivenöl" for "olive" isn't good enough — the user
      // may want a distinct "Olive". Only an exact name match suppresses the
      // cloud function; anything else hands over. A still-incomplete fragment
      // ("tomat") is harmless: the function canonicalises it back to the
      // existing "Tomato" instead of creating junk.
      final typedName = parseInput(text).remaining.join(' ').trim().toLowerCase();
      final hasExact =
      local.any((s) => s.displayName.trim().toLowerCase() == typedName);

      if (typedName.isNotEmpty && !hasExact && text.trim().length >= 3) {
        _functionTimer = Timer(_kFunctionDebounce, () async {
          if (!mounted || seq != _searchSeq) return;
          setState(() => _functionRunning = true);
          List<Suggestion> fromFn = const [];
          try {
            fromFn = await IngredientIndex.instance.resolveViaFunction(text);
          } catch (_) {
            if (mounted && seq == _searchSeq) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not resolve "$text".')),
              );
            }
          }
          if (!mounted || seq != _searchSeq) return;
          setState(() {
            // Keep the local prefix matches and prepend what the function
            // resolved/created, deduping by ingredient.
            final ids = fromFn.map((s) => s.ingredientId).toSet();
            _suggestions = [
              ...fromFn,
              ..._suggestions.where((s) => !ids.contains(s.ingredientId)),
            ];
            _functionRunning = false;
          });
        });
      }
    }();
  }

  List<Suggestion> _doneItemSuggestions() {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final done = _currentItems.where((i) {
      final t = i['doneAt'] as Timestamp?;
      return t != null && t.toDate().isAfter(cutoff);
    }).toList()
      ..sort((a, b) {
        final ta = a['doneAt'] as Timestamp;
        final tb = b['doneAt'] as Timestamp;
        return tb.compareTo(ta); // newest first
      });
    return done
        .take(20)
        .map((i) => Suggestion.fromMap(i, isRestoreDone: true))
        .toList();
  }

  Future<List<Suggestion>> _buildLocalSuggestions(String input) async {
    final parsed = parseInput(input);
    final qty = parsed.quantity; // null when the user didn't type a number
    final fullName = parsed.remaining.join(' ');
    final out = <Suggestion>[];
    final seen = <String>{};

    for (final c in nameDescCandidates(parsed.remaining)) {
      final matches = await IngredientIndex.instance.match(c.name, _lang);
      for (final m in matches) {
        final unitId = parsed.unitId ?? m.defaultUnit;
        final canonical = m.displayName(_lang);

        // When the typed text isn't just a prefix of the canonical name — i.e.
        // it matched via a synonym ("grüne Bohnen" → Prinzessbohne) or carries
        // extra words ("veganer Speck" → Speck) — offer the literal typed name
        // first, linked to the matched ingredient and without a description.
        if (!canonical.toLowerCase().startsWith(fullName.toLowerCase()) &&
            seen.add('${m.id}|$fullName|$unitId|$qty')) {
          out.add(Suggestion(
            ingredientId: m.id,
            displayName: fullName,
            description: '',
            unitId: unitId,
            quantity: qty,
            category: m.category(_lang),
          ));
        }

        if (seen.add('${m.id}|${c.description}|$unitId|$qty')) {
          out.add(Suggestion(
            ingredientId: m.id,
            // Canonical ingredient name so the user sees "Orange" when they typed "oran".
            displayName: canonical,
            description: c.description,
            unitId: unitId,
            quantity: qty,
            category: m.category(_lang),
          ));
        }
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
    try {
      await widget.targetRef.doc(id).update({'doneAt': null});
    } catch (_) {}
    _clearAndKeepFocus();
  }

  Future<void> _addSuggestion(Suggestion s) async {
    if (s.displayName.trim().isEmpty) return;

    // Combine in memory (no read round-trip): same ingredient, no description,
    // single matching unit → sum quantities.
    if (await _combineWithExisting(s)) {
      _clearAndKeepFocus();
      return;
    }

    try {
      final ref = await widget.targetRef.add({
        'ingredientId': s.ingredientId,
        'displayName': s.displayName,
        'description': s.description,
        'doneAt': null,
        'createdAt': FieldValue.serverTimestamp(),
        'quantity': s.quantityMap,
        'category': s.category,
      });
      _clearAndKeepFocus();
      unawaited(_afterUse(ref, s)); // resolve / refresh in the background
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding item: $e')),
        );
      }
    }
  }

  Future<bool> _combineWithExisting(Suggestion s) async {
    if (s.description.isNotEmpty) return false;

    // Null quantity counts as 1 piece in the default unit for combining.
    final newQty = s.quantity ?? 1;
    final newUnitId = s.quantity == null ? kDefaultUnitId : s.unitId;

    for (final data in _currentItems) {
      if (data['doneAt'] != null) continue;
      if ((data['description'] ?? '').toString().isNotEmpty) continue;
      if ((data['displayName'] ?? '').toString().toLowerCase() !=
          s.displayName.toLowerCase()) continue;

      final eq = readQuantity(data['quantity']);
      final existingQty = eq?.qty ?? 1;
      final existingUnitId = eq?.unitId ?? kDefaultUnitId;
      if (existingUnitId != newUnitId) continue;

      final total = existingQty + newQty;
      try {
        await widget.targetRef
            .doc(data['id'] as String)
            .update({'quantity': {newUnitId: total.toDouble()}});
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// After an item was added: resolve pending ones, and for matched ones pull
  /// the ingredient doc from the server (new synonyms land in the cache); if
  /// the doc was deleted meanwhile, re-resolve and fix the item in place.
  Future<void> _afterUse(
      DocumentReference<Map<String, dynamic>> ref, Suggestion s) async {
    if (s.ingredientId == kPendingIngredient) {
      await resolvePendingItem(ref, s.displayName, _lang);
      return;
    }
    final id = await IngredientIndex.instance
        .refreshAfterUse(s.ingredientId, s.displayName, _lang);
    if (id == s.ingredientId) return;
    // ingredientId changed (doc was deleted + re-resolved) — also update category.
    final updates = <String, dynamic>{'ingredientId': id};
    if (id != kPendingIngredient && id != kUnknownIngredient) {
      final candidates = await IngredientIndex.instance.match(s.displayName, _lang);
      final matched = candidates.where((m) => m.id == id).firstOrNull;
      if (matched != null) updates['category'] = matched.category(_lang);
    }
    try {
      await ref.update(updates);
    } catch (_) {}
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
                trailing: [
                  if (_functionRunning)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CupertinoActivityIndicator(),
                      ),
                    ),
                ],
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
                isEmptyQuery && _suggestions.isNotEmpty ? 'Done' : null,
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

bool _wouldCombine(Suggestion s, List<Map<String, dynamic>> currentItems) {
  if (s.description.isNotEmpty || s.isRestoreDone) return false;
  final newUnitId = s.quantity == null ? kDefaultUnitId : s.unitId;
  for (final data in currentItems) {
    if (data['doneAt'] != null) continue;
    if ((data['description'] ?? '').toString().isNotEmpty) continue;
    if ((data['displayName'] ?? '').toString().toLowerCase() !=
        s.displayName.toLowerCase()) continue;
    final existingUnitId =
        readQuantity(data['quantity'])?.unitId ?? kDefaultUnitId;
    if (existingUnitId != newUnitId) continue;
    return true;
  }
  return false;
}

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
            suggestion: s,
            lang: lang,
            onTap: () => onTap(s),
            isAdditive: _wouldCombine(s, currentItems),
          ),
        if (effectiveFallback != null)
          _SuggestionTile(
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
        backgroundColor: isDone ? cs.surfaceContainerHighest : null,
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
