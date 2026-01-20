import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    ()async {
      if(FirebaseAuth.instance.currentUser == null) {
        try {
          final userCredential = await FirebaseAuth.instance.signInAnonymously();
          print("Signed in with temporary account.");
        } on FirebaseAuthException catch (e) {
          print('Failed to sign in anonymously: $e');
        }
      }
    }();
  }

  @override
  void dispose() {
    () async {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        //delete user
        await user.delete();
        //sign out
        await FirebaseAuth.instance.signOut();
      }
    }();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Text("Welcome!", style: Theme.of(context).textTheme.headlineMedium),
              Text("Create an account by choosing a username:", style: Theme.of(context).textTheme.bodyMedium),
              SizedBox(height: MediaQuery.of(context).size.height/4),
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Username',
                  errorText: _errorMessage
                ),

                onSubmitted: (String value) async {
                  if (value.isEmpty || value.length < 3) {
                    //show error
                    setState(() {
                      _errorMessage = "Username must be at least 3 characters long.";
                    });
                    return;
                  }

                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) {
                    setState(() {
                      _errorMessage = "Internal error: No user logged in.";
                    });
                    return;
                  }
                  final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
                  final doc = await userDoc.get();
                  if (doc.exists) {
                    setState(() {
                      _errorMessage = "Internal error: User document already exists.";
                    });
                    return;
                  }
                  //check if username is taken
                  final userNameDoc = await FirebaseFirestore.instance.collection('usernames').doc(value).get();
                  if (userNameDoc.exists) {
                    setState(() {
                      _errorMessage = "Username is already taken.";
                    });
                    return;
                  }

                  try {
                    //create username document
                    await FirebaseFirestore.instance.collection('usernames').doc(
                        value).set({
                      'uid': user.uid,
                      'createdAt': FieldValue.serverTimestamp(),
                    });

                    //create user_public document
                    await FirebaseFirestore.instance.collection('users_public').doc(
                        user.uid).set({
                      'username': value,
                      'createdAt': FieldValue.serverTimestamp(),
                    });

                    PackageInfo packageInfo = await PackageInfo.fromPlatform();

                    await userDoc.set({
                      'username': value,
                      'createdAt': FieldValue.serverTimestamp(),
                      'lastLogin': FieldValue.serverTimestamp(),
                      'fcmToken': null,
                      'appVersion': packageInfo.version,
                    });
                    Navigator.of(context).pop();
                  }
                  catch (e) {
                    if(kDebugMode){
                      print("Error creating user: $e");
                    }
                    setState(() {
                      _errorMessage = "Failed to create user";
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
