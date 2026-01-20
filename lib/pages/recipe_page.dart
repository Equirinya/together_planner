import 'package:couple_planner/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'recipe_detail.dart';

class RecipePage extends StatelessWidget {
  final String groupId;

  const RecipePage({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final groupCollection = db.collection('groups').doc(groupId);
    int daysToShowPrior = 15; //show plans from the last 15 days
    int daysToShowFuture = 30; //show plans up to 30 days in the future
    final cookingPlanStream = groupCollection
        .collection('cooking_plan')
        .where('plannedFor', isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(Duration(days: daysToShowPrior))))
        .orderBy('plannedFor')
        .snapshots();
    final displaySize = MediaQuery.of(context).size;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        //Calendar with drop targets for recipes
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: displaySize.height / 3, minHeight: displaySize.height / 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: StreamBuilder(
              stream: cookingPlanStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CupertinoActivityIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: Text('No planned recipes.'));
                }
                final cookingPlans = snapshot.data!.docs;
                return CarouselView.weighted(
                  flexWeights: const <int>[3, 3, 3, 1],
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
                          bool isToday = DateTime.now().difference(day).inHours < 1;
                          return Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              children: [
                                if (isToday) VerticalDivider(),
                                Expanded(
                                  child: DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                                    builder: (context, candidateData, rejectedData) => Card(
                                      color: candidateData.isNotEmpty ? Theme.of(context).colorScheme.primaryContainer : null,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text("${day.day}/${day.month}", style: Theme.of(context).textTheme.titleMedium),
                                          ...dayPlans.map(
                                            (plan) => LongPressDraggable(
                                              data: plan,
                                              feedback: RecipeCard(recipeId: null, groupCollection: null),
                                              childWhenDragging: RecipeCard(recipeId: plan['recipe'], groupCollection: groupCollection),
                                              child: RecipeCard(recipeId: plan['recipe'], groupCollection: groupCollection),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
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
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                      }).toList(),
                );
              },
            ),
          ),
        ),
        //recipes list (recents/favorites) or filtered by searchbar
        Expanded(
          child: Stack(
            children: [
              DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                builder: (context, candidateData, rejectedData) => Card(
                  color: candidateData.isNotEmpty ? Theme.of(context).colorScheme.primaryContainer : null,
                  child: Center(child: Icon(Icons.cancel_outlined)),
                ),
                onWillAcceptWithDetails: (details) => ['cooking_plan', 'recipes'].contains(details.data.reference.parent.id),
                onAcceptWithDetails: (details) {
                  if (details.data.reference.parent.id == 'cooking_plan') {
                    details.data.reference.delete();
                    //TODO remove ingredients from shopping list if not needed anymore
                  }
                },
              ),
              LoadCollectionBuilder(
                collRef: groupCollection.collection('recipes').orderBy('lastUsedAt', descending: true).limit(50),
                builder: (recipeDocs) => GridView.count(
                  crossAxisCount: displaySize.width < displaySize.height ? 3 : displaySize.width ~/ (displaySize.height / 3),
                  children: recipeDocs
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
                                builder: (context) => RecipeDetailPage(groupId: groupId, recipeId: e.id),
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),

              TextButton(
                onPressed: () async {
                  var newRecipeRef = await groupCollection.collection('recipes').add({
                    'name': 'New Recipe',
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
                  });
                  if(context.mounted) {
                    Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => RecipeDetailPage(groupId: groupId, recipeId: newRecipeRef.id),
                    ),
                  );
                  }
                },
                child: const Text("Add Recipe"),
              ),
            ],
          ),
        ),
        //searchbar
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
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Card(
        child: (recipeId != null && groupCollection != null)
            ? LoadDocumentBuilder(
                docRef: groupCollection!.collection("recipes").doc(recipeId),
                builder: (recipeData) {
                  List<String> images = List<String>.from(recipeData['images'] ?? []);
                  return Stack(
                    children: [
                      if (images.isNotEmpty)
                        StorageImage(storagePath: images.first)
                      else
                        Container(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          child: Icon(Icons.restaurant_menu, size: smallerdim / 6, color: Theme.of(context).colorScheme.onPrimaryContainer),
                        ),
                      Text(
                        recipeData['name'] ?? 'Unnamed Recipe',
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      //more recipe details
                    ],
                  );
                },
              )
            : null,
      ),
    );
  }
}
