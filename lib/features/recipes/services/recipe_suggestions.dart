import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/pages/recipe_page.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';

/// Ranking of the group's own recipes (via the cooking-plan usage history)
/// and generation of search-time suggestions (public recipe matches + AI name
/// ideas), mixed into [RecipePage]'s state.
mixin RecipeSuggestionsMixin on State<RecipePage> {
  // ── provided by RecipePage's state ──────────────────────────────────────
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get recipes;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get searchedRecipes;
  set searchedRecipes(List<QueryDocumentSnapshot<Map<String, dynamic>>> value);
  String get searchQuery;

  // ── shared with SuggestedRowMixin ───────────────────────────────────────
  List<String> dietary = [];

  final functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

  // ── AI recipe suggestions (shown as tiles, only when aiEnabled) ────────────
  List<RecipeSuggestion> suggestions = [];      // AI name/url ideas
  List<RecipeSuggestion> publicSuggestions = []; // public recipe search matches
  Timer? aiTimer;
  Timer? publicTimer;
  int _aiSeq = 0;
  bool suggestionsLoading = false;
  final Map<String, List<RecipeSuggestion>> _publicCache = {};
  final Map<String, List<RecipeSuggestion>> _aiCache = {};

  // How often each recipe has been cooked (past cooking-plan entries within
  // [_usageWindowDays]) and which recipes are already planned in the future.
  // Drives the "cook again" ordering of the recipe grid; usage is read from the
  // cooking plans rather than stored on the recipe. Populated from
  // [RecipePage]'s usage listener.
  Map<String, int> get usageCounts;
  Set<String> get futurePlanned;
  Map<String, DateTime> get lastUsedDates;
  bool get usageLoaded;

  // Freezes each recipe's "cook again" score the first time it's computed, so
  // adding it to the plan (or otherwise changing its usage data) doesn't
  // instantly reshuffle the grid mid-session — e.g. while adding the same
  // recipe to several days in a row. The grid re-settles into a fresh order
  // on the next app start.
  Map<String, double> get scoreCache;

  void disposeSuggestions() {
    aiTimer?.cancel();
    publicTimer?.cancel();
  }

  /// How long a just-added recipe stays pinned to the very start of the grid.
  static const Duration _newRecipeWindow = Duration(days: 3);

  /// Orders the recipe grid. Recipes added within [_newRecipeWindow] come first
  /// (newest first) so a freshly added recipe is right at the start. The rest are
  /// ranked so the recipes worth cooking again rise to the top: ones cooked often
  /// but not in the last few days. Frequency comes from the cooking plans
  /// ([usageCounts]) with diminishing returns; a "due" factor starts at 0.35
  /// right after a recipe was last used and grows toward 1 over about a week,
  /// so a just-cooked favourite still sits roughly mid-pack (scaled by how
  /// often it's made) rather than the very bottom, while a regular favourite
  /// resurfaces further as the week goes by. Older never-used
  /// recipes keep a small decaying bonus, and a recipe already planned ahead is
  /// de-emphasised. Each recipe's score is cached the first time it's computed
  /// ([scoreCache]) so the grid doesn't reshuffle mid-session as plans are
  /// added or removed; it re-settles into a fresh order on the next app start.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _rankOwnRecipes(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> list) {
    final now = DateTime.now();
    final newCutoff = now.subtract(_newRecipeWindow);
    final scores = <String, double>{};
    for (final d in list) {
      final cached = scoreCache[d.id];
      if (cached != null) {
        scores[d.id] = cached;
        continue;
      }
      final data = d.data();
      final count = usageCounts[d.id] ?? 0;
      final freq = math.log(1 + count);

      final lastUsed = lastUsedDates[d.id] ?? (data['lastUsedAt'] as Timestamp?)?.toDate();
      double due = 0;
      if (lastUsed != null) {
        final days = now.difference(lastUsed).inHours / 24.0;
        // Floored at 0.35 so a just-cooked favourite still lands roughly in
        // the middle of the pack (scaled by its frequency) instead of the
        // very bottom; it then climbs the rest of the way toward 1 over the
        // following week or so.
        due = 0.35 + 0.65 * (1 - math.exp(-days / 7.0));
      }
      var score = freq * due;

      final created = (data['createdAt'] as Timestamp?)?.toDate();
      if (created != null) {
        final age = now.difference(created).inHours / 24.0;
        score += (count == 0 ? 1.2 : 0.3) * math.exp(-age / 10.0);
      }

      // Already on the plan ahead → less need to resurface it now.
      if (futurePlanned.contains(d.id)) score *= 0.5;
      scores[d.id] = score;
      // Don't cache until real usage data has actually loaded, otherwise a
      // render that races ahead of the usage stream's first snapshot would
      // freeze every recipe at a history-less (near-zero) score.
      if (usageLoaded) scoreCache[d.id] = score;
    }
    DateTime? createdOf(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
        (d.data()['createdAt'] as Timestamp?)?.toDate();

    final ordered = [...list];
    ordered.sort((a, b) {
      // Just-added recipes first, newest first.
      final ca = createdOf(a);
      final cb = createdOf(b);
      final na = ca != null && ca.isAfter(newCutoff);
      final nb = cb != null && cb.isAfter(newCutoff);
      if (na != nb) return na ? -1 : 1;
      if (na && nb) {
        return (cb?.millisecondsSinceEpoch ?? 0)
            .compareTo(ca?.millisecondsSinceEpoch ?? 0);
      }
      // Then by "cook again" score.
      final c = (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0);
      if (c != 0) return c;
      final la = (lastUsedDates[a.id] ?? (a.data()['lastUsedAt'] as Timestamp?)?.toDate())
              ?.millisecondsSinceEpoch ??
          0;
      final lb = (lastUsedDates[b.id] ?? (b.data()['lastUsedAt'] as Timestamp?)?.toDate())
              ?.millisecondsSinceEpoch ??
          0;
      return lb.compareTo(la);
    });
    return ordered;
  }

  /// Splits a raw search string into `#tag` filters and the remaining free
  /// text. A `#tag` token requires an exact (case-insensitive) tag match;
  /// everything else is matched as free text, as before.
  static final _tagTokenRe = RegExp(r'#(\S+)');
  ({List<String> tags, String text}) _parseSearchQuery(String query) {
    final tags = _tagTokenRe
        .allMatches(query)
        .map((m) => m.group(1)!.toLowerCase())
        .toList();
    final text = query.replaceAll(_tagTokenRe, ' ').trim();
    return (tags: tags, text: text);
  }

  void generateSearchedRecipes() {
    final parsed = _parseSearchQuery(searchQuery);
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> pool = recipes;
    if (parsed.tags.isNotEmpty) {
      pool = pool.where((doc) {
        final docTags = (doc.data()['tags'] ?? [])
            .map((e) => e.toString().toLowerCase())
            .toSet();
        return parsed.tags.every(docTags.contains);
      });
    }
    final candidates = pool.toList();

    if (parsed.text.isEmpty) {
      searchedRecipes = _rankOwnRecipes(candidates);
    } else {
      final query = parsed.text.toLowerCase();
      final splitRe = RegExp(r'[ \t\n\r,.;:!?\-()\[\]"\x27\\/]+');
      final queryWords = query.split(splitRe).where((s) => s.isNotEmpty).toList();

      final List<Map<String, dynamic>> scored = [];
      for (final doc in candidates) {
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

  // ── AI suggestions ─────────────────────────────────────────────────────────

  static final _urlRe = RegExp(r'https?://\S+', caseSensitive: false);

  String? extractUrl(String s) => _urlRe.firstMatch(s)?.group(0);

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
  /// Public matches use a short debounce (300 ms) and are shown regardless of
  /// [aiEnabled]; AI name ideas use a 1 s debounce and only when [aiEnabled].
  /// Cached results for the current query are shown immediately so suggestions
  /// persist while the user edits. Lists are only cleared when query is empty.
  /// `#tag` tokens are pulled out as exact tag filters (applied to public
  /// matches) and also folded into the free-text query passed to the public
  /// search and AI idea generation, so tags narrow those results too.
  void onSearchChangedAi(String value) {
    aiTimer?.cancel();
    publicTimer?.cancel();
    final seq = ++_aiSeq;
    final parsed = _parseSearchQuery(value.trim());
    final tags = parsed.tags;
    final q = parsed.text;

    if (q.isEmpty && tags.isEmpty) {
      setState(() {
        suggestions = [];
        publicSuggestions = [];
        suggestionsLoading = false;
      });
      return;
    }

    // URL tile: immediate, AI only. Not applicable while filtering by tag.
    if (widget.aiEnabled && tags.isEmpty) {
      final url = extractUrl(q);
      if (url != null) {
        setState(() {
          suggestions = [
            RecipeSuggestion(kind: SuggestionKind.url, title: '', url: url, loading: true),
          ];
          publicSuggestions = [];
          suggestionsLoading = false;
        });
        _loadUrlTitle(url, seq);
        return;
      }
    }

    // Show cached results immediately; keep current lists visible until replaced.
    final qKey = '${tags.join(',')}|${q.toLowerCase()}';
    setState(() {
      if (_publicCache.containsKey(qKey)) publicSuggestions = _publicCache[qKey]!;
      if (_aiCache.containsKey(qKey)) suggestions = _aiCache[qKey]!;
      suggestionsLoading = true;
    });

    // Public recipes + reused ideas: snappy 300 ms debounce. Both are single
    // indexed reads, so ideas already in the corpus show almost immediately
    // instead of waiting on the AI-generation debounce below.
    publicTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted || seq != _aiSeq) return;
      final results = await _fetchPublicMatches(q, tags);
      if (!mounted || seq != _aiSeq) return;
      _publicCache[qKey] = results;
      setState(() => publicSuggestions = results);

      if (widget.aiEnabled && !(q.isNotEmpty && _hasStrongLocalMatch(q))) {
        final cached = await _fetchCachedIdeas(q, tags);
        if (!mounted || seq != _aiSeq) return;
        if (cached.isNotEmpty) {
          _aiCache[qKey] = cached;
          setState(() => suggestions = cached);
        }
      }
    });

    // AI generation: 1 s debounce, only when the idea corpus didn't already
    // cover the query. Loading clears when this settles.
    if (widget.aiEnabled && !(q.isNotEmpty && _hasStrongLocalMatch(q))) {
      aiTimer = Timer(const Duration(seconds: 1), () async {
        if (!mounted || seq != _aiSeq) return;
        if (suggestions.length >= _minCachedIdeas) {
          setState(() => suggestionsLoading = false);
          return;
        }
        final results = await _generateNameIdeas(q, tags);
        if (!mounted || seq != _aiSeq) return;
        _aiCache[qKey] = results;
        setState(() {
          suggestions = results;
          suggestionsLoading = false;
        });
      });
    } else {
      // No AI fetch; clear loading once the public fetch has had time to land.
      aiTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted || seq != _aiSeq) return;
        setState(() => suggestionsLoading = false);
      });
    }
  }

  Future<void> _loadUrlTitle(String url, int seq) async {
    String title = url;
    try {
      final res = await functions
          .httpsCallable('recipes-fetchRecipeTitleFromUrl')
          .call(<String, dynamic>{'url': url, 'lang': LanguageService.instance.code.value});
      final t = (res.data['title'] ?? '').toString().trim();
      if (t.isNotEmpty) title = t;
    } catch (_) {}
    if (!mounted || seq != _aiSeq) return;
    setState(() {
      if (suggestions.isNotEmpty && suggestions.first.kind == SuggestionKind.url) {
        suggestions.first.title = title;
        suggestions.first.loading = false;
      }
    });
  }

  /// Minimum number of good cached ideas needed to skip AI generation entirely.
  static const int _minCachedIdeas = 3;

  /// Reuses ideas earlier searches already generated: up to [_minCachedIdeas]
  /// names whose search terms cover the whole query and fit the user's diet, or
  /// an empty list when the corpus doesn't cover it well enough. A single indexed
  /// read, so it runs on the snappy debounce to show reused ideas quickly.
  /// [tags] (from `#tag` filters) are folded into the required terms, so a
  /// cached idea must also carry that tag word in its name to qualify.
  Future<List<RecipeSuggestion>> _fetchCachedIdeas(String q, [List<String> tags = const []]) async {
    final lang = LanguageService.instance.code.value;
    final tokens = {
      ...q
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
          .where((t) => t.length >= 2),
      ...tags,
    }.toList();
    if (tokens.isEmpty) return const [];
    try {
      final snap = await FirebaseFirestore.instance
          .collection('recipe_idea_cache')
          .where('searchTokens', arrayContainsAny: tokens.take(10).toList())
          .limit(20)
          .get();
      final tokenSet = tokens.toSet();
      final prefs = dietary.map((e) => e.toLowerCase()).toSet();
      final seenNames = <String>{};
      final names = <String>[];
      for (final d in snap.docs) {
        final data = d.data();
        if ((data['lang'] ?? 'en') != lang) continue;
        final ideaTokens =
            (data['searchTokens'] as List?)?.map((e) => e.toString()).toSet() ??
                const <String>{};
        // The idea must match every word of the query to count as a good hit.
        if (tokenSet.where(ideaTokens.contains).length < tokenSet.length) {
          continue;
        }
        // …and satisfy every diet the user follows.
        final dietaryTags = (data['dietary'] as List?)
                ?.map((e) => e.toString().toLowerCase())
                .toSet() ??
            const <String>{};
        if (!prefs.every(dietaryTags.contains)) continue;
        final name = (data['name'] ?? '').toString().trim();
        if (name.isNotEmpty && seenNames.add(name.toLowerCase())) {
          names.add(name);
        }
      }
      if (names.length >= _minCachedIdeas) {
        return names
            .take(_minCachedIdeas)
            .map((n) => RecipeSuggestion(kind: SuggestionKind.name, title: n))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Generates fresh name ideas via the AI function (which stores them, tagged
  /// with search terms, for future reuse). Slower, so it runs only on the longer
  /// debounce when the idea corpus didn't already cover the query. [tags] (from
  /// `#tag` filters) are folded into the query text so the generated ideas fit
  /// them, even when there is no other free text.
  Future<List<RecipeSuggestion>> _generateNameIdeas(String q, [List<String> tags = const []]) async {
    final query = [q, ...tags].where((s) => s.isNotEmpty).join(' ');
    if (query.isEmpty) return const [];
    try {
      final res = await functions
          .httpsCallable('recipes-suggestRecipeNames')
          .call(<String, dynamic>{'groupId': widget.groupId, 'query': query, 'lang': LanguageService.instance.code.value});
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

  /// [tags] (from `#tag` filters) are folded into the token search so tagged
  /// recipes surface, and are then required as an exact match (case-insensitive,
  /// against the base or the current language's translated tags) so only
  /// recipes actually carrying every requested tag are returned.
  Future<List<RecipeSuggestion>> _fetchPublicMatches(String q, [List<String> tags = const []]) async {
    try {
      final tokens = {
        ...q
            .toLowerCase()
            .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
            .where((t) => t.length >= 2),
        ...tags,
      }.toList();
      if (tokens.isEmpty) return [];
      final snap = await FirebaseFirestore.instance
          .collection('public_recipes')
          .where('searchTokens', arrayContainsAny: tokens.take(10).toList())
          .limit(20)
          .get();
      final lang = LanguageService.instance.code.value;
      final tokenSet = tokens.toSet();
      // Public recipes keep an English base plus a `translations` map for the
      // languages listed in `languages`. Recipes available in the user's
      // language come first (shown translated); within each language bucket the
      // best matches — more query tokens hit, then more popular — come first.
      final ranked = <({bool hasOwn, double score, RecipeSuggestion s})>[];
      for (final d in snap.docs) {
        final data = d.data();
        final languages = (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
        final hasOwn = lang != 'en' && languages.contains(lang);
        var title = (data['name'] ?? '').toString();
        if (hasOwn) {
          final localized = (data['translations'] as Map?)?[lang] as Map?;
          final name = (localized?['name'] ?? '').toString();
          if (name.isNotEmpty) title = name;
        }
        if (tags.isNotEmpty) {
          Map? localizedTags;
          if (hasOwn) {
            localizedTags = (data['translations'] as Map?)?[lang] as Map?;
          }
          final docTags = {
            ...(data['tags'] as List? ?? const []).map((e) => e.toString().toLowerCase()),
            ...(localizedTags?['tags'] as List? ?? const []).map((e) => e.toString().toLowerCase()),
          };
          if (!tags.every(docTags.contains)) continue;
        }
        final recipeTokens =
            (data['searchTokens'] as List?)?.map((e) => e.toString()).toSet() ?? const <String>{};
        final relevance = tokenSet.where(recipeTokens.contains).length;
        final popularity = (data['popularity'] as num?)?.toDouble() ?? 0;
        ranked.add((
          hasOwn: hasOwn,
          score: relevance * 10 + math.log(1 + popularity),
          s: RecipeSuggestion(
            kind: SuggestionKind.public,
            title: title,
            publicId: d.id,
            publicImage: data['image'] as String?,
          ),
        ));
      }
      ranked.sort((a, b) {
        if (a.hasOwn != b.hasOwn) return a.hasOwn ? -1 : 1;
        return b.score.compareTo(a.score);
      });
      return ranked.map((e) => e.s).take(4).toList();
    } catch (_) {
      return [];
    }
  }
}
