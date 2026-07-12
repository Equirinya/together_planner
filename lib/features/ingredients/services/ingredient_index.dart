import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/ingredient_parser.dart';

const String _kFunctionsRegion = 'europe-west1';
const String _kResolveFn = 'ingredients-resolveShoppingItem';

// =============================================================================
// Ingredient index — fast, persistent-cache-first lookups
// =============================================================================

/// Smallest string strictly greater than every string with [prefix] — used for
/// Firestore range prefix queries.
String _prefixEnd(String prefix) {
  if (prefix.isEmpty) return prefix;
  final last = prefix.codeUnitAt(prefix.length - 1);
  return '${prefix.substring(0, prefix.length - 1)}${String.fromCharCode(last + 1)}';
}

/// Ingredient lookups built for speed:
///
///  * [match] answers from Firestore's **offline cache** first
///    (`Source.cache`) — practically instant and it survives app restarts,
///  * the same query is then re-run against the server, debounced so only the
///    prefix the user settled on costs a round-trip; listeners are notified
///    only when the result set actually changed,
///  * [refreshAfterUse] pulls the latest version of a just-used ingredient
///    (new synonyms land in the offline cache for free) and re-resolves it
///    when the doc was deleted — locally first, then via the cloud function.
class IngredientIndex extends ChangeNotifier {
  IngredientIndex._();
  static final IngredientIndex instance = IngredientIndex._();

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('ingredients');

  final Map<String, List<MatchedIngredient>> _results = {}; // key: lang|query
  final Set<String> _serverFresh = {}; // keys already server-confirmed this session
  Timer? _refreshTimer;
  (String key, String text, String lang)? _refreshNext;

  /// Searches ingredients whose name starts with [name] (prefix) or whose
  /// synonyms contain [name] exactly. Names are stored capitalized, synonyms
  /// lowercase — mirrored here. Falls back to English when [lang] isn't English.
  Future<List<MatchedIngredient>> match(String name, String lang) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const [];
    final key = '$lang|${trimmed.toLowerCase()}';

    final hit = _results[key];
    if (hit != null) {
      _scheduleServerRefresh(key, trimmed, lang);
      return hit;
    }

