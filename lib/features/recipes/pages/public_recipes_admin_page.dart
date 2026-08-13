import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kPendingIngredient, kUnknownIngredient;
import 'package:couple_planner/features/recipes/models/recipe_category.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';

/// Lists every generated public recipe (global, server-managed), newest
/// first, for moderation by users with `editPublicRecipes`. Tapping one opens
/// the same read-only preview used for a suggestion tile in [RecipePage].
class PublicRecipesAdminPage extends StatefulWidget {
  const PublicRecipesAdminPage({super.key, required this.groupId});

  /// The active group a previewed recipe would be adopted/saved into.
  final String groupId;

  @override
  State<PublicRecipesAdminPage> createState() => _PublicRecipesAdminPageState();
}

class _PublicRecipesAdminPageState extends State<PublicRecipesAdminPage> {
  static const _pageSize = 30;

  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');
  final Set<String> _regenerating = {};
  final Set<String> _regeneratingTags = {};

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _loading = false;
  bool _hasMore = true;
  bool _loadingAll = false;
  String _query = '';

  /// Category filter: null = all, `_kUncategorized` = only recipes that have
  /// never been classified, otherwise one of [kRecipeCategories]. Applied
  /// client-side over the loaded pages (like search), so selecting one pulls
  /// in every remaining page first.
  static const _kUncategorized = '__none__';
  String? _categoryFilter;

