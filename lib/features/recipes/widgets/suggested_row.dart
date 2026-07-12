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
  static const String _kDismissedKey = 'dismissed_public_recipes';
  // Calendar day the suggested row was last loaded for (see loadSuggestedRow's
  // date-seeded pool). Lets refreshSuggestedRowIfStale detect a session left
  // open across midnight, when the row would otherwise keep showing
  // yesterday's picks until the next app start.
  String? _suggestedRowDayKey;

  Future<void> loadDismissed() async {
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
  Future<void> loadSuggestedRow() async {
    try {
      final col = FirebaseFirestore.instance.collection('public_recipes');

      // A group with no recipes and no cooking plans yet has no usage signal
      // to weight suggestions by, so the usual weighted-random/dismissal/
      // seasonal ordering below isn't meaningful for it. Instead just show
      // recipes matching every one of the user's diets, sorted by popularity
      // alone (falling back to popularity alone if none match).
      final groupEmpty = recipesLoaded && plansLoaded && recipes.isEmpty && cookingPlans.isEmpty;
      if (groupEmpty) {
        final now = DateTime.now();
        _suggestedRowDayKey = '${now.year}-${now.month}-${now.day}';
        final ordered = await _loadEmptyGroupSuggestions(col);
        if (!mounted) return;
        setState(() => suggestedPool = ordered);
        return;
      }

      const poolSize = 40;
      final now = DateTime.now();
      _suggestedRowDayKey = '${now.year}-${now.month}-${now.day}';
      final seed =
          _stableHash('${widget.groupId}-${now.year}-${now.month}-${now.day}');
      final pivot = (_stableHash('pivot-$seed') % 100000) / 100000.0;
      final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final firstFuture = col
          .where('random', isGreaterThanOrEqualTo: pivot)
          .orderBy('random')
          .limit(poolSize)
          .get();
      // Also pull the most popular recipes so widely-adopted ones have a real
      // chance to surface, on top of the daily random sample. They still go
      // through the weighted sampling below, so the row stays varied. Fired
      // alongside `firstFuture` (rather than after it) since the two queries
      // don't depend on each other.
      final popularFuture = col
          .orderBy('popularity', descending: true)
          .limit(15)
          .get();
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
        final popular = await popularFuture;
        docs.addAll(popular.docs);
      } catch (_) {}
      // Fallback for public recipes missing the `random` field: those documents
      // are excluded from the range queries above, so fetch a plain page rather
      // than leaving the row empty.
      if (docs.isEmpty) {
        final plain = await col.limit(poolSize).get();
        docs.addAll(plain.docs);
      }

      final lang = LanguageService.instance.code.value;
      final prefs = dietary.map((e) => e.toLowerCase()).toSet();
      final seen = <String>{};
      final scored = <({double key, bool seasonal, RecipeSuggestion s})>[];
      for (final d in docs) {
        if (!seen.add(d.id)) continue;
        final data = d.data();
        final recipeDietary = List<String>.from(data['dietary'] ?? [])
            .map((e) => e.toLowerCase())
            .toSet();
        // A recipe is in season when its suitable months (1–12) include the
        // current month; a null/empty list means it fits any time of year.
        final suitableMonths = data['suitableMonths'];
        var title = (data['name'] ?? '').toString();
        if (lang != 'en') {
          final languages = (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
          if (languages.contains(lang)) {
            final localized = (data['translations'] as Map?)?[lang] as Map?;
            final localizedName = (localized?['name'] ?? '').toString();
            if (localizedName.isNotEmpty) title = localizedName;
          }
        }

        // Weighted-random ordering: a recipe's chance of ranking high grows with
        // how many of the user's dietary tags it matches and how often it has
        // been adopted (popularity), and shrinks each time it is dismissed.
        // Nothing is filtered out, so the row always fills.
        final matches = prefs.where(recipeDietary.contains).length;
        final popularity = (data['popularity'] as num?)?.toDouble() ?? 0;
        final dismissed = _dismissed[d.id] ?? 0;
        final weight = (1 + 2 * matches) *
            (1 + math.log(1 + popularity)) /
            (1 + dismissed);
        // Deterministic per-recipe uniform in (0,1], identical for every group
        // member and reshuffled each day via the group+date seed.
        final r = (_stableHash('$seed-${d.id}') % 100000 + 1) / 100001.0;
        // Efraimidis–Spirakis key: smaller wins, higher weight → smaller key.
        final key = -math.log(r) / weight;

        scored.add((
          key: key,
          seasonal: suitableMonths is List && suitableMonths.contains(now.month),
          s: RecipeSuggestion(
            kind: SuggestionKind.public,
            title: title,
            publicId: d.id,
            publicImage: data['image'] as String?,
          ),
        ));
      }
      scored.sort((a, b) => a.key.compareTo(b.key));
      // Interleave in-season and any-time recipes so roughly half of the shown
      // suggestions fit the current season, while each stream keeps the ranking
      // above. When one stream runs out the rest are simply appended.
      final seasonal = [for (final e in scored) if (e.seasonal) e.s];
      final anytime = [for (final e in scored) if (!e.seasonal) e.s];
      final ordered = <RecipeSuggestion>[];
      for (var i = 0; i < seasonal.length || i < anytime.length; i++) {
        if (i < seasonal.length) ordered.add(seasonal[i]);
        if (i < anytime.length) ordered.add(anytime[i]);
      }
      if (!mounted) return;
      setState(() {
        suggestedPool = ordered.toList();
      });
    } catch (_) {}
  }

  /// Suggestions for a group with no recipes and no cooking plans yet: the
  /// top public recipes by popularity that match every one of the user's
  /// diets, or — if none of the top-popularity recipes satisfy that unusual a
  /// combination — the top public recipes by popularity regardless of diet,
  /// so the row is never left empty.
  Future<List<RecipeSuggestion>> _loadEmptyGroupSuggestions(
      CollectionReference<Map<String, dynamic>> col) async {
    final lang = LanguageService.instance.code.value;
    final prefs = dietary.map((e) => e.toLowerCase()).toSet();

    Future<List<RecipeSuggestion>> topPopular({required bool requireAllDiets}) async {
      final snap = await col.orderBy('popularity', descending: true).limit(100).get();
      final out = <RecipeSuggestion>[];
      for (final d in snap.docs) {
        final data = d.data();
        if (requireAllDiets && prefs.isNotEmpty) {
          final recipeDietary = List<String>.from(data['dietary'] ?? [])
              .map((e) => e.toLowerCase())
              .toSet();
          if (!prefs.every(recipeDietary.contains)) continue;
        }
        var title = (data['name'] ?? '').toString();
        if (lang != 'en') {
          final languages = (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
          if (languages.contains(lang)) {
            final localized = (data['translations'] as Map?)?[lang] as Map?;
            final localizedName = (localized?['name'] ?? '').toString();
            if (localizedName.isNotEmpty) title = localizedName;
          }
        }
        out.add(RecipeSuggestion(
          kind: SuggestionKind.public,
          title: title,
          publicId: d.id,
          publicImage: data['image'] as String?,
        ));
      }
      return out;
    }

    try {
      final matched = await topPopular(requireAllDiets: true);
      if (matched.isNotEmpty) return matched;
      return await topPopular(requireAllDiets: false);
    } catch (_) {
      return const [];
    }
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
