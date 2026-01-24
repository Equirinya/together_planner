import 'dart:io';

import 'package:couple_planner/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import 'package:shared_preferences/shared_preferences.dart';

class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({super.key, required this.groupId, required this.recipeId, this.editMode = false});

  final String groupId;
  final String recipeId;
  final bool editMode;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  bool edit = false;

  TextEditingController? nameController;
  TextEditingController? descriptionController;
  List<TextEditingController>? stepsControllers;
  TextEditingController? tagsController;

  Map<String, dynamic>? recipeData;
  late DocumentReference<Map<String, dynamic>> docRef;

  late List<String> images;
  late List<String> steps;
  late List<String> tags;
  late int totalHour;
  late int totalMinute;
  late int prepHour;
  late int prepMinute;

  @override
  void initState() {
    edit = widget.editMode;
    final db = FirebaseFirestore.instance;
    final groupCollection = db.collection('groups').doc(widget.groupId);
    docRef = groupCollection.collection('recipes').doc(widget.recipeId);
    loadData();
    super.initState();
  }

  Future<void> loadData() async {
    final doc = await docRef.get();
    if (doc.exists) {
      recipeData = doc.data();

      images = List<String>.from(recipeData?['images'] ?? []);
      steps = List<String>.from(recipeData?['steps'] ?? []);
      if (steps.isEmpty) steps = [''];
      tags = List<String>.from(recipeData?['tags'] ?? []);
      totalHour = ((recipeData?['time'] ?? 0) / 60).floor();
      totalMinute = (recipeData?['time'] ?? 0) % 60;
      prepHour = ((recipeData?['preparationTime'] ?? 0) / 60).floor();
      prepMinute = (recipeData?['preparationTime'] ?? 0) % 60;

      nameController ??= TextEditingController(text: recipeData?['name']);
      descriptionController ??= TextEditingController(text: recipeData?['description']);
      stepsControllers ??= steps.map((step) => TextEditingController(text: step)).toList();
      tagsController ??= TextEditingController(text: (tags.map((e) => "#$e ")).join(''));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (recipeData == null) {
      return const Scaffold(body: Center(child: CupertinoActivityIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        // title: Text(data['name'] ?? 'Unnamed Recipe'),
        actions: [
          IconButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  icon: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                  title: const Text("Delete Recipe"),
                  content: const Text("Are you sure you want to delete this recipe? This action cannot be undone."),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: const Text("Cancel"),
                    ),
                    FilledButton(
                      onPressed: () async {
                        //delete images from storage
                        for (var imgPath in images) {
                          await FirebaseStorage.instance.ref().child(imgPath).delete();
                        }
                        await docRef.delete();
                        Navigator.of(context).pop(); //close dialog
                        Navigator.of(context).pop(); //go back
                      },
                      child: const Text("Delete"),
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ),
              );
            },
            icon: Icon(Icons.delete),
          ),
          IconButton(
            icon: Icon(edit ? Icons.check : Icons.edit),
            onPressed: () {
              if (edit) {
                var name = nameController!.text.trim();
                if (name.isEmpty) name = 'New Recipe';
                docRef.update({
                  'name': name,
                  'description': descriptionController!.text,
                  'steps': stepsControllers!.map((c) => c.text.trim()).where((element) => element.isNotEmpty).toList(),
                  'tags': tagsController!.text.split('#').map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toList(),
                });
                edit = !edit;
                loadData();
              } else {
                setState(() {
                  edit = !edit;
                });
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (edit || images.isNotEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.3,
                child: edit
                    ? ReorderableListView(
                        scrollDirection: Axis.horizontal,
                        onReorder: (oldIndex, newIndex) {
                          images.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, images.removeAt(oldIndex));
                          docRef.update({'images': images});
                          setState(() {});
                        },
                        padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
                        footer: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            fixedSize: Size(MediaQuery.of(context).size.width * 0.4, double.infinity),
                            elevation: 0,
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                          ),
                          onPressed: () async {
                            final ImagePicker picker = ImagePicker();
                            var image = await picker.pickImage(source: ImageSource.gallery);
                            if (image != null) {
                              //upload to firebase storage
                              final storageRef = FirebaseStorage.instance.ref().child(
                                'groups/${widget.groupId}/recipes/${widget.recipeId}/${DateTime.now().millisecondsSinceEpoch}',
                              );
                              await storageRef.putFile(File(image.path));
                              await docRef.update({
                                'images': FieldValue.arrayUnion([storageRef.fullPath]),
                              });
                              loadData();
                            }
                          },
                          child: const Icon(Icons.add_a_photo),
                        ),
                        children: images
                            .map<Widget>(
                              (imgPath) => SizedBox(
                                key: ValueKey(imgPath),
                                width: MediaQuery.of(context).size.width * 0.4,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8.0),
                                    child: Stack(
                                      children: [
                                        SizedBox.expand(
                                          child: StorageImage(storagePath: imgPath, fit: BoxFit.cover),
                                        ),
                                        Align(
                                          alignment: Alignment.topRight,
                                          child: IconButton(
                                            icon: Icon(Icons.cancel, color: Theme.of(context).colorScheme.error),
                                            onPressed: () {
                                              docRef.update({
                                                'images': FieldValue.arrayRemove([imgPath]),
                                              });
                                              FirebaseStorage.instance.ref().child(imgPath).delete();
                                              loadData();
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      )
                    : CarouselView.weighted(
                        flexWeights: const <int>[1, 7, 1],
                        enableSplash: false,
                        children: images.map((imgPath) => StorageImage(storagePath: imgPath, fit: BoxFit.cover)).toList(),
                      ),
              ),

            SizedBox(height: 16),
            //Title
            edit
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: TextField(controller: nameController, style: Theme.of(context).textTheme.headlineMedium),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                    child: Text(recipeData?['name'] ?? 'Unnamed Recipe', style: Theme.of(context).textTheme.headlineMedium),
                  ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  //Tags
                  Expanded(
                    child: edit
                        ? TextField(controller: tagsController, style: Theme.of(context).textTheme.bodyMedium)
                        : Wrap(
                            spacing: 8.0,
                            children: tags
                                .map(
                                  (tag) => Chip(
                                    label: Text(
                                      tag,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer),
                                    ),
                                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                    side: BorderSide.none,
                                  ),
                                )
                                .toList(),
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
                              docRef.update({'time': time.hour * 60 + time.minute});
                              loadData();
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
                              docRef.update({'preparationTime': time.hour * 60 + time.minute});
                              loadData();
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
            ),

            SizedBox(height: 16),
            //Steps
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text("Steps:", style: Theme.of(context).textTheme.headlineSmall),
            ),
            for (var (index, step) in steps.indexed)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                elevation: 0,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: Text("${index + 1}:", style: Theme.of(context).textTheme.titleMedium),
                    ),
                    Expanded(
                      child: edit
                          ? TextField(
                              controller: stepsControllers![index],
                              maxLines: null,
                              style: Theme.of(context).textTheme.bodyMedium,
                              decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.all(8.0)),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 16),
                              child: Text(step, style: Theme.of(context).textTheme.bodyMedium),
                            ),
                    ),
                  ],
                ),
              ),
            if (edit)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        steps.add('');
                        stepsControllers!.add(TextEditingController());
                      });
                    },
                    child: const Text("Add Step"),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
