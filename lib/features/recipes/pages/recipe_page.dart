import 'dart:async';

import 'package:couple_planner/core/date_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_card.dart';
import 'package:couple_planner/features/recipes/widgets/suggested_row.dart';
import 'package:couple_planner/features/recipes/widgets/add_to_shopping_list_dialog.dart';
import 'package:couple_planner/features/recipes/widgets/empty_recipes_state.dart';
import 'package:couple_planner/features/recipes/widgets/plan_next_days_button.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/recipe_actions.dart';
import 'package:couple_planner/features/recipes/services/recipe_suggestions.dart';
import 'package:couple_planner/features/recipes/pages/meal_plan_flow.dart';
import 'package:couple_planner/features/settings/recipe_suggestion_notifier.dart';
import 'package:couple_planner/features/ai/ai_access.dart';

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
  final AiAccess access;
  final bool canEditPublicRecipes;
  final RecipePageController? controller;

  const RecipePage({
    super.key,
    required this.groupId,
    required this.shoppingListEnabled,
    required this.access,
    this.canEditPublicRecipes = false,
    this.controller,
  });

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage>
    with RecipeSuggestionsMixin, SuggestedRowMixin, RecipeActionsMixin, WidgetsBindingObserver {
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
  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> cookingPlans = [];
  // Whether the cooking-plan stream has delivered its first snapshot yet.
  // The "Plan next days" trigger day depends on the latest planned day, so it
  // stays hidden until this is true — otherwise it would flash onto today's
  // tile (computed from the still-empty `cookingPlans`) and then jump once
  // the real data arrives.
  bool _plansLoaded = false;
  @override
  bool get plansLoaded => _plansLoaded;
  // Tracks the auto meal-plan trigger day across cooking-plan updates so a
  // move to a new day can fade out on the old one instead of just vanishing;
  // see the cooking-plan listener in initState and PlanNextDaysButton.
  String? _lastTriggerDayKey;
  String? _fadingTriggerDayKey;
  Timer? _fadingTriggerTimer;
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
  // True once the recipes stream has delivered its first snapshot, so the
  // "no recipes yet" empty state doesn't flash on briefly before real data
  // arrives.
  bool _recipesLoaded = false;
  @override
  bool get recipesLoaded => _recipesLoaded;

  // GlobalKey on the + button, handed to [EmptyRecipesState] so its guidance
  // arrow can point at the button's real measured position.
  final GlobalKey _plusButtonKey = GlobalKey();

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

  /// The day the "Plan the next days" button sits on: the day right after the
  /// group's last currently-planned day, or today if nothing is planned
  /// ahead. By construction this guarantees the auto-planner's window can
  /// never contain an already-planned day.
  DateTime get _triggerDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime? latestPlanned;
    for (final plan in cookingPlans) {
      final ts = plan['plannedFor'];
      if (ts is! Timestamp) continue;
      final d = ts.toDate();
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) continue;
      if (latestPlanned == null || day.isAfter(latestPlanned)) latestPlanned = day;
    }
    return latestPlanned == null ? today : latestPlanned.add(const Duration(days: 1));
  }

  /// Opens the auto meal-plan flow starting on [day], with the days stepper
  /// clamped to how much of the rendered carousel window remains ahead.
  void _openMealPlanFlow(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastRendered = today.add(Duration(days: daysToShowFuture - 1));
    final maxDays = (lastRendered.difference(day).inDays + 1).clamp(1, 14);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MealPlanSettingsPage(
          groupId: widget.groupId,
          groupDoc: groupDoc,
          startDate: day,
          maxDays: maxDays,
          access: widget.access,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      setState(() {
        cookingPlans = snapshot.docs;
        _plansLoaded = true;
        final newTriggerDate = _triggerDate;
        final newTriggerDayKey =
            '${newTriggerDate.year}-${newTriggerDate.month}-${newTriggerDate.day}';
        if (_lastTriggerDayKey != null && _lastTriggerDayKey != newTriggerDayKey) {
          _fadingTriggerDayKey = _lastTriggerDayKey;
          _fadingTriggerTimer?.cancel();
          _fadingTriggerTimer = Timer(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _fadingTriggerDayKey = null);
          });
        }
        _lastTriggerDayKey = newTriggerDayKey;
      });
      _maybeRefreshEmptyGroupSuggestedRow();
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

  // The initial loadSuggestedRow() call (in _initSuggestions) races the
  // recipes/cooking-plan listeners above, so it can't reliably tell a
  // genuinely empty group apart from one whose data just hasn't arrived yet.
  // Once both streams have delivered their first snapshot, reload the row
  // once so a truly empty group picks up loadSuggestedRow's empty-group
  // sorting (see suggested_row.dart).
  bool _emptyGroupRowChecked = false;
  void _maybeRefreshEmptyGroupSuggestedRow() {
    if (_emptyGroupRowChecked || !_recipesLoaded || !_plansLoaded) return;
    _emptyGroupRowChecked = true;
    if (_suggestionsEnabled && recipes.isEmpty && cookingPlans.isEmpty) {
      loadSuggestedRow();
    }
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
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?._clearSearch = null;
    RecipeSuggestionNotifier.instance.removeListener(_initSuggestions);
    planListener?.cancel();
    _fadingTriggerTimer?.cancel();
    recipesListener?.cancel();
    usageListener?.cancel();
    keyboardSubscription.cancel();
    for (final sub in imageTrackSubs) {
      sub.cancel();
    }
    disposeSuggestions();
    _scrollController.removeListener(_maybeLoadMoreRecipes);
    _scrollController.dispose();
    super.dispose();
  }

  // The suggested row is seeded by calendar day (see loadSuggestedRow), so a
  // session left open across midnight would otherwise keep showing
  // yesterday's picks until the app is restarted. Re-check on resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _suggestionsEnabled) {
      refreshSuggestedRowIfStale();
    }
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
        _recipesLoaded = true;
        // A full page means there may be more to load on scroll.
        _recipesMaybeMore = !_searchActive && snapshot.docs.length >= _recipeLimit;
        generateSearchedRecipes();
      });
      _maybeRefreshEmptyGroupSuggestedRow();
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

  /// Tapping a tag chip in the recipe detail page: close it and run a tag
  /// search for that tag in the grid below.
  void onDetailTagTap(String tag) {
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
    adoptingSuggestions.clear();
    widget.controller?.hasSearch.value = false;
    if (_searchActive) {
      _searchActive = false;
      _subscribeRecipes();
    }
    generateSearchedRecipes();
    onSearchChangedAi('');
  }

  /// Computes a [Timestamp] at the midpoint of the gap between the plan at
  /// [index − 1] and [index] within [plans] for [day], then creates or moves
  /// the dragged [data] to that position.
  ///
  /// The outer [DragTarget] per day deliberately has no [onAcceptWithDetails]
  /// and only provides the colour highlight. All actual drops are routed here
  /// through the inner per-plan targets and the append-zone target, which
  /// avoids double-firing from nested DragTargets.
  Future<void> handleDrop(
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

  /// A group recipe as a draggable grid tile (open on tap, drag onto a day).
  /// Shared by the searched-recipes grid and by a suggestion tile that has
  /// just transformed into its adopted recipe.
  /// [streamCard] makes the resting card render from the live recipe document
  /// (see [RecipeCard], which streams when its `data` is null) instead of a
  /// fixed snapshot, so a just-adopted tile picks up its image once it lands.
  Widget _privateRecipeTile(
      DocumentSnapshot<Map<String, dynamic>> e, int crossAxisCount,
      {bool streamCard = false, VoidCallback? onMissing}) {
    final data = e.data() ?? const <String, dynamic>{};
    return LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
      key: ValueKey(e.id),
      data: e,
      onDragStarted: () => _preloadIngredients(e.id),
      feedback: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: data, crossAxisCount: crossAxisCount),
      childWhenDragging:
          RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: data, crossAxisCount: crossAxisCount),
      child: RecipeOpenContainer(
        recipeId: e.id,
        groupId: widget.groupId,
        groupDoc: groupDoc,
        access: widget.access,
        initialData: data,
        onTagTap: onDetailTagTap,
        child: RecipeCard(recipeId: e.id, groupCollection: groupDoc, data: streamCard ? null : data, crossAxisCount: crossAxisCount, onMissing: streamCard ? onMissing : null),
      ),
    );
  }

  /// A search-grid suggestion tile. Normally a draggable idea; once it has been
  /// dragged onto the save zone or a day it shows in-place loading (not
  /// draggable), then transforms into its adopted recipe as soon as that
  /// recipe's doc has loaded — see [adoptingSuggestions].
  Widget _suggestionGridTile(RecipeSuggestion s, int crossAxisCount) {
    final key = suggestionKey(s);
    if (adoptingSuggestions.containsKey(key)) {
      final doc = adoptingSuggestions[key];
      if (doc != null) {
        return _privateRecipeTile(doc, crossAxisCount, streamCard: true,
            onMissing: () {
          if (mounted && adoptingSuggestions.containsKey(key)) {
            setState(() => adoptingSuggestions.remove(key));
          }
        });
      }
      // Loading: the drop was accepted but the recipe isn't ready to drag yet.
      // A dimmed card with a large centred spinner, matching the card's rounded
      // shape, so it reads clearly as "saving" in place.
      return AbsorbPointer(
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            RecipeSuggestionCard(suggestion: s, crossAxisCount: crossAxisCount),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: const ColoredBox(
                    color: Colors.black45,
                    child: Center(
                      child: CupertinoActivityIndicator(radius: 16, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return LongPressDraggable<RecipeSuggestion>(
      data: s,
      onDragStarted: () {
        setState(() => _isDraggingSuggestion = true);
        if (s.kind == SuggestionKind.public && s.publicId != null) {
          publicPreload.putIfAbsent(s.publicId!, () => preloadPublicRecipe(s.publicId!));
        }
      },
      onDragEnd: (_) => setState(() => _isDraggingSuggestion = false),
      onDraggableCanceled: (_, __) => setState(() => _isDraggingSuggestion = false),
      feedback: RecipeSuggestionCard(suggestion: s, crossAxisCount: crossAxisCount),
      childWhenDragging: RecipeSuggestionCard(suggestion: s, crossAxisCount: crossAxisCount),
      child: GestureDetector(
        onTap: () => openSuggestion(s),
        child: RecipeSuggestionCard(suggestion: s, crossAxisCount: crossAxisCount),
      ),
    );
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
      // A suggestion mid-adoption keeps its slot (transforming in place), even
      // once the adopted recipe would otherwise dedupe it away by name/source.
      final adopting = adoptingSuggestions.containsKey(suggestionKey(s));
      if (!adopting && s.publicId != null && adoptedPublicIds.contains(s.publicId)) continue;
      final t = s.title.trim().toLowerCase();
      if (t.isNotEmpty) {
        if (!adopting && ownRecipeNames.contains(t)) continue;
        if (!seenSuggestionTitles.add(t)) continue;
      }
      suggestionTiles.add(s);
    }
    // The private recipe ids that a currently-shown suggestion tile has
    // transformed into, so they aren't also rendered in the searched-recipes
    // section above (which would double them up).
    final adoptingRecipeIds = <String>{
      for (final s in suggestionTiles)
        if (adoptingSuggestions[suggestionKey(s)] != null)
          adoptingSuggestions[suggestionKey(s)]!.id,
    };
    final suggestedTopOffset =
        (showSuggestedRow || (widget.access.canUseSearchIdeas && suggestionTiles.isNotEmpty))
            ? smallerdim / crossAxisCount * 3 / 4 + 1
            : 0.0;

    final triggerDate = _triggerDate;
    final triggerDayKey = '${triggerDate.year}-${triggerDate.month}-${triggerDate.day}';

    final showEmptyRecipesState =
        recipes.isEmpty && searchQuery.trim().isEmpty && _recipesLoaded;
    final showShareTip = recipes.isNotEmpty &&
        searchQuery.trim().isEmpty &&
        widget.access.canGenerateRecipes;
    // Space reserved at the end of the scrollable content so the last row
    // (grid row, or the share tip when it's showing) clears the floating
    // search bar/+ button instead of sitting underneath it.
    final bottomBarClearance = MediaQuery.of(context).viewInsets.bottom + 72 + 32;

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
                      handleSuggestionDrop(day, dayPlans, insertIdx, data);
                    } else if (data is DocumentSnapshot<Map<String, dynamic>>) {
                      handleDrop(day, dayPlans, insertIdx, data);
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
                                                access: widget.access,
                                                initialData:
                                                _recipeDataFor(dayPlans[i]['recipe']),
                                                onTagTap: onDetailTagTap,
                                                child: RecipeCard(
                                                  recipeId: dayPlans[i]['recipe'],
                                                  groupCollection: groupDoc,
                                                  data: _recipeDataFor(dayPlans[i]['recipe']),
                                                  cropContent: true,
                                                  crossAxisCount: planCrossAxisCount,
                                                ),
                                              ),
                                              if (uploadingRecipeIds.contains(dayPlans[i]['recipe']))
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
                          // The auto meal-plan trigger: shown only on the
                          // single soonest day at/after today that has no
                          // plan yet (see _triggerDate), and only when the
                          // meal planner is available. Pinned below the scrollable
                          // plan list (not part of it) and sized like a
                          // cropped recipe card so it holds a fixed size
                          // instead of reflowing as the carousel's weighted
                          // widths change while scrolling. Kept mounted (as
                          // invisible) on the previous trigger day for a
                          // moment after the trigger moves, so it fades out
                          // there instead of just vanishing.
                          if (widget.access.canUseMealPlanner &&
                              _plansLoaded &&
                              (dayKey == triggerDayKey || dayKey == _fadingTriggerDayKey))
                            PlanNextDaysButton(
                              crossAxisCount: planCrossAxisCount,
                              visible: dayKey == triggerDayKey,
                              onTap: () => _openMealPlanFlow(day),
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
                        access: widget.access,
                        canEditPublicRecipes: widget.canEditPublicRecipes,
                        crossAxisCount: crossAxisCount,
                        onTagTap: onDetailTagTap,
                        onDragStarted: () => setState(() => _isDraggingSuggestion = true),
                        onDragEnd: () => setState(() => _isDraggingSuggestion = false),
                        onDragStartedWithSuggestion: (s) {
                          if (s.publicId != null) {
                            publicPreload.putIfAbsent(s.publicId!, () => preloadPublicRecipe(s.publicId!));
                          }
                        },
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                        bottom: showShareTip ? 8 : bottomBarClearance),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount),
                      delegate: SliverChildListDelegate([
                        // Own recipes first, then suggestion tiles (public
                        // matches, then AI names when enabled) — prefer what
                        // the group already has over ideas for something new.
                        for (final e in searchedRecipes)
                          if (!adoptingRecipeIds.contains(e.id))
                            _privateRecipeTile(e, crossAxisCount),
                        if (searchQuery.trim().isNotEmpty)
                          for (final s in suggestionTiles)
                            _suggestionGridTile(s, crossAxisCount),
                      ]),
                    ),
                  ),
                  if (showShareTip)
                    SliverPadding(
                      padding: EdgeInsets.only(bottom: bottomBarClearance),
                      sliver: const SliverToBoxAdapter(child: ShareTip()),
                    ),
                ],
              ),
              // ── Empty state (group has no recipes yet) ──────────────────
              // A full-bleed overlay rather than a sliver: it needs the exact
              // same coordinate space as the search bar/+ button below (see
              // EmptyRecipesState) so its arrows can reliably point at
              // them regardless of how much the suggested row above pushes
              // the (empty) grid sliver around.
              if (showEmptyRecipesState)
                Positioned.fill(
                  child: EmptyRecipesState(
                    access: widget.access,
                    groupId: widget.groupId,
                    plusButtonKey: _plusButtonKey,
                    topInset: showSuggestedRow ? suggestedTopOffset + 16 : 24,
                  ),
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
                        key: _plusButtonKey,
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
                          onPressed: openCreateMenu,
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
                    onAcceptWithDetails: (d) => handleSuggestionSave(d.data),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
