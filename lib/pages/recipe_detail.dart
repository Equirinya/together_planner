import 'dart:io';

import 'package:couple_planner/utils.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';

import 'package:shared_preferences/shared_preferences.dart';

class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({super.key, required this.groupId, required this.recipeId});

  final String groupId;
  final String recipeId;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  bool edit = false;

  TextEditingController? nameController;
  TextEditingController? descriptionController;
  List<TextEditingController>? stepsControllers;
  TextEditingController? tagsController;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final groupCollection = db.collection('groups').doc(widget.groupId);
    final docRef = groupCollection.collection('recipes').doc(widget.recipeId);

    return Material(
      child: LoadDocumentBuilder(
        docRef: docRef,
        builder: (data) {
          List<String> images = List<String>.from(data['images'] ?? []);
          List<String> steps = List<String>.from(data['steps'] ?? []);
          if (steps.isEmpty) steps = [''];
          List<String> tags = List<String>.from(data['tags'] ?? []);
          int totalHour = ((data['time'] ?? 0) / 60).floor();
          int totalMinute = (data['time'] ?? 0) % 60;
          int prepHour = ((data['preparationTime'] ?? 0) / 60).floor();
          int prepMinute = (data['preparationTime'] ?? 0) % 60;

          if (edit) {
            nameController ??= TextEditingController(text: data['name']);
            descriptionController ??= TextEditingController(text: data['description']);
            stepsControllers ??= steps.map((step) => TextEditingController(text: step)).toList();
            tagsController ??= TextEditingController(text: (tags.map((e) => "#$e ")).join(''));
          }

          return Scaffold(
            appBar: AppBar(
              title: Text(data['name'] ?? 'Unnamed Recipe'),
              actions: [
                IconButton(
                  icon: Icon(edit ? Icons.check : Icons.edit),
                  onPressed: () {
                    if (edit) {
                      docRef.update({
                        'name': nameController!.text,
                        'description': descriptionController!.text,
                        'steps': stepsControllers!.map((c) => c.text.trim()).where((element) => element.isNotEmpty).toList(),
                        'tags': tagsController!.text.split('#').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toList(),
                      });
                    }

                    setState(() {
                      edit = !edit;
                    });
                  },
                ),
              ],
            ),
            body: SingleChildScrollView(
              child: Column(
                children: [
                  CarouselView.weighted(
                    flexWeights: const <int>[1, 7, 1],
                    children: edit
                        ? (images
                              .map<Widget>(
                                (imgPath) => Stack(
                                  children: [
                                    Align(
                                      alignment: Alignment.topRight,
                                      child: IconButton(
                                        icon: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                                        onPressed: () {
                                          //remove image from firestore
                                          docRef.update({
                                            'images': FieldValue.arrayRemove([imgPath]),
                                          });
                                        },
                                      ),
                                    ),
                                    StorageImage(storagePath: imgPath),
                                  ],
                                ),
                              )
                              .toList()
                            ..add(
                              GestureDetector(
                                onTap: () async {
                                  final ImagePicker picker = ImagePicker();
                                  var image = await picker.pickImage(source: ImageSource.gallery);
                                  if (image != null) {
                                    //upload to firebase storage
                                    final storageRef = FirebaseStorage.instance.ref().child(
                                      'group/${widget.groupId}/recipes/${widget.recipeId}/${DateTime.now().millisecondsSinceEpoch}',
                                    );
                                    await storageRef.putFile(File(image.path));
                                    await docRef.update({
                                      'images': FieldValue.arrayUnion([storageRef.fullPath]),
                                    });
                                    setState(() {});
                                  }
                                },
                                child: Container(color: Theme.of(context).colorScheme.primaryContainer, child: const Icon(Icons.add_a_photo)),
                              ),
                            ))
                        : images.map((imgPath) => StorageImage(storagePath: imgPath)).toList(),
                  ),

                  //Title
                  edit
                      ? TextField(
                          controller: TextEditingController(text: data['name']),
                          decoration: const InputDecoration(labelText: 'Recipe Name'),
                          style: Theme.of(context).textTheme.headlineMedium,
                        )
                      : Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(data['name'] ?? 'Unnamed Recipe', style: Theme.of(context).textTheme.headlineMedium),
                        ),

                  Row(
                    children: [
                      //Tags
                      Expanded(
                        child: edit
                            ? TextField(
                                controller: tagsController,
                                decoration: const InputDecoration(contentPadding: EdgeInsets.all(8.0)),
                                style: Theme.of(context).textTheme.bodyMedium,
                              )
                            : Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Wrap(spacing: 8.0, children: tags.map((tag) => Chip(label: Text(tag))).toList()),
                              ),
                      ),

                      //Times
                      GestureDetector(
                        onTap: edit
                            ? () async {
                              var time = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay(hour: totalHour, minute: totalMinute),
                                builder: (BuildContext context, Widget? child) {
                                  return MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!);
                                },
                                initialEntryMode: TimePickerEntryMode.inputOnly,
                              );
                              if (time != null) {
                                docRef.update({
                                  'time': time.hour * 60 + time.minute,
                                });
                                setState(() {});
                              }
                            }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.schedule),
                              Text(" ${totalHour}h ${totalMinute}m", style: Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: edit
                            ? () async {
                          var time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(hour: prepHour, minute: prepMinute),
                            builder: (BuildContext context, Widget? child) {
                              return MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!);
                            },
                            initialEntryMode: TimePickerEntryMode.inputOnly,
                          );
                          if (time != null) {
                            docRef.update({
                              'preparationTime': time.hour * 60 + time.minute,
                            });
                            setState(() {});
                          }
                        }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.blender),
                              Text(" ${prepHour}h ${prepMinute}m", style: Theme.of(context).textTheme.bodyMedium),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  //Steps
                  Text("Steps:", style: Theme.of(context).textTheme.headlineSmall),
                  for (var (index, step) in steps.indexed)
                    Card(
                      child: Row(
                        children: [
                          Text("${index + 1}:", style: Theme.of(context).textTheme.titleMedium),
                          Expanded(
                            child: edit
                                ? TextField(
                                    controller: stepsControllers![index],
                                    maxLines: null,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                    decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(8.0)),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(step, style: Theme.of(context).textTheme.bodyMedium),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  if (edit)
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          stepsControllers!.add(TextEditingController());
                        });
                      },
                      child: const Text("Add Step"),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
