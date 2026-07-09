import 'dart:async';
import 'dart:convert';

import 'package:couple_planner/core/date_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kPendingIngredient;
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart' show resolvePendingItem;
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/widgets/create_recipe_sheet.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_card.dart';
import 'package:couple_planner/features/recipes/widgets/suggested_row.dart';
import 'package:couple_planner/features/recipes/widgets/add_to_shopping_list_dialog.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/recipe_suggestions.dart';
import 'package:couple_planner/features/settings/recipe_suggestion_notifier.dart';

/// Lets a parent widget (the bottom-nav host) query whether the recipe page's
/// search is currently active and clear it, so a system back press can close
/// the search before falling through to the app's normal back behaviour.
class RecipePageController {
  VoidCallback? _clearSearch;
  final ValueNotifier<bool> hasSearch = ValueNotifier(false);
  final ValueNotifier<bool> keyboardVisible = ValueNotifier(false);

  /// Clears the search if one is active. Returns whether it did so.
  bool clearSearchIfActive() {
    if (!hasSearch.value) return false;
    _clearSearch?.call();
    return true;
  }
}

class RecipePage extends StatefulWidget {
  final String groupId;
  final bool shoppingListEnabled;
  final bool aiEnabled;
  final bool canEditPublicRecipes;
  final RecipePageController? controller;

