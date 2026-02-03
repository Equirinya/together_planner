import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:couple_planner/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'recipe_detail.dart';

class RecipePage extends StatefulWidget {
  final String groupId;

  const RecipePage({super.key, required this.groupId});

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  late DocumentReference<Map<String, dynamic>> groupCollection;
  final int daysToShowPrior = 15; //show plans from the last 15 days
  final int daysToShowFuture = 30; //show plans up to 30 days in the future

  final SearchController _searchController = SearchController();
  String searchQuery = '';
  bool aiGenerating = false;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? planListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> cookingPlans = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? recipesListener;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> recipes = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> searchedRecipes = [];

  @override
  void initState() {
    groupCollection = FirebaseFirestore.instance.collection('groups').doc(widget.groupId);
    final cookingPlanStream = groupCollection
        .collection('cooking_plan')
        .where('plannedFor', isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(Duration(days: daysToShowPrior))))
        .orderBy('plannedFor')
        .snapshots();
    planListener = cookingPlanStream.listen((snapshot) {
      setState(() {
        cookingPlans = snapshot.docs;
      });
    });
    final recipesStream = groupCollection.collection('recipes').orderBy('lastUsedAt', descending: true).limit(50).snapshots();
    recipesListener = recipesStream.listen((snapshot) {
      setState(() {
        recipes = snapshot.docs;
        generateSearchedRecipes();
      });
    });

