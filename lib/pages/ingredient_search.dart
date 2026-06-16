import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:couple_planner/utils.dart'; // StorageImage

// ─── Configure these ─────────────────────────────────────────────────────────
const String kDefaultUnitId = 'QDXQ6Du2gQgEOoRIRsqJ'; // pcs / Stk unit doc id
const String kPendingIngredient = '0'; // newly added, resolution in progress
const String kUnknownIngredient = '1'; // could not be matched at all

const String _kFunctionsRegion = 'europe-west1';
const String _kResolveFn = 'ingredients-resolveShoppingItem';

const Duration _kFunctionDebounce = Duration(seconds: 2);

// =============================================================================
// Small shared helpers
// =============================================================================

/// Reads the single `{unitId: qty}` entry from a Firestore `quantity` map.
/// Returns null when the field is null or empty — meaning "no quantity".
({String unitId, num qty})? readQuantity(Object? quantity) {
  if (quantity == null) return null;
  final q = Map<String, dynamic>.from(quantity as Map);
  if (q.isEmpty) return null;
  return (unitId: q.keys.first, qty: q.values.first as num);
}

String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String fmtQty(num q) =>
    q == q.roundToDouble() ? q.toInt().toString() : q.toString();

String sanitizeLang(String code) =>
    RegExp(r'^[a-z]{2}').firstMatch(code.toLowerCase())?.group(0) ?? 'en';

// =============================================================================
// Models
// =============================================================================

class MatchedIngredient {
  MatchedIngredient(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;

  String get defaultUnit => (data['defaultUnit'] ?? kDefaultUnitId).toString();

  String displayName(String lang) {
    final n = data['name'];
    return n is Map ? (n[lang] ?? n['en'] ?? '').toString() : '';
  }

  /// Returns the category string to store on list items for sorting.
  /// Handles both plain strings and localized maps.
  String category(String lang) {
    final cat = data['category'];
    if (cat is Map) return (cat[lang] ?? cat['en'] ?? '').toString();
    return (cat ?? '').toString();
  }
}

class Suggestion {
  Suggestion({
    required this.ingredientId,
    required this.displayName,
    required this.description,
    required this.unitId,
    this.quantity,   // null → no quantity (hidden in UI; counts as 1 when combining)
    this.category = '',
    this.isFallback = false,
    this.isRestoreDone = false,
    this.docId,
  });

  final String ingredientId;
  final String displayName;
  final String description;
  final String unitId; // always set; defaults to kDefaultUnitId
  final num? quantity;
  final String category;
  final bool isFallback;
  final bool isRestoreDone;
  final String? docId;

  /// null when there is no quantity — stored as null in Firestore too.
  Map<String, double>? get quantityMap =>
      quantity == null ? null : {unitId: quantity!.toDouble()};

