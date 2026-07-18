import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ai/ai_access.dart';
import 'package:couple_planner/features/settings/pages/language_page.dart';
import 'package:couple_planner/features/settings/recipe_suggestion_notifier.dart';
import 'package:couple_planner/features/settings/ai_feature_settings.dart';
import 'package:couple_planner/features/settings/notification_feature_settings.dart';

// GitHub Pages (see /docs).
const String _homeUrl = 'https://equirinya.github.io/together_planner/';
const String _privacyUrl = 'https://equirinya.github.io/together_planner/privacy.html';
const String _termsUrl = 'https://equirinya.github.io/together_planner/terms.html';
const String _contactEmail = 'equirinya@gmail.com';

/// General app settings hub: about and links. More settings to be added later.
/// (Group switching/management lives in the group overview.)
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.access});

  /// The user's current AI entitlement. Each AI toggle below is only shown
  /// when the matching feature is actually unlocked for this user — a toggle
  /// for a feature they can't use anyway is just confusing clutter.
  final AiAccess access;

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final showMealPlanner = access.canUseMealPlanner;
    final showSearchIdeas = access.canUseSearchIdeas;
    final showGeneration = access.canEnhanceText || access.canGenerateImage;
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
          const Divider(),
          _SectionHeader('AI features'),
          if (showMealPlanner)
            ValueListenableBuilder<bool>(
              valueListenable: AiFeatureSettings.mealPlannerEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: Icon(MdiIcons.chefHat),
                title: const Text('Smart meal planner'),
                subtitle: const Text('Show the AI meal-planning entry points on the recipe page'),
                value: enabled,
                onChanged: AiFeatureSettings.setMealPlannerEnabled,
              ),
            ),
          if (showSearchIdeas)
            ValueListenableBuilder<bool>(
              valueListenable: AiFeatureSettings.searchIdeasEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: const Icon(Icons.tips_and_updates_outlined),
                title: const Text('AI suggestions in search'),
                subtitle: const Text('Show AI-generated recipe ideas while searching'),
                value: enabled,
                onChanged: AiFeatureSettings.setSearchIdeasEnabled,
              ),
            ),
          if (showGeneration)
            ValueListenableBuilder<bool>(
              valueListenable: AiFeatureSettings.generationEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                secondary: const Icon(Icons.auto_fix_high_outlined),
                title: const Text('AI generation'),
                subtitle: const Text('Show buttons that generate or enhance content with AI'),
                value: enabled,
                onChanged: AiFeatureSettings.setGenerationEnabled,
              ),
            ),
          const _RecipeSuggestionToggle(),
          const Divider(),
          _SectionHeader('Notifications'),
          ...NotificationFeatureSettings.buildTiles(),
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

class _RecipeSuggestionToggle extends StatefulWidget {
  const _RecipeSuggestionToggle();

  @override
  State<_RecipeSuggestionToggle> createState() => _RecipeSuggestionToggleState();
}

class _RecipeSuggestionToggleState extends State<_RecipeSuggestionToggle> {
  static const _key = 'recipe_suggestions_enabled';
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _enabled = prefs.getBool(_key) ?? true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.restaurant_menu_outlined),
          title: const Text('Recipe suggestions'),
          subtitle: const Text('Show "Suggested for you" on the recipe page'),
          value: _enabled,
          onChanged: (v) async {
            setState(() => _enabled = v);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(_key, v);
            RecipeSuggestionNotifier.notify();
          },
        ),
        ListTile(
          enabled: _enabled,
          leading: const Icon(Icons.refresh),
          title: const Text('Reset dismissed recipe suggestions'),
          onTap: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('dismissed_public_recipes');
            RecipeSuggestionNotifier.notify();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Dismissed suggestions reset')),
              );
            }
          },
        ),
      ],
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
