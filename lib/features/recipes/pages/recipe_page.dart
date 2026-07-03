import 'dart:async';
import 'dart:convert';

import 'package:couple_planner/core/date_utils.dart';
import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:animations/animations.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kDefaultUnitId, kPendingIngredient;
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart' show UnitsCache;
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart' show resolvePendingItem;
import 'package:couple_planner/features/ingredients/widgets/avatar.dart' show Avatar;
import 'package:couple_planner/features/ingredients/models/categories.dart' show categoryRank;
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/widgets/create_recipe_sheet.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';

class RecipePage extends StatefulWidget {
  final String groupId;
  final bool shoppingListEnabled;
  final bool aiEnabled;

  const RecipePage({
    super.key,
    required this.groupId,
    required this.shoppingListEnabled,
    required this.aiEnabled,
  });

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  late DocumentReference<Map<String, dynamic>> groupDoc;
  final int daysToShowPrior = 15;
  final int daysToShowFuture = 30;

  late StreamSubscription<bool> keyboardSubscription;
  bool keyboardVisible = false;
  final SearchController _searchController = SearchController();
  String searchQuery = '';

  // ── AI recipe suggestions (shown as tiles, only when aiEnabled) ────────────
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');
  List<String> _dietary = [];
  List<RecipeSuggestion> _suggestions = [];
  Timer? _aiTimer;
  int _aiSeq = 0;

  // ── "Suggested for you" row (shown when not searching) ─────────────────────
  List<RecipeSuggestion> _suggestedRow = [];
  List<RecipeSuggestion> _suggestedPool = [];
  Map<String, int> _dismissed = {};
  static const String _kDismissedKey = 'dismissed_public_recipes';

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? planListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> cookingPlans = [];
  final Set<String> _deletingPlanIds = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? recipesListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> recipes = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> searchedRecipes = [];

  // One stable GlobalKey per cooking-plan id, used to compute drop position.
  final Map<String, GlobalKey> _planCardKeys = {};
  GlobalKey _planKey(String planId) =>
      _planCardKeys.putIfAbsent(planId, () => GlobalKey());

  // Shopping-list rows preloaded when a recipe drag starts, keyed by recipe id,
  // so the add-to-shopping-list dialog can open instantly.
  final Map<String, Future<List<_IngPreload>>> _ingredientPreload = {};
  Future<List<_IngPreload>> _preloadIngredients(String recipeId) =>
      _ingredientPreload.putIfAbsent(
        recipeId,
            () => _ShoppingListDialogState.loadRows(groupDoc, recipeId),
      );

  // Live drop preview: the day (by date key) currently hovered and the index at
  // which a dropped card would be inserted, used to open a gap in that day.
  String? _hoverDayKey;
  int _hoverIndex = -1;

  int _computeInsertIndex(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> dayPlans,
      double pointerDy,
      ) {
    int insertIdx = dayPlans.length;
    for (int i = 0; i < dayPlans.length; i++) {
      final box = _planKey(dayPlans[i].id).currentContext?.findRenderObject()
      as RenderBox?;
      if (box == null) continue;
      final midY = box.localToGlobal(Offset(0, box.size.height / 2)).dy;
      if (pointerDy < midY) {
        insertIdx = i;
        break;
      }
    }
    return insertIdx;
  }

  @override
  void initState() {
    super.initState();
    groupDoc = FirebaseFirestore.instance.collection('groups').doc(widget.groupId);

    final cookingPlanStream = groupDoc
        .collection('cooking_plan')
        .where(
      'plannedFor',
      isGreaterThan: Timestamp.fromDate(
        DateTime.now().subtract(Duration(days: daysToShowPrior)),
      ),
    )
        .orderBy('plannedFor')
        .snapshots();
    planListener = cookingPlanStream.listen((snapshot) {
      setState(() => cookingPlans = snapshot.docs);
    });

    final recipesStream = groupDoc
        .collection('recipes')
        .orderBy('lastUsedAt', descending: true)
        .limit(50)
        .snapshots();
    recipesListener = recipesStream.listen((snapshot) {
      setState(() {
        recipes = snapshot.docs;
        generateSearchedRecipes();
      });
    });

    final keyboardVisibilityController = KeyboardVisibilityController();
    keyboardSubscription = keyboardVisibilityController.onChange.listen((visible) {
      if (!visible) FocusManager.instance.primaryFocus?.unfocus();
      setState(() => keyboardVisible = visible);
    });

    // Dietary preferences drive the AI name suggestions, which public recipes
    // match, and the "suggested for you" row.
    _initSuggestions();
  }