  factory Suggestion.fromMap(Map<String, dynamic> m, {bool isRestoreDone = false}) {
    final q = readQuantity(m['quantity']);
    return Suggestion(
      ingredientId: (m['ingredientId'] ?? kUnknownIngredient).toString(),
      displayName: (m['displayName'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      unitId: q?.unitId ?? kDefaultUnitId,
      quantity: q?.qty,
      category: (m['category'] ?? '').toString(),
      isRestoreDone: isRestoreDone,
      docId: m['id']?.toString(),
    );
  }
}

// =============================================================================
// Unit cache (snapshot listener serves the offline cache first → instant)
// =============================================================================

class UnitModel {
  final String id;

  /// { "en": { "singular": "cup", "plural": "cups" }, "de": { … } }
  final Map<String, dynamic> name;

  /// { "en": ["c."], "de": ["Ts."] }
  final Map<String, dynamic> synonyms;

  /// How much one +/– tap changes the amount for this unit.
  /// Defaults to 1 if not set in Firestore.
  /// Examples: 1 for pieces/grams/ml, 5 for grams when editing in bulk, 0.25 for cups.
  final num defaultIncrement;

  UnitModel(this.id, this.name, this.synonyms, [this.defaultIncrement = 1]);

  // ── Display ──────────────────────────────────────────────────────────────

  /// Returns the localised unit name only (singular or plural).
  /// The caller is responsible for formatting and prepending the amount.
  String display(String lang, num count) {
    final langMap =
    (name[lang] ?? name['en'] ?? const {}) as Map<dynamic, dynamic>;
    final singular = (langMap['singular'] ?? id).toString();
    final plural = (langMap['plural'] ?? singular).toString();
    return count == 1 ? singular : plural;
  }

  // ── Matching (used by recipe parsing / search) ───────────────────────────

  /// Returns true if [word] matches any singular, plural, or synonym for
  /// any language.
  bool matches(String word) {
    final lower = word.toLowerCase();
    for (final entry in name.values) {
      if (entry is Map) {
        if ((entry['singular'] ?? '').toString().toLowerCase() == lower) {
          return true;
        }
        if ((entry['plural'] ?? '').toString().toLowerCase() == lower) {
          return true;
        }
      }
    }
    for (final list in synonyms.values) {
      if (list is List) {
        if (list.any((s) => s.toString().toLowerCase() == lower)) return true;
      }
    }
    return false;
  }
}

// ── Cache ──────────────────────────────────────────────────────────────────

class UnitsCache {
  UnitsCache._();
  static final UnitsCache instance = UnitsCache._();

  final Map<String, UnitModel> _units = {};
  bool _loaded = false;
  StreamSubscription? _sub;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _sub ??= FirebaseFirestore.instance
        .collection('units')
        .snapshots()
        .listen(_apply);
  }

  void _apply(QuerySnapshot snap) {
    for (final d in snap.docs) {
      final data = d.data()! as Map<String, dynamic>;
      _units[d.id] = UnitModel(
        d.id,
        Map<String, dynamic>.from(data['name'] ?? const {}),
        Map<String, dynamic>.from(data['synonyms'] ?? const {}),
        // Fall back to 1 if the field is absent or null
        (data['defaultIncrement'] as num?) ?? 1,
      );
    }
  }

  UnitModel? byId(String? id) => id == null ? null : _units[id];
  List<UnitModel> get all => _units.values.toList();

  UnitModel? matchWord(String word) {
    for (final u in _units.values) {
      if (u.matches(word)) return u;
    }
    return null;
  }

  /// Formats [count] with the correct singular/plural name for [unitId].
  /// Falls back to [kDefaultUnitId] then to the raw id string.
  String display(String? unitId, String lang, num count) =>
      (byId(unitId) ?? byId(kDefaultUnitId))?.display(lang, count) ??
          (unitId ?? kDefaultUnitId);

  /// Returns the step size for +/– controls for [unitId].
  /// Falls back to 1 if the unit is unknown or has no defaultIncrement set.
  num increment(String? unitId) => byId(unitId)?.defaultIncrement ?? 1;

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _loaded = false;
    _units.clear();
  }
}

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
      final fromFn = await resolveViaFunction(displayName);
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
  Future<List<Suggestion>> resolveViaFunction(String query) async {
    final res = await FirebaseFunctions.instanceFor(region: _kFunctionsRegion)
        .httpsCallable(_kResolveFn)
        .call(<String, dynamic>{'query': query.trim()});
    final items = (res.data['items'] as List?) ?? const [];
    return [
      for (final e in items)
        Suggestion.fromMap(Map<String, dynamic>.from(e as Map)),
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
    String lang) async {
  if (!_resolvingPending.add(ref.id)) return;
  try {
    final parsed = parseInput(displayName);
    final cleanName =
        parsed.remaining.isNotEmpty ? parsed.remaining.join(' ') : displayName;
    final id = await IngredientIndex.instance.resolveByName(cleanName, lang);
    final updates = <String, dynamic>{
      'ingredientId': id,
      'displayName': cleanName,
    };
    if (parsed.quantity != null) {
      final unitId = parsed.unitId ?? kDefaultUnitId;
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

// =============================================================================
// Input parser
// =============================================================================

class ParsedInput {
  ParsedInput(this.quantity, this.unitId, this.remaining);
  final num? quantity;
  final String? unitId;
  final List<String> remaining; // tokens that form name + optional description
}

num? _tryNum(String s) => num.tryParse(s.replaceAll(',', '.'));

/// Splits glued tokens ("300g"), extracts a leading/trailing number as the
/// quantity, then a unit word adjacent to it (only when it matches the cache).
ParsedInput parseInput(String input) {
  final tokens = input
      .trim()
      .split(RegExp(r'[\s,]+')) // commas act as separators
      .where((t) => t.isNotEmpty)
      .expand<String>((t) {
    final glued =
        RegExp(r'^(\d+[.,]?\d*)([a-zA-ZäöüÄÖÜß]+)$').firstMatch(t) ??
            RegExp(r'^([a-zA-ZäöüÄÖÜß]+)(\d+[.,]?\d*)$').firstMatch(t);
    return glued != null ? [glued.group(1)!, glued.group(2)!] : [t];
  })
      .toList();

  num? qty;
  if (tokens.isNotEmpty && _tryNum(tokens.first) != null) {
    qty = _tryNum(tokens.removeAt(0));
  } else if (tokens.isNotEmpty && _tryNum(tokens.last) != null) {
    qty = _tryNum(tokens.removeLast());
  }

  String? unitId;
  if (tokens.isNotEmpty) {
    if (UnitsCache.instance.matchWord(tokens.first) case final u?) {
      unitId = u.id;
      tokens.removeAt(0);
    } else if (tokens.length > 1) {
      if (UnitsCache.instance.matchWord(tokens.last) case final u?) {
        unitId = u.id;
        tokens.removeLast();
      }
    }
  }

  return ParsedInput(qty, unitId, tokens);
}

/// Enumerates (name, description) candidates where description is a leading or
/// trailing word run. Full-name-no-description comes first.
List<({String name, String description})> nameDescCandidates(List<String> tokens) {
  final n = tokens.length;
  if (n == 0) return const [];

  final out = <({String name, String description})>[
    (name: tokens.join(' '), description: ''),
  ];
  for (var i = 1; i < n; i++) {
    out.add((name: tokens.sublist(i).join(' '), description: tokens.sublist(0, i).join(' ')));
    out.add((name: tokens.sublist(0, n - i).join(' '), description: tokens.sublist(n - i).join(' ')));
  }

  final seen = <String>{};
  return out.where((c) => c.name.isNotEmpty && seen.add('${c.name}|${c.description}')).toList();
}

/// Progressively shorter substrings to try when resolving a pending item.
List<String> subsetCandidates(String displayName) {
  final tokens =
  displayName.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final n = tokens.length;

  final out = [
    tokens.join(' '),
    for (var i = 1; i < n; i++) tokens.sublist(i).join(' '),
    for (var j = 1; j < n; j++) tokens.sublist(0, n - j).join(' '),
    ...tokens,
  ];

  final seen = <String>{};
  return out.where((s) => seen.add(s.toLowerCase())).toList();
}

// =============================================================================
// Avatar (shared by list rows and suggestion tiles)
// =============================================================================

/// Listens to the ingredient doc so the icon refreshes the moment the
/// icon-generation function finishes (avatarVersion bumps 0 → timestamp).
/// With persistence on, the snapshot listener serves the cached doc instantly.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.ingredientId,
    this.radius = 20,
    this.backgroundColor,
  });

  final String ingredientId;
  final double radius;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (ingredientId == kPendingIngredient) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.surfaceContainerHighest,
        child: const CupertinoActivityIndicator(),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ingredients')
          .doc(ingredientId)
          .snapshots(),
      builder: (context, snap) {
        final version = (snap.data?.data()?['avatarVersion'] ?? 0).toString();
        return CircleAvatar(
          radius: radius,
          backgroundColor: backgroundColor ?? cs.primaryContainer,
          child: StorageImage(
            key: ValueKey('$ingredientId#$version'),
            storagePath: 'ingredients/$ingredientId.png',
            fit: BoxFit.contain,
            memCacheWidth: 128,
            memCacheHeight: 128,
            errorWidget: Text('?', style: Theme.of(context).textTheme.labelMedium),
            placeholder: Text('?', style: Theme.of(context).textTheme.labelMedium),
          ),
        );
      },
    );
  }
}

