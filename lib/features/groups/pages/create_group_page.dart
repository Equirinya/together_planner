import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/animated_background.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart' show onboardingTheme, FeatureBubbleField, kOnboardingFeatures;
import 'package:couple_planner/features/groups/invite_links.dart' show createGroup;

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

  /// Guards against a double tap firing two createGroup calls, which would
  /// leave the user with two identical groups.
  bool _busy = false;

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

  bool get _valid => _nameCtrl.text.trim().isNotEmpty && _selected.isNotEmpty && !_busy;

  /// Creating the group is a round trip to the createGroup Cloud Function
  /// rather than two direct Firestore writes: the group doc and the creator's
  /// admin member doc have to land together, and the rules no longer let a
  /// client write either one. Hence the busy flag and the error path, neither
  /// of which the old fire-and-forget version needed.
  Future<void> _create() async {
    if (_busy) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _busy = true);

    final ordered = kOnboardingFeatures.where((f) => _selected.contains(f.key)).map((f) => f.key).toList();
    try {
      final groupId = await createGroup(
        name: _nameCtrl.text.trim(),
        enabledFeatures: ordered,
        defaultPage: ordered.contains('recipes') ? 'recipes' : ordered.first,
      );
      if (!mounted) return;
      Navigator.of(context).pop(groupId);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the group: $error')),
      );
    }
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
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            )
                          : const Text('Create group'),
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