  const RecipePage({
    super.key,
    required this.groupId,
    required this.shoppingListEnabled,
    required this.aiEnabled,
    this.canEditPublicRecipes = false,
    this.controller,
  });

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage>
    with RecipeSuggestionsMixin, SuggestedRowMixin {
  late DocumentReference<Map<String, dynamic>> groupDoc;
  final int daysToShowPrior = 15;
  final int daysToShowFuture = 30;

  late StreamSubscription<bool> keyboardSubscription;
  bool keyboardVisible = false;
  final SearchController _searchController = SearchController();
  String searchQuery = '';

  final ScrollController _scrollController = ScrollController();

  bool _isDraggingSuggestion = false;
  bool _isDraggingPlan = false;

  bool _suggestionsEnabled = true;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? planListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> cookingPlans = [];
  final Set<String> _deletingPlanIds = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? recipesListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> recipes = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> searchedRecipes = [];

  // Growable window over the group's recipes: the listener starts at [_recipeLimit]
  // and grows by [_recipePageSize] whenever the grid is scrolled near its end and
  // the previous page came back full (so more recipes likely exist).
  static const int _recipePageSize = 50;
  int _recipeLimit = _recipePageSize;
  bool _recipesMaybeMore = true;
  // While searching, the window is widened to cover the whole group so search
  // isn't limited to whatever page happened to be loaded already.
  static const int _allRecipesLimit = 100000;
  bool _searchActive = false;

  // How often each recipe has been cooked (past cooking-plan entries within
  // [_usageWindowDays]) and which recipes are already planned in the future.
  // Drives the "cook again" ordering of the recipe grid; usage is read from the
  // cooking plans rather than stored on the recipe.
  static const int _usageWindowDays = 180;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? usageListener;
  @override
  Map<String, int> usageCounts = {};
  @override
  Set<String> futurePlanned = {};
  @override
  Map<String, DateTime> lastUsedDates = {};

  // Freezes each recipe's "cook again" score the first time it's computed, so
  // adding it to the plan (or otherwise changing its usage data) doesn't
  // instantly reshuffle the grid mid-session — e.g. while adding the same
  // recipe to several days in a row. The grid re-settles into a fresh order
  // on the next app start.
  @override
  final Map<String, double> scoreCache = {};
  // Guards scoreCache against caching scores computed before the usage
  // stream's first snapshot arrives (which would otherwise freeze every
  // recipe at a wrong, history-less score for the rest of the session).
  @override
  bool usageLoaded = false;

  // One stable GlobalKey per cooking-plan id, used to compute drop position.
  final Map<String, GlobalKey> _planCardKeys = {};
  GlobalKey _planKey(String planId) =>
      _planCardKeys.putIfAbsent(planId, () => GlobalKey());

  // Shopping-list rows preloaded when a recipe drag starts, keyed by recipe id,
  // so the add-to-shopping-list dialog can open instantly.
  final Map<String, Future<List<IngPreload>>> _ingredientPreload = {};

  // Public recipe data preloaded when a suggestion drag starts, keyed by public
  // recipe id. Awaited on drop so the recipe doc can be written immediately.
  final Map<String, Future<PublicRecipePreload>> _publicPreload = {};

  // Recipe ids whose image upload is still in progress after an instant adopt.
  // Plan tiles for these recipes show a loading overlay until the upload finishes.
  final Set<String> _uploadingRecipeIds = {};
  Future<List<IngPreload>> _preloadIngredients(String recipeId) =>
      _ingredientPreload.putIfAbsent(
        recipeId,
            () => AddToShoppingListDialogState.loadRows(groupDoc, recipeId),
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
    widget.controller?._clearSearch = _clearSearch;
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

    _subscribeRecipes();
    _scrollController.addListener(_maybeLoadMoreRecipes);

    // A longer window over the cooking plans, used only to derive how often each
    // recipe is cooked (and whether it is already planned ahead) for ordering.
    final usageStream = groupDoc
        .collection('cooking_plan')
        .where(
          'plannedFor',
          isGreaterThan: Timestamp.fromDate(
            DateTime.now().subtract(Duration(days: _usageWindowDays)),
          ),
        )
        .snapshots();
    usageListener = usageStream.listen((snapshot) {
      final counts = <String, int>{};
      final future = <String>{};
      final lastUsed = <String, DateTime>{};
      final now = DateTime.now();
      for (final d in snapshot.docs) {
        final rid = d.data()['recipe'];
        final when = (d.data()['plannedFor'] as Timestamp?)?.toDate();
        if (rid is! String || when == null) continue;
        if (when.isAfter(now)) {
          future.add(rid);
        } else {
          counts[rid] = (counts[rid] ?? 0) + 1;
          final prev = lastUsed[rid];
          if (prev == null || when.isAfter(prev)) lastUsed[rid] = when;
        }
      }
      setState(() {
        usageCounts = counts;
        futurePlanned = future;
        lastUsedDates = lastUsed;
        usageLoaded = true;
        generateSearchedRecipes();
      });
    });

    final keyboardVisibilityController = KeyboardVisibilityController();
    keyboardSubscription = keyboardVisibilityController.onChange.listen((visible) {
      if (!visible) FocusManager.instance.primaryFocus?.unfocus();
      setState(() => keyboardVisible = visible);
      widget.controller?.keyboardVisible.value = visible;
    });

    // Dietary preferences drive the AI name suggestions, which public recipes
    // match, and the "suggested for you" row.
    _initSuggestions();
    RecipeSuggestionNotifier.instance.addListener(_initSuggestions);
  }

  Future<void> _initSuggestions() async {
    await loadDismissed();
    final prefs = await SharedPreferences.getInstance();
    _suggestionsEnabled = prefs.getBool('recipe_suggestions_enabled') ?? true;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    // Fetch dietary prefs and the suggested row concurrently rather than
    // sequentially: loadSuggestedRow only reads `dietary` once it starts
    // scoring, well after its own network round trips are already underway.
    final dietaryFuture = uid == null ? null : _loadDietaryPreferences(uid);
    final rowFuture = _suggestionsEnabled ? loadSuggestedRow() : null;
    if (dietaryFuture != null) await dietaryFuture;
    if (mounted) setState(() {});
    if (rowFuture != null) await rowFuture;
  }

  Future<void> _loadDietaryPreferences(String uid) async {
    try {
      final d =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      dietary = List<String>.from(d.data()?['dietaryPreferences'] ?? []);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant RecipePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller?._clearSearch = null;
      widget.controller?._clearSearch = _clearSearch;
    }
  }

  @override
  void dispose() {
    widget.controller?._clearSearch = null;
    RecipeSuggestionNotifier.instance.removeListener(_initSuggestions);
    planListener?.cancel();
    recipesListener?.cancel();
    usageListener?.cancel();
    keyboardSubscription.cancel();
    disposeSuggestions();
    _scrollController.removeListener(_maybeLoadMoreRecipes);
    _scrollController.dispose();
    super.dispose();
  }

  /// (Re)subscribes to the group's recipes with the current [_recipeLimit], or
  /// with [_allRecipesLimit] while [_searchActive] so search covers every
  /// recipe rather than just the loaded page. Ordered by `createdAt` so
  /// freshly added recipes always sit in the loaded window (a recipe never
  /// cooked yet has no `lastUsedAt`); the grid itself is re-ranked
  /// client-side by [_rankOwnRecipes] when not searching.
  ///
  /// While searching the `orderBy` is dropped entirely: search re-sorts by
  /// match score anyway, and a doc whose `createdAt` is still an unresolved
  /// `FieldValue.serverTimestamp()` write is excluded by Firestore from any
  /// query ordered by that same field until the write reaches the server —
  /// which made a just-saved recipe briefly vanish from the search results.
  void _subscribeRecipes() {
    recipesListener?.cancel();
    final limit = _searchActive ? _allRecipesLimit : _recipeLimit;
    Query<Map<String, dynamic>> query = groupDoc.collection('recipes');
    if (!_searchActive) {
      query = query.orderBy('createdAt', descending: true);
    }
    recipesListener = query.limit(limit).snapshots().listen((snapshot) {
      setState(() {
        recipes = snapshot.docs;
        // A full page means there may be more to load on scroll.
        _recipesMaybeMore = !_searchActive && snapshot.docs.length >= _recipeLimit;
        generateSearchedRecipes();
      });
    });
  }

  /// Grows the recipe window when the grid is scrolled near its end, so groups
  /// with more than a page of recipes keep loading further ones on demand.
  void _maybeLoadMoreRecipes() {
    if (!_recipesMaybeMore) return;
    if (recipes.length < _recipeLimit) return; // current page not full yet
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 600) return;
    _recipeLimit += _recipePageSize;
    _subscribeRecipes();
  }

