import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/features/auth/pages/login_page.dart' show animatedBackground;
import 'package:couple_planner/features/auth/pages/onboarding_page.dart' show onboardingTheme, FeatureBubbleField, kOnboardingFeatures;

/// Onboarding-styled screen for creating an additional group: the animated
/// background and the floating feature bubbles, reused from onboarding. Pops
/// with the new group id on success.
class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final TextEditingController _nameCtrl = TextEditingController();
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _valid => _nameCtrl.text.trim().isNotEmpty && _selected.isNotEmpty;

  void _create() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final ordered = kOnboardingFeatures.where((f) => _selected.contains(f.key)).map((f) => f.key).toList();
    final db = FirebaseFirestore.instance;
    final ref = db.collection('groups').doc();
    ref.set({
      'name': _nameCtrl.text.trim(),
      'enabledFeatures': ordered,
      'defaultPage': ordered.first,
    });
    ref.collection('members').doc(uid).set({
      'role': 'admin',
      'status': 'active',
      'joinedAt': FieldValue.serverTimestamp(),
      'lastActive': FieldValue.serverTimestamp(),
    });
    Navigator.of(context).pop(ref.id);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Theme(
      data: onboardingTheme(),
      child: Scaffold(
        body: Stack(
          children: [
            SizedBox(width: size.width, height: size.height, child: animatedBackground()),
            Container(width: size.width, height: size.height, color: Colors.black.withAlpha(50)),
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.black),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Create a new group',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.black, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'With different friends, your family or anyone else.',
                          style: TextStyle(color: Colors.black87, fontSize: 14),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.group_outlined),
                            labelText: 'Group name',
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'What would you like to use?',
                          style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                  Expanded(
                    child: FeatureBubbleField(
                      features: kOnboardingFeatures,
                      selected: _selected,
                      height: null,
                      onToggle: (key) => setState(() {
                        if (_selected.contains(key)) {
                          _selected.remove(key);
                        } else {
                          _selected.add(key);
                        }
                      }),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 8, 32, 16),
                    child: FilledButton(
                      onPressed: _valid ? _create : null,
                      child: const Text('Create group'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
