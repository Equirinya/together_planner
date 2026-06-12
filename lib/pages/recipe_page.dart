import 'dart:async';

import 'package:couple_planner/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'ingredient_search.dart' show UnitsCache;
import 'recipe_detail.dart';

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
  bool aiGenerating = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? planListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> cookingPlans = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? recipesListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> recipes = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> searchedRecipes = [];

  // One stable GlobalKey per cooking-plan id, used to compute drop position.
  final Map<String, GlobalKey> _planCardKeys = {};
  GlobalKey _planKey(String planId) =>
      _planCardKeys.putIfAbsent(planId, () => GlobalKey());

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
      setState(() => keyboardVisible = visible);
    });
  }

  @override
  void dispose() {
    planListener?.cancel();
    recipesListener?.cancel();
    keyboardSubscription.cancel();
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

  void addNewRecipe() async {
    final newRecipeRef = await groupDoc.collection('recipes').add({
      'name': searchQuery,
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
    });
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
      final planRef = await groupDoc.collection('cooking_plan').add({
        'recipe': data.id,
        'plannedFor': ts,
        'servings': servings,
      });
      data.reference.update({'lastUsedAt': FieldValue.serverTimestamp()});
      if (widget.shoppingListEnabled && mounted) {
        showDialog(
          context: context,
          builder: (_) => _ShoppingListDialog(
            group: groupDoc,
            recipeId: data.id,
            planRef: planRef,
            recipeServings: servings.toInt(),
          ),
        );
      }
    } else if (data.reference.parent.id == 'cooking_plan') {
      data.reference.update({'plannedFor': ts});
    }
  }

  /// Removes a cooking-plan document and subtracts its contributed ingredient
  /// quantities from the shopping list (deletes shopping-list entries that
  /// reach zero).
  Future<void> _removePlan(DocumentReference<Map<String, dynamic>> planRef) async {
    final added = await planRef.collection('added_ingredients').get();
    for (final a in added.docs) {
      final ingId = a['ingredientId'].toString();
      final q = Map<String, dynamic>.from(a['quantity'] ?? {});
      final existing = await groupDoc
          .collection('shopping_list')
          .where('ingredientId', isEqualTo: ingId)
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) {
        final doc = existing.docs.first;
        final cur = Map<String, dynamic>.from(doc['quantity'] ?? {});
        q.forEach((k, v) {
          if (cur.containsKey(k)) {
            final n = (cur[k] as num) - (v as num);
            n > 0 ? cur[k] = n : cur.remove(k);
          }
        });
        cur.isEmpty
            ? await doc.reference.delete()
            : await doc.reference.update({'quantity': cur});
      }
      await a.reference.delete();
    }
    await planRef.delete();
  }

  @override
  Widget build(BuildContext context) {
    final displaySize = MediaQuery.of(context).size;
    final colorScheme = Theme.of(context).colorScheme;

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
              flexWeights: const <int>[1, 3, 3, 1],
              enableSplash: false,
              controller: CarouselController(initialItem: daysToShowPrior),
              children: List.generate(
                daysToShowPrior + daysToShowFuture,
                    (i) => DateTime.now()
                    .subtract(Duration(days: daysToShowPrior))
                    .add(Duration(days: i)),
              ).map((day) {
                final dayPlans = cookingPlans.where((plan) {
                  final d = (plan['plannedFor'] as Timestamp).toDate();
                  return d.year == day.year && d.month == day.month && d.day == day.day;
                }).toList();
                final bool isToday = DateTime.now().difference(day).inHours < 1 &&
                    DateTime.now().difference(day).inHours > -1;
                final String dateString = getRelativeDateString(day);

                // Single DragTarget per day. onAcceptWithDetails computes the
                // insertion index from each plan card's GlobalKey midpoint, so
                // there are no nested DragTargets and no double-fire issues.
                return DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                  onWillAcceptWithDetails: (d) =>
                      ['cooking_plan', 'recipes'].contains(d.data.reference.parent.id),
                  onAcceptWithDetails: (d) {
                    int insertIdx = dayPlans.length;
                    for (int i = 0; i < dayPlans.length; i++) {
                      final box = _planKey(dayPlans[i].id)
                          .currentContext
                          ?.findRenderObject() as RenderBox?;
                      if (box == null) continue;
                      final midY =
                          box.localToGlobal(Offset(0, box.size.height / 2)).dy;
                      if (d.offset.dy < midY) {
                        insertIdx = i;
                        break;
                      }
                    }
                    _handleDrop(day, dayPlans, insertIdx, d.data);
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
                                children: dayPlans.map((plan) => Container(
                                  key: _planKey(plan.id),
                                  child: LongPressDraggable<
                                      DocumentSnapshot<Map<String, dynamic>>>(
                                    data: plan,
                                    feedback: RecipeCard(
                                      recipeId: plan['recipe'],
                                      groupCollection: groupDoc,
                                    ),
                                    childWhenDragging: const RecipeCard(
                                      recipeId: null,
                                      groupCollection: null,
                                    ),
                                    child: GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => RecipeDetailPage(
                                            groupId: groupDoc.id,
                                            recipeId: plan['recipe'],
                                            aiEnabled: widget.aiEnabled,
                                          ),
                                        ),
                                      ),
                                      child: RecipeCard(
                                        recipeId: plan['recipe'],
                                        groupCollection: groupDoc,
                                      ),
                                    ),
                                  ),
                                )).toList(),
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
              GridView.count(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 72 + 32),
                crossAxisCount: displaySize.width < displaySize.height
                    ? 3
                    : displaySize.width ~/ (displaySize.height / 3),
                children: searchedRecipes
                    .map(
                      (e) => LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
                    data: e,
                    feedback: RecipeCard(recipeId: e.id, groupCollection: groupDoc),
                    childWhenDragging:
                    RecipeCard(recipeId: e.id, groupCollection: groupDoc),
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RecipeDetailPage(
                            groupId: widget.groupId,
                            recipeId: e.id,
                            aiEnabled: widget.aiEnabled,
                          ),
                        ),
                      ),
                      child: RecipeCard(recipeId: e.id, groupCollection: groupDoc),
                    ),
                  ),
                )
                    .toList(),
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
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: const Radius.circular(16),
                          bottom: keyboardVisible
                              ? Radius.zero
                              : const Radius.circular(16),
                        ),
                      ),
                    ),
                    controller: _searchController,
                    hintText: 'Search Recipes',
                    onChanged: (value) {
                      searchQuery = value;
                      generateSearchedRecipes();
                    },
                    trailing: [
                      if (widget.aiEnabled)
                        StatefulBuilder(
                          builder: (context, setAIState) => aiGenerating
                              ? const CupertinoActivityIndicator()
                              : IconButton(
                            icon: Icon(MdiIcons.creation),
                            onPressed: searchQuery.isNotEmpty
                                ? () async {
                              setAIState(() => aiGenerating = true);
                              try {
                                final result = await FirebaseFunctions
                                    .instanceFor(region: 'europe-west1')
                                    .httpsCallable('recipes-generateFromPrompt')
                                    .call(<String, dynamic>{
                                  'groupId': widget.groupId,
                                  'prompt': searchQuery,
                                });
                                setAIState(() => aiGenerating = false);
                                final recipeId =
                                result.data['recipeId'] as String?;
                                if (context.mounted &&
                                    recipeId != null &&
                                    recipeId.isNotEmpty) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => RecipeDetailPage(
                                        groupId: widget.groupId,
                                        recipeId: recipeId,
                                        editMode: false,
                                        aiEnabled: widget.aiEnabled,
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  String errorCode;
                                  try {
                                    errorCode =
                                        (e as dynamic).code?.toString() ??
                                            e.runtimeType.toString();
                                  } catch (_) {
                                    errorCode = e.runtimeType.toString();
                                  }
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'Error generating recipe: $errorCode'),
                                    ),
                                  );
                                }
                              } finally {
                                setAIState(() => aiGenerating = false);
                              }
                            }
                                : null,
                          ),
                        ),
                      IconButton(onPressed: addNewRecipe, icon: const Icon(Icons.add)),
                    ],
                  ),
                ),
              ),
              // ── Delete target ──────────────────────────────────────────
              DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                builder: (context, candidateData, _) => Visibility(
                  visible: candidateData.isNotEmpty &&
                      candidateData.first!.reference.parent.id == 'cooking_plan',
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: colorScheme.errorContainer.withAlpha(200),
                    ),
                    child: Center(
                      child: Icon(Icons.delete_outline,
                          size: 128, color: colorScheme.onErrorContainer),
                    ),
                  ),
                ),
                onWillAcceptWithDetails: (d) =>
                    ['cooking_plan', 'recipes'].contains(d.data.reference.parent.id),
                onAcceptWithDetails: (d) {
                  if (d.data.reference.parent.id == 'cooking_plan') {
                    _removePlan(d.data.reference);
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

// ─── RecipeCard ───────────────────────────────────────────────────────────────

class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.recipeId, required this.groupCollection});

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
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
        maxWidth: smallerdim / 3,
        minHeight: smallerdim / 4,
        minWidth: smallerdim / 3,
      ),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: (recipeId != null && groupCollection != null)
                  ? BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: containerColor.toColor(),
              )
                  : BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  width: 2,
                ),
              ),
              child: (recipeId != null && groupCollection != null)
                  ? LoadDocumentBuilder(
                docRef: groupCollection!.collection('recipes').doc(recipeId),
                builder: (recipeData) {
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
                              padding: const EdgeInsets.all(4),
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
                },
              )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shopping-list dialog ─────────────────────────────────────────────────────

