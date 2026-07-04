import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/pages/recipe_page.dart' show RecipeCard;
import 'package:couple_planner/features/recipes/services/copy_group_recipe.dart';

/// Browses another group's recipes (as a recipe viewer) and lets the user add
/// any of them to their own active group. A filled round check marks recipes
/// already copied into the active group; tapping it copies or removes the
/// recipe. Tapping the tile body opens a read-only detail preview.
class SharedRecipesPage extends StatefulWidget {
  const SharedRecipesPage({super.key, required this.sourceGroupId});

  final String sourceGroupId;

  @override
  State<SharedRecipesPage> createState() => _SharedRecipesPageState();
}

class _SharedRecipesPageState extends State<SharedRecipesPage> {
  final _db = FirebaseFirestore.instance;
  final String _uid = FirebaseAuth.instance.currentUser!.uid;

  String? _destGroupId;

  StreamSubscription? _sourceSub;
  StreamSubscription? _destSub;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _sourceRecipes = [];
  // Maps a source recipe id to the id of its copy in the active group.
  Map<String, String> _addedBySource = {};
  final Set<String> _busy = {};

  DocumentReference<Map<String, dynamic>> get _sourceGroupRef =>
      _db.collection('groups').doc(widget.sourceGroupId);

  @override
  void initState() {
    super.initState();
    _sourceSub = _sourceGroupRef
        .collection('recipes')
        .orderBy('lastUsedAt', descending: true)
        .snapshots()
        .listen((s) {
      if (mounted) setState(() => _sourceRecipes = s.docs);
    });
    _loadDestGroup();
  }

  Future<void> _loadDestGroup() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('selected_group');
    if (!mounted) return;
    setState(() => _destGroupId = (id != null && id.isNotEmpty) ? id : null);
    if (_destGroupId != null) _subscribeDest(_destGroupId!);
  }

  void _subscribeDest(String destId) {
    _destSub?.cancel();
    _destSub = _db
        .collection('groups')
        .doc(destId)
        .collection('recipes')
        .where('sourceGroupId', isEqualTo: widget.sourceGroupId)
        .snapshots()
        .listen((s) {
      if (!mounted) return;
      setState(() {
        _addedBySource = {
          for (final d in s.docs)
            if (d.data()['sourceRecipeId'] != null)
              d.data()['sourceRecipeId'] as String: d.id,
        };
      });
    });
  }

  @override
  void dispose() {
    _sourceSub?.cancel();
    _destSub?.cancel();
    super.dispose();
  }

  Future<void> _toggle(String sourceRecipeId) async {
    final destId = _destGroupId;
    if (destId == null) {
      _snack('Select or create your own group first.');
      return;
    }
    if (_busy.contains(sourceRecipeId)) return;
    setState(() => _busy.add(sourceRecipeId));
    try {
      final existingId = _addedBySource[sourceRecipeId];
      if (existingId != null) {
        await _removeCopy(destId, existingId);
      } else {
        await copyGroupRecipe(
          groupId: destId,
          sourceGroupId: widget.sourceGroupId,
          sourceRecipeId: sourceRecipeId,
          uid: _uid,
        );
      }
    } catch (_) {
      _snack('Could not update this recipe.');
    } finally {
      if (mounted) setState(() => _busy.remove(sourceRecipeId));
    }
  }

  /// Deletes a copied recipe from the active group, mirroring the detail page's
  /// delete: any cooking plans referencing it are removed too.
  Future<void> _removeCopy(String destId, String recipeId) async {
    final destGroup = _db.collection('groups').doc(destId);
    final plans = await destGroup
        .collection('cooking_plan')
        .where('recipe', isEqualTo: recipeId)
        .get();
    final batch = _db.batch();
    for (final p in plans.docs) {
      batch.delete(p.reference);
    }
    batch.delete(destGroup.collection('recipes').doc(recipeId));
    await batch.commit();
  }

  void _openDetail(String sourceRecipeId, Map<String, dynamic> data) {
    if (_destGroupId == null) {
      _snack('Select or create your own group first.');
      return;
    }
    final existingId = _addedBySource[sourceRecipeId];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => existingId != null
          // Already copied: open the editable local recipe directly.
          ? RecipeDetailPage(groupId: _destGroupId!, recipeId: existingId)
          // Not yet copied: read-only preview with a "Save in own recipes" button.
          : RecipeDetailPage(
              groupId: _destGroupId!,
              recipeId: sourceRecipeId,
              sharedSourceGroupId: widget.sourceGroupId,
              initialData: data,
            ),
    ));
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final displaySize = MediaQuery.of(context).size;
    final isTablet = displaySize.shortestSide >= 600;
    final crossAxisCount = isTablet
        ? (displaySize.width < displaySize.height ? 5 : displaySize.width ~/ (displaySize.height / 5))
        : (displaySize.width < displaySize.height ? 3 : displaySize.width ~/ (displaySize.height / 3));

    return Scaffold(
      appBar: AppBar(
        title: LoadDocumentBuilder(
          docRef: _sourceGroupRef,
          builder: (data) => Text((data['name'] ?? 'Recipes').toString()),
        ),
      ),
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: _sourceRecipes.isEmpty
                ? const Center(child: Text('No recipes to show yet.'))
                : GridView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: crossAxisCount),
                    itemCount: _sourceRecipes.length,
                    itemBuilder: (context, i) => _tile(_sourceRecipes[i], crossAxisCount),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: _destGroupId == null
          ? const Text('Select or create your own group to add recipes.')
          : Row(
              children: [
                const Icon(Icons.add_task, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: LoadDocumentBuilder(
                    docRef: _db.collection('groups').doc(_destGroupId),
                    builder: (data) => Text(
                      'Select recipes to add them to group ${(data['name'] ?? '').toString()}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tile(QueryDocumentSnapshot<Map<String, dynamic>> doc, int crossAxisCount) {
    final data = doc.data();
    final added = _addedBySource.containsKey(doc.id);
    final busy = _busy.contains(doc.id);
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        GestureDetector(
          onTap: () => _openDetail(doc.id, data),
          child: RecipeCard(
            recipeId: doc.id,
            groupCollection: _sourceGroupRef,
            data: data,
            crossAxisCount: crossAxisCount,
          ),
        ),
        Positioned(
          top: 8,
          right: 12,
          child: GestureDetector(
            onTap: () => _toggle(doc.id),
            behavior: HitTestBehavior.opaque,
            child: Container(
              decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
              padding: const EdgeInsets.all(2),
              child: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    )
                  : Icon(
                      added ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: added ? cs.primary : Colors.white,
                      size: 24,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
