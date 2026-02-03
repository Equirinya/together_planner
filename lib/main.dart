import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:couple_planner/pages/recipe_page.dart';
import 'package:couple_planner/utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:system_theme/system_theme.dart';
import 'firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'pages/login_page.dart';
import 'pages/shopping_list_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemTheme.fallbackColor = const Color(0xFFB7FF5E);
  await SystemTheme.accentColor.load();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.accent),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.dark, brightness: Brightness.dark),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 3;
  String? _selectedGroup;

  final db = FirebaseFirestore.instance;
  //groups where the user is a member of
  Stream<QuerySnapshot<Map<String, dynamic>>>? groupsStream;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? groupListener;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> acceptedGroups = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> pendingGroups = [];

  @override
  void initState() {
    _testUserLoggedIn();
    super.initState();
  }

  @override
  void dispose() {
    groupListener?.cancel();
    super.dispose();
  }

  Future<void> _testUserLoggedIn() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final DocumentSnapshot? userDoc = currentUser == null ? null : await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    if (currentUser == null || !userDoc!.exists) {
      await Future.delayed(Duration(milliseconds: 100));
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (context) => WelcomePage(onFinished: () => _testUserLoggedIn(), infoText: "")));
    } else {
      if (Platform.isAndroid || Platform.isIOS) {
        // final fcmToken = await FirebaseMessaging.instance.getToken();
        // final notificationSettings = await FirebaseMessaging.instance
        //     .requestPermission(provisional: true); //TODO ask on a better moment
        // if (kDebugMode) {
        //   print("FCM Token: $fcmToken");
        // }
        //
        // // Save FCM token to SharedPreferences
        // final prefs = await SharedPreferences.getInstance();
        // await prefs.setString('fcmToken', fcmToken!);

        PackageInfo packageInfo = await PackageInfo.fromPlatform();

        String uid = FirebaseAuth.instance.currentUser!.uid;
        groupsStream = db.collection('users').doc(uid).collection("invites").snapshots();
        groupListener?.cancel();
        groupListener = groupsStream!.listen((snapshot) {

          var groups = snapshot.docs;
          acceptedGroups = groups.where((inviteDoc) => inviteDoc.data()['status'] == 'accepted').toList();
          pendingGroups = groups.where((inviteDoc) => inviteDoc.data()['status'] == 'pending').toList();
          if (_selectedGroup == null || !acceptedGroups.any((element) => element.id == _selectedGroup)) {
            _selectedGroup = acceptedGroups.first.id;
          }
          setState(() {});

          //handle new invites
          // for (var docChange in snapshot.docChanges) {
          //   if (docChange.type == DocumentChangeType.added) {
          //     var data = docChange.doc.data();
          //     if (data != null && data['status'] == 'pending') {
          //       showInfoDialog(context, "You have been invited to join a new group!");
          //     }
          //   }
          // }
        });

        // Update user document in Firebase
        await db.collection('users').doc(uid).update({
          // 'fcmToken': fcmToken,
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
        surfaceTintColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        //dropdown to select group

        title:  SizedBox()
      //   DropdownButton<String>(
      //   value: _selectedGroup,
      //   items: acceptedGroups.map((inviteDoc) => DropdownMenuItem<String>(
      //     value: inviteDoc.id,
      //     child: LoadDocumentBuilder(docRef: db.collection("groups").doc(inviteDoc.id), builder: (data) => Text(data['name'])),
      //   )).toList(),
      //   onChanged: (String? newValue) {
      //     setState(() {
      //       _selectedGroup = newValue!;
      //     });
      //   },
      // );
      ),
      // bottomNavigationBar: NavigationBar(
      //   destinations: const [
      //     NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Calendar'),
      //     NavigationDestination(icon: Icon(Icons.list), label: 'ToDo\'s'),
      //     NavigationDestination(icon: Icon(Icons.shopping_bag), label: 'Shopping List'),
      //     NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'Recipes'),
      //   ],
      //   onDestinationSelected: (int index) {
      //     setState(() {
      //       _selectedIndex = index;
      //     });
      //   },
      //   selectedIndex: _selectedIndex,
      // ),
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
