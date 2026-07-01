import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/utils.dart';
import 'package:couple_planner/features/groups/pages/create_group_page.dart';
import 'package:couple_planner/features/groups/pages/group_settings_page.dart';
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
          if (widget.groupIds.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('You are not a member of any groups yet.', textAlign: TextAlign.center),
            ),
          for (final id in widget.groupIds)
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
                trailing: IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Group settings',
                  constraints: const BoxConstraints(),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => GroupSettingsPage(groupId: id)),
                  ),
                ),
                onTap: () {
                  widget.onSelect(id);
                  Navigator.of(context).pop();
                },
              ),
            ),
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
}
