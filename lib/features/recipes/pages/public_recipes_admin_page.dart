import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
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

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  final _scrollController = ScrollController();
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _loading = false;
  bool _hasMore = true;

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

  Future<void> _regenerateImage(String recipeId) async {
    setState(() => _regenerating.add(recipeId));
    try {
      await _functions
          .httpsCallable('recipesEnhancement-regeneratePublicRecipeImage')
          .call({'recipeId': recipeId});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate image: $e')));
    } finally {
      if (mounted) setState(() => _regenerating.remove(recipeId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Public recipes')),
      body: ListView.builder(
        controller: _scrollController,
        itemCount: _docs.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _docs.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final d = _docs[i];
          final data = d.data();
          final lang = LanguageService.instance.code.value;
          var title = (data['name'] ?? '').toString();
          if (lang != 'en') {
            final languages =
                (data['languages'] as List?)?.map((e) => e.toString()).toList() ?? const ['en'];
            if (languages.contains(lang)) {
              final localized = (data['translations'] as Map?)?[lang] as Map?;
              final localizedName = (localized?['name'] ?? '').toString();
              if (localizedName.isNotEmpty) title = localizedName;
            }
          }
          final image = data['image'] as String?;
          final tags = (data['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [];
          final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
          final dateStr = createdAt == null
              ? null
              : '${createdAt.day.toString().padLeft(2, '0')}.${createdAt.month.toString().padLeft(2, '0')}.${createdAt.year}';
          final subtitleParts = [
            if (dateStr != null) dateStr,
            if (tags.isNotEmpty) tags.join(', '),
          ];
          final isRegenerating = _regenerating.contains(d.id);

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
      final hasUnresolved = snap.docs.any((d) => (d.data()['ingredientId'] as String?)?.trim().isNotEmpty != true);
      if (mounted) setState(() => _hasUnresolved = hasUnresolved);
    } catch (_) {
      // leave as-is, retried next time the tile is rebuilt
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resolve() async {
    setState(() => _resolving = true);
    try {
      final res = await widget.functions
          .httpsCallable('ingredients-resolvePublicRecipeIngredients')
          .call({'recipeId': widget.recipeId});
      final data = res.data as Map;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Resolved ${data['count']}/${data['total']} ingredients')),
        );
      }
      await _checkUnresolved();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not resolve ingredients: $e')));
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
