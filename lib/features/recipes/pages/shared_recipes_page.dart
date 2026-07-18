import 'dart:async';

import 'package:animations/animations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_card.dart' show RecipeCard;
import 'package:couple_planner/features/recipes/services/copy_group_recipe.dart';
import 'package:couple_planner/features/recipes/services/delete_recipe.dart';

/// Browses another group's recipes (as a recipe viewer) and lets the user add
/// any of them to their own active group. A filled round check marks recipes
/// already copied into the active group; tapping it copies or removes the
/// recipe. Tapping the tile body opens a read-only detail preview.
class SharedRecipesPage extends StatefulWidget {
  const SharedRecipesPage({
    super.key,
    required this.sourceGroupId,
    this.showLeaveButton = true,
  });

  final String sourceGroupId;
  final bool showLeaveButton;

  @override
  State<SharedRecipesPage> createState() => _SharedRecipesPageState();
}

class _SharedRecipesPageState extends State<SharedRecipesPage> {
  final _db = FirebaseFirestore.instance;
  final String _uid = FirebaseAuth.instance.currentUser!.uid;

  String? _destGroupId;
  List<String> _memberGroupIds = [];
  bool _groupPickerExpanded = false;

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
    final memberSnap = await _db.collection('users').doc(_uid).collection('groups').get();
    if (!mounted) return;
    final memberIds = memberSnap.docs.map((d) => d.id).toList();
    setState(() => _memberGroupIds = memberIds);

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('selected_group');
    // If the preferred dest is the source itself (or unset), pick a different member group.
    if (id == null || id.isEmpty || id == widget.sourceGroupId) {
      id = memberIds.firstWhere((g) => g != widget.sourceGroupId, orElse: () => '');
      if (id.isEmpty) id = null;
    }
    if (!mounted) return;
    setState(() => _destGroupId = id);
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
  Future<void> _removeCopy(String destId, String recipeId) =>
      deleteGroupRecipe(groupId: destId, recipeId: recipeId);

  Future<void> _leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop viewing recipes?'),
        content: const Text('You can be invited again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _db.collection('users').doc(_uid).collection('recipe_groups').doc(widget.sourceGroupId).delete();
    if (mounted) Navigator.of(context).pop();
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
        actions: [
          if (widget.showLeaveButton)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Leave',
              onPressed: _leave,
            ),
        ],
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
    // Member groups that can serve as copy destination (exclude the source group itself).
    final targets = _memberGroupIds.where((g) => g != widget.sourceGroupId).toList();
    final canSwitch = targets.length > 1;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: double.infinity,
        color: cs.surfaceContainerHigh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: canSwitch
                  ? () => setState(() => _groupPickerExpanded = !_groupPickerExpanded)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.add_task, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _destGroupId == null
                          ? const Text('No group available to copy to.')
                          : LoadDocumentBuilder(
                              docRef: _db.collection('groups').doc(_destGroupId),
                              builder: (data) => Text(
                                'Copying to: ${(data['name'] ?? '').toString()}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                    ),
                    if (canSwitch)
                      Icon(_groupPickerExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                  ],
                ),
              ),
            ),
            if (_groupPickerExpanded)
              for (final gid in targets)
                RadioListTile<String>(
                  value: gid,
                  groupValue: _destGroupId,
                  title: LoadDocumentBuilder(
                    docRef: _db.collection('groups').doc(gid),
                    builder: (data) => Text((data['name'] ?? 'Group').toString()),
                  ),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _destGroupId = v;
                      _groupPickerExpanded = false;
                    });
                    _subscribeDest(v);
                  },
                ),
          ],
        ),
      ),
    );
  }

  Widget _tile(QueryDocumentSnapshot<Map<String, dynamic>> doc, int crossAxisCount) {
    final data = doc.data();
    final added = _addedBySource.containsKey(doc.id);
    final busy = _busy.contains(doc.id);
    final cs = Theme.of(context).colorScheme;
    final destId = _destGroupId;
    final existingId = _addedBySource[doc.id];

    return Stack(
      fit: StackFit.expand,
      children: [
        OpenContainer(
          tappable: false,
          transitionType: ContainerTransitionType.fade,
          transitionDuration: const Duration(milliseconds: 300),
          closedElevation: 0,
          closedColor: Colors.transparent,
          openColor: Theme.of(context).scaffoldBackgroundColor,
          closedShape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          closedBuilder: (_, open) => GestureDetector(
            onTap: destId == null
                ? () => _snack('Select or create your own group first.')
                : open,
            child: RecipeCard(
              recipeId: doc.id,
              groupCollection: _sourceGroupRef,
              data: data,
              crossAxisCount: crossAxisCount,
            ),
          ),
          openBuilder: (_, __) => existingId != null
              ? RecipeDetailPage(groupId: destId!, recipeId: existingId)
              : RecipeDetailPage(
                  groupId: destId!,
                  recipeId: doc.id,
                  sharedSourceGroupId: widget.sourceGroupId,
                  initialData: data,
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
