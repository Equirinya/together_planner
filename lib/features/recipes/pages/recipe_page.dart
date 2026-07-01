import 'dart:async';

import 'package:couple_planner/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import 'package:animations/animations.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/features/recipes/ingredient_search.dart' show UnitsCache, sanitizeLang, Avatar, kDefaultUnitId;
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/shopping_list/pages/shopping_list_page.dart' show categoryRank;

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
  final Set<String> _deletingPlanIds = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? recipesListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> recipes = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> searchedRecipes = [];

  // One stable GlobalKey per cooking-plan id, used to compute drop position.
  final Map<String, GlobalKey> _planCardKeys = {};
  GlobalKey _planKey(String planId) =>
      _planCardKeys.putIfAbsent(planId, () => GlobalKey());

  // Shopping-list rows preloaded when a recipe drag starts, keyed by recipe id,
  // so the add-to-shopping-list dialog can open instantly.
  final Map<String, Future<List<_IngPreload>>> _ingredientPreload = {};
  Future<List<_IngPreload>> _preloadIngredients(String recipeId) =>
      _ingredientPreload.putIfAbsent(
        recipeId,
            () => _ShoppingListDialogState.loadRows(groupDoc, recipeId),
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
      if (!visible) FocusManager.instance.primaryFocus?.unfocus();
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

  // The already-loaded recipe document data for [recipeId], if it's among the
  // streamed recipes, so the detail page can paint its image/title immediately
  // during the open transition instead of flashing a loading state.
  Map<String, dynamic>? _recipeDataFor(String recipeId) {
    for (final r in recipes) {
      if (r.id == recipeId) return r.data();
    }
    return null;
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
      // Create the document reference synchronously and write without awaiting,
      // so the dialog can open immediately instead of waiting for the write.
      final planRef = groupDoc.collection('cooking_plan').doc();
      planRef.set({
        'recipe': data.id,
        'plannedFor': ts,
        'servings': servings,
      });
      data.reference.update({'lastUsedAt': FieldValue.serverTimestamp()});
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
            builder: (_) => _ShoppingListDialog(
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
                return DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                  onWillAcceptWithDetails: (d) =>
                      ['cooking_plan', 'recipes'].contains(d.data.reference.parent.id),
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
                                          feedback: RecipeCard(
                                            recipeId: dayPlans[i]['recipe'],
                                            groupCollection: groupDoc,
                                            crossAxisCount: planCrossAxisCount,
                                          ),
                                          childWhenDragging: const SizedBox.shrink(),
                                          child: _RecipeOpenContainer(
                                            recipeId: dayPlans[i]['recipe'],
                                            groupId: groupDoc.id,
                                            groupDoc: groupDoc,
                                            aiEnabled: widget.aiEnabled,
                                            initialData:
                                            _recipeDataFor(dayPlans[i]['recipe']),
                                            child: RecipeCard(
                                              recipeId: dayPlans[i]['recipe'],
                                              groupCollection: groupDoc,
                                              cropContent: true,
                                              crossAxisCount: planCrossAxisCount,
                                            ),
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
              GridView.count(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 72 + 32),
                crossAxisCount: crossAxisCount,
                children: searchedRecipes
                    .map(
                      (e) => LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
                    key: ValueKey(e.id),
                    data: e,
                    onDragStarted: () => _preloadIngredients(e.id),
                    feedback: RecipeCard(recipeId: e.id, groupCollection: groupDoc, crossAxisCount: crossAxisCount),
                    childWhenDragging:
                    RecipeCard(recipeId: e.id, groupCollection: groupDoc, crossAxisCount: crossAxisCount),
                    child: _RecipeOpenContainer(
                      recipeId: e.id,
                      groupId: widget.groupId,
                      groupDoc: groupDoc,
                      aiEnabled: widget.aiEnabled,
                      initialData: e.data(),
                      child: RecipeCard(recipeId: e.id, groupCollection: groupDoc, crossAxisCount: crossAxisCount),
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
                      keyboardVisible
                          ? const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      )
                          : const StadiumBorder(),
                    ),
                    controller: _searchController,
                    hintText: 'Search recipes',
                    leading: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.search,
                          color: colorScheme.onSurfaceVariant),
                    ),
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
                      borderRadius: BorderRadius.circular(16),
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

// ─── RecipeOpenContainer ──────────────────────────────────────────────────────

/// Wraps a recipe card so tapping it expands the card into the full
/// [RecipeDetailPage] with a Material container transform.
class _RecipeOpenContainer extends StatelessWidget {
  const _RecipeOpenContainer({
    required this.recipeId,
    required this.groupId,
    required this.groupDoc,
    required this.aiEnabled,
    required this.initialData,
    required this.child,
  });

  final String recipeId;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final bool aiEnabled;
  final Map<String, dynamic>? initialData;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return OpenContainer(
      tappable: false,
      transitionType: ContainerTransitionType.fade,
      transitionDuration: const Duration(milliseconds: 300),
      closedElevation: 0,
      closedColor: Colors.transparent,
      openColor: Theme.of(context).scaffoldBackgroundColor,
      closedShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      closedBuilder: (_, open) => GestureDetector(onTap: open, child: child),
      openBuilder: (_, __) => RecipeDetailPage(
        groupId: groupId,
        recipeId: recipeId,
        aiEnabled: aiEnabled,
        initialData: initialData,
      ),
    );
  }
}

// ─── RecipeCard ───────────────────────────────────────────────────────────────

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.recipeId,
    required this.groupCollection,
    this.cropContent = false,
    this.crossAxisCount = 3,
  });

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;

  /// When true, the inner content is laid out at the card's full size and
  /// cropped by the rounded frame instead of shrinking with the available
  /// width (used inside the calendar carousel).
  final bool cropContent;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    // Full inner size of the card at its unconstrained width, used to keep the
    // content at a fixed size and crop it when [cropContent] is set.
    final fullContentWidth = smallerdim / crossAxisCount - 8;
    final fullContentHeight = smallerdim / crossAxisCount * 3 / 4 - 8;
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
        maxWidth: smallerdim / crossAxisCount,
        minHeight: smallerdim / crossAxisCount * 3 / 4,
        minWidth: smallerdim / crossAxisCount,
      ),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: (recipeId != null && groupCollection != null)
                  ? BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: containerColor.toColor(),
              )
                  : BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  width: 2,
                ),
              ),
              child: !cropContent
                  ? _content(context, color)
                  : OverflowBox(
                minWidth: fullContentWidth,
                maxWidth: fullContentWidth,
                minHeight: fullContentHeight,
                maxHeight: fullContentHeight,
                alignment: Alignment.center,
                child: _content(context, color),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _content(BuildContext context, HSVColor color) {
    final size = MediaQuery.of(context).size;
    final smallerdim = size.width < size.height ? size.width : size.height;
    return (recipeId != null && groupCollection != null)
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
                    padding: const EdgeInsets.symmetric(vertical:4, horizontal: 6),
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
        : null;
  }
}

