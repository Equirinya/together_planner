import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/groups/pages/create_group_page.dart';
import 'package:couple_planner/features/groups/pages/group_settings_page.dart';
import 'package:couple_planner/features/recipes/pages/shared_recipes_page.dart';
import 'package:couple_planner/features/settings/pages/settings_page.dart';

/// Lists the groups the user belongs to: tap to make one active, open its
/// settings, or create a new group.
class GroupOverviewPage extends StatefulWidget {
  const GroupOverviewPage({
    super.key,
    required this.groupIds,
    required this.selectedGroup,
    required this.onSelect,
  });

  final List<String> groupIds;
  final String? selectedGroup;
  final void Function(String groupId) onSelect;

  @override
  State<GroupOverviewPage> createState() => _GroupOverviewPageState();
}

class _GroupOverviewPageState extends State<GroupOverviewPage> {
  final _db = FirebaseFirestore.instance;
  late List<String> _groupIds;
  StreamSubscription? _groupsSub;

  @override
  void initState() {
    super.initState();
    _groupIds = List<String>.from(widget.groupIds);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _groupsSub = _db
          .collection('users')
          .doc(uid)
          .collection('groups')
          .snapshots()
          .listen((snap) {
        if (mounted) setState(() => _groupIds = snap.docs.map((d) => d.id).toList());
      });
    }
  }

  @override
  void dispose() {
    _groupsSub?.cancel();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    );
    if (newId != null && mounted) {
      widget.onSelect(newId);
      Navigator.of(context).pop(); // close the overview, landing on the new group
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your groups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createGroup,
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          if (_groupIds.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('You are not a member of any groups yet.', textAlign: TextAlign.center),
            ),
          for (final id in _groupIds)
            Card(
              child: ListTile(
                contentPadding: EdgeInsetsDirectional.only(start: 16.0, end: 8.0),
                leading: Icon(
                  id == widget.selectedGroup ? Icons.check_circle : Icons.group_outlined,
                  color: id == widget.selectedGroup ? Theme.of(context).colorScheme.primary : null,
                ),
                title: LoadDocumentBuilder(
                  docRef: _db.collection('groups').doc(id),
                  builder: (data) => Text((data['name'] ?? 'Group').toString()),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_groupIds.length > 1)
                      IconButton(
                        icon: Icon(MdiIcons.bookPlusMultiple),
                        tooltip: 'Copy recipes',
                        constraints: const BoxConstraints(),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SharedRecipesPage(sourceGroupId: id, showLeaveButton: false),
                          ),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.share_outlined),
                      tooltip: 'Share invite',
                      constraints: const BoxConstraints(),
                      onPressed: () => showGroupInvitePicker(context, id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Group settings',
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => GroupSettingsPage(groupId: id)),
                      ),
                    ),
                  ],
                ),
                onTap: () {
                  widget.onSelect(id);
                  Navigator.of(context).pop();
                },
              ),
            ),
          ..._buildRecipeViewerSection(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('App Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
    );
  }

  /// A section listing the groups whose recipes the user may view (shown only
  /// when non-empty). Tapping one opens its recipes to browse and add.
  List<Widget> _buildRecipeViewerSection() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];
    return [
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _db.collection('users').doc(uid).collection('recipe_groups').snapshots(),
        builder: (context, snapshot) {
          final docs = snapshot.data?.docs ?? const [];
          if (docs.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Groups you can view recipes from'),
              ),
              for (final d in docs)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: LoadDocumentBuilder(
                      docRef: _db.collection('groups').doc(d.id),
                      builder: (data) => Text((data['name'] ?? 'Group').toString()),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => SharedRecipesPage(sourceGroupId: d.id)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }
}