    // Offline cache: instant, no network, empty result if never synced —
    // the server refresh below fills it in and notifies listeners.
    final local = await _query(trimmed, lang, Source.cache);
    _results[key] = local;
    _scheduleServerRefresh(key, trimmed, lang);
    return local;
  }

  /// Call after an ingredient was added to a list. Returns the id the item
  /// should end up with (usually unchanged).
  Future<String> refreshAfterUse(String id, String displayName, String lang) async {
    if (id == kPendingIngredient || id == kUnknownIngredient) {
      return resolveByName(displayName, lang);
    }
    try {
      final doc = await _col.doc(id).get(const GetOptions(source: Source.server));
      if (doc.exists) return id; // fresh synonyms are now in the offline cache
    } catch (_) {
      return id; // offline — keep as-is, refreshed on next use
    }
    invalidate(); // cached query results may still contain the deleted doc
    return resolveByName(displayName, lang);
  }

  /// Local match (progressively shorter substrings) → cloud function → unknown.
  Future<String> resolveByName(String displayName, String lang) async {
    for (final cand in subsetCandidates(displayName)) {
      final matches = await match(cand, lang);
      if (matches.isNotEmpty) return matches.first.id;
    }
    try {
      final fromFn = await resolveViaFunction(displayName, lang);
      final id = fromFn.isEmpty ? '' : fromFn.first.ingredientId;
      if (id.isNotEmpty &&
          id != kPendingIngredient &&
          id != kUnknownIngredient) {
        return id;
      }
    } catch (_) {}
    return kUnknownIngredient;
  }

  /// Fetches the stored category for [id], or '' when unavailable.
  Future<String> categoryById(String id, String lang) async {
    try {
      final doc = await _col.doc(id).get();
      final data = doc.data();
      if (data == null) return '';
      return MatchedIngredient(id, data).category(lang);
    } catch (_) {
      return '';
    }
  }

  /// Cloud-function resolution; throws on failure so callers can react.
  Future<List<Suggestion>> resolveViaFunction(String query, String lang) async {
    final res = await FirebaseFunctions.instanceFor(region: _kFunctionsRegion)
        .httpsCallable(_kResolveFn)
        .call(<String, dynamic>{'query': query.trim(), 'lang': lang});
    final items = (res.data['items'] as List?) ?? const [];
    final keepQty = parseInput(query).quantity != null;
    return [
      for (final e in items)
        Suggestion.fromMap(Map<String, dynamic>.from(e as Map),
            keepQuantity: keepQty),
    ];
  }

  void invalidate() {
    _results.clear();
    _serverFresh.clear();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  void _scheduleServerRefresh(String key, String text, String lang) {
    if (_serverFresh.contains(key)) return;
    _refreshNext = (key, text, lang);
    _refreshTimer?.cancel();
    // Debounced: while typing, only the prefix the user settles on is
    // verified against the server. Everything shown meanwhile came from cache.
    _refreshTimer = Timer(const Duration(milliseconds: 400), () async {
      final next = _refreshNext;
      if (next == null || _serverFresh.contains(next.$1)) return;
      try {
        final fresh = await _query(next.$2, next.$3); // server (default source)
        _serverFresh.add(next.$1);
        final old = _results[next.$1];
        _results[next.$1] = fresh;
        if (!_sameIds(old, fresh)) notifyListeners();
      } catch (_) {
        // offline — cached results stand, retried on the next keystroke
      }
    });
  }

  bool _sameIds(List<MatchedIngredient>? a, List<MatchedIngredient> b) {
    if (a == null || a.length != b.length) return false;
    final ids = a.map((m) => m.id).toSet();
    return b.every((m) => ids.contains(m.id));
  }

  // Note: Firestore may require a composite index for name.<lang> range
  // queries — check the Firebase console on first run.
  Future<List<MatchedIngredient>> _query(
      String trimmed, String lang, [Source? source]) async {
    final opts = source == null ? null : GetOptions(source: source);
    final langs = lang == 'en' ? const ['en'] : [lang, 'en'];
    final cap = capitalize(trimmed);

    final snaps = await Future.wait([
      for (final l in langs) ...[
        _col
            .where('name.$l', isGreaterThanOrEqualTo: cap)
            .where('name.$l', isLessThan: _prefixEnd(cap))
            .limit(20)
            .get(opts),
        _col
            .where('synonyms.$l', arrayContains: trimmed.toLowerCase())
            .limit(20)
            .get(opts),
      ],
    ]);

    final map = <String, MatchedIngredient>{};
    for (final s in snaps) {
      for (final d in s.docs) {
        map.putIfAbsent(d.id, () => MatchedIngredient(d.id, d.data()));
      }
    }
    return map.values.toList();
  }
}

// =============================================================================
// Pending resolution (shared by all hosts of the sheet)
// =============================================================================

final Set<String> _resolvingPending = {};

/// Resolves a `kPendingIngredient` item in place: local match first, then the
/// cloud function, then `kUnknownIngredient`. Host pages call this from their
/// list snapshot listener so items pending from a previous session (or added
/// by the other user) get resolved too. Safe to call repeatedly.
///
/// ⚠ Requires "ingredientId" in the update rule's changedKeys().hasOnly([...]).
Future<void> resolvePendingItem(
    DocumentReference<Map<String, dynamic>> ref,
    String displayName,
    String lang,
    {Object? quantity}) async {
  if (!_resolvingPending.add(ref.id)) return;
  try {
    // Items that already carry a quantity (e.g. adopted from a recipe) keep
    // their name and quantity as-is: their displayName may legitimately contain
    // a number that is part of the ingredient ("Dinkelmehl 630"), not an amount.
    // Only free-text items with no quantity get one parsed out of the name.
    final parsed = readQuantity(quantity) != null ? null : parseInput(displayName);
    final cleanName = (parsed != null && parsed.remaining.isNotEmpty)
        ? parsed.remaining.join(' ')
        : displayName;
    final id = await IngredientIndex.instance.resolveByName(cleanName, lang);
    final updates = <String, dynamic>{
      'ingredientId': id,
      'displayName': cleanName,
    };
    if (parsed?.quantity != null) {
      final unitId = parsed!.unitId ?? kDefaultUnitId;
      updates['quantity'] = {unitId: parsed.quantity!.toDouble()};
    }
    // Populate category from the resolved ingredient. The match results are
    // already cached from resolveByName so this is effectively free.
    if (id != kPendingIngredient && id != kUnknownIngredient) {
      final cat = await IngredientIndex.instance.categoryById(id, lang);
      if (cat.isNotEmpty) updates['category'] = cat;
    }
    await ref.update(updates);
  } catch (_) {
    // left pending; retried on next snapshot / startup
  } finally {
    _resolvingPending.remove(ref.id);
  }
}
