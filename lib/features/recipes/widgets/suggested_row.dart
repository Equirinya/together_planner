import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:animations/animations.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/services/recipe_suggestions.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';
import 'package:couple_planner/features/ai/ai_access.dart';

/// The "suggested for you" row shown above the recipe grid when not
/// searching: loading, dismissal-tracking and the row widget itself, mixed
/// into [RecipePage]'s state alongside [RecipeSuggestionsMixin].
mixin SuggestedRowMixin on RecipeSuggestionsMixin {
  // ── "Suggested for you" row (shown when not searching) ─────────────────────
  List<RecipeSuggestion> suggestedPool = [];
  Map<String, int> _dismissed = {};
  // Calendar day each recipe was last dismissed on, so a recipe dismissed
  // today can be hidden from the row until the next daily reshuffle while the
  // cumulative count in [_dismissed] still deprioritizes it on later days.
  Map<String, String> _dismissedDay = {};
  static const String _kDismissedKey = 'dismissed_public_recipes';
  static const String _kDismissedDayKey = 'dismissed_public_recipes_day';
  // Calendar day the suggested row was last loaded for (see loadSuggestedRow's
  // date-seeded pool). Lets refreshSuggestedRowIfStale detect a session left
  // open across midnight, when the row would otherwise keep showing
  // yesterday's picks until the next app start.
  String? _suggestedRowDayKey;

  // The raw public-recipe docs backing the suggested row, cached per calendar
  // day and per group shape (empty vs. not). Fetching is separated from
  // ranking so the row can be re-ranked — after a dismissal, a day-rollover
  // recheck, the empty-group recheck, or a dietary-preference change — by
  // reusing these docs instead of re-reading `public_recipes` every time.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _suggestedDocs = [];
  String? _suggestedDocsDayKey;
  bool _suggestedDocsEmptyGroup = false;

  Future<void> loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDismissedKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _dismissed = map.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
      final rawDay = prefs.getString(_kDismissedDayKey);
      if (rawDay != null) {
        final map = jsonDecode(rawDay) as Map<String, dynamic>;
        _dismissedDay = map.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
  }

  Future<void> _saveDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDismissedKey, jsonEncode(_dismissed));
      await prefs.setString(_kDismissedDayKey, jsonEncode(_dismissedDay));
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
  Future<void> loadSuggestedRow() async {
    try {
      final col = FirebaseFirestore.instance.collection('public_recipes');
      final now = DateTime.now();
      final dayKey = '${now.year}-${now.month}-${now.day}';
      // A group with no recipes and no cooking plans yet has no usage signal to
      // weight suggestions by, so it uses a simpler popularity ordering (see
      // _rankEmptyGroup) instead of the weighted-random/seasonal path.
      final groupEmpty =
          recipesLoaded && plansLoaded && recipes.isEmpty && cookingPlans.isEmpty;
      _suggestedRowDayKey = dayKey;
      final seed = _stableHash('${widget.groupId}-$dayKey');

      // Fetch the backing docs once per day (per group shape) and reuse them on
      // later calls — the init, dietary-change, day-rollover and empty-group
      // rechecks all re-rank this same pool rather than re-reading Firestore.
      if (_suggestedDocsDayKey != dayKey ||
          _suggestedDocsEmptyGroup != groupEmpty ||
          _suggestedDocs.isEmpty) {
        _suggestedDocs = groupEmpty
            ? await _fetchEmptyGroupDocs(col)
            : await _fetchSuggestedDocs(col, seed);
        _suggestedDocsDayKey = dayKey;
        _suggestedDocsEmptyGroup = groupEmpty;
      }

      final ordered = groupEmpty
          ? _rankEmptyGroup(_suggestedDocs)
          : _rankSuggested(_suggestedDocs, seed, now);
      if (!mounted) return;
      setState(() => suggestedPool = ordered);
    } catch (_) {}
  }

  /// The daily random+popular sample of public recipes backing the row. A
  /// seeded `random`-range window (identical for every group member, reshuffled
  /// daily) plus the most popular recipes so widely-adopted ones can surface,
  /// with plain-page and de-dup handling. Fetch only — ranking is separate so
  /// it can re-run against this cached pool without re-reading.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchSuggestedDocs(
      CollectionReference<Map<String, dynamic>> col, int seed) async {
    const poolSize = 40;
    final pivot = (_stableHash('pivot-$seed') % 100000) / 100000.0;
    final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    // Fired together (they don't depend on each other): the daily random window
    // and the top-popularity recipes.
    final firstFuture = col
        .where('random', isGreaterThanOrEqualTo: pivot)
        .orderBy('random')
        .limit(poolSize)
        .get();
    final popularFuture =
        col.orderBy('popularity', descending: true).limit(15).get();
    final first = await firstFuture;
    docs.addAll(first.docs);
    if (docs.length < poolSize) {
      final second = await col
          .where('random', isLessThan: pivot)
          .orderBy('random')
          .limit(poolSize - docs.length)
          .get();
      docs.addAll(second.docs);
    }
    try {
      docs.addAll((await popularFuture).docs);
    } catch (_) {}
    // Fallback for public recipes missing the `random` field: those are
    // excluded from the range queries above, so fetch a plain page rather than
    // leaving the row empty.
    if (docs.isEmpty) {
      docs.addAll((await col.limit(poolSize).get()).docs);
    }
    return docs;
  }

  /// The top public recipes by popularity, backing the row for a group with no
  /// recipes/plans yet.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchEmptyGroupDocs(
      CollectionReference<Map<String, dynamic>> col) async {
    final snap = await col.orderBy('popularity', descending: true).limit(100).get();
    return snap.docs;
  }

  /// Ranks the daily pool. Recipes matching more of the user's diets always
  /// come first (a preference, not a hard filter, so the row still fills); each
  /// dietary tier is then ordered by the weighted-random key, with never-
  /// dismissed recipes ahead of dismissed ones and in-season interleaved with
  /// any-time.
  List<RecipeSuggestion> _rankSuggested(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
      int seed,
      DateTime now) {
    final lang = LanguageService.instance.code.value;
    final seen = <String>{};
    final scored =
        <({int diet, double key, bool seasonal, int dismissed, RecipeSuggestion s})>[];
    for (final d in docs) {
      if (!seen.add(d.id)) continue;
      // Recipes dismissed today stay hidden until the next daily reshuffle.
      if (_dismissedDay[d.id] == _suggestedRowDayKey) continue;
      final data = d.data();
      final popularity = (data['popularity'] as num?)?.toDouble() ?? 0;
      final dismissed = _dismissed[d.id] ?? 0;
      // Weight carries popularity and the dismissal penalty; dietary fit is the
      // primary ordering below rather than a weighting boost, so a matching
      // recipe can never be buried under a non-matching one by the random draw.
      final weight =
          (1 + math.log(1 + popularity)) / math.pow(4, dismissed);
      // Deterministic per-recipe uniform in (0,1], identical for every group
      // member and reshuffled each day via the group+date seed.
      final r = (_stableHash('$seed-${d.id}') % 100000 + 1) / 100001.0;
      // Efraimidis–Spirakis key: smaller wins, higher weight → smaller key.
      final key = -math.log(r) / weight;
      // In season when its suitable months (1–12) include the current month; a
      // null/empty list means it fits any time of year.
      final suitableMonths = data['suitableMonths'];
      scored.add((
        diet: dietMatchCount(data),
        key: key,
        seasonal: suitableMonths is List && suitableMonths.contains(now.month),
        dismissed: dismissed,
        s: publicSuggestion(d.id, data, lang),
      ));
    }
    scored.sort((a, b) => a.key.compareTo(b.key));

    // Interleave in-season and any-time recipes so roughly half the shown
    // suggestions fit the current season, each stream keeping the key ranking.
    List<RecipeSuggestion> interleaveSeasonal(
        Iterable<({int diet, double key, bool seasonal, int dismissed, RecipeSuggestion s})>
            entries) {
      final seasonal = [for (final e in entries) if (e.seasonal) e.s];
      final anytime = [for (final e in entries) if (!e.seasonal) e.s];
      final out = <RecipeSuggestion>[];
      for (var i = 0; i < seasonal.length || i < anytime.length; i++) {
        if (i < seasonal.length) out.add(seasonal[i]);
        if (i < anytime.length) out.add(anytime[i]);
      }
      return out;
    }

    // Best dietary fit first; within each tier, never-dismissed ahead of
    // dismissed (so a dismissal keeps a recipe out unless the pool runs dry).
    final tiers = scored.map((e) => e.diet).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final ordered = <RecipeSuggestion>[];
    for (final tier in tiers) {
      final inTier = scored.where((e) => e.diet == tier);
      ordered
        ..addAll(interleaveSeasonal(inTier.where((e) => e.dismissed == 0)))
        ..addAll(interleaveSeasonal(inTier.where((e) => e.dismissed > 0)));
    }
    return ordered;
  }

  /// Ranks the empty-group pool: best dietary fit first, then most popular. Not
  /// a hard filter — non-matching recipes still follow, so the row never empties
  /// even for an unusual diet combination.
  List<RecipeSuggestion> _rankEmptyGroup(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final lang = LanguageService.instance.code.value;
    final scored = <({int diet, double popularity, RecipeSuggestion s})>[];
    for (final d in docs) {
      if (_dismissedDay[d.id] == _suggestedRowDayKey) continue;
      final data = d.data();
      scored.add((
        diet: dietMatchCount(data),
        popularity: (data['popularity'] as num?)?.toDouble() ?? 0,
        s: publicSuggestion(d.id, data, lang),
      ));
    }
    scored.sort((a, b) {
      if (a.diet != b.diet) return b.diet.compareTo(a.diet);
      return b.popularity.compareTo(a.popularity);
    });
    return [for (final e in scored) e.s];
  }

  /// Reloads the suggested row if the calendar day has advanced since it was
  /// last loaded. The row's pool is seeded by group + day, so a session left
  /// open across midnight would otherwise keep showing yesterday's picks
  /// until the app is restarted.
  Future<void> refreshSuggestedRowIfStale() async {
    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month}-${now.day}';
    if (_suggestedRowDayKey != todayKey) {
      await loadSuggestedRow();
    }
  }

  void dismissSuggested(RecipeSuggestion s) {
    final id = s.publicId;
    if (id == null) return;
    _dismissed[id] = (_dismissed[id] ?? 0) + 1;
    final now = DateTime.now();
    _dismissedDay[id] = '${now.year}-${now.month}-${now.day}';
    _saveDismissed();
  }
}

