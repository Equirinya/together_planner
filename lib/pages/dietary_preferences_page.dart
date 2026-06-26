import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../dietary_preferences.dart';

/// Settings screen to view and edit the user's dietary preferences, stored in
/// their private profile (users/{uid}.dietaryPreferences).
class DietaryPreferencesPage extends StatefulWidget {
  const DietaryPreferencesPage({super.key});

  @override
  State<DietaryPreferencesPage> createState() => _DietaryPreferencesPageState();
}

class _DietaryPreferencesPageState extends State<DietaryPreferencesPage> {
  final String _uid = FirebaseAuth.instance.currentUser!.uid;
  List<String> _prefs = [];
  bool _loading = true;

  DocumentReference<Map<String, dynamic>> get _userRef =>
      FirebaseFirestore.instance.collection('users').doc(_uid);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await _userRef.get();
      final raw = snap.data()?['dietaryPreferences'];
      if (mounted) {
        setState(() {
          _prefs = raw is List ? raw.map((e) => e.toString()).toList() : [];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _save(List<String> value) {
    setState(() => _prefs = value);
    _userRef
        .set({'dietaryPreferences': value}, SetOptions(merge: true))
        .catchError((e) {
          if (kDebugMode) debugPrint('Failed to save dietary preferences: $e');
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dietary preferences')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                DietaryPreferencesSelector(value: _prefs, onChanged: _save),
              ],
            ),
    );
  }
}
