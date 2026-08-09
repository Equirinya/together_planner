import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/features/ai/ai_access.dart';
import 'package:couple_planner/features/ai/pages/ai_plan_page.dart';
import 'package:couple_planner/features/auth/widgets/auth_form.dart';
import 'package:couple_planner/features/groups/invite_links.dart' as account;

/// Profile & account management. Lets the user change the name others see and —
/// for the default anonymous accounts — upgrade to a real email + password
/// account so they can sign in on other devices. Also hosts the account actions
/// (log out, delete account) that used to live in App Settings.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _db = FirebaseFirestore.instance;

  final TextEditingController _nameCtrl = TextEditingController();
  String _initialName = '';
  bool _nameLoaded = false;
  bool _savingName = false;

  // AI-plan gating inputs (from the user doc + server-owned config/ai).
  DateTime? _createdAt;
  int _aiTier = AiAccess.defaultTier;
  int _anonMinAgeHours = 0;
  int _defaultNewUserTier = AiAccess.defaultTier;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadAiConfig();
    _nameCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  User? get _user => FirebaseAuth.instance.currentUser;

  bool get _isAnonymous => _user?.isAnonymous ?? true;

  Future<void> _loadProfile() async {
    final uid = _user?.uid;
    if (uid == null) return;
    try {
      final doc = await _db.collection('users').doc(uid).get();
      final data = doc.data() ?? const {};
      final name = (data['username'] ?? '').toString();
      final createdAt = data['createdAt'];
      final tier = data['aiTier'];
      if (mounted) {
        setState(() {
          _initialName = name;
          if (!_nameLoaded) _nameCtrl.text = name;
          _nameLoaded = true;
          if (createdAt is Timestamp) _createdAt = createdAt.toDate();
          if (tier is num) _aiTier = tier.toInt();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _nameLoaded = true);
    }
  }

  /// Reads the server-owned AI defaults used to decide whether to nudge a guest
  /// to upgrade before opening the AI plan. Best-effort: on failure the defaults
  /// stay put and the plan opens normally.
  Future<void> _loadAiConfig() async {
    try {
      final doc = await _db.collection('config').doc('ai').get();
      final data = doc.data() ?? const {};
      if (!mounted) return;
      setState(() {
        final minAge = data['anonymousAiMinAgeHours'];
        if (minAge is num) _anonMinAgeHours = minAge.toInt();
        final def = data['defaultNewUserTier'];
        if (def is num) _defaultNewUserTier = def.toInt();
      });
    } catch (_) {
      // Keep defaults; the plan page opens without a gate.
    }
  }

  bool get _nameChanged => _nameCtrl.text.trim() != _initialName.trim();
  bool get _nameValid => _nameCtrl.text.trim().length >= 3;

  Future<void> _saveName() async {
    final uid = _user?.uid;
    final name = _nameCtrl.text.trim();
    if (uid == null || !_nameValid) return;
    setState(() => _savingName = true);
    try {
      await _db.collection('users').doc(uid).update({'username': name});
      await _db.collection('users_public').doc(uid).set({
        'username': name,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _initialName = name;
      if (mounted) {
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name updated')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your name.')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _upgradeAccount() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _UpgradeSheet(),
    );
    if (ok == true && mounted) {
      setState(() {}); // reflect the now-permanent account
      await _loadProfile(); // pick up the bumped AI tier + cleared guest flag
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account secured. You can now sign in anywhere.')),
        );
      }
    }
  }

  /// A guest is nudged to upgrade before using AI when their account is still
  /// younger than the required minimum age, or when a full account would put
  /// them on a higher AI tier than their current guest tier.
  bool get _shouldPromptAiUpgrade {
    if (!_isAnonymous) return false;
    final tooYoung = _anonMinAgeHours > 0 &&
        (_createdAt == null ||
            DateTime.now().difference(_createdAt!) < Duration(hours: _anonMinAgeHours));
    final wouldProfit = _aiTier < _defaultNewUserTier;
    return tooYoung || wouldProfit;
  }

  void _openAiPlan() {
    if (_shouldPromptAiUpgrade) {
      _showAiUpgradePrompt();
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiPlanPage()));
    }
  }

  Future<void> _showAiUpgradePrompt() async {
    final upgrade = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock AI features'),
        content: const Text(
          'AI features are available on full accounts. Add an email and password '
          'to unlock them. Your groups and recipes stay exactly as they are.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add email & password')),
        ],
      ),
    );
    if (upgrade == true && mounted) await _upgradeAccount();
  }

  Future<void> _logOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Log out')),
        ],
      ),
    );
    if (confirmed == true) await FirebaseAuth.instance.signOut();
  }

  Future<void> _deleteAccount() async {
    var deleteRecipes = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Delete account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This happens immediately and cannot be undone. The following will be permanently deleted:'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: true,
                onChanged: (_) {},
                title: const Text('All data of your account'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: true,
                onChanged: (_) {},
                title: const Text('All groups where you are the last member'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteRecipes,
                onChanged: (v) => setState(() => deleteRecipes = v ?? false),
                title: const Text('Recipes you created in groups with other members'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep my account')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete forever'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await account.deleteAccount(deleteOwnedRecipes: deleteRecipes);
      await FirebaseAuth.instance.signOut();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss the progress indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not delete your account.')),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete your account.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = _user?.email;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          const _SectionHeader('The name other members of your groups see'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _nameCtrl,
              enabled: _nameLoaded && !_savingName,
              maxLength: 127,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.person_outline),
                hintText: 'Name',
                errorText: (_nameCtrl.text.isNotEmpty && !_nameValid)
                    ? 'At least 3 characters'
                    : null,
                suffixIcon: _nameChanged && _nameValid
                    ? (_savingName
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            icon: const Icon(Icons.save_outlined),
                            tooltip: 'Save',
                            onPressed: _saveName,
                          ))
                    : null,
              ),
              onSubmitted: (_) {
                if (_nameChanged && _nameValid) _saveName();
              },
            ),
          ),
          const Divider(height: 32),

          // ── AI ──────────────────────────────────────────────────────────
          if (_aiTier != 0) ...[
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('AI plan'),
              subtitle: _isAnonymous && _shouldPromptAiUpgrade
                  ? const Text('Add an email & password to use AI')
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: _openAiPlan,
            ),
            const Divider(height: 32),
          ],

          // ── Account type ────────────────────────────────────────────────
          const _SectionHeader('Account'),
          if (_isAnonymous) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "You're using a guest account",
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Add an email and password so you can sign in on other '
                      'devices and never lose your groups and recipes.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _upgradeAccount,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Add email & password'),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Email'),
              subtitle: Text(email ?? 'Signed in'),
            ),
            ListTile(
              leading: const Padding(
                padding: EdgeInsets.only(left: 2),
                child: Icon(Icons.logout),
              ),
              title: const Text('Log out'),
              onTap: _logOut,
            ),
          ],
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: _deleteAccount,
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet that links an email + password credential onto the current
/// (anonymous) account, turning it into a permanent one with the same uid.
class _UpgradeSheet extends StatefulWidget {
  const _UpgradeSheet();