// =============================================================================
// Search sheet — reusable: pass any collection where items should be created
// =============================================================================

/// Bottom-sheet ingredient search. Adds documents of the shape
/// `{ingredientId, displayName, description, quantity, doneAt, createdAt}`
/// to [targetRef]. Works for the shopping list, recipe ingredient lists, etc.
///
///  * same ingredient + same single unit + no description → quantities merge,
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

      if (local.isEmpty && text.trim().length >= 3) {
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
            _suggestions = fromFn;
            _functionRunning = false;
          });
        });
      }
    }();
  }

  List<Suggestion> _doneItemSuggestions() {
    final done = _currentItems.where((i) => i['doneAt'] != null).toList()
      ..sort((a, b) {
        final ta = a['doneAt'] as Timestamp?;
        final tb = b['doneAt'] as Timestamp?;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta); // newest first
      });
    return done.map((i) => Suggestion.fromMap(i, isRestoreDone: true)).toList();
  }

  Future<List<Suggestion>> _buildLocalSuggestions(String input) async {
    final parsed = parseInput(input);
    final qty = parsed.quantity; // null when the user didn't type a number
    final out = <Suggestion>[];
    final seen = <String>{};

    for (final c in nameDescCandidates(parsed.remaining)) {
      final matches = await IngredientIndex.instance.match(c.name, _lang);
      for (final m in matches) {
        final unitId = parsed.unitId ?? m.defaultUnit;
        if (!seen.add('${m.id}|${c.description}|$unitId|$qty')) continue;
        out.add(Suggestion(
          ingredientId: m.id,
          // Canonical ingredient name so the user sees "Orange" when they typed "oran".
          displayName: m.displayName(_lang),
          description: c.description,
          unitId: unitId,
          quantity: qty,
          category: m.category(_lang),
        ));
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
    final unresolved =
        s.ingredientId == kPendingIngredient || s.ingredientId == kUnknownIngredient;

    // Null quantity counts as 1 piece in kDefaultUnit for combining.
    final newQty = s.quantity ?? 1;
    final newUnitId = s.unitId; // always kDefaultUnitId when quantity was null

    for (final data in _currentItems) {
      if (data['doneAt'] != null) continue;
      if ((data['ingredientId'] ?? '').toString() != s.ingredientId) continue;
      if ((data['description'] ?? '').toString().isNotEmpty) continue;
      if (unresolved &&
          (data['displayName'] ?? '').toString().toLowerCase() !=
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

class _SuggestionsList extends StatelessWidget {
  const _SuggestionsList({
    required this.suggestions,
    required this.fallback,
    required this.lang,
    required this.onTap,
    this.headerLabel,
  });

  final List<Suggestion> suggestions;
  final Suggestion? fallback;
  final String lang;
  final String? headerLabel;
  final ValueChanged<Suggestion> onTap;

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
          _SuggestionTile(suggestion: s, lang: lang, onTap: () => onTap(s)),
        if (effectiveFallback != null)
          _SuggestionTile(
            suggestion: effectiveFallback,
            lang: lang,
            onTap: () => onTap(effectiveFallback),
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
  });

  final Suggestion suggestion;
  final String lang;
  final VoidCallback onTap;

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
      trailing: suggestion.quantity == null
          ? null
          : Text(
        '${fmtQty(suggestion.quantity!)} '
            '${UnitsCache.instance.display(suggestion.unitId, lang, suggestion.quantity!)}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}