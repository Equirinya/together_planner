import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/groups/invite_links.dart' as account;
import 'package:couple_planner/features/settings/pages/dietary_preferences_page.dart';
import 'package:couple_planner/features/settings/pages/language_page.dart';

// GitHub Pages (see /docs).
const String _homeUrl = 'https://equirinya.github.io/together_planner/';
const String _privacyUrl = 'https://equirinya.github.io/together_planner/privacy.html';
const String _termsUrl = 'https://equirinya.github.io/together_planner/terms.html';
const String _contactEmail = 'equirinya@gmail.com';

/// General app settings hub: about and links. More settings to be added later.
/// (Group switching/management lives in the group overview.)
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _deleteAccount(BuildContext context) async {
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
    if (confirmed != true || !context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await account.deleteAccount(deleteOwnedRecipes: deleteRecipes);
      await FirebaseAuth.instance.signOut();
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // dismiss the progress indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not delete your account.')),
      );
    } catch (_) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete your account.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 128),
        children: [
          _SectionHeader('Preferences'),
          ValueListenableBuilder<String>(
            valueListenable: LanguageService.instance.code,
            builder: (context, code, _) {
              final service = LanguageService.instance;
              final option = languageOptionFor(code);
              final name = option?.english ?? code;
              return ListTile(
                leading: const Icon(Icons.language_outlined),
                title: const Text('Language'),
                subtitle: Text(service.isFollowingDevice ? 'System default ($name)' : name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LanguagePage()),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.restaurant_outlined),
            title: const Text('Dietary preferences'),
            subtitle: const Text('Used when generating recipes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DietaryPreferencesPage()),
            ),
          ),
          const Divider(),
          _SectionHeader('Account'),
          ListTile(
            leading: const Padding(
              padding: EdgeInsets.only(left: 2),
              child: Icon(Icons.logout),
            ),
            title: const Text('Log out'),
            onTap: () async {
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
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete account'),
            onTap: () => _deleteAccount(context),
          ),
          const Divider(),
          _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Contact'),
            subtitle: const Text('Feedback, bug reports or feature requests'),
            onTap: () => _open('mailto:$_contactEmail'),
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Website'),
            onTap: () => _open(_homeUrl),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy Policy'),
            onTap: () => _open(_privacyUrl),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Terms & Conditions'),
            onTap: () => _open(_termsUrl),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('App information and licenses'),
            onTap: () async {
              final info = await PackageInfo.fromPlatform();
              if (context.mounted) {
                showAboutDialog(
                  context: context,
                  applicationIcon: Image.asset('assets/icon/icon_transparent.png', height: 64, width: 64),
                  applicationName: info.appName,
                  applicationVersion: info.version,
                  applicationLegalese: '© ${DateTime.now().year} Jacob Peters',
                );
              }
            },
          ),
        ],
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