    super.initState();
  }

  @override
  void dispose() {
    planListener?.cancel();
    recipesListener?.cancel();
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
        final tags = (data['tags'] ?? []).map<String>((e) => e.toString().toLowerCase()).toList();

        final nameTokens = name.split(splitRe).where((s) => s.isNotEmpty).toList();
        final descTokens = description.split(splitRe).where((s) => s.isNotEmpty).toList();
        final tokens = [...nameTokens, ...descTokens, ...tags];

        double score = 0;
        for (final q in queryWords) {
          var matchedThisWord = false;
          for (final t in tokens) {
            if (t == q) {
              score += 5;
              matchedThisWord = true;
              break;
            } else if (t.startsWith(q)) {
              score += 3;
              matchedThisWord = true;
              break;
            } else if (t.contains(q)) {
              final overlapRatio = q.length / t.length;
              score += overlapRatio;
              matchedThisWord = true;
              break;
            }
          }
        }

        if (score > 0) {
          scored.add({'doc': doc, 'score': score, 'last': (data['lastUsedAt'] as Timestamp?)?.toDate()});
        }
      }

      scored.sort((a, b) {
        final sc = (b['score'] as double).compareTo(a['score'] as double);
        if (sc != 0) return sc;
        final ta = a['last'];
        final tb = b['last'];
        final ma = ta?.millisecondsSinceEpoch ?? -1;
        final mb = tb?.millisecondsSinceEpoch ?? -1;
        return mb.compareTo(ma);
      });

      searchedRecipes = scored.map((e) => e['doc'] as QueryDocumentSnapshot<Map<String, dynamic>>).toList();
    }
    setState(() {});
  }

  void addNewRecipe() async {
    var newRecipeData = {
      'name': searchQuery,
      'description': '',
      'creator': FirebaseAuth.instance.currentUser!.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': null,
      'ingredients': <int>[],
      'ingredientsQuantity': <String, double>{},
      'preparationTime': 0,
      'time': 0,
      'tags': <String>[],
      'images': <String>[],
      'steps': <String>[],
    };
    var newRecipeRef = await groupCollection.collection('recipes').add(newRecipeData);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RecipeDetailPage(groupId: widget.groupId, recipeId: newRecipeRef.id, editMode: true),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final displaySize = MediaQuery.of(context).size;
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        //Calendar with drop targets for recipes
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: displaySize.height / 3, minHeight: displaySize.height / 4),
          child: CarouselView.weighted(
            flexWeights: const <int>[1, 3, 3, 1],
            enableSplash: false,
            controller: CarouselController(initialItem: daysToShowPrior),
            children:
                List.generate(
                  daysToShowPrior + daysToShowFuture,
                  (index) => DateTime.now().subtract(Duration(days: daysToShowPrior)).add(Duration(days: index)),
                ).map((day) {
                  {
                    final dayPlans = cookingPlans.where((plan) {
                      final plannedFor = (plan['plannedFor'] as Timestamp).toDate();
                      return plannedFor.year == day.year && plannedFor.month == day.month && plannedFor.day == day.day;
                    }).toList();
                    bool isToday = DateTime.now().difference(day).inHours < 1 && DateTime.now().difference(day).inHours > -1;
                    String dateString = getRelativeDateString(day);

                    return DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                      builder: (context, candidateData, rejectedData) {
                        Color color = candidateData.isNotEmpty ? colorScheme.primaryContainer : colorScheme.surfaceContainerLow;
                        return Container(
                          decoration: BoxDecoration(
                            color: color,
                            gradient: isToday
                                ? LinearGradient(
                                    colors: [?Color.lerp(color, colorScheme.primary, 0.1), color],
                                    begin: Alignment.centerLeft,
                                    end: Alignment(-0.7, 0),
                                  )
                                : null,
                          ),
                          child: Column(
                            children: [
                              Text(dateString, style: Theme.of(context).textTheme.titleMedium, maxLines: 1),
                              Expanded(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Column(
                                    children: dayPlans
                                        .map(
                                          (plan) => LongPressDraggable(
                                            data: plan,
                                            feedback: RecipeCard(recipeId: plan['recipe'], groupCollection: groupCollection),
                                            childWhenDragging: RecipeCard(recipeId: null, groupCollection: null),
                                            child: RecipeCard(recipeId: plan['recipe'], groupCollection: groupCollection),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                      onWillAcceptWithDetails: (details) => ['cooking_plan', 'recipes'].contains(details.data.reference.parent.id),
                      onAcceptWithDetails: (details) {
                        if (details.data.reference.parent.id == 'recipes') {
                          //adding a new cooking plan
                          groupCollection.collection('cooking_plan').add({
                            'recipe': details.data.id,
                            'plannedFor': Timestamp.fromDate(DateTime(day.year, day.month, day.day)),
                            'servings': 2,
                          });
                          //TODO save default (or most recent) servings in recipe and show status bar to update servings
                          //TODO add ingredients to shopping list
                          details.data.reference.update({'lastUsedAt': FieldValue.serverTimestamp()});
                        } else if (details.data.reference.parent.id == 'cooking_plan') {
                          //moving an existing cooking plan
                          details.data.reference.update({'plannedFor': Timestamp.fromDate(DateTime(day.year, day.month, day.day))});
                        }
                      },
                    );
                  }
                }).toList(),
          ),
        ),
        //recipes list (recents/favorites) or filtered by searchbar
        Expanded(
          child: Stack(
            children: [
              GridView.count(
                padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 72 + 32),
                crossAxisCount: displaySize.width < displaySize.height ? 3 : displaySize.width ~/ (displaySize.height / 3),
                children: searchedRecipes
                    .map(
                      (e) => LongPressDraggable<DocumentSnapshot<Map<String, dynamic>>>(
                        data: e,
                        feedback: RecipeCard(recipeId: e.id, groupCollection: groupCollection),
                        childWhenDragging: RecipeCard(recipeId: e.id, groupCollection: groupCollection),
                        child: GestureDetector(
                          child: RecipeCard(recipeId: e.id, groupCollection: groupCollection),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => RecipeDetailPage(groupId: widget.groupId, recipeId: e.id),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SearchBar(
                  controller: _searchController,
                  padding: WidgetStateProperty.resolveWith<EdgeInsetsGeometry?>((Set<WidgetState> states) {
                    if (states.contains(WidgetState.focused)) {
                      return const EdgeInsets.all(8.0);
                    }
                    return EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 16, left: 8, right: 8, top: 8);
                  }),
                  shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16)))),
                  hintText: "Search Recipes",
                  onChanged: (value) {
                    searchQuery = value;
                    generateSearchedRecipes();
                  },
                  trailing: [
                    StatefulBuilder(
                      builder: (context, setAIState) => aiGenerating
                          ? CupertinoActivityIndicator()
                          : IconButton(
                              icon: Icon(MdiIcons.creation),
                              onPressed: searchQuery.isNotEmpty ? () async {
                                setAIState(() => aiGenerating = true);
                                try {
                                  var result = await FirebaseFunctions.instance.httpsCallable('generateRecipe').call(<String, dynamic>{
                                    'groupId': widget.groupId,
                                    'prompt': searchQuery,
                                  });
                                  setAIState(() => aiGenerating = false);
                                  String? recipeId = result.data['recipeId'];
                                  if (context.mounted && recipeId != null && recipeId.isNotEmpty) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => RecipeDetailPage(groupId: widget.groupId, recipeId: recipeId, editMode: false),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error generating recipe: $e')));
                                  }
                                } finally {
                                  setAIState(() => aiGenerating = false);
                                }
                              } : null,
                            ),
                    ),
                    IconButton(onPressed: addNewRecipe, icon: const Icon(Icons.add)),
                  ],
                ),
              ),
              DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                builder: (context, candidateData, rejectedData) => Visibility(
                  visible: candidateData.isNotEmpty && candidateData.first!.reference.parent.id == 'cooking_plan',
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: colorScheme.errorContainer.withAlpha(200)),
                    child: Center(child: Icon(Icons.delete_outline, size: 128, color: colorScheme.onErrorContainer)),
                  ),
                ),
                onWillAcceptWithDetails: (details) => ['cooking_plan', 'recipes'].contains(details.data.reference.parent.id),
                onAcceptWithDetails: (details) {
                  if (details.data.reference.parent.id == 'cooking_plan') {
                    details.data.reference.delete();
                    //TODO remove ingredients from shopping list if not needed anymore
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

class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.recipeId, required this.groupCollection});

  final String? recipeId;
  final DocumentReference<Map<String, dynamic>>? groupCollection;

  @override
  Widget build(BuildContext context) {
    var size = MediaQuery.of(context).size;
    var smallerdim = size.width < size.height ? size.width : size.height;
    var primaryColor = HSVColor.fromColor(Theme.of(context).colorScheme.primary);
    var primaryContainerColor = HSVColor.fromColor(Theme.of(context).colorScheme.primaryContainer);
    var color = HSVColor.fromAHSV(1, (recipeId.hashCode % 360), primaryColor.saturation, primaryColor.value);
    var containerColor = color.withValue((primaryContainerColor.value + primaryColor.value) / 2);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: smallerdim / 3, minHeight: smallerdim / 4, minWidth: smallerdim / 3),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: (recipeId != null && groupCollection != null)
                  ? BoxDecoration(borderRadius: BorderRadius.circular(8), color: containerColor.toColor())
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Theme.of(context).colorScheme.onSurfaceVariant, width: 2),
                    ),
              child: (recipeId != null && groupCollection != null)
                  ? LoadDocumentBuilder(
                      docRef: groupCollection!.collection("recipes").doc(recipeId),
                      builder: (recipeData) {
                        List<String> images = List<String>.from(recipeData['images'] ?? []);
                        return Stack(
                          children: [
                            if (images.isNotEmpty) ...[
                              SizedBox.expand(
                                child: StorageImage(storagePath: images.first, fit: BoxFit.cover),
                              ),
                              Container(color: Colors.black26),
                            ] else
                              Align(
                                alignment: Alignment(0, -0.3),
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final double smallerdim = constraints.maxWidth < constraints.maxHeight
                                        ? constraints.maxWidth
                                        : constraints.maxHeight;
                                    return Icon(Icons.restaurant_menu, size: smallerdim / 2, color: color.toColor());
                                  },
                                ),
                              ),
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Text(
                                  recipeData['name'] ?? 'Unnamed Recipe',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white, height: 1.2),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            //more recipe details
                          ],
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
