// Siri / Shortcuts / Spotlight bridge (iOS only).
//
// The Swift half lives in `ios/Runner/AppDelegate.swift`: Apple requires every
// AppIntent to be a concrete type in the main app target, discovered at compile
// time, so it cannot be declared from Dart. Those structs do nothing except
// push a payload string across to here (or, for the "what's planned" query,
// answer straight from the entity store without waking the app at all).
//
// Two directions of traffic:
//
//   Swift → Dart   `Intelligence().selectionsStream()` delivers the payload an
//                  intent pushed. Payloads are the `k*Payload` strings below.
//
//   Dart → Swift   [syncPlannedRecipes] mirrors the group's upcoming cooking
//                  plan into the plugin's entity store via `populate`. That
//                  store is what backs the `PlannedRecipeEntity` query — so
//                  Siri can resolve "open the lasagne" — and what
//                  `NextRecipesIntent` reads to answer without a Flutter engine.
//
// Nothing here is Android-aware: `intelligence` is an iOS-only plugin and every
// entry point no-ops elsewhere.

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intelligence/intelligence.dart';
import 'package:intelligence/model/representable.dart';

import 'package:couple_planner/core/language.dart';

/// Add free text to the shopping list. Suffix is the spoken item, so the whole
/// payload reads `shopping:2 litres milk`.
const String kShoppingPayloadPrefix = 'shopping:';

/// Open a specific planned meal. Suffix is the `cooking_plan` document id.
/// Entity ids handed to [Intelligence.populate] use this prefix too, so a
/// selection arrives already routable.
const String kPlanPayloadPrefix = 'plan:';

/// Open the recipes tab (which is where the plan is shown).
const String kOpenRecipesPayload = 'open:recipes';

/// Open the shopping list tab.
const String kOpenShoppingPayload = 'open:shopping';

/// How far ahead [syncPlannedRecipes] publishes planned meals.
const int _kPlanHorizonDays = 14;

/// The most entities to publish. Siri's disambiguation list and the spoken
/// answer both get unwieldy past a handful, and the store is rewritten whole
/// on every change.
const int _kMaxPublishedPlans = 10;

typedef SiriPayloadHandler = Future<void> Function(String payload);

class SiriService {
  SiriService._();
  static final SiriService instance = SiriService._();

  final Intelligence _intelligence = Intelligence();

  StreamSubscription<String>? _selectionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _planSub;

  SiriPayloadHandler? _handler;

  /// A payload that arrived before [setHandler] — i.e. the intent is what
  /// launched the app, and Dart got the string before the widget tree could
  /// act on it. Replayed once a handler registers. Only the most recent is
  /// kept; a user firing two intents into a cold start wants the second.
  String? _pendingPayload;

  /// The group whose plan is currently mirrored, so a redundant resubscribe is
  /// cheap to skip.
  String? _publishedGroupId;

  bool get _supported => Platform.isIOS;

  // ── incoming: Swift → Dart ────────────────────────────────────────────────

  /// Subscribes to intent payloads. Safe to call before the app has a group or
  /// a signed-in user — payloads are buffered until [setHandler] is called.
  void start() {
    if (!_supported || _selectionSub != null) return;
    _selectionSub = _intelligence.selectionsStream().listen(
      _dispatch,
      onError: (Object e) => debugPrint('Siri selection stream error: $e'),
    );
  }

  /// Registers the handler that acts on a payload, and immediately replays a
  /// payload that arrived beforehand.
  void setHandler(SiriPayloadHandler handler) {
    _handler = handler;
    final pending = _pendingPayload;
    if (pending == null) return;
    _pendingPayload = null;
    _dispatch(pending);
  }

  void _dispatch(String payload) {
    final handler = _handler;
    if (handler == null) {
      _pendingPayload = payload;
      return;
    }
    handler(payload).catchError(
      (Object e) => debugPrint('Siri payload "$payload" failed: $e'),
    );
  }

  // ── outgoing: Dart → Swift ────────────────────────────────────────────────

  /// Mirrors [groupId]'s upcoming cooking plan into the OS entity store and
  /// keeps it in sync. Call whenever the active group changes; pass null on
  /// sign-out or when no group is selected, which clears the store so a
  /// previous account's meals can't be read back by an intent.
  void syncPlannedRecipes(String? groupId) {
    if (!_supported) return;
    if (groupId == _publishedGroupId) return;

    _planSub?.cancel();
    _planSub = null;
    _publishedGroupId = groupId;

    if (groupId == null) {
      _publish(const []);
      return;
    }

    final group = FirebaseFirestore.instance.collection('groups').doc(groupId);
    // From the start of today rather than `now`, so a meal planned for this
    // evening doesn't drop off the moment the app is opened after it.
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);

