import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/features/groups/invite_links.dart';
import 'package:couple_planner/features/recipes/pages/shared_recipes_page.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart' show kOnboardingFeatures, FeatureSpec;

/// Landing screen shown when a user opens an invite link. It previews the group
/// (name, features, members) without joining, then lets the user join.
class JoinGroupPage extends StatefulWidget {
  const JoinGroupPage({super.key, required this.groupId, required this.inviteId, this.onJoined});

  final String groupId;
  final String inviteId;

  /// Called with the group id after a successful join, so the host can select it.
  final void Function(String groupId)? onJoined;

  @override
  State<JoinGroupPage> createState() => _JoinGroupPageState();
}

class _JoinGroupPageState extends State<JoinGroupPage> {
  Map<String, dynamic>? _preview;
  String? _error;
  bool _loading = true;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await previewInvite(widget.groupId, widget.inviteId);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'This invite link could not be opened.';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong opening this invite.';
        _loading = false;
      });
    }
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await joinGroupViaInvite(widget.groupId, widget.inviteId);
      final isRecipeViewer = _preview?['type'] == 'recipe_viewer';
      if (!mounted) return;
      if (isRecipeViewer) {
        // A recipe viewer never becomes the active group; the group appears in
        // the "groups you can view recipes from" section instead. Open it now.
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => SharedRecipesPage(sourceGroupId: widget.groupId),
        ));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_group', widget.groupId);
      if (!mounted) return;
      widget.onJoined?.call(widget.groupId);
      Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = e.message ?? 'Could not join the group.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Could not join the group.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join group')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadPreview)
              : _buildPreview(context),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final preview = _preview!;
    final name = (preview['name'] as String?) ?? 'Group';
    final features = ((preview['enabledFeatures'] as List?) ?? const []).map((e) => e.toString()).toList();
    final members = ((preview['members'] as List?) ?? const []).cast<dynamic>();
    final alreadyMember = preview['alreadyMember'] == true;
    final isRecipeViewer = preview['type'] == 'recipe_viewer';

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                isRecipeViewer ? "You've been invited to view recipes from" : "You've been invited to join",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(name, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              if (!isRecipeViewer && features.isNotEmpty) ...[
                Text('Features', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final key in features)
                      Chip(
                        avatar: Icon(_featureFor(key).icon, size: 18),
                        label: Text(_featureFor(key).label),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
              if (!isRecipeViewer) ...[
                Text('Members (${members.length})', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final m in members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text((m['username'] ?? 'Member').toString()),
                    trailing: (m['role'] == 'admin') ? const Text('admin') : null,
                  ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: _joining ? null : _join,
              child: _joining
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(alreadyMember
                      ? (isRecipeViewer ? 'Open recipes' : 'Open group')
                      : (isRecipeViewer ? 'View recipes' : 'Join group')),
            ),
          ),
        ),
      ],
    );
  }

  FeatureSpec _featureFor(String key) {
    return kOnboardingFeatures.firstWhere(
      (f) => f.key == key,
      orElse: () => FeatureSpec(key, Icons.widgets, key, true),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 40),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