  bool _backfilling = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    var query = FirebaseFirestore.instance
        .collection('public_recipes')
        .orderBy('createdAt', descending: true)
        .limit(_pageSize);
    if (_lastDoc != null) query = query.startAfterDocument(_lastDoc!);
    final snap = await query.get();
    if (!mounted) return;
    setState(() {
      _docs.addAll(snap.docs);
      if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
      _hasMore = snap.docs.length == _pageSize;
      _loading = false;
    });
  }

  /// Search only matches what's already loaded, so pull in every remaining
  /// page once the user starts typing.
  Future<void> _loadAll() async {
    if (_loadingAll) return;
    _loadingAll = true;
    try {
      while (_hasMore) {
        await _loadMore();
      }
    } finally {
      _loadingAll = false;
    }
  }

  Future<void> _regenerateImage(String recipeId) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _regenerating.add(recipeId));
    try {
      await _functions
          .httpsCallable('recipesEnhancement-regeneratePublicRecipeImage')
          .call({'recipeId': recipeId});
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not generate image: $e')));
    } finally {
      if (mounted) setState(() => _regenerating.remove(recipeId));
    }
  }

  Future<void> _regenerateTags(String recipeId) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _regeneratingTags.add(recipeId));
    try {
      final res = await _functions
          .httpsCallable('recipes-regeneratePublicRecipeTags')
          .call({'recipeId': recipeId});
      final dietary = (res.data as Map)['dietary'] as List?;
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Dietary tags: ${dietary?.isEmpty ?? true ? 'none' : dietary!.join(', ')}')),
        );
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not regenerate tags: $e')));
    } finally {
      if (mounted) setState(() => _regeneratingTags.remove(recipeId));
    }
  }

  /// Runs the server-side category backfill until nothing is left to do. Each
  /// call handles a capped batch and reports what remains, so this loops rather
  /// than asking one invocation to chew through the whole pool.
  Future<void> _backfillCategories() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _backfilling = true);
    var processed = 0;
    var failed = 0;
    try {
      while (true) {
        final res = await _functions
            .httpsCallable('recipes-backfillPublicRecipeCategories')
            .call();
        final data = res.data as Map;
        final done = (data['processed'] as num?)?.toInt() ?? 0;
        processed += done;
        failed += (data['failed'] as num?)?.toInt() ?? 0;
        final remaining = (data['remaining'] as num?)?.toInt() ?? 0;
        if (!mounted) return;
        // Stop once nothing is left — or when a run made no progress at all,
        // which means every batch failed and retrying would just loop on the
        // same recipes.
        if (remaining <= 0 || done == 0) break;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Categorised $processed recipe(s)'
            '${failed > 0 ? ', $failed could not be classified' : ''}.',
          ),
        ),
      );
      // The loaded docs still carry the old (missing) category — reload so the
      // list and the filter reflect what was just written.
      if (mounted) await _reload();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Backfill failed: $e')));
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  /// Drops every loaded page and starts over from the newest recipe.
  Future<void> _reload() async {
    setState(() {
      _docs.clear();
      _lastDoc = null;
      _hasMore = true;
      _loading = false;
    });
    await _loadMore();
    // Search and the category filter both work over loaded pages only.
    if (_query.isNotEmpty || _categoryFilter != null) await _loadAll();
  }

  String _titleFor(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    final lang = LanguageService.instance.code.value;
    var title = (data['name'] ?? '').toString();
    if (lang != 'en') {
      final languages = (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
      if (languages.contains(lang)) {
        final localized = (data['translations'] as Map?)?[lang] as Map?;
        final localizedName = (localized?['name'] ?? '').toString();
        if (localizedName.isNotEmpty) title = localizedName;
      }
    }
    return title;
  }

  @override
  Widget build(BuildContext context) {
    final filteredDocs = _docs.where((d) {
      if (_query.isNotEmpty &&
          !_titleFor(d).toLowerCase().contains(_query.toLowerCase())) {
        return false;
      }
      if (_categoryFilter == null) return true;
      final category = recipeCategoryOf(d.data()['category']);
      return _categoryFilter == _kUncategorized
          ? category == null
          : category == _categoryFilter;
    }).toList();
    // The "load more on scroll" spinner only makes sense while the full list is
    // showing; both filters work over already-loaded pages.
    final showLoadMore = _query.isEmpty && _categoryFilter == null && _hasMore;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Public recipes'),
        actions: [
          IconButton(
            icon: _backfilling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.category_outlined),
            tooltip: 'Backfill missing categories',
            onPressed: _backfilling ? null : _backfillCategories,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) {
                setState(() => _query = v);
                if (v.isNotEmpty) _loadAll();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: DropdownButtonFormField<String?>(
              initialValue: _categoryFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Category',
                prefixIcon: Icon(Icons.filter_list),
              ),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All categories')),
                const DropdownMenuItem<String?>(
                  value: _kUncategorized,
                  child: Text('Uncategorized'),
                ),
                for (final key in kRecipeCategories)
                  DropdownMenuItem<String?>(
                    value: key,
                    child: Text(kRecipeCategoryLabels[key] ?? key),
                  ),
              ],
              onChanged: (v) {
                setState(() => _categoryFilter = v);
                if (v != null) _loadAll();
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: filteredDocs.length + (showLoadMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= filteredDocs.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final d = filteredDocs[i];
                final data = d.data();
                final title = _titleFor(d);
                final image = data['image'] as String?;
                final tags = (data['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [];
                final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
                final dateStr = createdAt == null
                    ? null
                    : '${createdAt.day.toString().padLeft(2, '0')}.${createdAt.month.toString().padLeft(2, '0')}.${createdAt.year}';
                final category = recipeCategoryOf(data['category']);
                final subtitleParts = [
                  if (dateStr != null) dateStr,
                  // Always shown, so an uncategorized recipe is visible as such
                  // without having to filter for it.
                  category == null ? 'Uncategorized' : recipeCategoryLabel(category),
                  if (tags.isNotEmpty) tags.join(', '),
                ];
                final isRegenerating = _regenerating.contains(d.id);
                // final isRegeneratingTags = _regeneratingTags.contains(d.id);

                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: (image?.isNotEmpty ?? false)
                          ? StorageImage(
                              storagePath: image!,
                              fit: BoxFit.cover,
                              memCacheWidth: 128,
                              memCacheHeight: 128,
                              errorWidget: const Icon(Icons.restaurant_menu),
                              placeholder: const Icon(Icons.restaurant_menu),
                            )
                          : Container(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.restaurant_menu),
                            ),
                    ),
                  ),
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: subtitleParts.isEmpty
                      ? null
                      : Text(subtitleParts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ResolveIngredientsButton(recipeId: d.id, functions: _functions),
                      // IconButton(
                      //   icon: isRegeneratingTags
                      //       ? const SizedBox(
                      //           width: 20,
                      //           height: 20,
                      //           child: CircularProgressIndicator(strokeWidth: 2),
                      //         )
                      //       : const Icon(Icons.local_dining),
                      //   tooltip: 'Regenerate dietary tags',
                      //   onPressed: isRegeneratingTags ? null : () => _regenerateTags(d.id),
                      // ),
                      if (!(image?.isNotEmpty ?? false))
                        IconButton(
                          icon: isRegenerating
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome),
                          tooltip: 'Generate image',
                          onPressed: isRegenerating ? null : () => _regenerateImage(d.id),
                        ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecipeDetailPage(
                        groupId: widget.groupId,
                        recipeId: '',
                        publicRecipeId: d.id,
                        canEditPublicRecipes: true,
                        initialData: {
                          'name': title,
                          'description': '',
                          'images': (image?.isNotEmpty ?? false) ? [image] : <String>[],
                          'steps': <String>[],
                          'tags': <String>[],
                          'servings': 2,
                          'time': 0,
                          'preparationTime': 0,
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Only renders a button when the recipe has at least one ingredient without
/// a resolved `ingredientId`. Checks once on mount and re-checks after a
/// resolve run so it hides itself once everything is resolved.
class _ResolveIngredientsButton extends StatefulWidget {
  const _ResolveIngredientsButton({required this.recipeId, required this.functions});

  final String recipeId;
  final FirebaseFunctions functions;

  @override
  State<_ResolveIngredientsButton> createState() => _ResolveIngredientsButtonState();
}

class _ResolveIngredientsButtonState extends State<_ResolveIngredientsButton> {
  bool _checking = true;
  bool _hasUnresolved = false;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _checkUnresolved();
  }

  Future<void> _checkUnresolved() async {
    if (mounted) setState(() => _checking = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('public_recipes')
          .doc(widget.recipeId)
          .collection('ingredients')
          .get();
      final hasUnresolved = snap.docs.any((d) {
        final id = (d.data()['ingredientId'] as String?)?.trim() ?? '';
        return id.isEmpty || id == kPendingIngredient || id == kUnknownIngredient;
      });
      if (mounted) setState(() => _hasUnresolved = hasUnresolved);
    } catch (_) {
      // leave as-is, retried next time the tile is rebuilt
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resolve() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _resolving = true);
    try {
      final res = await widget.functions
          .httpsCallable('ingredients-resolvePublicRecipeIngredients')
          .call({'recipeId': widget.recipeId});
      final data = res.data as Map;
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Resolved ${data['count']}/${data['total']} ingredients')),
        );
      }
      await _checkUnresolved();
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not resolve ingredients: $e')));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || !_hasUnresolved) return const SizedBox.shrink();
    return IconButton(
      icon: _resolving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.checklist),
      tooltip: 'Resolve ingredients',
      onPressed: _resolving ? null : _resolve,
    );
  }
}