// ─── Shopping-list dialog ─────────────────────────────────────────────────────

/// Immutable snapshot of a recipe ingredient used to (pre)load the shopping
/// list dialog: id, localised name, base quantities, default add flag and
/// category. Kept separate from [_IngRow] so cached preloads stay pristine
/// across repeated drags while each dialog gets its own mutable rows.
class _IngPreload {
  final String id;
  final String name;
  final String description;
  final Map<String, num?> base;
  final bool added;
  final String category;
  final String unit; // default unit to seed a quantity from when there is none
  const _IngPreload(this.id, this.name, this.description, this.base, this.added,
      this.category, this.unit);
}

class _IngRow {
  final String id;
  final String name;
  final String description;
  final Map<String, num?> base; // amounts at the recipe's base servings
  Map<String, num?> cur; // amounts scaled to the current servings selector
  bool added;
  final String category;
  final String unit; // default unit to seed a quantity from when there is none

  _IngRow(this.id, this.name, this.description, this.base, this.added,
      this.category, this.unit)
      : cur = Map.of(base);
}

class _ShoppingListDialog extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> group;
  final String recipeId;
  final DocumentReference<Map<String, dynamic>> planRef;
  final int recipeServings;
  final List<_IngPreload> preloadedRows;

  const _ShoppingListDialog({
    required this.group,
    required this.recipeId,
    required this.planRef,
    required this.recipeServings,
    required this.preloadedRows,
  });

  @override
  State<_ShoppingListDialog> createState() => _ShoppingListDialogState();
}

class _ShoppingListDialogState extends State<_ShoppingListDialog> {
  bool saving = false;
  late int servings = widget.recipeServings < 1 ? 1 : widget.recipeServings;
  final List<_IngRow> rows = [];

  @override
  void initState() {
    super.initState();
    for (final p in widget.preloadedRows) {
      rows.add(_IngRow(
          p.id, p.name, p.description, p.base, p.added, p.category, p.unit));
    }
    _rescale();
  }

