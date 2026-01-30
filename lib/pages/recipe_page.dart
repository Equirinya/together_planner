import 'package:couple_planner/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

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
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        //Calendar with drop targets for recipes
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: displaySize.height / 3, minHeight: displaySize.height / 4),
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
                            Color color = candidateData.isNotEmpty
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surfaceContainerLow;
                            return Container(
                              decoration: BoxDecoration(
                                color: color,
                                gradient: isToday
                                    ? LinearGradient(
                                        colors: [?Color.lerp(color, Theme.of(context).colorScheme.primary, 0.1), color],
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
              );
            },
          ),
        ),
        //recipes list (recents/favorites) or filtered by searchbar
        Expanded(
          child: Stack(
            children: [
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
              DragTarget<DocumentSnapshot<Map<String, dynamic>>>(
                builder: (context, candidateData, rejectedData) => Visibility(
                  visible: candidateData.isNotEmpty && candidateData.first!.reference.parent.id == 'cooking_plan',
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        borderRadius:  BorderRadius.circular(8),
                        color: Theme.of(context).colorScheme.errorContainer.withAlpha(200)),
                    child: Center(child: Icon(Icons.delete_outline, size: 128, color: Theme.of(context).colorScheme.onErrorContainer)),
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
        //searchbar
        TextButton(
          onPressed: () async {
            var newRecipeData = {
              'name': '',
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
            if (context.mounted) {
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
      constraints: BoxConstraints(maxWidth: smallerdim / 3, maxHeight: smallerdim / 3),
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
                              alignment: Alignment(-0.6, 0.8),
                              child: Text(
                                recipeData['name'] ?? 'Unnamed Recipe',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  // fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.surface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