  @override
  State<_UpgradeSheet> createState() => _UpgradeSheetState();
}

class _UpgradeSheetState extends State<_UpgradeSheet> {
  /// Links the entered credential onto the current anonymous user, keeping the
  /// same uid. Returns `null` on success or a user-facing error message.
  Future<String?> _link(String email, String password) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'Please restart the app and try again.';
    try {
      final cred = EmailAuthProvider.credential(email: email, password: password);
      await user.linkWithCredential(cred);
      // The credential is now linked, so the account is no longer anonymous.
      // Ask the backend to clear the guest flag and raise the AI tier to the
      // full-user default (best-effort — linking already succeeded).
      try {
        await account.upgradeAnonymousAccount();
      } catch (_) {}
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'email-already-in-use':
        case 'credential-already-in-use':
          return 'An account with this email already exists.';
        case 'weak-password':
          return 'That password is too weak.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'requires-recent-login':
          return 'Please restart the app and try again.';
        case 'network-request-failed':
          return "You're not connected to the internet.";
        default:
          return 'Could not add your email. Please try again.';
      }
    } catch (_) {
      return 'An unknown error occurred.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      child: AuthForm(
        mode: AuthFormMode.register,
        title: 'Add email & password',
        subtitle: 'Keep your same account and data:\nJust add a way to sign back in.',
        submitText: 'Save',
        padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottomInset),
        onSubmit: _link,
        onSuccess: () {
          if (mounted) Navigator.of(context).pop(true);
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
