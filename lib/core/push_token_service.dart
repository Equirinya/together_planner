import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Everything to do with getting this device's FCM token onto
/// `users/{uid}.fcmTokens`, in one place so every entry point that can end up
/// granting notification permission stores the token the same way.
///
/// The field is an **array** of tokens, one per device: a single `fcmToken`
/// field silently dropped notifications for every device except the most
/// recently registered one. Dead tokens are pruned server-side on send (see
/// firebase/functions/src/lib/push.ts), so nothing expires them here.
class PushTokenService {
  PushTokenService._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// True when the OS has granted (or provisionally granted) notifications.
  /// Never prompts.
  static Future<bool> isAuthorized() async {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (error) {
      if (kDebugMode) print('getNotificationSettings failed: $error');
      return false;
    }
  }

  /// The current OS authorization status, or null if it can't be read.
  static Future<AuthorizationStatus?> status() async {
    try {
      return (await FirebaseMessaging.instance.getNotificationSettings()).authorizationStatus;
    } catch (error) {
      if (kDebugMode) print('getNotificationSettings failed: $error');
      return null;
    }
  }

  /// True when the OS prompt has already been answered with "Don't allow", or
  /// notifications were switched off for the app in the system settings.
  ///
  /// Neither platform shows its prompt a second time in that state, so the only
  /// way back is [openNotificationSettings].
  ///
  /// Caveat on Android 13+: a dismissed (rather than declined) prompt also
  /// reports `denied`, so this is only meaningful once the app has actually
  /// asked at least once.
  static Future<bool> isBlocked() async => (await status()) == AuthorizationStatus.denied;

  /// Sends the user to the OS notification settings for this app.
  ///
  /// Android opens `ACTION_APP_NOTIFICATION_SETTINGS` — the app's notification
  /// screen itself. iOS only exposes `UIApplication.openSettingsURLString`, so
  /// it lands on the app's settings root and the user taps through to
  /// "Notifications" from there; the `App-Prefs:` deep link is private API and
  /// fails review. Copy shown next to a button calling this should therefore
  /// not promise to open the notification page specifically.
  static Future<void> openNotificationSettings() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    } catch (error) {
      if (kDebugMode) print('openAppSettings failed: $error');
    }
  }

  /// Reads the FCM token, waiting for APNs registration first on iOS.
  ///
  /// On iOS `getToken()` throws `apns-token-not-set` until the device has
  /// finished registering with APNs, which is frequently still in flight in the
  /// moment right after the user taps "Allow". Because `onTokenRefresh` only
  /// fires on *rotation* and never for the initial token, a throw here used to
  /// mean the token was lost for good and `fcmTokens` stayed empty forever.
  ///
  /// So: poll [FirebaseMessaging.getAPNSToken] briefly first, then retry the
  /// fetch itself a few times. A null APNs token after the timeout isn't
  /// treated as fatal — it falls through to the attempt, which surfaces the
  /// real error. A persistent `apns-token-not-set` in the log almost always
  /// means no APNs auth key is uploaded in the Firebase console, or the build
  /// is signed with a profile lacking the push capability.
  static Future<String?> fetchToken() async {
    if (Platform.isIOS) {
      for (var i = 0; i < 20; i++) {
        try {
          if (await FirebaseMessaging.instance.getAPNSToken() != null) break;
        } catch (_) {
          // Keep waiting; the retry loop below reports a persistent failure.
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) return token;
      } catch (error) {
        lastError = error;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    if (kDebugMode) print('getToken() returned nothing after retries: $lastError');
    return null;
  }

  /// Adds [token] to `users/{uid}.fcmTokens`.
  static Future<void> register(String uid, String token) async {
    try {
      await _db.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
    } catch (error) {
      if (kDebugMode) print('Failed to register FCM token: $error');
    }
  }

  /// Fetches this device's token and mirrors it onto the user document.
  /// Assumes permission has been granted. No-op while signed out.
  ///
  /// Safe to call repeatedly: `arrayUnion` is idempotent.
  static Future<void> storeForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final token = await fetchToken();
    if (token == null) return;
    await register(uid, token);
  }
}
