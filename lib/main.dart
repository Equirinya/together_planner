import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:couple_planner/pages/recipe_page.dart';
import 'package:couple_planner/utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'pages/login_page.dart';
import 'pages/shopping_list_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _selectedIndex = 0;
  String? _selectedGroup;

  final db = FirebaseFirestore.instance;
  //groups where the user is a member of
  Stream<QuerySnapshot<Map<String, dynamic>>>? groupsStream;

  @override
  void initState() {
    _testUserLoggedIn();
    super.initState();
  }

  Future<void> _testUserLoggedIn() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final DocumentSnapshot? userDoc = currentUser == null ? null : await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    if (currentUser == null || !userDoc!.exists) {
      await Future.delayed(Duration(milliseconds: 100));
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => const LoginPage()));
      _testUserLoggedIn();
    } else {
      if (Platform.isAndroid || Platform.isIOS) {
        final fcmToken = await FirebaseMessaging.instance.getToken();
        final notificationSettings = await FirebaseMessaging.instance
            .requestPermission(provisional: true); //TODO ask on a better moment
        if (kDebugMode) {
          print("FCM Token: $fcmToken");
        }

        // Save FCM token to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcmToken', fcmToken!);

        PackageInfo packageInfo = await PackageInfo.fromPlatform();

        String uid = FirebaseAuth.instance.currentUser!.uid;
        groupsStream = db.collection('users').doc(uid).collection("invites").where("status", isEqualTo: "pending").snapshots();
        // Update user document in Firebase
        await db.collection('users').doc(uid).update({
          'fcmToken': fcmToken,
          'lastLogin': FieldValue.serverTimestamp(),
          'appVersion': packageInfo.version,
        }).catchError((error) {
          if (kDebugMode) {
            print("Failed to update user: $error");
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        //dropdown to select group
        title: StreamBuilder(stream: groupsStream, builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const CupertinoActivityIndicator();
          }
          if (snapshot.hasError) {
            return const Text("Error loading groups");
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Text("No groups"); //TODO show dialog to create or join group
          }
          var groups = snapshot.data!.docs;
          if (_selectedGroup == null || !groups.any((element) => element.id == _selectedGroup)) {
            setState(() {
              _selectedGroup = groups.first.id;
            });
          }
          return DropdownButton<String>(
            value: _selectedGroup,
            items: groups.map((inviteDoc) => DropdownMenuItem<String>(
              value: inviteDoc.id,
              child: LoadDocumentBuilder(docRef: db.collection("groups").doc(inviteDoc.id), builder: (data) => Text(data['name'])),
            )).toList(),
            onChanged: (String? newValue) {
              setState(() {
                _selectedGroup = newValue!;
              });
            },
          );
        },)
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Calendar'),
          NavigationDestination(icon: Icon(Icons.list), label: 'ToDo\'s'),
          NavigationDestination(icon: Icon(Icons.shopping_bag), label: 'Shopping List'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'Recipes'),
        ],
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        selectedIndex: _selectedIndex,
      ),
      body: _selectedGroup != null && _selectedGroup!.isNotEmpty ? IndexedStack(
        index: _selectedIndex,
        children: [
          Placeholder(),
          Placeholder(),
          ShoppingListPage(groupId: _selectedGroup!),
          RecipePage(groupId: _selectedGroup!),
        ],
      ) : const Center(child: CupertinoActivityIndicator())
    );
  }
}
