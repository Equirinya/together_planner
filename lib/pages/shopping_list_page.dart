import 'package:couple_planner/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:shared_preferences/shared_preferences.dart';

class ShoppingListPage extends StatefulWidget {
  final String groupId;

  const ShoppingListPage({super.key, required this.groupId});

  @override
  State<ShoppingListPage> createState() => _ShoppingListPageState();
}

class _ShoppingListPageState extends State<ShoppingListPage> {
  final db = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    //for every doc get the igrendients document by its id
    var stream = db
        .collection('groups')
        .doc(widget.groupId)
        .collection('shopping_list')
        .snapshots()
        .asyncMap(
          (s) async => Future.wait(
            s.docs.map(
              (d) async => {
                ...d.data(),
                'id': d.id,
                ...((await FirebaseFirestore.instance
                        .collection('ingredients')
                        .doc(d.id)
                        .get())
                    .data()??{}),
              },
            ),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: StreamBuilder(
            stream: stream,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              if (!snapshot.hasData) {
                if (kDebugMode)
                  print(
                    "No items found in shopping list for group ${widget.groupId}",
                  ); //TODO check if this fires
                // return const Center(child: Text('No items found.'));
              }
              var items = snapshot.data!;
              var done = items.where((item) => item['done'] == true).toList()..sort((a, b) => a['name'].compareTo(b['name']));
              var notDone = items.where((item) => item['done'] == false).toList()..sort((a, b) => a['name'].compareTo(b['name']));
              return
                ListView.builder(
                itemCount: notDone.length+1,
                itemBuilder: (context, index) {
                  if(index<notDone.length) {
                    var item = items[index];
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                        child: StorageImage(storagePath: "ingredients/${item['id']}.jpg", errorWidget: const Text("?"))
                      ),
                      title: Text(item['name']),
                      trailing: Checkbox(
                        value: item['done'],
                        onChanged: (value) {
                          db
                              .collection('groups')
                              .doc(widget.groupId)
                              .collection('shopping_list')
                              .doc(item['id'])
                              .update({'done': value});
                        },
                      ),
                    );
                  }
                  else{
                    return ExpansionTile(
                      title: Text("Done (${done.length})"),
                      children: done.map((item) => ListTile(
                        title: Text(item['name'], style: const TextStyle(decoration: TextDecoration.lineThrough)),
                        trailing: Checkbox(
                          value: item['done'],
                          onChanged: (value) {
                            db
                                .collection('groups')
                                .doc(widget.groupId)
                                .collection('shopping_list')
                                .doc(item['id'])
                                .update({'done': value});
                          },
                        ),
                      )).toList(),
                    );
                  }
                },
              );
            },
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Add Item',
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              onSubmitted: (value) async {
                if (value.trim().isEmpty) return;
                String? ingredientId;

                //call cloud function to get ingredientId (if it doesnt exist yet it is created)
                try {
                  final ingredientIdResult =
                  await FirebaseFunctions.instance.httpsCallable('addMessage').call();
                  ingredientId = ingredientIdResult.data as String;
                } on FirebaseFunctionsException catch (error) {
                  print(error.code);
                  print(error.details);
                  print(error.message);
                }

                if(ingredientId == null) return;

                //TODO check if already on List

                //add to shopping list
                await db
                    .collection('groups')
                    .doc(widget.groupId)
                    .collection('shopping_list')
                    .doc(ingredientId)
                    .set({
                  'done': false,
                  'description': '',
                  'createdAt': FieldValue.serverTimestamp(),
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}
