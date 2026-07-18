import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-category push notification opt-outs.
///
/// The **source of truth is the Firestore user profile** (`users/{uid}`, field
/// [kFirestoreField]) so Cloud Functions can honour these when deciding whether
/// to send a push. SharedPreferences is kept purely as a local cache so the
/// first frame already shows the right switch positions before the profile has
/// been read, and so toggling still works offline (Firestore's own offline
/// queue replays the write when connectivity returns).
///
/// Named `NotificationFeatureSettings` rather than `NotificationSettings` to
/// avoid clashing with `firebase_messaging`'s own `NotificationSettings` type
/// (the return value of `getNotificationSettings()` / `requestPermission()`),
/// which is imported alongside this file in several places.
///
/// The individual toggle tiles are produced by [buildTiles] so the exact same
/// list can be dropped into both the App Settings page and the notification
/// info/priming page. New categories can be added here later without touching
/// either of those call sites.
class NotificationFeatureSettings {
  NotificationFeatureSettings._();

  /// Field on `users/{uid}` holding the switches. Read this server-side before
  /// sending a push; a missing field or key means the user is opted in.
  static const kFirestoreField = 'notificationPrefs';

  // Keys inside the Firestore map.
  static const _fShoppingList = 'shoppingList';
  static const _fReminders = 'reminders';

  // Local cache keys (SharedPreferences).
  static const _kShoppingListKey = 'notif_shopping_list_enabled';
  static const _kRemindersKey = 'notif_reminders_enabled';

  /// Items were added to or checked off the shared shopping list.
  static final ValueNotifier<bool> shoppingListEnabled = ValueNotifier<bool>(true);

  /// Chores and to-dos: assignments, due dates and reminders.
  static final ValueNotifier<bool> remindersEnabled = ValueNotifier<bool>(true);

  /// Loads the locally cached values and publishes them. Call before runApp so
  /// the first frame already reflects the stored choice; [syncFromUserDoc] then
  /// reconciles against the profile once it's read.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    shoppingListEnabled.value = prefs.getBool(_kShoppingListKey) ?? true;
    remindersEnabled.value = prefs.getBool(_kRemindersKey) ?? true;
  }

  /// Adopts the values stored on the user profile (the source of truth), called
  /// whenever the user document is read. If the profile has no
  /// [kFirestoreField] yet — existing accounts, or a fresh sign-up — the current
  /// local values are backfilled to Firestore so the backend always has
  /// something to read.
  static Future<void> syncFromUserDoc(Map<String, dynamic>? data) async {
    final raw = data?[kFirestoreField];
    if (raw is! Map) {
      await _pushToFirestore();
      return;
    }
    shoppingListEnabled.value = raw[_fShoppingList] as bool? ?? true;
    remindersEnabled.value = raw[_fReminders] as bool? ?? true;
    await _cacheLocally();
  }

  /// The switches as stored on the user profile.
  static Map<String, dynamic> toMap() => <String, dynamic>{
        _fShoppingList: shoppingListEnabled.value,
        _fReminders: remindersEnabled.value,
      };

  static Future<void> setShoppingListEnabled(bool value) async {
    shoppingListEnabled.value = value;
    await _persist();
  }

  static Future<void> setRemindersEnabled(bool value) async {
    remindersEnabled.value = value;
    await _persist();
  }

  static Future<void> _persist() async {
    await _cacheLocally();
    await _pushToFirestore();
  }

  static Future<void> _cacheLocally() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShoppingListKey, shoppingListEnabled.value);
    await prefs.setBool(_kRemindersKey, remindersEnabled.value);
  }

  /// Mirrors the whole map onto the user profile. No-op while signed out; the
  /// next [syncFromUserDoc] after sign-in backfills it.
  static Future<void> _pushToFirestore() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .update({kFirestoreField: toMap()}).catchError((_) {});
  }

  /// The reusable list of on/off tiles, shown both in App Settings and on the
  /// notification info page. Add future notification categories here once and
  /// they appear in both places.
  static List<Widget> buildTiles() {
    return [
      _NotificationToggleTile(
        icon: Icons.shopping_bag_outlined,
        title: 'Shopping list',
        subtitle: 'When items are added to or checked off the shared list',
        notifier: shoppingListEnabled,
        onChanged: setShoppingListEnabled,
      ),
      _NotificationToggleTile(
        icon: Icons.checklist_outlined,
        title: 'Chores & to-do reminders',
        subtitle: 'When a chore or to-do is assigned to you or falls due',
        notifier: remindersEnabled,
        onChanged: setRemindersEnabled,
      ),
    ];
  }
}

/// A single notification-category switch, driven by one of the
/// [NotificationFeatureSettings] notifiers.
class _NotificationToggleTile extends StatelessWidget {
  const _NotificationToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.notifier,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final ValueNotifier<bool> notifier;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, enabled, _) => SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        value: enabled,
        onChanged: onChanged,
      ),
    );
  }
}