class _IngRow {
  final String id;
  final String name;
  final Map<String, num?> base; // amounts at the recipe's base servings
  Map<String, num?> cur; // amounts scaled to the current servings selector
  bool added;

  _IngRow(this.id, this.name, this.base, this.added) : cur = Map.of(base);
}

class _ShoppingListDialog extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> group;
  final String recipeId;
  final DocumentReference<Map<String, dynamic>> planRef;
  final int recipeServings;

  const _ShoppingListDialog({
    required this.group,
    required this.recipeId,
    required this.planRef,
    required this.recipeServings,
  });

  @override
  State<_ShoppingListDialog> createState() => _ShoppingListDialogState();
}

class _ShoppingListDialogState extends State<_ShoppingListDialog> {
  bool loading = true;
  bool saving = false;
  late int servings = widget.recipeServings < 1 ? 1 : widget.recipeServings;
  final List<_IngRow> rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await UnitsCache.instance.ensureLoaded();

      final ingSnap = await widget.group
          .collection('recipes')
          .doc(widget.recipeId)
          .collection('ingredients')
          .get();

      // Determine per-ingredient add/skip preference from up to 5 past plans.
      final pastSnap = await widget.group
          .collection('cooking_plan')
          .where('recipe', isEqualTo: widget.recipeId)
          .get();
      final past = pastSnap.docs.where((d) => d.id != widget.planRef.id).toList()
        ..sort((a, b) =>
            (b['plannedFor'] as Timestamp).compareTo(a['plannedFor'] as Timestamp));
      final recent = past.take(5).toList();
      final recentAdded = <Set<String>>[];
      for (final p in recent) {
        final ai = await p.reference.collection('added_ingredients').get();
        recentAdded.add(ai.docs.map((d) => d['ingredientId'].toString()).toSet());
      }