  Future<void> _initSuggestions() async {
    await _loadDismissed();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        final d =
            await FirebaseFirestore.instance.collection('users').doc(uid).get();
        _dietary = List<String>.from(d.data()?['dietaryPreferences'] ?? []);
      } catch (_) {}
    }
    if (mounted) setState(() {});
    await _loadSuggestedRow();
  }

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDismissedKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _dismissed = map.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
    } catch (_) {}
  }

  Future<void> _saveDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDismissedKey, jsonEncode(_dismissed));
    } catch (_) {}
  }

  /// Deterministic 31-bit string hash so every member of a group computes the
  /// same seed/keys (Dart's String.hashCode is not guaranteed stable enough).
  int _stableHash(String s) {
    int h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  /// Loads a dietary-filtered set of public recipes for the suggested row.
  /// Seeded by group + calendar day so everyone in the group sees the same
  /// suggestions (refreshed daily); each user's own dismissals push recipes
  /// down so they resurface less often, without affecting other members.
  Future<void> _loadSuggestedRow() async {
    try {
      final col = FirebaseFirestore.instance.collection('public_recipes');
      const poolSize = 40;
      final now = DateTime.now();
      final seed =
          _stableHash('${widget.groupId}-${now.year}-${now.month}-${now.day}');
      final pivot = (_stableHash('pivot-$seed') % 100000) / 100000.0;
      final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final first = await col
          .where('random', isGreaterThanOrEqualTo: pivot)
          .orderBy('random')
          .limit(poolSize)
          .get();
      docs.addAll(first.docs);
      if (docs.length < poolSize) {
        final second = await col
            .where('random', isLessThan: pivot)
            .orderBy('random')
            .limit(poolSize - docs.length)
            .get();
        docs.addAll(second.docs);
      }
      // Fallback for public recipes missing the `random` field: those documents
      // are excluded from the range queries above, so fetch a plain page rather
      // than leaving the row empty.
      if (docs.isEmpty) {
        final plain = await col.limit(poolSize).get();
        docs.addAll(plain.docs);
      }

      final seen = <String>{};
      final weighted = <MapEntry<double, RecipeSuggestion>>[];
      for (final d in docs) {
        if (!seen.add(d.id)) continue;
        final data = d.data();
        final recipeDietary = List<String>.from(data['dietary'] ?? []);
        if (!_dietary.every(recipeDietary.contains)) continue;
        // Deterministic per-recipe key (identical for every group member),
        // multiplied up by this user's own dismiss count so it sorts later.
        final count = _dismissed[d.id] ?? 0;
        final base = (_stableHash('$seed-${d.id}') % 100000) / 100000.0;
        final key = base * (1 + count * 3);
        weighted.add(MapEntry(
          key,
          RecipeSuggestion(
            kind: SuggestionKind.public,
            title: (data['name'] ?? '').toString(),
            publicId: d.id,
            publicImage: data['image'] as String?,
          ),
        ));
      }
      weighted.sort((a, b) => a.key.compareTo(b.key));
      final ordered = weighted.map((e) => e.value).toList();
      if (!mounted) return;
      setState(() {
        _suggestedRow = ordered.take(8).toList();
        _suggestedPool = ordered.skip(8).toList();
      });
    } catch (e) {
      debugPrint('loadSuggestedRow failed: $e');
    }
  }

  void _dismissSuggested(RecipeSuggestion s) {
    final id = s.publicId;
    if (id == null) return;
    _dismissed[id] = (_dismissed[id] ?? 0) + 1;
    _saveDismissed();
    setState(() {
      _suggestedRow.remove(s);
      if (_suggestedPool.isNotEmpty) _suggestedRow.add(_suggestedPool.removeAt(0));
    });
  }

  Widget _suggestedRowSection(int crossAxisCount) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    final tileW = smallerdim / crossAxisCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text('Suggested for you',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        SizedBox(
          height: tileW * 3 / 4,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            children: [
              for (final s in _suggestedRow) _suggestedTile(s, tileW, crossAxisCount),
            ],
          ),
        ),
      ],
    );
  }

  Widget _suggestedTile(RecipeSuggestion s, double tileW, int crossAxisCount) {
    return SizedBox(
      width: tileW,
      child: Stack(
        children: [
          LongPressDraggable<RecipeSuggestion>(
            data: s,
            feedback: RecipeSuggestionCard(
                suggestion: s, crossAxisCount: crossAxisCount),
            childWhenDragging: RecipeSuggestionCard(
                suggestion: s, crossAxisCount: crossAxisCount),
            child: GestureDetector(
              onTap: () => _openSuggestion(s),
              child: RecipeSuggestionCard(
                  suggestion: s, crossAxisCount: crossAxisCount),
            ),
          ),
          Positioned(
            top: 6,
            right: 10,
            child: GestureDetector(
              onTap: () => _dismissSuggested(s),
              child: Container(
                decoration:
                    const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                padding: const EdgeInsets.all(2),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    planListener?.cancel();
    recipesListener?.cancel();
    keyboardSubscription.cancel();
    _aiTimer?.cancel();
    super.dispose();
  }

  void generateSearchedRecipes() {
    if (searchQuery.isEmpty) {
      searchedRecipes = recipes;
    } else {
      final query = searchQuery.trim().toLowerCase();
      final splitRe = RegExp(r'[ \t\n\r,.;:!?\-()\[\]"\x27\\/]+');
      final queryWords = query.split(splitRe).where((s) => s.isNotEmpty).toList();

      final List<Map<String, dynamic>> scored = [];
      for (final doc in recipes) {
        final data = doc.data();
        final name = (data['name'] ?? '').toString().toLowerCase();
        final description = (data['description'] ?? '').toString().toLowerCase();
        final tags =
        (data['tags'] ?? []).map<String>((e) => e.toString().toLowerCase()).toList();
        final tokens = [
          ...name.split(splitRe).where((s) => s.isNotEmpty),
          ...description.split(splitRe).where((s) => s.isNotEmpty),
          ...tags,
        ];

        double score = 0;
        for (final q in queryWords) {
          for (final t in tokens) {
            if (t == q) {
              score += 5;
              break;
            } else if (t.startsWith(q)) {
              score += 3;
              break;
            } else if (t.contains(q)) {
              score += q.length / t.length;
              break;
            }
          }
        }
        if (score > 0) {
          scored.add({
            'doc': doc,
            'score': score,
            'last': (data['lastUsedAt'] as Timestamp?)?.toDate(),
          });
        }
      }

      scored.sort((a, b) {
        final sc = (b['score'] as double).compareTo(a['score'] as double);
        if (sc != 0) return sc;
        final ma = (a['last'] as DateTime?)?.millisecondsSinceEpoch ?? -1;
        final mb = (b['last'] as DateTime?)?.millisecondsSinceEpoch ?? -1;
        return mb.compareTo(ma);
      });

      searchedRecipes =
          scored.map((e) => e['doc'] as QueryDocumentSnapshot<Map<String, dynamic>>).toList();
    }
    setState(() {});
  }

  // The already-loaded recipe document data for [recipeId], if it's among the
  // streamed recipes, so the detail page can paint its image/title immediately
  // during the open transition instead of flashing a loading state.
  Map<String, dynamic>? _recipeDataFor(String recipeId) {
    for (final r in recipes) {
      if (r.id == recipeId) return r.data();
    }
    return null;
  }

  void addNewRecipe({String? name}) async {
    final newRecipeRef = await _createRecipeDoc(name: name ?? searchQuery);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RecipeDetailPage(
            groupId: widget.groupId,
            recipeId: newRecipeRef.id,
            editMode: true,
            aiEnabled: widget.aiEnabled,
          ),
        ),
      );
    }
  }

  /// Creates a bare recipe document (the shape addNewRecipe used inline) and
  /// returns its reference. Shared by the blank/generated/link/photo flows.
  Future<DocumentReference<Map<String, dynamic>>> _createRecipeDoc({
    required String name,
    String? attribution,
  }) {
    return groupDoc.collection('recipes').add({
      'name': name,
      'description': '',
      'creator': FirebaseAuth.instance.currentUser!.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': null,
      'preparationTime': 0,
      'time': 0,
      'servings': 2,
      'tags': <String>[],
      'images': <String>[],
      'steps': <String>[],
      if (attribution != null) 'attribution': attribution,
    });
  }

  // ── AI suggestions ─────────────────────────────────────────────────────────

  static final _urlRe = RegExp(r'https?://\S+', caseSensitive: false);

  String? _extractUrl(String s) => _urlRe.firstMatch(s)?.group(0);

  /// True when an existing recipe's name already contains the whole query, in
  /// which case the local results are good enough and no AI ideas are shown.
  bool _hasStrongLocalMatch(String query) {
    final q = query.toLowerCase();
    for (final doc in recipes) {
      if ((doc.data()['name'] ?? '').toString().toLowerCase().contains(q)) {
        return true;
      }
    }
    return false;
  }

  /// Called on every keystroke (in addition to [generateSearchedRecipes]).
  /// Debounces AI name ideas by one second; a pasted link shows a globe tile
  /// immediately while its title loads.
  void _onSearchChangedAi(String value) {
    _aiTimer?.cancel();
    final seq = ++_aiSeq;
    final q = value.trim();

    if (!widget.aiEnabled || q.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }

    final url = _extractUrl(q);
    if (url != null) {
      setState(() => _suggestions = [
            RecipeSuggestion(kind: SuggestionKind.url, title: '', url: url, loading: true),
          ]);
      _loadUrlTitle(url, seq);
      return;
    }

    setState(() => _suggestions = []);
    _aiTimer = Timer(const Duration(seconds: 1), () => _runAiSuggestions(q, seq));
  }

  Future<void> _loadUrlTitle(String url, int seq) async {
    String title = url;
    try {
      final res = await _functions
          .httpsCallable('recipes-fetchRecipeTitleFromUrl')
          .call(<String, dynamic>{'url': url, 'lang': LanguageService.instance.code.value});
      final t = (res.data['title'] ?? '').toString().trim();
      if (t.isNotEmpty) title = t;
    } catch (_) {}
    if (!mounted || seq != _aiSeq) return;
    setState(() {
      if (_suggestions.isNotEmpty && _suggestions.first.kind == SuggestionKind.url) {
        _suggestions.first.title = title;
        _suggestions.first.loading = false;
      }
    });
  }

  Future<void> _runAiSuggestions(String q, int seq) async {
    if (!mounted || seq != _aiSeq || _hasStrongLocalMatch(q)) return;
    final results = await Future.wait([_fetchNameIdeas(q), _fetchPublicMatches(q)]);
    if (!mounted || seq != _aiSeq) return;
    setState(() => _suggestions = [...results[1], ...results[0]]);
  }

  Future<List<RecipeSuggestion>> _fetchNameIdeas(String q) async {
    try {
      final res = await _functions
          .httpsCallable('recipes-suggestRecipeNames')
          .call(<String, dynamic>{'groupId': widget.groupId, 'query': q, 'lang': LanguageService.instance.code.value});
      final names = (res.data['names'] as List?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty) ??
          const <String>[];
      return names
          .map((n) => RecipeSuggestion(kind: SuggestionKind.name, title: n))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<RecipeSuggestion>> _fetchPublicMatches(String q) async {
    try {
      final tokens = q
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
          .where((t) => t.length >= 2)
          .toList();
      if (tokens.isEmpty) return [];
      final snap = await FirebaseFirestore.instance
          .collection('public_recipes')
          .where('searchTokens', arrayContainsAny: tokens.take(10).toList())
          .limit(20)
          .get();
      final lang = LanguageService.instance.code.value;
      // Public recipes keep an English base plus a `translations` map for the
      // languages listed in `languages`. Recipes available in the user's
      // language come first (shown translated); the rest fall back to English.
      final own = <RecipeSuggestion>[];
      final english = <RecipeSuggestion>[];
      for (final d in snap.docs) {
        final data = d.data();
        final recipeDietary = List<String>.from(data['dietary'] ?? []);
        // Only offer a public recipe when it satisfies every one of the user's
        // dietary preferences.
        if (!_dietary.every(recipeDietary.contains)) continue;
        final languages = (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
        final hasOwn = lang != 'en' && languages.contains(lang);
        var title = (data['name'] ?? '').toString();
        if (hasOwn) {
          final localized = (data['translations'] as Map?)?[lang] as Map?;
          final name = (localized?['name'] ?? '').toString();
          if (name.isNotEmpty) title = name;
        }
        final suggestion = RecipeSuggestion(
          kind: SuggestionKind.public,
          title: title,
          publicId: d.id,
          publicImage: data['image'] as String?,
        );
        (hasOwn ? own : english).add(suggestion);
      }
      return [...own, ...english].take(4).toList();
    } catch (_) {
      return [];
    }
  }

  // ── acting on a suggestion (tap / drag) ────────────────────────────────────

  Map<String, dynamic> _seedData(String name, {String? attribution}) => {
        'name': name,
        'description': '',
        'images': <String>[],
        'steps': <String>[],
        'tags': <String>[],
        'servings': 2,
        'time': 0,
        'preparationTime': 0,
        if (attribution != null) 'attribution': attribution,
      };

  Future<void> _callStaged(String recipeId, RecipeSuggestion s) {
    final data = <String, dynamic>{'groupId': widget.groupId, 'recipeId': recipeId, 'lang': LanguageService.instance.code.value};
    if (s.kind == SuggestionKind.url) {
      data['source'] = 'url';
      data['url'] = s.url;
    } else {
      data['source'] = 'name';
      data['prompt'] = s.title;
    }
    return _functions.httpsCallable('recipes-generateRecipeStaged').call(data);
  }

  /// Tapping a suggestion: public recipes are copied into the group and opened;
  /// name/link ideas open the detail page immediately and generate in the
  /// background (shimmering the parts that haven't arrived yet).
  Future<void> _openSuggestion(RecipeSuggestion s) async {
    if (s.kind == SuggestionKind.public) {
      try {
        final res = await _functions
            .httpsCallable('recipes-adoptPublicRecipe')
            .call(<String, dynamic>{
          'groupId': widget.groupId,
          'publicRecipeId': s.publicId,
          'lang': LanguageService.instance.code.value,
        });
        final recipeId = res.data['recipeId'] as String?;
        if (recipeId != null && mounted) _pushDetail(recipeId);
      } catch (_) {
        _snack('Could not add this recipe.');
      }
      return;
    }

    final name = s.kind == SuggestionKind.name ? s.title : '';
    final ref = await _createRecipeDoc(
        name: name, attribution: s.kind == SuggestionKind.url ? s.url : null);
    if (!mounted) return;
    _pushDetail(
      ref.id,
      generating: true,
      initialData:
          _seedData(name, attribution: s.kind == SuggestionKind.url ? s.url : null),
    );
    // Fire and forget; the detail page streams progress from the document.
    _callStaged(ref.id, s).ignore();
  }

  void _pushDetail(String recipeId,
      {bool generating = false, Map<String, dynamic>? initialData}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          groupId: widget.groupId,
          recipeId: recipeId,
          aiEnabled: widget.aiEnabled,
          generating: generating,
          initialData: initialData,
        ),
      ),
    );
  }

  /// Resolves any still-pending (unmatched) ingredients of a freshly generated
  /// or adopted recipe in place, so the shopping-list dialog shows clean names.
  Future<void> _resolvePendingIngredients(String recipeId) async {
    final lang = LanguageService.instance.code.value;
    final ingRef =
        groupDoc.collection('recipes').doc(recipeId).collection('ingredients');
    final snap = await ingRef.get();
    await Future.wait(snap.docs
        .where((d) => (d.data()['ingredientId'] ?? '').toString() == kPendingIngredient)
        .map((d) => resolvePendingItem(
              ingRef.doc(d.id),
              (d.data()['displayName'] ?? '').toString(),
              lang,
            )));
  }

  /// Dragging a suggestion onto a day: generate/adopt the recipe (loading
  /// dialog), then plan it and open the add-to-shopping-list dialog.
  Future<void> _handleSuggestionDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    RecipeSuggestion s,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _GeneratingDialog(),
    );
    String? recipeId;
    try {
      if (s.kind == SuggestionKind.public) {
        final res = await _functions
            .httpsCallable('recipes-adoptPublicRecipe')
            .call(<String, dynamic>{
          'groupId': widget.groupId,
          'publicRecipeId': s.publicId,
          'lang': LanguageService.instance.code.value,
        });
        recipeId = res.data['recipeId'] as String?;
      } else {
        final ref = await _createRecipeDoc(
            name: s.kind == SuggestionKind.name ? s.title : '',
            attribution: s.kind == SuggestionKind.url ? s.url : null);
        recipeId = ref.id;
        await _callStaged(recipeId, s);
      }
      if (recipeId != null) await _resolvePendingIngredients(recipeId);
    } catch (_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _snack('Could not generate this recipe.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close loading dialog
    if (recipeId == null) return;
    final snap = await groupDoc.collection('recipes').doc(recipeId).get();
    if (mounted) _handleDrop(day, plans, index, snap);
  }

  // ── create menu (plus button) ──────────────────────────────────────────────

  Future<void> _openCreateMenu() async {
    final result = await showModalBottomSheet<CreateRecipeResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CreateRecipeSheet(aiEnabled: widget.aiEnabled),
    );
    if (result == null || !mounted) return;
    switch (result.type) {
      case CreateRecipeType.blank:
        addNewRecipe(name: result.text ?? '');
        break;
      case CreateRecipeType.photo:
        _createFromPhoto();
        break;
      case CreateRecipeType.text:
        _createFromText(result.text ?? '');
        break;
    }
  }

  Future<void> _createFromText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final url = _extractUrl(t);
    final name = url != null ? '' : t;
    final ref = await _createRecipeDoc(name: name, attribution: url);
    if (!mounted) return;
    _pushDetail(ref.id,
        generating: true, initialData: _seedData(name, attribution: url));
    _callStaged(
      ref.id,
      url != null
          ? RecipeSuggestion(kind: SuggestionKind.url, title: t, url: url)
          : RecipeSuggestion(kind: SuggestionKind.name, title: t),
    ).ignore();
  }

  Future<void> _createFromPhoto() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (image == null || !mounted) return;
    final bytes = await image.readAsBytes();
    final ref = await _createRecipeDoc(name: '');
    if (!mounted) return;
    _pushDetail(ref.id, generating: true, initialData: _seedData(''));
    _functions.httpsCallable('recipes-generateRecipeStaged').call(<String, dynamic>{
      'groupId': widget.groupId,
      'recipeId': ref.id,
      'source': 'photo',
      'imageBase64': base64Encode(bytes),
      'imageMimeType': image.mimeType ?? 'image/jpeg',
      'lang': LanguageService.instance.code.value,
    }).ignore();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Computes a [Timestamp] at the midpoint of the gap between the plan at
  /// [index − 1] and [index] within [plans] for [day], then creates or moves
  /// the dragged [data] to that position.
  ///
  /// The outer [DragTarget] per day deliberately has no [onAcceptWithDetails]
  /// and only provides the colour highlight. All actual drops are routed here
  /// through the inner per-plan targets and the append-zone target, which
  /// avoids double-firing from nested DragTargets.
  Future<void> _handleDrop(
      DateTime day,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
      int index,
      DocumentSnapshot<Map<String, dynamic>> data,
      ) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    // Exclude the dragged plan from neighbour computation (no-op for recipes).
    final others = plans.where((p) => p.id != data.id).toList();

    // When the dragged item sat before the drop position in the original list,
    // its removal shifts every subsequent index down by one in `others`.
    int insertIdx = index;
    final selfOrigIdx = plans.indexWhere((p) => p.id == data.id);
    if (selfOrigIdx >= 0 && selfOrigIdx < index) {
      insertIdx = (index - 1).clamp(0, others.length);
    }

    final beforeDt = insertIdx <= 0
        ? start
        : (others[insertIdx - 1]['plannedFor'] as Timestamp).toDate();
    final afterDt = insertIdx >= others.length
        ? end
        : (others[insertIdx]['plannedFor'] as Timestamp).toDate();
    final ts = Timestamp.fromDate(
      beforeDt.add(
        Duration(milliseconds: afterDt.difference(beforeDt).inMilliseconds ~/ 2),
      ),
    );

    if (data.reference.parent.id == 'recipes') {
      final servings = ((data.data() as Map<String, dynamic>?)?['servings'] ?? 2) as num;
      // Create the document reference synchronously and write without awaiting,
      // so the dialog can open immediately instead of waiting for the write.
      final planRef = groupDoc.collection('cooking_plan').doc();
      planRef.set({
        'recipe': data.id,
        'plannedFor': ts,
        'servings': servings,
      });
      data.reference.update({'lastUsedAt': FieldValue.serverTimestamp()});
      if (widget.shoppingListEnabled && mounted) {
        // Resolve the rows first (preloaded when dragging started, or a fresh
        // load) so the dialog only opens when the recipe actually has
        // ingredients to add — no loading dialog flashes for empty recipes.
        final rowsFuture = _ingredientPreload[data.id] ?? _preloadIngredients(data.id);
        _ingredientPreload.remove(data.id); // avoid serving stale preference data
        final rows = await rowsFuture;
        if (rows.isNotEmpty && mounted) {
          showDialog(
            context: context,
            builder: (_) => _ShoppingListDialog(
              group: groupDoc,
              recipeId: data.id,
              planRef: planRef,
              recipeServings: servings.toInt(),
              preloadedRows: rows,
            ),
          );
        }
      }
    } else if (data.reference.parent.id == 'cooking_plan') {
      data.reference.update({'plannedFor': ts});
    }
  }

  /// Removes a cooking-plan document and subtracts its contributed ingredient
  /// quantities from the shopping list (deletes shopping-list entries that
  /// reach zero).
  Future<void> _removePlan(DocumentReference<Map<String, dynamic>> planRef) async {
    setState(() => _deletingPlanIds.add(planRef.id));
    // The plan now stores the shopping-list item ids it contributed to and the
    // matching quantities as parallel arrays, instead of an added_ingredients
    // subcollection.
    final planSnap = await planRef.get();
    final planData = planSnap.data() ?? {};
    final itemIds = List<String>.from(planData['itemIds'] ?? const []);
    final quantities = (planData['quantities'] as List?) ?? const [];
    // Read all affected shopping-list items in parallel, then apply every
    // change (and the plan deletion) as a single atomic batch commit.
    final snaps = await Future.wait([
      for (final id in itemIds) groupDoc.collection('shopping_list').doc(id).get(),
    ]);
    final batch = FirebaseFirestore.instance.batch();
    for (int i = 0; i < snaps.length; i++) {
      final itemSnap = snaps[i];
      if (!itemSnap.exists) continue;
      final q = i < quantities.length
          ? Map<String, dynamic>.from(quantities[i] as Map? ?? {})
          : <String, dynamic>{};
      final cur = Map<String, dynamic>.from(itemSnap['quantity'] ?? {});
      q.forEach((k, v) {
        if (cur.containsKey(k)) {
          final n = (cur[k] as num) - (v as num);
          n > 0 ? cur[k] = n : cur.remove(k);
        }
      });
      cur.isEmpty
          ? batch.delete(itemSnap.reference)
          : batch.update(itemSnap.reference, {'quantity': cur});
    }
    batch.delete(planRef);
    await batch.commit();
    if (mounted) setState(() => _deletingPlanIds.remove(planRef.id));
  }

  @override
  Widget build(BuildContext context) {
    final displaySize = MediaQuery.of(context).size;
    final colorScheme = Theme.of(context).colorScheme;
    final isTablet = displaySize.shortestSide >= 600;
    final crossAxisCount = isTablet
        ? (displaySize.width < displaySize.height
        ? 5
        : displaySize.width ~/ (displaySize.height / 5))
        : (displaySize.width < displaySize.height
        ? 3
        : displaySize.width ~/ (displaySize.height / 3));
    final carouselWeights =
    isTablet ? const <int>[1, 2, 2, 2, 2, 1] : const <int>[1, 3, 3, 1];
    final planCrossAxisCount =
    isTablet && displaySize.width < displaySize.height ? 5 : 3;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        // ── Calendar carousel ──────────────────────────────────────────────
        AnimatedSize(
          alignment: Alignment.topCenter,
          duration: const Duration(milliseconds: 300),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: displaySize.height / (keyboardVisible ? 4 : 3),
              minHeight: displaySize.height / 4,
            ),
            child: CarouselView.weighted(
              flexWeights: carouselWeights,
              enableSplash: false,
              controller: CarouselController(initialItem: daysToShowPrior),
              children: List.generate(
                daysToShowPrior + daysToShowFuture,
                    (i) => DateTime.now()
                    .subtract(Duration(days: daysToShowPrior))
                    .add(Duration(days: i)),
              ).map((day) {
                final dayPlans = cookingPlans.where((plan) {
                  if (_deletingPlanIds.contains(plan.id)) return false;
                  final d = (plan['plannedFor'] as Timestamp).toDate();
                  return d.year == day.year && d.month == day.month && d.day == day.day;
                }).toList();
                final bool isToday = DateTime.now().difference(day).inHours < 1 &&
                    DateTime.now().difference(day).inHours > -1;
                final String dateString = getRelativeDateString(day);
                final String dayKey = '${day.year}-${day.month}-${day.day}';

                // Single DragTarget per day. onAcceptWithDetails computes the
                // insertion index from each plan card's GlobalKey midpoint, so
                // there are no nested DragTargets and no double-fire issues.
                return DragTarget<Object>(
                  onWillAcceptWithDetails: (d) {
                    final data = d.data;
                    return (data is DocumentSnapshot<Map<String, dynamic>> &&
                            ['cooking_plan', 'recipes']
                                .contains(data.reference.parent.id)) ||
                        data is RecipeSuggestion;
                  },
                  onMove: (d) {
                    final idx = _computeInsertIndex(dayPlans, d.offset.dy);
                    if (_hoverDayKey != dayKey || _hoverIndex != idx) {
                      setState(() {
                        _hoverDayKey = dayKey;
                        _hoverIndex = idx;
                      });
                    }
                  },
                  onLeave: (_) {
                    if (_hoverDayKey == dayKey) {
                      setState(() {
                        _hoverDayKey = null;
                        _hoverIndex = -1;
                      });
                    }
                  },
                  onAcceptWithDetails: (d) {
                    final insertIdx = _computeInsertIndex(dayPlans, d.offset.dy);
                    if (_hoverDayKey != null) {
                      setState(() {
                        _hoverDayKey = null;
                        _hoverIndex = -1;
                      });
                    }
                    final data = d.data;
                    if (data is RecipeSuggestion) {
                      _handleSuggestionDrop(day, dayPlans, insertIdx, data);
                    } else if (data is DocumentSnapshot<Map<String, dynamic>>) {
                      _handleDrop(day, dayPlans, insertIdx, data);
                    }
                  },
                  builder: (context, candidateData, _) {
                    final Color color = candidateData.isNotEmpty
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerLow;
                    return Container(
                      decoration: BoxDecoration(
                        color: color,
                        gradient: isToday
                            ? LinearGradient(
                          colors: [
                            Color.lerp(color, colorScheme.primary, 0.1)!,
                            color,
                          ],
                          begin: Alignment.centerLeft,
                          end: const Alignment(-0.7, 0),
                        )
                            : null,
                      ),
                      child: Column(
                        children: [
                          Text(
                            dateString,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Column(
                                children: [
                                  for (int i = 0; i < dayPlans.length; i++)
                                    AnimatedPadding(
                                      duration: const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      // Open a gap above this card while a drag
                                      // hovers at its index, so the incoming
                                      // recipe visibly makes room for itself.
                                      padding: EdgeInsets.only(
                                        top: (_hoverDayKey == dayKey &&
                                            _hoverIndex == i)
                                            ? 72
                                            : 0,
                                      ),
                                      child: Container(
                                        key: _planKey(dayPlans[i].id),
                                        child: LongPressDraggable<
                                            DocumentSnapshot<Map<String, dynamic>>>(
                                          data: dayPlans[i],
                                          feedback: RecipeCard(
                                            recipeId: dayPlans[i]['recipe'],
                                            groupCollection: groupDoc,
                                            data: _recipeDataFor(dayPlans[i]['recipe']),
                                            crossAxisCount: planCrossAxisCount,
                                          ),
                                          childWhenDragging: const SizedBox.shrink(),
                                          child: _RecipeOpenContainer(
                                            recipeId: dayPlans[i]['recipe'],
                                            groupId: groupDoc.id,
                                            groupDoc: groupDoc,
                                            aiEnabled: widget.aiEnabled,
                                            initialData:
                                            _recipeDataFor(dayPlans[i]['recipe']),
                                            child: RecipeCard(
                                              recipeId: dayPlans[i]['recipe'],
                                              groupCollection: groupDoc,
                                              data: _recipeDataFor(dayPlans[i]['recipe']),
                                              cropContent: true,
                                              crossAxisCount: planCrossAxisCount,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  // Gap shown when the drop position is the end
                                  // of the list.
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 150),
                                    curve: Curves.easeOut,
                                    child: SizedBox(
                                      height: (_hoverDayKey == dayKey &&
                                          _hoverIndex >= dayPlans.length)
                                          ? 72
                                          : 0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }).toList(),
            ),
          ),
        ),
        // ── Recipe grid + search bar + delete target ───────────────────────
        Expanded(
          child: Stack(
            children: [
              Column(
                children: [
                  // ── "Suggested for you" row (only when not searching) ──────
                  if (searchQuery.trim().isEmpty && _suggestedRow.isNotEmpty)
                    _suggestedRowSection(crossAxisCount),
                  Expanded(
                    child: GridView.count(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 72 + 32),
                crossAxisCount: crossAxisCount,
                children: [
                  // AI suggestion tiles first, then matching recipes.
                  if (widget.aiEnabled && searchQuery.trim().isNotEmpty)
                    for (final s in _suggestions)
                      LongPressDraggable<RecipeSuggestion>(
                        data: s,
                        feedback: RecipeSuggestionCard(
                            suggestion: s, crossAxisCount: crossAxisCount),
                        childWhenDragging: RecipeSuggestionCard(
                            suggestion: s, crossAxisCount: crossAxisCount),
                        child: GestureDetector(
                          onTap: () => _openSuggestion(s),
                          child: RecipeSuggestionCard(
                              suggestion: s, crossAxisCount: crossAxisCount),
                        ),
                      ),
                  ...searchedRecipes.map(
                      (e) => LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
                    key: ValueKey(e.id),
                    data: e,
                    onDragStarted: () => _preloadIngredients(e.id),
                    feedback: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                    childWhenDragging:
                    RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                    child: _RecipeOpenContainer(
                      recipeId: e.id,
                      groupId: widget.groupId,
                      groupDoc: groupDoc,
                      aiEnabled: widget.aiEnabled,
                      initialData: e.data(),
                      child: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                    ),
                  ),
                ),
                ],
                    ),
                  ),
                ],
              ),
              // ── Search bar ─────────────────────────────────────────────
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: keyboardVisible
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: SearchBar(
                    shape: WidgetStatePropertyAll(
                      keyboardVisible
                          ? const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      )
                          : const StadiumBorder(),
                    ),
                    controller: _searchController,
                    hintText: 'Search recipes',
                    leading: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.search,
                          color: colorScheme.onSurfaceVariant),
                    ),
                    onChanged: (value) {
                      searchQuery = value;
                      generateSearchedRecipes();
                      _onSearchChangedAi(value);
                    },
                    trailing: [
                      IconButton(
                          onPressed: _openCreateMenu,
                          icon: const Icon(Icons.add)),
                    ],
                  ),
                ),
              ),
              // ── Delete target ──────────────────────────────────────────
              DragTarget<Object>(
                builder: (context, candidateData, _) {
                  final first = candidateData.isNotEmpty ? candidateData.first : null;
                  return Visibility(
                    visible: first is DocumentSnapshot<Map<String, dynamic>> &&
                        first.reference.parent.id == 'cooking_plan',
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: colorScheme.errorContainer.withAlpha(200),
                      ),
                      child: Center(
                        child: Icon(Icons.delete_outline,
                            size: 128, color: colorScheme.onErrorContainer),
                      ),
                    ),
                  );
                },
                onWillAcceptWithDetails: (d) =>
                    d.data is DocumentSnapshot<Map<String, dynamic>> &&
                    (d.data as DocumentSnapshot).reference.parent.id == 'cooking_plan',
                onAcceptWithDetails: (d) {
                  final data = d.data;
                  if (data is DocumentSnapshot<Map<String, dynamic>> &&
                      data.reference.parent.id == 'cooking_plan') {
                    _removePlan(data.reference);
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── RecipeOpenContainer ──────────────────────────────────────────────────────

/// Wraps a recipe card so tapping it expands the card into the full
/// [RecipeDetailPage] with a Material container transform.
class _RecipeOpenContainer extends StatelessWidget {
  const _RecipeOpenContainer({
    required this.recipeId,
    required this.groupId,
    required this.groupDoc,
    required this.aiEnabled,
    required this.initialData,
    required this.child,
  });

  final String recipeId;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final bool aiEnabled;
  final Map<String, dynamic>? initialData;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return OpenContainer(
      tappable: false,
      transitionType: ContainerTransitionType.fade,
      transitionDuration: const Duration(milliseconds: 300),
      closedElevation: 0,
      closedColor: Colors.transparent,
      openColor: Theme.of(context).scaffoldBackgroundColor,
      closedShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      closedBuilder: (_, open) => GestureDetector(onTap: open, child: child),
      openBuilder: (_, __) => RecipeDetailPage(
        groupId: groupId,
        recipeId: recipeId,
        aiEnabled: aiEnabled,
        initialData: initialData,
      ),
    );
  }
}

// ─── RecipeCard ───────────────────────────────────────────────────────────────

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.recipeId,
    required this.groupCollection,
    this.data,
    this.cropContent = false,
    this.crossAxisCount = 3,
  });

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;
  final Map<String, dynamic>? data;

  /// When true, the inner content is laid out at the card's full size and
  /// cropped by the rounded frame instead of shrinking with the available
  /// width (used inside the calendar carousel).
  final bool cropContent;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    // Full inner size of the card at its unconstrained width, used to keep the
    // content at a fixed size and crop it when [cropContent] is set.
    final fullContentWidth = smallerdim / crossAxisCount - 8;
    final fullContentHeight = smallerdim / crossAxisCount * 3 / 4 - 8;
    final primaryColor = HSVColor.fromColor(Theme.of(context).colorScheme.primary);
    final primaryContainerColor =
    HSVColor.fromColor(Theme.of(context).colorScheme.primaryContainer);
    final color = HSVColor.fromAHSV(
      1.0,
      (recipeId.hashCode % 360).toDouble(),
      primaryColor.saturation,
      primaryColor.value,
    );
    final containerColor =
    color.withValue((primaryContainerColor.value + primaryColor.value) / 2);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: smallerdim / crossAxisCount,
        minHeight: smallerdim / crossAxisCount * 3 / 4,
        minWidth: smallerdim / crossAxisCount,
      ),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: (recipeId != null && groupCollection != null)
                  ? BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: containerColor.toColor(),
              )
                  : BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  width: 2,
                ),
              ),
              child: !cropContent
                  ? _content(context, color)
                  : OverflowBox(
                minWidth: fullContentWidth,
                maxWidth: fullContentWidth,
                minHeight: fullContentHeight,
                maxHeight: fullContentHeight,
                alignment: Alignment.center,
                child: _content(context, color),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _content(BuildContext context, HSVColor color) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    if (recipeId == null || groupCollection == null) return null;
    Widget buildContent(Map<String, dynamic> recipeData) {
        final images = List<String>.from(recipeData['images'] ?? []);
        return LayoutBuilder(
          builder: (context, constraints) {
            final double sd =
            constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
            final dpr = MediaQuery.of(context).devicePixelRatio;
            return Stack(
              children: [
                if (images.isNotEmpty) ...[
                  SizedBox.expand(
                    child: StorageImage(
                      storagePath: images.first,
                      fit: BoxFit.cover,
                      memCacheHeight:
                      (constraints.maxHeight * dpr).toInt(),
                    ),
                  ),
                  Container(color: Colors.black26),
                ] else
                  Align(
                    alignment: const Alignment(0, -0.3),
                    child: Icon(
                      Icons.restaurant_menu,
                      size: sd / 2,
                      color: color.toColor(),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical:4, horizontal: 6),
                    child: Text(
                      recipeData['name'] ?? 'Unnamed Recipe',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                          color: Colors.white, height: 1.2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          },
        );
    }
    if (data != null) return buildContent(data!);
    return LoadDocumentBuilder(
      docRef: groupCollection!.collection('recipes').doc(recipeId),
      builder: buildContent,
    );
  }
}

// ─── Shopping-list dialog ─────────────────────────────────────────────────────

/// Immutable snapshot of a recipe ingredient used to (pre)load the shopping
/// list dialog: id, localised name, base quantities, default add flag and
/// category. Kept separate from [_IngRow] so cached preloads stay pristine
/// across repeated drags while each dialog gets its own mutable rows.
class _IngPreload {
  final String id;
  final String name;
  final String description;
  final Map<String, num?> base;
  final bool added;
  final String category;
  final String unit; // default unit to seed a quantity from when there is none
  const _IngPreload(this.id, this.name, this.description, this.base, this.added,
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

class _ShoppingListDialog extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> group;
  final String recipeId;
  final DocumentReference<Map<String, dynamic>> planRef;
  final int recipeServings;
  final List<_IngPreload> preloadedRows;

  const _ShoppingListDialog({
    required this.group,
    required this.recipeId,
    required this.planRef,
    required this.recipeServings,
    required this.preloadedRows,
  });

  @override
  State<_ShoppingListDialog> createState() => _ShoppingListDialogState();
}

class _ShoppingListDialogState extends State<_ShoppingListDialog> {
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
  static Future<List<_IngPreload>> loadRows(
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
    if (ingSnap.docs.isEmpty) return const <_IngPreload>[];

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
      return _IngPreload(id, name, description, base, added, category, unit);
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

// ─── Generating dialog ─────────────────────────────────────────────────────────

/// Blocking loading dialog shown while a dragged suggestion is being generated
/// or adopted, before the add-to-shopping-list dialog opens.
class _GeneratingDialog extends StatelessWidget {
  const _GeneratingDialog();

  @override
  Widget build(BuildContext context) {
    return const Dialog(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(),
            SizedBox(width: 16),
            Flexible(child: Text('Generating recipe…')),
          ],
        ),
      ),
    );
  }
}