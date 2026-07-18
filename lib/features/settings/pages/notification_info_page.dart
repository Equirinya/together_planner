import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/features/settings/notification_feature_settings.dart';

/// Explains what group notifications are good for, lets the user pre-configure
/// which categories they care about, and — via a big call-to-action at the
/// bottom — triggers the OS permission prompt.
///
/// Pops with `true` once notifications end up authorized (or provisionally
/// authorized), so the caller can fetch and store the FCM token. Pops with
/// `false`/`null` if the user backs out or the OS prompt is declined.
class NotificationInfoPage extends StatefulWidget {
  const NotificationInfoPage({super.key});

  @override
  State<NotificationInfoPage> createState() => _NotificationInfoPageState();
}

class _NotificationInfoPageState extends State<NotificationInfoPage> {
  bool _busy = false;

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
    if (!mounted) return;
    final granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
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
                    children: NotificationFeatureSettings.buildTiles(),
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
              child: SizedBox(
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
}
