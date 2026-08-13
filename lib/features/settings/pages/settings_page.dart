import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/push_token_service.dart';
import 'package:couple_planner/features/ai/ai_access.dart';
import 'package:couple_planner/features/recipes/widgets/suggested_row.dart'
    show kDismissedPrefsKey, kDismissedDayPrefsKey;
import 'package:couple_planner/features/settings/pages/language_page.dart';
import 'package:couple_planner/features/settings/pages/notification_info_page.dart';
import 'package:couple_planner/features/settings/recipe_suggestion_notifier.dart';
import 'package:couple_planner/features/settings/ai_feature_settings.dart';
import 'package:couple_planner/features/settings/recipe_feature_settings.dart';
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
          // Not under "AI features": Swipe to Plan draws its deck from recipes
          // that already exist, costs no generations, and is available on every
          // tier — so it's a plain preference, not an AI switch.
          ValueListenableBuilder<bool>(
            valueListenable: RecipeFeatureSettings.swipeToPlanEnabled,
            builder: (context, enabled, _) => SwitchListTile(
              secondary: Icon(MdiIcons.gestureSwipeHorizontal),
              title: const Text('Swipe to Plan'),
              subtitle: const Text(
                'Offer group recipe votes on the recipe page. A vote you\'re '
                'already part of stays visible either way.',
              ),
              value: enabled,
              onChanged: RecipeFeatureSettings.setSwipeToPlanEnabled,
            ),
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
          const _NotificationSection(),
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

/// The whole Notifications block: the OS permission state on top, the
/// per-category switches underneath.
///
/// Three states, driven by [PushTokenService.status]:
///
/// * **authorized / provisional** — nothing above the switches, they're the
///   whole story.
/// * **notDetermined** — a tile leading to [NotificationInfoPage], which is
///   what actually triggers the OS prompt. Without this the page was reachable
///   from exactly one place (the one-shot priming in main.dart, which only
///   fires for a user in a multi-member group who hasn't dismissed it), so
///   anyone outside that path could flip the switches all day and still never
///   have an FCM token registered.
/// * **denied** — the OS is blocking. Neither platform re-shows its prompt, so
///   instead of a dead "turn on" tile there's a banner explaining the state
///   with a button into the system settings, and the category switches are
///   greyed out: their values are still stored, but nothing can arrive while
///   the OS says no.
///
/// The status is re-read on resume because the trip into the system settings
/// leaves the app; without that the banner would linger after the user has
/// already flipped notifications back on.
class _NotificationSection extends StatefulWidget {
  const _NotificationSection();

  @override
  State<_NotificationSection> createState() => _NotificationSectionState();
}

class _NotificationSectionState extends State<_NotificationSection> with WidgetsBindingObserver {
  AuthorizationStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final status = await PushTokenService.status();
    if (mounted) setState(() => _status = status);
  }

  /// Permission may have been granted outside the app (system settings), in
  /// which case this device still has no token on the user profile. Registering
  /// here is idempotent — `arrayUnion` — so it's safe to call on every flip to
  /// authorized.
  Future<void> _refreshAndRegister() async {
    await _refresh();
    if (_status == AuthorizationStatus.authorized ||
        _status == AuthorizationStatus.provisional) {
      await PushTokenService.storeForCurrentUser();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;

    // Desktop builds have no push at all; don't advertise it there. Same while
    // the status is still being read — a banner that flashes in and out on
    // every visit is worse than a beat of nothing.
    final supported = Platform.isAndroid || Platform.isIOS;
    final blocked = supported && status == AuthorizationStatus.denied;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (supported && status != null) ...[
          if (blocked)
            _BlockedBanner(onReturned: _refreshAndRegister)
          else if (status != AuthorizationStatus.authorized &&
              status != AuthorizationStatus.provisional)
            _permissionTile(context),
        ],
        ...NotificationFeatureSettings.buildTiles(enabled: !blocked),
      ],
    );
  }

  Widget _permissionTile(BuildContext context) => ListTile(
        leading: Icon(
          Icons.notifications_active_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: const Text('Turn on notifications'),
        subtitle: const Text('Get notified when someone you plan with makes a change'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NotificationInfoPage()),
          );
          // The page registers the token itself; just re-read the status so the
          // tile disappears when permission was granted.
          await _refresh();
        },
      );
}

/// Shown in place of the "turn on notifications" tile when the OS is blocking.
///
/// The button can't ask for permission again — that prompt is spent — so it
/// hands off to the system settings instead. The copy deliberately says
/// "settings" rather than "notification settings": on iOS the OS only lets an
/// app open its own settings root, and the user has to tap Notifications there
/// themselves.
class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({required this.onReturned});

  /// Called after coming back from the settings app, to re-read the status.
  /// (The section also refreshes on resume; this covers the case where the
  /// settings screen never backgrounded the app.)
  final Future<void> Function() onReturned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_off_outlined, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Notifications are blocked',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        Platform.isIOS
                            ? 'Your device is blocking notifications for this app. '
                                'Open Settings, tap Notifications and allow them.'
                            : 'Your device is blocking notifications for this app. '
                                'Turn them on in the system settings.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  await PushTokenService.openNotificationSettings();
                  await onReturned();
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open settings'),
              ),
            ),
          ],
        ),
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
            // Both halves of the dismissal state must go: the cumulative
            // counts *and* the per-day record. The day map hides anything
            // dismissed today from the row outright, so clearing only the
            // counts would leave today's dismissals invisible and let much
            // deeper pool entries take their place on the row.
            await prefs.remove(kDismissedPrefsKey);
            await prefs.remove(kDismissedDayPrefsKey);
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