// ─── SuggestedRowWidget ───────────────────────────────────────────────────────

class SuggestedRowWidget extends StatefulWidget {
  final List<RecipeSuggestion> pool;
  final void Function(RecipeSuggestion) onDismiss;
  final bool visible;
  final String groupId;
  final AiAccess access;
  final bool canEditPublicRecipes;
  final int crossAxisCount;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnd;
  final void Function(RecipeSuggestion)? onDragStartedWithSuggestion;
  final void Function(String tag)? onTagTap;

  const SuggestedRowWidget({
    super.key,
    required this.pool,
    required this.onDismiss,
    required this.visible,
    required this.groupId,
    required this.access,
    required this.crossAxisCount,
    this.canEditPublicRecipes = false,
    this.onDragStarted,
    this.onDragEnd,
    this.onDragStartedWithSuggestion,
    this.onTagTap,
  });

  @override
  State<SuggestedRowWidget> createState() => _SuggestedRowWidgetState();
}

class _SuggestedRowWidgetState extends State<SuggestedRowWidget> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey();
  late List<RecipeSuggestion> _visible;
  late List<RecipeSuggestion> _remaining;
  bool _appeared = false;

  @override
  void initState() {
    super.initState();
    _visible = widget.pool.take(3).toList();
    _remaining = widget.pool.skip(3).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _appeared = true);
    });
  }

  void _dismiss(int index) {
    final removed = _visible[index];
    _visible.removeAt(index);
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _tile(removed, -1, animation, interactive: false),
      duration: const Duration(milliseconds: 300),
    );
    if (_remaining.isNotEmpty) {
      final next = _remaining.removeAt(0);
      _visible.add(next);
      _listKey.currentState?.insertItem(
        _visible.length - 1,
        duration: const Duration(milliseconds: 300),
      );
    }
    widget.onDismiss(removed);
  }

  Widget _tile(
    RecipeSuggestion s,
    int index,
    Animation<double> animation, {
    bool interactive = true,
  }) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    final tileW = smallerdim / widget.crossAxisCount;
    final card = RecipeSuggestionCard(suggestion: s, crossAxisCount: widget.crossAxisCount);
    return SizeTransition(
      sizeFactor: animation,
      axis: Axis.horizontal,
      child: SizedBox(
        width: tileW,
        child: Stack(
          children: [
            interactive
                ? LongPressDraggable<RecipeSuggestion>(
                    data: s,
                    onDragStarted: () {
                      widget.onDragStarted?.call();
                      widget.onDragStartedWithSuggestion?.call(s);
                    },
                    onDragEnd: (_) => widget.onDragEnd?.call(),
                    onDraggableCanceled: (_, __) => widget.onDragEnd?.call(),
                    feedback: RecipeSuggestionCard(
                        suggestion: s, crossAxisCount: widget.crossAxisCount),
                    childWhenDragging: RecipeSuggestionCard(
                        suggestion: s, crossAxisCount: widget.crossAxisCount),
                    child: OpenContainer(
                      tappable: false,
                      transitionType: ContainerTransitionType.fade,
                      transitionDuration: const Duration(milliseconds: 300),
                      closedElevation: 0,
                      closedColor: Colors.transparent,
                      openColor: Theme.of(context).scaffoldBackgroundColor,
                      closedShape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                      closedBuilder: (_, open) => GestureDetector(onTap: open, child: card),
                      openBuilder: (_, __) => RecipeDetailPage(
                        groupId: widget.groupId,
                        recipeId: '',
                        access: widget.access,
                        publicRecipeId: s.publicId,
                        canEditPublicRecipes: widget.canEditPublicRecipes,
                        onTagTap: widget.onTagTap,
                        initialData: {
                          'name': s.title,
                          'description': '',
                          'images': (s.publicImage?.isNotEmpty ?? false)
                              ? [s.publicImage!]
                              : <String>[],
                          'steps': <String>[],
                          'tags': <String>[],
                          'servings': 2,
                          'time': 0,
                          'preparationTime': 0,
                        },
                      ),
                    ),
                  )
                : card,
            if (interactive)
              Positioned(
                top: 0,
                right: 4,
                child: GestureDetector(
                  onTap: () => _dismiss(index),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      decoration: const BoxDecoration(
                          color: Colors.black45, shape: BoxShape.circle),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_visible.isEmpty) return const SizedBox.shrink();
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    final tileW = smallerdim / widget.crossAxisCount;
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: widget.visible && _appeared ? tileW * 3 / 4 + 1 : 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: tileW * 3 / 4,
                child: AnimatedList(
                  key: _listKey,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  initialItemCount: _visible.length,
                  itemBuilder: (context, index, animation) =>
                      _tile(_visible[index], index, animation),
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
    );
  }
}