    _planSub = group
        .collection('cooking_plan')
        .where('plannedFor', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('plannedFor',
            isLessThan: Timestamp.fromDate(
                from.add(const Duration(days: _kPlanHorizonDays))))
        .orderBy('plannedFor')
        .limit(_kMaxPublishedPlans)
        .snapshots()
        .listen(
      (snap) => _publishFromPlans(group, snap.docs),
      onError: (Object e) => debugPrint('Siri plan listener error: $e'),
    );
  }

  /// Resolves each plan's recipe name and publishes the result. Recipes are
  /// fetched individually because a plan holds only the recipe id; the reads
  /// are cheap and almost always served from Firestore's offline cache, which
  /// the recipes tab has already warmed.
  Future<void> _publishFromPlans(
    DocumentReference<Map<String, dynamic>> group,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
  ) async {
    final items = <Representable>[];
    final lang = LanguageService.instance.code.value;

    for (final plan in plans) {
      final recipeId = plan.data()['recipe'];
      final when = (plan.data()['plannedFor'] as Timestamp?)?.toDate();
      if (recipeId is! String || recipeId.isEmpty || when == null) continue;

      String name;
      try {
        final recipe = await group.collection('recipes').doc(recipeId).get();
        name = (recipe.data()?['name'] ?? '').toString().trim();
      } catch (_) {
        continue; // unreadable (deleted, or offline with a cold cache)
      }
      if (name.isEmpty) continue; // still generating — no name to speak yet

      items.add(Representable(
        id: '$kPlanPayloadPrefix${plan.id}',
        representation: '$name · ${_dayLabel(when, lang)}',
      ));
    }

    await _publish(items);
  }

  Future<void> _publish(List<Representable> items) async {
    try {
      await _intelligence.populate(items);
    } catch (e) {
      debugPrint('Siri populate failed: $e');
    }
  }

  /// Weekday names and the two relative labels, for the languages the Siri
  /// integration is localised into. Anything else falls back to English.
  ///
  /// These live here rather than in Localizable.xcstrings because they are
  /// baked into the entity `representation` at publish time, in Dart — by the
  /// time Swift reads the store, the string is already formed.
  static const Map<String, ({String today, String tomorrow, List<String> weekdays})>
      _dayNames = {
    'en': (
      today: 'today',
      tomorrow: 'tomorrow',
      weekdays: [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday',
        'Friday', 'Saturday', 'Sunday',
      ],
    ),
    'de': (
      today: 'heute',
      tomorrow: 'morgen',
      weekdays: [
        'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
        'Freitag', 'Samstag', 'Sonntag',
      ],
    ),
    'es': (
      today: 'hoy',
      tomorrow: 'mañana',
      weekdays: [
        'lunes', 'martes', 'miércoles', 'jueves',
        'viernes', 'sábado', 'domingo',
      ],
    ),
  };

  /// A short, spoken-friendly day label in [lang].
  ///
  /// Note this follows the *app's* language, not Siri's. It has to: the label
  /// is written into the entity store whenever the plan changes, long before
  /// anyone speaks, so Siri's language isn't knowable yet. A user with German
  /// Siri and the app in English will hear an English day word inside an
  /// otherwise German sentence. The alternative — publishing every language and
  /// picking in Swift — costs three entity stores to spare a single word, and
  /// the two settings agree for almost everyone.
  static String _dayLabel(DateTime date, String lang) {
    final names = _dayNames[lang] ?? _dayNames['en']!;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days =
        DateTime(date.year, date.month, date.day).difference(today).inDays;
    if (days == 0) return names.today;
    if (days == 1) return names.tomorrow;
    if (days < 7) return names.weekdays[date.weekday - 1];
    return '${date.day}/${date.month}';
  }

  // ── teardown ──────────────────────────────────────────────────────────────

  /// Drops the published entities and stops listening. Call on sign-out.
  Future<void> clear() async {
    _planSub?.cancel();
    _planSub = null;
    _publishedGroupId = null;
    if (_supported) await _publish(const []);
  }

  /// Detaches everything. [_publishedGroupId] is reset too, so the plan
  /// listener is rebuilt rather than skipped when the widget tree comes back
  /// (RestartWidget disposes and recreates the host state).
  void dispose() {
    _selectionSub?.cancel();
    _selectionSub = null;
    _planSub?.cancel();
    _planSub = null;
    _publishedGroupId = null;
    _handler = null;
  }
}