  // Recipe ranking (usage-based "cook again" ordering) and search filtering
  // live in [RecipeSuggestionsMixin.generateSearchedRecipes].

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
    String? searchHint,
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
      if (searchHint != null && searchHint.isNotEmpty) 'searchHint': searchHint,
    });
  }

  /// Returns the id of an already-existing recipe whose [attribution] matches
  /// [url], or null if no such recipe is loaded yet.
  String? _findRecipeIdByUrl(String url) {
    for (final r in recipes) {
      if ((r.data()['attribution'] ?? '') == url) return r.id;
    }
    return null;
  }

  // The remaining AI-suggestion generation (typeahead debouncing, public
  // recipe matches, AI name ideas) lives in [RecipeSuggestionsMixin].

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
    return functions.httpsCallable('recipes-generateRecipeStaged').call(data);
  }

  /// Tapping a suggestion: public recipes open a read-only preview that saves
  /// itself into the group in place; name/link ideas open the detail page
  /// immediately and generate in the background (shimmering the parts that
  /// haven't arrived yet).
  Future<void> _openSuggestion(RecipeSuggestion s) async {
    if (s.kind == SuggestionKind.public) {
      _pushDetail(
        '',
        publicRecipeId: s.publicId,
        initialData: _seedData(s.title)
          ..['images'] = (s.publicImage?.isNotEmpty ?? false)
              ? [s.publicImage!]
              : <String>[],
      );
      return;
    }

    if (s.kind == SuggestionKind.url && s.url != null) {
      final existing = _findRecipeIdByUrl(s.url!);
      if (existing != null) {
        _pushDetail(existing);
        return;
      }
    }

    final name = s.kind == SuggestionKind.name ? s.title : '';
    final attribution = s.kind == SuggestionKind.url ? s.url : null;
    final ref = groupDoc.collection('recipes').doc();
    ref.set({
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
    _pushDetail(
      ref.id,
      generating: true,
      initialData: _seedData(name, attribution: attribution),
    );
    // Fire and forget; the detail page streams progress from the document.
    _callStaged(ref.id, s).ignore();
  }

  void _pushDetail(String recipeId,
      {bool generating = false,
      Map<String, dynamic>? initialData,
      String? publicRecipeId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          groupId: widget.groupId,
          recipeId: recipeId,
          aiEnabled: widget.aiEnabled,
          generating: generating,
          initialData: initialData,
          publicRecipeId: publicRecipeId,
          canEditPublicRecipes: widget.canEditPublicRecipes,
          onTagTap: _onDetailTagTap,
        ),
      ),
    );
  }

  /// Tapping a tag chip in the recipe detail page: close it and run a tag
  /// search for that tag in the grid below.
  void _onDetailTagTap(String tag) {
    Navigator.of(context).pop();
    final value = '#$tag ';
    _searchController.text = value;
    searchQuery = value;
    widget.controller?.hasSearch.value = true;
    generateSearchedRecipes();
    onSearchChangedAi(value);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// Clears the search field, reverting the recipe grid to its unsearched
  /// state. Shared by the search bar's clear button and the back-button
  /// handling in the app's bottom-nav host (which clears search on the first
  /// back press before falling through to the normal back behaviour).
  void _clearSearch() {
    _searchController.clear();
    searchQuery = '';
    widget.controller?.hasSearch.value = false;
    if (_searchActive) {
      _searchActive = false;
      _subscribeRecipes();
    }
    generateSearchedRecipes();
    onSearchChangedAi('');
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

  /// Waits only until the recipe's `ingredients` stage has cleared from the
  /// doc's `pending` array (steps 1–3 of generateRecipeStaged), rather than the
  /// whole call — the image (stage 4) keeps generating in the background via
  /// [generation]. Also surfaces a failure if [generation] itself rejects
  /// before ever writing `pending`, or if the function flags generationError.
  Future<void> _awaitIngredientsStage(
      String recipeId, Future<void> generation) async {
    final ref = groupDoc.collection('recipes').doc(recipeId);
    final ready = Completer<void>();
    late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
    sub = ref.snapshots().listen((snap) {
      final data = snap.data();
      if (data == null || ready.isCompleted) return;
      if (data['generationError'] == true) {
        ready.completeError(Exception('Recipe generation failed'));
        return;
      }
      if (!data.containsKey('pending')) return;
      final pending = List<String>.from(data['pending'] ?? const []);
      if (!pending.contains('ingredients')) ready.complete();
    });
    generation.catchError((Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });
    try {
      await ready.future;
    } finally {
      sub.cancel();
    }
  }

  /// Dragging a suggestion onto the save zone: generate/adopt the recipe and
  /// set lastUsedAt to now, without planning it. Public recipes are adopted
  /// instantly from preloaded data; AI-generated recipes show a loading dialog.
  Future<void> _handleSuggestionSave(RecipeSuggestion s) async {
    if (s.kind == SuggestionKind.public) {
      try {
        final preloadFuture =
            _publicPreload.remove(s.publicId!) ?? preloadPublicRecipe(s.publicId!);
        final preload = await preloadFuture;
        final result = await adoptPublicRecipeFromPreload(
          groupId: widget.groupId,
          publicRecipeId: s.publicId!,
          preload: preload,
          uid: FirebaseAuth.instance.currentUser!.uid,
          lang: LanguageService.instance.code.value,
        );
        result.imageUpload.ignore();
      } catch (_) {
        _snack('Could not save this recipe.');
      }
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _GeneratingDialog(),
    );
    // The current search text, if any, is stamped onto the new recipe as
    // `searchHint` so it stays findable under the term that surfaced this
    // suggestion, even once AI generation replaces its name/description/tags
    // with something that doesn't literally contain those words.
    final searchHint = searchQuery.trim();
    String? recipeId;
    try {
      if (s.kind == SuggestionKind.url && s.url != null) {
        final existing = _findRecipeIdByUrl(s.url!);
        if (existing != null) {
          recipeId = existing;
        } else {
          final ref = await _createRecipeDoc(
              name: '', attribution: s.url, searchHint: searchHint);
          recipeId = ref.id;
          // Fire and forget; the doc is edited in place as generation streams in.
          _callStaged(recipeId, s).ignore();
        }
      } else {
        final ref = await _createRecipeDoc(
            name: s.kind == SuggestionKind.name ? s.title : '',
            searchHint: searchHint);
        recipeId = ref.id;
        _callStaged(recipeId, s).ignore();
      }
      if (recipeId != null) {
        groupDoc
            .collection('recipes')
            .doc(recipeId)
            .update({'lastUsedAt': FieldValue.serverTimestamp()});
      }
    } catch (_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _snack('Could not save this recipe.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
  }

  /// Dragging a suggestion onto a day: generate/adopt the recipe, then plan it
  /// and open the add-to-shopping-list dialog. Public recipes are adopted
  /// instantly from preloaded data; AI-generated recipes show a loading dialog.
  Future<void> _handleSuggestionDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    RecipeSuggestion s,
  ) async {
    if (s.kind == SuggestionKind.public) {
      await _handlePublicRecipeDrop(day, plans, index, s);
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _GeneratingDialog(),
    );
    String? recipeId;
    try {
      if (s.kind == SuggestionKind.url && s.url != null) {
        final existing = _findRecipeIdByUrl(s.url!);
        if (existing != null) {
          recipeId = existing;
        } else {
          final ref = await _createRecipeDoc(
              name: '',
              attribution: s.url);
          recipeId = ref.id;
          await _awaitIngredientsStage(recipeId, _callStaged(recipeId, s));
        }
      } else {
        final ref = await _createRecipeDoc(
            name: s.kind == SuggestionKind.name ? s.title : '',
            attribution: null);
        recipeId = ref.id;
        await _awaitIngredientsStage(recipeId, _callStaged(recipeId, s));
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

  /// Adopts [s] using preloaded data: writes recipe + cooking plan instantly,
  /// then uploads the image in the background with a loading overlay on the tile.
  Future<void> _handlePublicRecipeDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    RecipeSuggestion s,
  ) async {
    String? recipeId;
    try {
      final preloadFuture =
          _publicPreload.remove(s.publicId!) ?? preloadPublicRecipe(s.publicId!);
      final preload = await preloadFuture;
      final result = await adoptPublicRecipeFromPreload(
        groupId: widget.groupId,
        publicRecipeId: s.publicId!,
        preload: preload,
        uid: FirebaseAuth.instance.currentUser!.uid,
        lang: LanguageService.instance.code.value,
      );
      recipeId = result.recipeId;
      if (mounted) setState(() => _uploadingRecipeIds.add(recipeId!));
      result.imageUpload.whenComplete(() {
        if (mounted) setState(() => _uploadingRecipeIds.remove(recipeId));
      });
    } catch (_) {
      _snack('Could not adopt this recipe.');
      return;
    }
    if (!mounted || recipeId == null) return;
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
    final url = extractUrl(t);
    if (url != null) {
      final existing = _findRecipeIdByUrl(url);
      if (existing != null) {
        if (mounted) _pushDetail(existing);
        return;
      }
    }
    final name = url != null ? '' : t;
    final ref = groupDoc.collection('recipes').doc();
    ref.set({
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
      if (url != null) 'attribution': url,
    });
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
    functions.httpsCallable('recipes-generateRecipeStaged').call(<String, dynamic>{
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
      // Note: we deliberately don't touch the recipe's `lastUsedAt` field
      // here. Ranking derives "last used" live from the cooking_plan
      // collection (see usageListener/_lastUsedDates below), so it stays in
      // sync automatically when a plan is moved or removed instead of
      // getting stuck at whatever this write set it to.
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
            builder: (_) => AddToShoppingListDialog(
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
    final smallerdim = displaySize.width < displaySize.height
        ? displaySize.width
        : displaySize.height;

    // Drop suggestions for public recipes already adopted into this group so
    // they are not offered again. Adopted recipes carry the source id.
    final adoptedPublicIds = {
      for (final r in recipes)
        if (r.data()['sourcePublicId'] != null)
          r.data()['sourcePublicId'] as String,
    };
    final suggestedPool = this.suggestedPool
        .where((s) => !adoptedPublicIds.contains(s.publicId))
        .toList();
    final bool showSuggestedRow = _suggestionsEnabled &&
        suggestedPool.isNotEmpty &&
        !keyboardVisible &&
        searchQuery.trim().isEmpty;
    // Suggestion tiles shown while searching, de-duplicated so a public/AI idea
    // never repeats a recipe the group already has (matched by title, or an
    // already-adopted public recipe) nor another suggestion with the same title.
    final ownRecipeNames = {
      for (final r in searchedRecipes)
        (r.data()['name'] ?? '').toString().trim().toLowerCase(),
    };
    final seenSuggestionTitles = <String>{};
    final suggestionTiles = <RecipeSuggestion>[];
    for (final s in [...publicSuggestions, ...suggestions]) {
      if (s.publicId != null && adoptedPublicIds.contains(s.publicId)) continue;
      final t = s.title.trim().toLowerCase();
      if (t.isNotEmpty) {
        if (ownRecipeNames.contains(t)) continue;
        if (!seenSuggestionTitles.add(t)) continue;
      }
      suggestionTiles.add(s);
    }
    final suggestedTopOffset =
        (showSuggestedRow || (widget.aiEnabled && suggestionTiles.isNotEmpty))
            ? smallerdim / crossAxisCount * 3 / 4 + 1
            : 0.0;

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
                                          onDragStarted: () => setState(() => _isDraggingPlan = true),
                                          onDragEnd: (_) => setState(() => _isDraggingPlan = false),
                                          onDraggableCanceled: (_, __) => setState(() => _isDraggingPlan = false),
                                          feedback: RecipeCard(
                                            recipeId: dayPlans[i]['recipe'],
                                            groupCollection: groupDoc,
                                            data: _recipeDataFor(dayPlans[i]['recipe']),
                                            crossAxisCount: planCrossAxisCount,
                                          ),
                                          childWhenDragging: const SizedBox.shrink(),
                                          child: Stack(
                                            children: [
                                              RecipeOpenContainer(
                                                recipeId: dayPlans[i]['recipe'],
                                                groupId: groupDoc.id,
                                                groupDoc: groupDoc,
                                                aiEnabled: widget.aiEnabled,
                                                initialData:
                                                _recipeDataFor(dayPlans[i]['recipe']),
                                                onTagTap: _onDetailTagTap,
                                                child: RecipeCard(
                                                  recipeId: dayPlans[i]['recipe'],
                                                  groupCollection: groupDoc,
                                                  data: _recipeDataFor(dayPlans[i]['recipe']),
                                                  cropContent: true,
                                                  crossAxisCount: planCrossAxisCount,
                                                ),
                                              ),
                                              if (_uploadingRecipeIds.contains(dayPlans[i]['recipe']))
                                                Positioned.fill(
                                                  child: IgnorePointer(
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(20),
                                                      child: const ColoredBox(
                                                        color: Colors.black26,
                                                        child: Center(
                                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
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
              CustomScrollView(
                controller: _scrollController,
                slivers: [
                  if (showSuggestedRow)
                    SliverToBoxAdapter(
                      child: SuggestedRowWidget(
                        key: ValueKey(
                            Object.hashAll(suggestedPool.map((s) => s.publicId))),
                        pool: suggestedPool,
                        onDismiss: dismissSuggested,
                        visible: true,
                        groupId: widget.groupId,
                        aiEnabled: widget.aiEnabled,
                        canEditPublicRecipes: widget.canEditPublicRecipes,
                        crossAxisCount: crossAxisCount,
                        onTagTap: _onDetailTagTap,
                        onDragStarted: () => setState(() => _isDraggingSuggestion = true),
                        onDragEnd: () => setState(() => _isDraggingSuggestion = false),
                        onDragStartedWithSuggestion: (s) {
                          if (s.publicId != null) {
                            _publicPreload.putIfAbsent(s.publicId!, () => preloadPublicRecipe(s.publicId!));
                          }
                        },
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom + 72 + 32),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount),
                      delegate: SliverChildListDelegate([
                        // Own recipes first, then suggestion tiles (public
                        // matches, then AI names when enabled) — prefer what
                        // the group already has over ideas for something new.
                        for (final e in searchedRecipes)
                          LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
                            key: ValueKey(e.id),
                            data: e,
                            onDragStarted: () => _preloadIngredients(e.id),
                            feedback: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                            childWhenDragging:
                            RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                            child: RecipeOpenContainer(
                              recipeId: e.id,
                              groupId: widget.groupId,
                              groupDoc: groupDoc,
                              aiEnabled: widget.aiEnabled,
                              initialData: e.data(),
                              onTagTap: _onDetailTagTap,
                              child: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: e.data(), crossAxisCount: crossAxisCount),
                            ),
                          ),
                        if (searchQuery.trim().isNotEmpty)
                          for (final s in suggestionTiles)
                            LongPressDraggable<RecipeSuggestion>(
                              data: s,
                              onDragStarted: () {
                                setState(() => _isDraggingSuggestion = true);
                                if (s.kind == SuggestionKind.public && s.publicId != null) {
                                  _publicPreload.putIfAbsent(s.publicId!, () => preloadPublicRecipe(s.publicId!));
                                }
                              },
                              onDragEnd: (_) => setState(() => _isDraggingSuggestion = false),
                              onDraggableCanceled: (_, __) => setState(() => _isDraggingSuggestion = false),
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
                      ]),
                    ),
                  ),
                ],
              ),
              // ── Search bar ─────────────────────────────────────────────
              Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  padding: keyboardVisible
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: keyboardVisible
                                ? const BorderRadius.only(
                                    topLeft: Radius.circular(16))
                                : BorderRadius.circular(28),
                          ),
                          child: SearchBar(
                          shape: const WidgetStatePropertyAll(
                            RoundedRectangleBorder(),
                          ),
                          controller: _searchController,
                          hintText: 'Search recipes',
                          leading: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(Icons.search,
                                color: colorScheme.onSurfaceVariant),
                          ),
                          onChanged: (value) {
                            final wasEmpty = searchQuery.trim().isEmpty;
                            final isEmptyNow = value.trim().isEmpty;
                            searchQuery = value;
                            widget.controller?.hasSearch.value = !isEmptyNow;
                            // Widen the loaded recipe window to the whole group while
                            // searching, so search isn't limited to whatever page had
                            // already been scrolled into view; revert once cleared.
                            if (wasEmpty && !isEmptyNow && !_searchActive) {
                              _searchActive = true;
                              _subscribeRecipes();
                            } else if (!wasEmpty && isEmptyNow && _searchActive) {
                              _searchActive = false;
                              _subscribeRecipes();
                            }
                            generateSearchedRecipes();
                            onSearchChangedAi(value);
                            if (wasEmpty && value.trim().isNotEmpty && _scrollController.hasClients) {
                              _scrollController.jumpTo(0);
                            }
                          },
                          trailing: [
                            if (suggestionsLoading && searchQuery.trim().isNotEmpty)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CupertinoActivityIndicator(),
                              ),
                            if (searchQuery.isNotEmpty)
                              IconButton(
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.close),
                              ),
                          ],
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                        alignment: Alignment.center,
                        width: keyboardVisible ? 1 : 8,
                        height: 56,
                        color: keyboardVisible
                            ? colorScheme.surfaceContainerHigh
                            : Colors.transparent,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: keyboardVisible ? 1 : 0,
                          child: Container(
                            width: 1,
                            height: 32,
                            color: colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                        clipBehavior: Clip.antiAlias,
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          borderRadius: keyboardVisible
                              ? const BorderRadius.only(
                                  topRight: Radius.circular(16))
                              : BorderRadius.circular(28),
                        ),
                        child: IconButton(
                          onPressed: _openCreateMenu,
                          icon: const Icon(Icons.add),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ── Delete target (topmost when dragging a plan) ───────────
              if (_isDraggingPlan)
                DragTarget<Object>(
                  builder: (context, candidateData, _) {
                    final hovering = candidateData.isNotEmpty;
                    return Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: hovering
                            ? colorScheme.errorContainer.withAlpha(200)
                            : colorScheme.errorContainer.withAlpha(60),
                        border: hovering
                            ? null
                            : Border.all(color: colorScheme.error, width: 2),
                      ),
                      child: Center(
                        child: Icon(Icons.delete_outline,
                            size: 128,
                            color: hovering ? colorScheme.onErrorContainer : colorScheme.error),
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
              // ── Save-to-recipes target (topmost when dragging a suggestion) ──
              if (_isDraggingSuggestion)
                Positioned(
                  top: suggestedTopOffset + 4,
                  left: 4,
                  right: 4,
                  bottom: 4,
                  child: DragTarget<RecipeSuggestion>(
                    builder: (context, candidateData, _) {
                      final hovering = candidateData.isNotEmpty;
                      return Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: hovering
                              ? Colors.green.withAlpha(200)
                              : Colors.green.withAlpha(40),
                          border: hovering
                              ? null
                              : Border.all(color: Colors.green, width: 2),
                        ),
                        child: Center(
                          child: Icon(Icons.bookmark_add,
                              size: 128,
                              color: hovering ? Colors.white : Colors.green),
                        ),
                      );
                    },
                    onWillAcceptWithDetails: (_) => true,
                    onAcceptWithDetails: (d) => _handleSuggestionSave(d.data),
                  ),
                ),
            ],
          ),
        ),
      ],
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