  /// Loads the shopping-list rows for [recipeId]: each recipe ingredient with
  /// its base quantity, localised name, category and a default add/skip flag.
  /// Extracted so it can be kicked off as soon as a recipe drag starts and
  /// reused when the dialog opens. Returns an empty list when there are none.
  static Future<List<_IngPreload>> loadRows(
      DocumentReference<Map<String, dynamic>> group,
      String recipeId,
      ) async {
    // Kick off the independent reads concurrently: the units cache, the
    // recipe's ingredients, and the recipe's past cooking plans.
    final unitsFuture = UnitsCache.instance.ensureLoaded();
    final ingFuture = group
        .collection('recipes')
        .doc(recipeId)
        .collection('ingredients')
        .get();
    final pastFuture = group
        .collection('cooking_plan')
        .where('recipe', isEqualTo: recipeId)
        .get();

    final ingSnap = await ingFuture;
    if (ingSnap.docs.isEmpty) return const <_IngPreload>[];

    // Determine per-ingredient add/skip preference from up to 5 past plans.
    // Only plans that actually went through the ingredient-adding flow carry a
    // signal: those have an itemIds field (an empty array when nothing was
    // added). Plans from older app versions — and plans where the add dialog
    // was skipped — have no itemIds field at all and are excluded, so they
    // don't dilute the majority calculation.
    final pastSnap = await pastFuture;
    final past = pastSnap.docs
        .where((d) => d.data().containsKey('itemIds'))
        .toList()
      ..sort((a, b) =>
          (b['plannedFor'] as Timestamp).compareTo(a['plannedFor'] as Timestamp));
    final recent = past.take(5).toList();

    // Past plans record the shopping-list item ids they contributed to
    // (itemIds), so resolve each item back to its ingredientId. Items removed
    // since are simply skipped.
    final allItemIds = <String>{
      for (final p in recent)
        ...List<String>.from(p.data()['itemIds'] ?? const []),
    };
    final itemToIng = <String, String>{};
    await Future.wait(allItemIds.map((itemId) async {
      final snap = await group.collection('shopping_list').doc(itemId).get();
      final ingId = snap.data()?['ingredientId'];
      if (ingId != null) itemToIng[itemId] = ingId.toString();
    }));
    final recentAdded = <Set<String>>[
      for (final p in recent)
        {
          for (final itemId in List<String>.from(p.data()['itemIds'] ?? const []))
            if (itemToIng.containsKey(itemId)) itemToIng[itemId]!,
        },
    ];

    // Fetch every ingredient's master document in parallel rather than one at a
    // time. Future.wait preserves order, so the rows stay in recipe order.
    final preload = await Future.wait(ingSnap.docs.map((ing) async {
      final id = ing['ingredientId'].toString();
      final description = (ing.data()['description'] ?? '').toString();

      final ingDoc =
      await FirebaseFirestore.instance.collection('ingredients').doc(id).get();
      final ingData = ingDoc.data();
      final category = (ingData?['category'] ?? '').toString();
      final rawUnit = (ingData?['defaultUnit'] ?? '').toString();
      final unit = rawUnit.isEmpty ? kDefaultUnitId : rawUnit;
      final name = (ing.data()['displayName'] ?? ingData?['name']?['en'] ?? id).toString();

      // A quantity map with a real amount is used as-is (a null amount for a
      // present unit is treated as 1). A missing, empty, or zero quantity is
      // kept as no quantity — the ingredient is still added to the shopping
      // list, just without an amount.
      final base = <String, num?>{};
      final rawQuantity = ing.data()['quantity'] as Map?;
      if (rawQuantity != null && rawQuantity.isNotEmpty) {
        rawQuantity.forEach(
              (k, v) => base[k.toString()] = v == null ? 1 : v as num,
        );
      }

      final bool added;
      if (recent.isEmpty) {
        // First time: add everything except spices/herbs and condiments/sauces.
        added = category != 'spices_and_herbs' &&
            category != 'condiments_and_sauces';
      } else {
        // Majority of the last 5 plans; ties favour adding.
        final addCount = recentAdded.where((s) => s.contains(id)).length;
        added = addCount * 2 >= recent.length;
      }
      return _IngPreload(id, name, description, base, added, category, unit);
    }).toList());

    await unitsFuture;
    return preload;
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
    // Record which shopping-list items this plan contributed to, and how much,
    // as parallel arrays on the plan document (replaces the old
    // added_ingredients subcollection). The arrays are always written here —
    // empty when nothing was added — so the plan is marked as having gone
    // through the add flow. Skipped plans (and plans from older app versions)
    // keep these fields absent instead, and are ignored by the heuristic.
    // Collect the kept rows (with their positive amounts, if any), then look up
    // their existing shopping-list entries in parallel (reads can't go in a
    // batch). A kept row with no positive amount is added without a quantity.
    final pending = <(_IngRow, Map<String, num>)>[];
    for (final row in rows.where((r) => r.added)) {
      final q = <String, num>{};
      row.cur.forEach((k, v) {
        if (v != null && v > 0) q[k] = v;
      });
      pending.add((row, q));
    }
    final existing = await Future.wait([
      for (final p in pending)
        widget.group
            .collection('shopping_list')
            .where('ingredientId', isEqualTo: p.$1.id)
            .get(),
    ]);

    // Apply every shopping-list write and the plan update as one atomic batch.
    final batch = FirebaseFirestore.instance.batch();
    final itemIds = <String>[];
    final quantities = <Map<String, num>>[];
    for (int i = 0; i < pending.length; i++) {
      final row = pending[i].$1;
      final q = pending[i].$2;
      // Ignore completed entries: merge only into an active one, otherwise
      // create a fresh item so the ingredient reappears on the list.
      final active =
      existing[i].docs.where((d) => d.data()['doneAt'] == null).toList();
      final DocumentReference<Map<String, dynamic>> itemRef;
      if (active.isNotEmpty) {
        itemRef = active.first.reference;
        final cur = Map<String, dynamic>.from(active.first['quantity'] ?? {});
        q.forEach((k, v) => cur[k] = ((cur[k] ?? 0) as num) + v);
        batch.update(itemRef, {'quantity': cur.isEmpty ? null : cur});
      } else {
        itemRef = widget.group.collection('shopping_list').doc();
        batch.set(itemRef, {
          'ingredientId': row.id,
          'displayName': row.name,
          'description': '',
          'createdAt': FieldValue.serverTimestamp(),
          'quantity': q.isEmpty ? null : q,
          'doneAt': null,
          'category': row.category,
        });
      }
      itemIds.add(itemRef.id);
      quantities.add(q);
    }
    batch.update(widget.planRef, {'itemIds': itemIds, 'quantities': quantities});
    await batch.commit();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lang = sanitizeLang(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode);
    int cmp(_IngRow a, _IngRow b) {
      final c = categoryRank(a.category).compareTo(categoryRank(b.category));
      return c != 0 ? c : rows.indexOf(a).compareTo(rows.indexOf(b));
    }
    // Added first, then skipped; each group ordered by category.
    final ordered = [
      ...rows.where((r) => r.added).toList()..sort(cmp),
      ...rows.where((r) => !r.added).toList()..sort(cmp),
    ];
    final orderKey = ValueKey(ordered.map((r) => r.id).join('|'));

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
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
              key: orderKey,
              shrinkWrap: true,
              children: ordered.map((row) {
                final toggleIcon = Icon(
                  row.added
                      ? Icons.remove_shopping_cart
                      : Icons.add_shopping_cart,
                );
                final quantityText = row.cur.entries
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
                      contentPadding: const EdgeInsets.only(left: 16, right: 4),
                      minVerticalPadding: 8,
                      minTileHeight: 64,
                      leading: Avatar(ingredientId: row.id),
                      title: Text(row.name),
                      subtitle: row.description.isNotEmpty
                          ? Text(row.description)
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (quantityText.isNotEmpty)
                            IconButton(
                              iconSize: 18,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
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
                          quantityText.isNotEmpty
                              ? Text(quantityText, style: Theme.of(context).textTheme.bodyLarge)
                              : Text('—', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: colorScheme.outline)),
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 40),
                            icon: const Icon(Icons.add),
                            onPressed: () => setState(() {
                              // Seed a quantity for a no-amount row from the
                              // ingredient's default unit, so + works on items
                              // that were added without a quantity.
                              if (!row.cur.values.any((v) => v != null && v > 0)) {
                                row.cur = {
                                  row.unit: UnitsCache.instance.increment(row.unit)
                                };
                              } else {
                                row.cur = row.cur.map(
                                      (k, v) => MapEntry(
                                    k,
                                    v == null
                                        ? null
                                        : v + UnitsCache.instance.increment(k),
                                  ),
                                );
                              }
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