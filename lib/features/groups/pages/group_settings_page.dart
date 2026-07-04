import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:couple_planner/features/groups/invite_links.dart' as invites;
import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart' show kOnboardingFeatures, FeatureSpec;

class GroupSettingsPage extends StatefulWidget {
  const GroupSettingsPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  final _db = FirebaseFirestore.instance;
  final String _uid = FirebaseAuth.instance.currentUser!.uid;

  StreamSubscription? _groupSub;
  StreamSubscription? _membersSub;
  StreamSubscription? _invitesSub;

  Map<String, dynamic>? _group;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _members = [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _invites = [];
  bool _busy = false;

  DocumentReference<Map<String, dynamic>> get _groupRef => _db.collection('groups').doc(widget.groupId);

  @override
  void initState() {
    super.initState();
    _groupSub = _groupRef.snapshots().listen((s) {
      if (mounted) setState(() => _group = s.data());
    });
    _membersSub = _groupRef.collection('members').snapshots().listen((s) {
      if (mounted) setState(() => _members = s.docs);
    });
    _invitesSub = _groupRef.collection('invites').snapshots().listen((s) {
      if (mounted) setState(() => _invites = s.docs);
    });
  }

  @override
  void dispose() {
    _groupSub?.cancel();
    _membersSub?.cancel();
    _invitesSub?.cancel();
    super.dispose();
  }

  // ── derived state ────────────────────────────────────────────────────────--

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _activeMembers =>
      _members.where((m) => m.data()['status'] != 'left').toList();

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _fullMembers =>
      _activeMembers.where((m) => m.data()['role'] != 'recipe_viewer').toList();

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _recipeViewers =>
      _activeMembers.where((m) => m.data()['role'] == 'recipe_viewer').toList();

  bool get _isAdmin => _activeMembers.any((m) => m.id == _uid && m.data()['role'] == 'admin');

  bool get _membersCanEditFeatures => _group?['membersCanEditFeatures'] as bool? ?? true;
  bool get _membersCanInvite => _group?['membersCanInvite'] as bool? ?? true;

  bool get _canEditFeatures => _isAdmin || _membersCanEditFeatures;
  bool get _canInvite => _isAdmin || _membersCanInvite;

  List<String> get _enabledFeatures =>
      ((_group?['enabledFeatures'] as List?) ?? const []).map((e) => e.toString()).toList();

  // ── actions ──────────────────────────────────────────────────────────────--

  Future<void> _setDefaultPage(String key) => _groupRef.update({'defaultPage': key});

  Future<void> _toggleFeature(String key) async {
    final enabled = List<String>.from(_enabledFeatures);
    if (enabled.contains(key)) {
      if (enabled.length <= 1) {
        _snack('Keep at least one feature enabled.');
        return;
      }
      enabled.remove(key);
    } else {
      enabled.add(key);
    }
    // Re-order by the canonical feature order.
    final ordered = kOnboardingFeatures.where((f) => enabled.contains(f.key)).map((f) => f.key).toList();
    final defaultPage = _group?['defaultPage'] as String?;
    final update = <String, dynamic>{'enabledFeatures': ordered};
    if (defaultPage == null || !ordered.contains(defaultPage)) {
      update['defaultPage'] = ordered.first;
    }
    await _groupRef.update(update);
  }

  Future<void> _setBoolSetting(String field, bool value) => _groupRef.update({field: value});

  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: (_group?['name'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await _groupRef.update({'name': name.trim()});
    }
  }

  Future<void> _createAndShareInvite({bool recipeViewer = false}) async {
    setState(() => _busy = true);
    try {
      final ref = _groupRef.collection('invites').doc();
      await ref.set({
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(days: 14))),
        'createdBy': _uid,
        if (recipeViewer) 'type': 'recipe_viewer',
      });
      final link = invites.buildInviteLink(widget.groupId, ref.id);
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        text: recipeViewer
            ? 'View my recipes on Together Planner: $link'
            : 'Join my group on Together Planner: $link',
        subject: 'Together Planner invite',
        sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      ));
    } catch (_) {
      _snack('Could not create the invite link.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeInvite(String inviteId) async {
    await _groupRef.collection('invites').doc(inviteId).delete();
  }

  Future<void> _removeMember(String uid) async {
    await _groupRef.collection('members').doc(uid).delete();
  }

  Future<void> _removeAllJoinedVia(String inviteId) async {
    final batch = _db.batch();
    for (final m in _activeMembers) {
      if (m.id != _uid && m.data()['joinedVia'] == inviteId) {
        batch.delete(m.reference);
      }
    }
    await batch.commit();
  }

  Future<void> _promote(String uid) async {
    await _groupRef.collection('members').doc(uid).update({'role': 'admin'});
  }

  Future<void> _upgradeToMember(String uid) async {
    await _groupRef.collection('members').doc(uid).update({'role': 'member'});
  }

  Future<void> _leave() async {
    // Don't let the last admin abandon a group that still has other members —
    // it would leave everyone unable to manage it.
    final others = _activeMembers.where((m) => m.id != _uid).toList();
    final otherAdmins = others.where((m) => m.data()['role'] == 'admin');
    if (_isAdmin && others.isNotEmpty && otherAdmins.isEmpty) {
      _snack('You are the only admin. Make someone else an admin before leaving.');
      return;
    }

    final confirmed = await _confirm('Leave group?', 'You can rejoin later with an invite link.');
    if (!confirmed) return;
    await _db.collection('users').doc(_uid).collection('groups').doc(widget.groupId).delete();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _deleteGroup() async {
    final confirmed = await _confirm('Delete group?', 'This permanently deletes the group and all its data for everyone.');
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await invites.deleteGroup(widget.groupId);
      if (mounted) Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'Could not delete the group.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────--

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String title, String body) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    return res ?? false;
  }

  FeatureSpec _featureFor(String key) =>
      kOnboardingFeatures.firstWhere((f) => f.key == key, orElse: () => FeatureSpec(key, Icons.widgets, key, true));

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_group == null) {
      return Scaffold(appBar: AppBar(title: const Text('Group settings')), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text((_group?['name'] ?? 'Group settings').toString()),
        actions: [
          if (_isAdmin) IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Rename', onPressed: _renameGroup),
        ],
      ),
      body: ListView(
        children: [
          ..._buildFeatures(),
          ..._buildInvites(),
          if (_isAdmin) ..._buildPermissions(),
          ..._buildMembers(),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Leave group'),
            onTap: _busy ? null : _leave,
          ),
          if (_isAdmin)
            ListTile(
              leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
              title: Text('Delete group', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: _busy ? null : _deleteGroup,
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _featureTile(FeatureSpec f) {
    final enabled = _enabledFeatures.contains(f.key);
    final isDefault = (_group?['defaultPage'] as String? ?? _enabledFeatures.firstOrNull) == f.key;
    return ListTile(
      leading: Icon(f.icon),
      title: Text(f.label),
      subtitle: f.implemented ? null : const Text('coming soon'),
      onTap: (f.implemented && _canEditFeatures) ? () => _toggleFeature(f.key) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (enabled)
            IconButton(
              icon: Icon(isDefault ? Icons.home : Icons.home_outlined),
              tooltip: 'Set as default page',
              onPressed: (_canEditFeatures && !isDefault) ? () => _setDefaultPage(f.key) : () {},
            ),
          Checkbox(
            value: enabled,
            onChanged: (f.implemented && _canEditFeatures) ? (_) => _toggleFeature(f.key) : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFeatures() {
    return [
      const _SectionHeader('Features'),
      if (!_canEditFeatures)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('Only admins can change features in this group.', style: TextStyle(fontSize: 13)),
        ),
      for (final f in kOnboardingFeatures) _featureTile(f),
    ];
  }

  List<Widget> _buildPermissions() {
    return [
      const _SectionHeader('Permissions'),
      SwitchListTile(
        title: const Text('Members can change features'),
        value: _membersCanEditFeatures,
        onChanged: (v) => _setBoolSetting('membersCanEditFeatures', v),
      ),
      SwitchListTile(
        title: const Text('Members can create invite links'),
        value: _membersCanInvite,
        onChanged: (v) => _setBoolSetting('membersCanInvite', v),
      ),
    ];
  }

  List<Widget> _buildInvites() {
    final now = DateTime.now();
    final active = _invites.where((d) {
      final exp = (d.data()['expiresAt'] as Timestamp?)?.toDate();
      return exp != null && exp.isAfter(now);
    }).toList();

    return [
      const _SectionHeader('Invite links'),
      if (_canInvite)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _busy ? null : _createAndShareInvite,
            icon: const Icon(Icons.add_link),
            label: const Text('Create & share invite link'),
          ),
        ),
      if (_canInvite)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _createAndShareInvite(recipeViewer: true),
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Share recipes only'),
          ),
        ),
      if (active.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No active invite links.', style: TextStyle(fontSize: 13)),
        ),
      for (final inv in active) _inviteCard(inv),
    ];
  }

  Widget _inviteCard(QueryDocumentSnapshot<Map<String, dynamic>> inv) {
    final data = inv.data();
    final exp = (data['expiresAt'] as Timestamp?)?.toDate();
    final daysLeft = exp == null ? 0 : exp.difference(DateTime.now()).inDays;
    final createdBy = data['createdBy'] as String?;
    final canRevoke = _isAdmin || createdBy == _uid;
    final joiners = _fullMembers.where((m) => m.data()['joinedVia'] == inv.id).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Expires in $daysLeft day${daysLeft == 1 ? '' : 's'}')),
                if (canRevoke)
                  TextButton(onPressed: () => _revokeInvite(inv.id), child: const Text('Revoke')),
              ],
            ),
            if (_isAdmin && joiners.isNotEmpty) ...[
              const Divider(),
              Row(
                children: [
                  Expanded(child: Text('Joined via this link (${joiners.length})', style: const TextStyle(fontWeight: FontWeight.w600))),
                  TextButton(onPressed: () => _removeAllJoinedVia(inv.id), child: const Text('Remove all')),
                ],
              ),
              for (final m in joiners)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: _Username(uid: m.id),
                  trailing: IconButton(
                    icon: const Icon(Icons.person_remove_outlined),
                    tooltip: 'Remove',
                    onPressed: () => _removeMember(m.id),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildMembers() {
    return [
      const _SectionHeader('Members'),
      for (final m in _fullMembers) _memberTile(m),
      if (_recipeViewers.isNotEmpty) ...[
        const _SectionHeader('Recipe viewers'),
        for (final m in _recipeViewers) _recipeViewerTile(m),
      ],
    ];
  }

  Widget _recipeViewerTile(QueryDocumentSnapshot<Map<String, dynamic>> m) {
    final isMe = m.id == _uid;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.menu_book_outlined)),
      title: _Username(uid: m.id),
      subtitle: const Text('Can view recipes'),
      trailing: (!isMe && _isAdmin)
          ? PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'upgrade') _upgradeToMember(m.id);
                if (v == 'remove') _removeMember(m.id);
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'upgrade', child: Text('Make full member')),
                const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            )
          : null,
    );
  }

  Widget _memberTile(QueryDocumentSnapshot<Map<String, dynamic>> m) {
    final isMe = m.id == _uid;
    final role = (m.data()['role'] ?? 'member').toString();
    final isMemberAdmin = role == 'admin';

    Widget? trailing;
    if (isMe) {
      trailing = const SizedBox(
        width: 48,
        child: Center(child: Text('You')),
      );
    } else if (_isAdmin) {
      trailing = PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'promote') _promote(m.id);
          if (v == 'remove') _removeMember(m.id);
        },
        itemBuilder: (context) => [
          if (!isMemberAdmin) const PopupMenuItem(value: 'promote', child: Text('Make admin')),
          const PopupMenuItem(value: 'remove', child: Text('Remove from group')),
        ],
      );
    }

    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person)),
      title: _Username(uid: m.id),
      subtitle: Text(isMemberAdmin ? 'Admin' : 'Member'),
      trailing: trailing,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

/// Shows a user's public username (from users_public/{uid}).
class _Username extends StatelessWidget {
  const _Username({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return LoadDocumentBuilder(
      docRef: FirebaseFirestore.instance.collection('users_public').doc(uid),
      builder: (data) => Text((data['username'] ?? 'Member').toString()),
    );
  }
}
