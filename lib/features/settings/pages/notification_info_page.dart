import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/push_token_service.dart';
import 'package:couple_planner/features/settings/notification_feature_settings.dart';

/// Explains what group notifications are good for, lets the user pre-configure
/// which categories they care about, and — via a big call-to-action at the
/// bottom — triggers the OS permission prompt.
///
/// Registers this device's FCM token itself once permission is granted, so
/// every entry point (the one-shot priming from main.dart, and the Notifications
/// tile in App Settings) ends up with a token on `users/{uid}.fcmTokens` without
/// having to remember to do it. `arrayUnion` makes a second call harmless.
///
/// Pops with `true` once notifications end up authorized (or provisionally
/// authorized). Pops with `false`/`null` if the user backs out or the OS prompt
/// is declined.
///
/// Note the OS only shows its prompt once per install. If the status is already
/// `denied`, the button here can't do anything — hence [_deniedNotice], which
/// points the user at the system settings instead.
class NotificationInfoPage extends StatefulWidget {
  const NotificationInfoPage({super.key});

  @override
  State<NotificationInfoPage> createState() => _NotificationInfoPageState();
}

class _NotificationInfoPageState extends State<NotificationInfoPage> with WidgetsBindingObserver {
  bool _busy = false;

  /// True when the OS prompt has already been answered with "Don't allow".
  /// Asking again is a no-op at that point, so the CTA is swapped for a note.
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The "Open settings" button in [_deniedNotice] leaves the app, so the
  /// status has to be re-read on the way back — otherwise the notice stays up
  /// after the user has already allowed notifications.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkStatus();
  }

  Future<void> _checkStatus() async {
    final status = await PushTokenService.status();
    if (!mounted) return;
    final granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
    // Permission may have been granted in the system settings rather than
    // through the prompt below; that's still the moment the token first
    // becomes obtainable, so register it here too.
    if (granted) await PushTokenService.storeForCurrentUser();
    if (!mounted) return;
    setState(() => _denied = status == AuthorizationStatus.denied);
  }

  Future<void> _requestPermission() async {
    if (_busy) return;
    setState(() => _busy = true);
    AuthorizationStatus status = AuthorizationStatus.denied;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      status = settings.authorizationStatus;
    } catch (_) {
      // Fall through — treated as not granted.
    }
    final granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;

    // Register before popping: this is the moment the token first becomes
    // obtainable, and onTokenRefresh never fires for the initial token.
    if (granted) await PushTokenService.storeForCurrentUser();

    if (!mounted) return;
    Navigator.of(context).pop(granted);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Stay in the loop')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              children: [
                const SizedBox(height: 8),
                CircleAvatar(
                  radius: 40,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.notifications_active_outlined,
                      size: 40, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(height: 20),
                Text(
                  'Never miss what happens in your group',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  'Now that you share a group, we can let you know when the '
                  'people you plan with make changes — like adding a recipe, '
                  'updating the shopping list, or setting a reminder. Pick what '
                  'you want to hear about below; you can change these any time '
                  'in Settings.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: NotificationFeatureSettings.buildTiles(enabled: !_denied),
                  ),
                ),
              ],
            ),
          ),
          // ── the big, engaging call-to-action → OS permission prompt ──────────
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: _denied
                  ? _deniedNotice(scheme)
                  : SizedBox(
                      width: double.infinity,
                      height: 68,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _requestPermission,
                        icon: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Icon(Icons.favorite, size: 24),
                        label: const Text(
                          'Yes, keep me in the loop!',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shown instead of the CTA when the OS prompt was already declined. iOS and
  /// Android both refuse to show it a second time, so the only route back is
  /// the system settings app — hence the button rather than just a note.
  ///
  /// On iOS the button can only land on the app's settings root (Apple has no
  /// public deep link to the notification sub-page), so the copy names the
  /// extra tap.
  Widget _deniedNotice(ColorScheme scheme) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
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
                  child: Text(
                    Platform.isIOS
                        ? 'Notifications are turned off for this app. Open '
                            'Settings, tap Notifications and allow them — then '
                            'come back here.'
                        : 'Notifications are turned off for this app. Turn them '
                            'on in your device settings, then come back here.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: PushTokenService.openNotificationSettings,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open settings'),
              ),
            ),
          ],
        ),
      );
}