      for (final ing in ingSnap.docs) {
        final id = ing['ingredientId'].toString();
        final base = <String, num?>{};
        (ing.data()['quantity'] as Map?)?.forEach(
              (k, v) => base[k.toString()] = v == null ? null : v as num,
        );

        final ingDoc =
        await FirebaseFirestore.instance.collection('ingredients').doc(id).get();
        final ingData = ingDoc.data();
        final category = (ingData?['category'] ?? '').toString();
        final nameMap = (ingData?['name'] as Map?) ?? {};
        final name = (nameMap['en'] ??
            (nameMap.values.isNotEmpty ? nameMap.values.first : id))
            .toString();

        final bool added;
        if (recent.isEmpty) {
          // First time: add everything except spices and herbs.
          added = category != 'spices_and_herbs';
        } else {
          // Majority of the last 5 plans; ties favour adding.
          final addCount = recentAdded.where((s) => s.contains(id)).length;
          added = addCount * 2 >= recent.length;
        }
        rows.add(_IngRow(id, name, base, added));
      }
      _rescale();
      if (mounted) setState(() => loading = false);
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
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
    for (final row in rows.where((r) => r.added)) {
      final q = <String, num>{};
      row.cur.forEach((k, v) {
        if (v != null && v > 0) q[k] = v;
      });
      if (q.isEmpty) continue;

      await widget.planRef.collection('added_ingredients').add({
        'ingredientId': row.id,
        'quantity': q,
        'addedAt': FieldValue.serverTimestamp(),
      });

      // Merge into an existing shopping-list entry for the same ingredient,
      // or create a new one.
      final existing = await widget.group
          .collection('shopping_list')
          .where('ingredientId', isEqualTo: row.id)
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) {
        final cur = Map<String, dynamic>.from(existing.docs.first['quantity'] ?? {});
        q.forEach((k, v) => cur[k] = ((cur[k] ?? 0) as num) + v);
        await existing.docs.first.reference.update({'quantity': cur});
      } else {
        await widget.group.collection('shopping_list').add({
          'ingredientId': row.id,
          'displayName': row.name,
          'description': '',
          'createdAt': FieldValue.serverTimestamp(),
          'quantity': q,
          'doneAt': null,
        });
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    final ordered = [...rows.where((r) => r.added), ...rows.where((r) => !r.added)];

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: loading
          ? const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      )
          : Column(
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
              shrinkWrap: true,
              children: ordered.map((row) {
                final toggleIcon = Icon(
                  row.added
                      ? Icons.remove_shopping_cart
                      : Icons.add_shopping_cart,
                );
                final subtitle = row.cur.entries
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
                      title: Text(row.name),
                      subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
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
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () => setState(() {
                              row.cur = row.cur.map(
                                    (k, v) => MapEntry(
                                  k,
                                  v == null
                                      ? null
                                      : v + UnitsCache.instance.increment(k),
                                ),
                              );
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