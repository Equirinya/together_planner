import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:shared_preferences/shared_preferences.dart';

class RecipePage extends StatelessWidget {
  final String groupId;
  const RecipePage({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final groupCollection = db.collection('groups').doc(groupId);
    int daysToShowPrior = 15; //show plans from the last 15 days
    int daysToShowFuture = 30; //show plans up to 30 days in the future
    final cookingPlanStream = groupCollection.collection('cooking_plan').where('planned_for', isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(Duration(days: daysToShowPrior)))).orderBy('planned_for').snapshots();
    final displaySize = MediaQuery.of(context).size;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        StreamBuilder(stream: cookingPlanStream, builder: (context, snapshot) {
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
          return ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: daysToShowPrior+daysToShowFuture,
            itemBuilder: (context, index) {
              final day = DateTime.now().subtract(Duration(days: daysToShowPrior)).add(Duration(days: index));
              final dayPlans = cookingPlans.where((plan) {
                final plannedFor = (plan['planned_for'] as Timestamp).toDate();
                return plannedFor.year == day.year && plannedFor.month == day.month && plannedFor.day == day.day;
              }).toList();
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: SizedBox(
                  width: displaySize.width / 5,
                  child: Drag(
                    child: Card(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text("${day.day}/${day.month}", style: Theme.of(context).textTheme.titleMedium),
                          ...dayPlans.map((plan) => ListTile(
                            //TODO
                            title: Text(plan['recipe_name'] ?? 'Unnamed Recipe', style: Theme.of(context).textTheme.bodyMedium),
                            subtitle: Text("Servings: ${plan['servings'] ?? 'N/A'}", style: Theme.of(context).textTheme.bodySmall),
                          )),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },),
        //Calendar with drop targets for recipes
        //recipes list (recents/favorites) or filtered by searchbar
        //searchbar
      ],
    );
  }
}
