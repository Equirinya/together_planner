import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_material_design_icons/flutter_material_design_icons.dart';

import 'package:couple_planner/core/date_utils.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/pages/meal_plan_shopping_list_page.dart';
import 'package:couple_planner/features/recipes/pages/swipe_to_plan_flow.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';
import 'package:couple_planner/features/recipes/services/swipe_session_service.dart';
import 'package:couple_planner/features/recipes/widgets/meal_plan_mesh.dart';
import 'package:couple_planner/features/recipes/widgets/meal_plan_widgets.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_preview_sheet.dart';
import 'package:couple_planner/features/settings/dietary_preferences.dart';
import 'package:couple_planner/features/ai/ai_access.dart';

/// Style presets a meal plan can be steered by, on top of dietary
/// preferences. Deliberately overlaps the themes the public-recipe corpus is
/// already seeded with (see firebase/functions/src/recipes.ts
/// dailyPublicRecipes) so style-based candidate search actually finds
/// matches. Duplicated (not shared) between Dart and TypeScript, matching how
/// STANDARD_DIETS/kDietaryOptions already work in this codebase.
const List<String> kMealPlanStyles = [
  'Quick & Easy',
  'High Protein',
  'Comfort Food',
  'Budget-Friendly',
  'One-Pot / Low Effort',
  'Meal-Prep Friendly',
];

const Map<String, IconData> _kStyleIcons = {
  'Quick & Easy': Icons.bolt,
  'High Protein': Icons.fitness_center,
  'Comfort Food': Icons.ramen_dining,
  'Budget-Friendly': Icons.savings_outlined,
  'One-Pot / Low Effort': Icons.soup_kitchen_outlined,
  'Meal-Prep Friendly': Icons.kitchen_outlined,
};

const String _kPrefDays = 'meal_plan_last_days';
const String _kPrefPeople = 'meal_plan_last_people';
const String _kPrefStyles = 'meal_plan_last_styles';
const String _kPrefNotes = 'meal_plan_last_notes';

/// Whether the last AI plan asked for the complementary side recipe. Defaults
/// to on, matching the behaviour from before the switch existed.
const String _kPrefExtra = 'meal_plan_last_extra';

/// Whether the last swipe session let public recipes into the deck. Defaults to
/// on, matching the behaviour from before the switch existed.
const String _kPrefSwipePublic = 'swipe_last_include_public';

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const String _kPrefPlanCache = 'meal_plan_proposal_cache';

/// Serializes a [MealPlanSlot] for [_kPrefPlanCache], mirroring the shape
/// [MealPlanSlot.fromJson] already expects from the server plus its own
/// [MealPlanSlot.date], [MealPlanSlot.removed] and [MealPlanSlot.isExtra]
/// (none of which the server response carries, since those come from the
/// client's request/UI).
Map<String, dynamic> _slotToJson(MealPlanSlot s) => {
      'date': _dateKey(s.date),
      'source': switch (s.source) {
        MealPlanSource.own => 'own',
        MealPlanSource.public => 'public',
        MealPlanSource.newIdea => 'new',
      },
      'recipeId': s.recipeId,
      'publicRecipeId': s.publicRecipeId,
      'image': s.publicImage,
      'name': s.name,
      'description': s.description,
      'reason': s.reason,
      'dietary': s.dietary,
      'removed': s.removed,
      // Without this the extra comes back as an ordinary day slot and, since it
      // shares a date with that day's main, silently replaces it.
      'isExtra': s.isExtra,
    };

MealPlanSlot? _slotFromJson(Map<String, dynamic> json) {
  final dateStr = json['date'] as String?;
  if (dateStr == null) return null;
  final parts = dateStr.split('-').map(int.parse).toList();
  final slot = MealPlanSlot.fromJson(DateTime(parts[0], parts[1], parts[2]), json);
  slot.removed = json['removed'] == true;
  slot.isExtra = json['isExtra'] == true;
  return slot;
}

// ─── Settings step ──────────────────────────────────────────────────────────

/// Which flow [MealPlanSettingsPage] is configuring.
///
/// The two share this page rather than forking it, because days/people/dietary
/// mean exactly the same thing in both. What differs is what the answers are
/// used for, and that changes which controls make sense — see
/// [_MealPlanSettingsPageState.build].
enum MealPlanMode {
  /// Smart Meal Planner: the answers steer an AI prompt.
  ai,

  /// Swipe to Plan: the answers filter and size a deck the group votes on.
  swipe,
}

/// First step of both planning flows: lets the user set how many days/people to
/// plan for plus dietary preferences, then either generates an AI proposal on
/// [MealPlanOverviewPage] or opens a [SwipeToPlanFlow] session.
class MealPlanSettingsPage extends StatefulWidget {
  const MealPlanSettingsPage({
    super.key,
    required this.groupId,
    required this.groupDoc,
    required this.startDate,
    required this.maxDays,
    required this.access,
    this.mode = MealPlanMode.ai,
  });

  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final DateTime startDate;
  final int maxDays;
  final AiAccess access;
  final MealPlanMode mode;

  @override
  State<MealPlanSettingsPage> createState() => _MealPlanSettingsPageState();
}

class _MealPlanSettingsPageState extends State<MealPlanSettingsPage> {
  bool _loading = true;
  late int _days;
  int _people = 2;
  List<String> _dietary = [];
  final Set<String> _styles = {};
  final TextEditingController _notesCtrl = TextEditingController();

  /// AI mode only: whether to also ask for the complementary "Additionally?"
  /// side recipe. Restored from [_kPrefExtra], so the choice sticks between
  /// plans — someone who never wants a dessert alongside their week shouldn't
  /// have to turn it off every time.
  bool _wantExtra = true;

  /// Swipe mode only: whether public recipes may supplement the group's own in
  /// the deck. Restored from [_kPrefSwipePublic], so a group that only ever
  /// wants to vote on recipes it already owns doesn't have to say so every
  /// time. Absolute: turning it off means a shorter deck, never a quietly
  /// padded one — see [_thinCollectionNotice], which warns when that would
  /// leave too little to swipe on.
  bool _includePublic = true;

  /// Swipe mode only: how many recipes the group owns, loaded in [_load] as a
  /// count aggregation rather than a document read. Only used to warn when
  /// turning public recipes off would leave too few cards to swipe on — see
  /// [_thinCollectionNotice]. Null until loaded, which suppresses the warning
  /// rather than guessing.
  int? _ownRecipeCount;

  bool get _isSwipe => widget.mode == MealPlanMode.swipe;

  /// The warning to show on the public-recipes switch, or null when there is
  /// nothing to warn about: the group's own recipes can't fill the deck [_days]
  /// asks for, and public recipes aren't allowed to make up the difference.
  ///
  /// A getter rather than cached state, so it re-evaluates on every build —
  /// changing the day count or flipping the switch updates it immediately.
  ///
  /// Deliberately compares against the *total* recipe count: the server also
  /// drops recipes cooked in the last week or already on the calendar, so the
  /// real pool is smaller than this and the warning under-fires rather than
  /// crying wolf. Left unsaid in the message on purpose — a caveat about
  /// exclusions the user can't see would cost more attention than it repays.
  String? get _thinCollectionNotice {
    final count = _ownRecipeCount;
    if (!_isSwipe || _includePublic || count == null) return null;
    final deckSize = swipeDeckSize(_days);
    if (count >= deckSize) return null;
    return 'You have only $count own ${count == 1 ? 'recipe' : 'recipes'} to swipe '
        'through, and we\'d suggest around $deckSize for this many days.';
  }

  /// Swipe mode only: every member who could take part, and who currently is.
  /// Loaded in [_load]; the picker itself is hidden for groups of two or fewer,
  /// where "everyone" is the only sensible answer anyway.
  List<String> _memberUids = [];
  final Set<String> _participants = {};
  bool _starting = false;

  /// Proposals from previous, uncommitted visits to [MealPlanOverviewPage],
  /// keyed by [_signature] (dietary + styles + notes — not days/people, so a
  /// plan generated for 5 days/2 people can still be reused, trimmed or
  /// grown, after the user only changes those two numbers). Persisted to
  /// [_kPrefPlanCache] (see [_loadPlanCache]/[_savePlanCache]) so it survives
  /// closing the whole flow or the app, not just an in-app back-and-forth.
  /// Cleared entirely once a plan is actually committed, or once the target
  /// window is no longer free (see [_windowStillFree]) — either way the
  /// cached days are no longer a safe basis to propose again.
  final Map<String, List<MealPlanSlot>> _planCache = {};

  String _signature() {
    final dietary = List<String>.from(_dietary)..sort();
    final styles = _styles.toList()..sort();
    return '${dietary.join(',')}||${styles.join(',')}||${_notesCtrl.text.trim()}';
  }

  /// Whether nothing has been planned for [widget.groupDoc] within the
  /// currently selected [_days] window since we last cached a proposal for
  /// it — if something has, the cache no longer reflects reality and must be
  /// discarded rather than reused.
  Future<bool> _windowStillFree() async {
    final end = widget.startDate.add(Duration(days: _days));
    final snap = await widget.groupDoc
        .collection('cooking_plan')
        .where('plannedFor', isGreaterThanOrEqualTo: Timestamp.fromDate(widget.startDate))
        .where('plannedFor', isLessThan: Timestamp.fromDate(end))
        .limit(1)
        .get();
    return snap.docs.isEmpty;
  }

  /// Restores [_planCache] from [_kPrefPlanCache], so a proposal survives the
  /// whole flow being closed (or the app restarting) — not just an in-app
  /// back-and-forth. Only entries for this exact group/window are loaded, since
  /// a different startDate means [_windowStillFree] can't vouch for them.
  void _loadPlanCache(SharedPreferences prefs) {
    final raw = prefs.getString(_kPrefPlanCache);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['groupId'] != widget.groupId) return;
      if (decoded['startDate'] != _dateKey(widget.startDate)) return;
      final entries = Map<String, dynamic>.from(decoded['entries'] ?? const {});
      entries.forEach((sig, rawSlots) {
        final slots = <MealPlanSlot>[
          for (final s in List<dynamic>.from(rawSlots as List))
            if (_slotFromJson(Map<String, dynamic>.from(s as Map)) case final slot?) slot,
        ];
        if (slots.isNotEmpty) _planCache[sig] = slots;
      });
    } catch (_) {
      // Corrupt or old-format cache — ignore and start fresh.
    }
  }

  Future<void> _savePlanCache() async {
    final prefs = await SharedPreferences.getInstance();
    if (_planCache.isEmpty) {
      await prefs.remove(_kPrefPlanCache);
      return;
    }
    await prefs.setString(
      _kPrefPlanCache,
      jsonEncode({
        'groupId': widget.groupId,
        'startDate': _dateKey(widget.startDate),
        'entries': {
          for (final e in _planCache.entries) e.key: [for (final s in e.value) _slotToJson(s)],
        },
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    _days = widget.maxDays < 5 ? widget.maxDays : 5;
    _load();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefsFuture = SharedPreferences.getInstance();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final dietaryFuture = uid == null
        ? Future.value(<String>[])
        : FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get()
            .then((d) => List<String>.from(d.data()?['dietaryPreferences'] ?? const []))
            .catchError((_) => <String>[]);

    // Only the swipe flow needs to know who else is in the group; the AI flow
    // plans for a headcount, not for named people.
    final membersFuture = _isSwipe
        ? widget.groupDoc
            .collection('members')
            .get()
            .then((s) => [
                  for (final d in s.docs)
                    if (d.data()['status'] != 'left' &&
                        (d.data()['role'] == 'admin' || d.data()['role'] == 'member'))
                      d.id,
                ])
            .catchError((_) => <String>[])
        : Future.value(<String>[]);

    // A count aggregation, not a read of every recipe: the setup page only
    // needs the size of the collection, and a group with 200 recipes shouldn't
    // pay 200 reads to open a settings screen.
    final recipeCountFuture = _isSwipe
        ? widget.groupDoc
            .collection('recipes')
            .count()
            .get()
            .then((s) => s.count)
            .catchError((_) => null)
        : Future.value(null);

    final prefs = await prefsFuture;
    final dietary = await dietaryFuture;
    final members = await membersFuture;
    final recipeCount = await recipeCountFuture;
    _loadPlanCache(prefs);
    if (!mounted) return;
    setState(() {
      _days = (prefs.getInt(_kPrefDays) ?? _days).clamp(1, widget.maxDays);
      _people = (prefs.getInt(_kPrefPeople) ?? 2).clamp(1, 12);
      _styles.addAll((prefs.getStringList(_kPrefStyles) ?? const []).where(kMealPlanStyles.contains));
      _wantExtra = prefs.getBool(_kPrefExtra) ?? true;
      _includePublic = prefs.getBool(_kPrefSwipePublic) ?? true;
      _ownRecipeCount = recipeCount;
      // Swipe mode drops the user's free-text dietary entries on the way in,
      // not just out of the picker: they can't filter a recipe corpus (see the
      // selector's allowCustomEntries note), so showing them preselected would
      // promise something the deck can't deliver.
      _dietary = _isSwipe ? dietary.where(kDietaryOptions.contains).toList() : dietary;
      _notesCtrl.text = prefs.getString(_kPrefNotes) ?? '';
      _memberUids = members;
      // Everyone is in by default — unchecking is the exception, not the setup.
      _participants
        ..clear()
        ..addAll(members);
      if (uid != null && members.contains(uid)) _participants.add(uid);
      _loading = false;
    });
  }

  /// Opens a swipe session for the chosen window and drops the user straight
  /// into the deck. Style and notes are deliberately not sent: they exist to
  /// steer generation, and there is nothing to steer here.
  Future<void> _startSwiping() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _starting) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefDays, _days);
    await prefs.setInt(_kPrefPeople, _people);
    await prefs.setBool(_kPrefSwipePublic, _includePublic);

    setState(() => _starting = true);
    final dates = [
      for (var i = 0; i < _days; i++) widget.startDate.add(Duration(days: i)),
    ];
    // A group of two (or one) never sees the picker, so fall back to everyone.
    final participants = _memberUids.length > 2
        ? (_participants.toList()..remove(uid))
        : List<String>.from(_memberUids);
    if (!participants.contains(uid)) participants.add(uid);

    try {
      final sessionId = await createSwipeSession(
        groupId: widget.groupId,
        dates: dates,
        people: _people,
        dietary: _dietary,
        participants: participants,
        includePublic: _includePublic,
      );
      if (!mounted) return;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => SwipeToPlanFlow(
            groupDoc: widget.groupDoc,
            sessionId: sessionId,
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (e.code) {
          'already-exists' => 'A swipe session is already running for this group.',
          'failed-precondition' => 'There aren\'t enough recipes to swipe on yet.',
          _ => 'Could not start the session. Please try again.',
        }),
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _starting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start the session. Please try again.')),
      );
    }
  }

  Future<void> _generate() async {
    final notes = _notesCtrl.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefDays, _days);
    await prefs.setInt(_kPrefPeople, _people);
    await prefs.setStringList(_kPrefStyles, _styles.toList());
    await prefs.setString(_kPrefNotes, notes);
    await prefs.setBool(_kPrefExtra, _wantExtra);

    final sig = _signature();
    var cached = _planCache[sig];
    if (cached != null && !(await _windowStillFree())) {
      _planCache.clear();
      await _savePlanCache();
      cached = null;
    }

    if (!mounted) return;
    final result = await Navigator.push<_MealPlanFlowResult>(
      context,
      MaterialPageRoute(
        builder: (_) => MealPlanOverviewPage(
          groupId: widget.groupId,
          groupDoc: widget.groupDoc,
          startDate: widget.startDate,
          days: _days,
          people: _people,
          dietary: _dietary,
          styles: _styles.toList(),
          notes: notes,
          access: widget.access,
          includeExtra: _wantExtra,
          initialSlots: cached,
        ),
      ),
    );
    if (!mounted) return;
    if (result?.committed == true) {
      _planCache.clear();
      await _savePlanCache();
    } else if (result?.slotsForCache != null) {
      _planCache[sig] = result!.slotsForCache!;
      await _savePlanCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only worth asking who takes part once there's an actual choice to make:
    // in a couple it is always "both of us", so the picker would be noise.
    final showParticipants = _isSwipe && _memberUids.length > 2;

    return Scaffold(
      appBar: AppBar(title: Text(_isSwipe ? 'Swipe to Plan' : 'Plan the next days')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                const SectionLabel('How many days?'),
                StepperRow(
                  icon: Icons.calendar_month,
                  value: _days,
                  min: 1,
                  max: widget.maxDays,
                  onChanged: (v) => setState(() => _days = v),
                  // Sits in the days card rather than in its own section: it
                  // describes what else the week should contain, so it belongs
                  // with the window it applies to. Swipe mode has no extra to
                  // ask for — the deck is main dishes only.
                  footer: _isSwipe
                      ? null
                      : SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: _wantExtra,
                          onChanged: (v) => setState(() => _wantExtra = v),
                          title: const Text('Add a side recipe'),
                        ),
                ),
                const SizedBox(height: 20),
                const SectionLabel('For how many people?'),
                StepperRow(
                  icon: Icons.people_outline,
                  value: _people,
                  min: 1,
                  max: 12,
                  onChanged: (v) => setState(() => _people = v),
                ),
                // Style and notes steer *generation*: they tell the model what
                // kind of week to invent. The swipe deck is drawn from recipes
                // that already exist, and neither a style preset nor free text
                // like "use up the zucchini" is something an existing corpus
                // can be filtered by — so rather than offer controls that
                // silently do nothing, the swipe flow omits them.
                if (!_isSwipe) ...[
                  const SizedBox(height: 24),
                  const SectionLabel('Style'),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.05,
                    children: [
                      for (final style in kMealPlanStyles)
                        DietaryOptionButton(
                          label: style,
                          icon: _kStyleIcons[style] ?? Icons.restaurant,
                          checked: _styles.contains(style),
                          disabled: false,
                          onTap: () => setState(() {
                            _styles.contains(style) ? _styles.remove(style) : _styles.add(style);
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesCtrl,
                    textInputAction: TextInputAction.done,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Anything else? e.g. "use up the zucchini"…',
                    ),
                  ),
                ],
                if (showParticipants) ...[
                  const SizedBox(height: 24),
                  const SectionLabel('Who\'s swiping?'),
                  for (final uid in _memberUids)
                    _ParticipantTile(
                      uid: uid,
                      checked: _participants.contains(uid),
                      // The person setting this up is always in it.
                      locked: uid == FirebaseAuth.instance.currentUser?.uid,
                      onChanged: (v) => setState(() {
                        v ? _participants.add(uid) : _participants.remove(uid);
                      }),
                    ),
                ],
                const SizedBox(height: 24),
                const SectionLabel('Dietary preferences'),
                DietaryPreferencesSelector(
                  value: _dietary,
                  onChanged: (v) => setState(() => _dietary = v),
                  showCustomEntriesInfo: false,
                  // The AI can read "no shellfish" and act on it. A deck filter
                  // can't — it matches the canonical dietary tags recipes are
                  // stored with, and there is nothing for free text to match
                  // against. So swipe mode doesn't offer custom entries at all
                  // rather than accepting one and silently dropping it.
                  allowCustomEntries: !_isSwipe,
                ),
                // Last thing on the page: it widens the pool everything above
                // is drawn from, so it only makes sense once the rest has been
                // answered. AI mode has no equivalent — it writes recipes
                // rather than drawing them from a corpus.
                if (_isSwipe) ...[
                  const SizedBox(height: 24),
                  const SectionLabel('Recipe pool'),
                  SettingSwitchCard(
                    value: _includePublic,
                    onChanged: (v) => setState(() => _includePublic = v),
                    icon: Icons.public,
                    title: 'Include public recipes',
                    subtitle: 'Mix in main dishes from the community',
                    notice: _thinCollectionNotice,
                  ),
                ],
                const SizedBox(height: 88),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _loading || _starting ? null : (_isSwipe ? _startSwiping : _generate),
          icon: _starting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_isSwipe ? MdiIcons.gestureSwipeHorizontal : Icons.auto_awesome),
          label: Text(_isSwipe ? 'Start swiping' : 'Generate plan'),
        ),
      ),
    );
  }
}

/// One row of the swipe-session participant picker: a member's username on a
/// selectable card. The starter's own row is shown but locked — leaving
/// yourself out of a vote you're starting isn't a thing anyone means to do. It
/// is drawn in the selected style like any other checked row, with a padlock in
/// place of the tick: the row is on, it just can't be turned off.
///
/// Styled to match [DietaryOptionButton] — same filled-card treatment, radius
/// and selected/disabled colours — so the whole settings screen reads as one
/// family of controls rather than a grid of buttons plus a stray checkbox. Laid
/// out as a row rather than that widget's icon-over-label column because a
/// username is a variable-length string, not a one-word tag.
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.uid,
    required this.checked,
    required this.locked,
    required this.onChanged,
  });

  final String uid;
  final bool checked;
  final bool locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // A locked row is still a *selected* row, so it keeps the selected colours.
    // Greying it out said "unavailable" when the truth is "already in, and not
    // yours to change" — the padlock carries that, the palette shouldn't.
    final Color cardColor =
        checked ? colorScheme.primary : colorScheme.surfaceContainerHighest;

    final Color contentColor =
        checked ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: locked ? null : () => onChanged(!checked),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.person_outline, size: 22, color: contentColor),
                const SizedBox(width: 12),
                Expanded(
                  child: LoadDocumentBuilder(
                    docRef:
                        FirebaseFirestore.instance.collection('users_public').doc(uid),
                    builder: (data) => Text(
                      locked
                          ? '${(data['username'] ?? 'Member')} (you)'
                          : (data['username'] ?? 'Member').toString(),
                      style: TextStyle(color: contentColor, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  locked
                      ? Icons.lock_outline
                      : checked
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                  size: 20,
                  // The padlock is a status marker, not the row's point, so it
                  // sits a step back from the username next to it.
                  color: locked ? contentColor.withValues(alpha: 0.7) : contentColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fixed height every day tile (and the skipped-day row) is laid out to, so
/// the list reads as a steady column of equal-sized cards. The thumbnail is
/// square and sized to match, so it fills the card top-to-bottom on the left.
const double _kTileHeight = 120;

// ─── Overview step ──────────────────────────────────────────────────────────

/// Result handed back to [MealPlanSettingsPage] when [MealPlanOverviewPage]
/// closes. When [committed] is false, [slotsForCache] carries whatever the
/// user was looking at (so going back after only tweaking days/people can
/// reuse it); when [committed] is true, it means a plan was actually written
/// for this window, so any cached proposal for it is stale and must be
/// dropped instead of reused.
class _MealPlanFlowResult {
  const _MealPlanFlowResult({this.slotsForCache, this.committed = false});
  final List<MealPlanSlot>? slotsForCache;
  final bool committed;
}

/// Second step: shows the generated proposal, lets the user swap/remove
/// individual days or regenerate the whole batch, then commits it.
class MealPlanOverviewPage extends StatefulWidget {
  const MealPlanOverviewPage({
    super.key,
    required this.groupId,
    required this.groupDoc,
    required this.startDate,
    required this.days,
    required this.people,
    required this.dietary,
    required this.styles,
    required this.notes,
    required this.access,
    this.includeExtra = true,
    this.initialSlots,
  });

  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final DateTime startDate;
  final int days;
  final int people;
  final List<String> dietary;
  final List<String> styles;
  final String notes;
  final AiAccess access;

  /// Whether to ask for the complementary "Additionally?" side recipe, from the
  /// switch on [MealPlanSettingsPage]. When false the extra is never requested,
  /// never fetched on its own, and its section is absent from the list — no
  /// candidate read, no schema field, no tile to dismiss.
  final bool includeExtra;

  /// Slots reused verbatim, by date, from a previous uncommitted proposal for
  /// the same dietary/styles/notes (see [_MealPlanSettingsPageState._planCache]).
  /// Only dates missing from this list are actually generated.
  final List<MealPlanSlot>? initialSlots;

  @override
  State<MealPlanOverviewPage> createState() => _MealPlanOverviewPageState();
}

class _MealPlanOverviewPageState extends State<MealPlanOverviewPage> {
  List<MealPlanSlot>? _slots; // null while the first proposal is loading
  String? _error;
  bool _committing = false;
  final Map<String, Future<PublicRecipePreload>> _publicPreloads = {};

  /// The optional "Additionally?" suggestion (a complementary non-main item),
  /// shown once at the end of the list. Null until it has been generated.
  MealPlanSlot? _extra;

  /// True while [_ensureExtra] is in flight. The day slots come straight from
  /// cache on that path, so without this the page renders complete and finished
  /// while a fetch is still running — indistinguishable from nothing happening.
  bool _extraPending = false;

  /// Every recipe name surfaced anywhere in this planning session — across days,
  /// swaps, regenerates and the extra. Passed as `avoidNames` on every
  /// subsequent generation so a swap/regenerate never re-proposes something the
  /// user has already seen. [_shownLower] backs de-duplication; [_shownNames]
  /// preserves original casing for the prompt (newest last, capped).
  final List<String> _shownNames = [];
  final Set<String> _shownLower = {};

  String get _lang => LanguageService.instance.code.value;
  String get _uid => FirebaseAuth.instance.currentUser!.uid;
  List<MealPlanSlot> get _activeSlots => (_slots ?? []).where((s) => !s.removed).toList();

  /// Whether the extra is part of this plan. [_extra] can be non-null with the
  /// switch off — a cached one is held onto so flipping the switch back on is
  /// free — so every place that shows or commits it goes through here.
  bool get _showExtra => widget.includeExtra && _extra != null;

  /// The day slots plus the extra (when the user hasn't disabled it) — i.e.
  /// everything that actually gets written on confirm. The extra shares its day
  /// with that day's main, so the day simply ends up with two planned recipes.
  List<MealPlanSlot> get _committableSlots => [
        ..._activeSlots,
        if (_showExtra && !_extra!.removed) _extra!,
      ];

  /// Plants the extra on one of the plan's middle days, so it lands in the
  /// thick of the week rather than on the first or last day.
  void _placeExtra(MealPlanSlot extra) {
    final days = _activeSlots.isNotEmpty ? _activeSlots : (_slots ?? const <MealPlanSlot>[]);
    extra.date = days.isEmpty ? widget.startDate : days[days.length ~/ 2].date;
  }

  /// Records [slots]' names as "seen this session". Safe to call repeatedly.
  void _remember(Iterable<MealPlanSlot?> slots) {
    for (final s in slots) {
      final name = s?.name.trim();
      if (name == null || name.isEmpty) continue;
      if (_shownLower.add(name.toLowerCase())) _shownNames.add(name);
    }
  }

  /// The names to avoid on the next generation — everything seen so far, capped
  /// to the most recent 40 so a long session can't bloat the prompt.
  List<String> get _avoidNames =>
      _shownNames.length > 40 ? _shownNames.sublist(_shownNames.length - 40) : _shownNames;

  @override
  void initState() {
    super.initState();
    _generateInitial();
  }

  /// Builds the proposal for [widget.days] starting [widget.startDate],
  /// reusing any day already covered by [widget.initialSlots] and only
  /// calling `generateMealPlan` for the remaining, still-missing dates.
  Future<void> _generateInitial() async {
    final dates = List.generate(
      widget.days,
      (i) => DateTime(widget.startDate.year, widget.startDate.month, widget.startDate.day + i),
    );
    // The extra shares its date with that day's main, so it must be pulled out
    // before the list is keyed by date — otherwise it overwrites the main and
    // is then treated as a day slot for the rest of the session.
    final initial = widget.initialSlots ?? const <MealPlanSlot>[];
    final cachedExtra = initial.where((s) => s.isExtra).firstOrNull;
    final cache = {
      for (final s in initial)
        if (!s.isExtra) _dateKey(s.date): s,
    };
    final reused = <MealPlanSlot>[];
    final missingDates = <DateTime>[];
    for (final d in dates) {
      final s = cache[_dateKey(d)];
      if (s != null) {
        reused.add(s);
      } else {
        missingDates.add(d);
      }
    }
    // Reused proposals count as already seen this session, so a later
    // swap/regenerate won't circle back to them.
    _remember(reused);
    // A cached extra is restored even when the switch is off: it is kept, just
    // not shown or committed (see [_showExtra]). Dropping it here instead would
    // make turning the switch off and on again cost a fresh generation — the
    // one thing the cache exists to avoid.
    if (cachedExtra != null) {
      _remember([cachedExtra]);
      if (widget.includeExtra) _startBackgroundWork([cachedExtra]);
      _extra = cachedExtra;
    }

    if (missingDates.isEmpty) {
      _startBackgroundWork(reused);
      setState(() {
        _slots = reused;
        _error = null;
        // The window may have grown or shrunk since the extra was cached.
        if (_extra != null) _placeExtra(_extra!);
      });
      // Every day was reused and no extra was cached — fetch one on its own.
      if (_extra == null && widget.includeExtra) _ensureExtra();
      return;
    }

    setState(() {
      _slots = null;
      _error = null;
    });
    try {
      final locked = reused.where((s) => !s.removed).toList();
      final result = await generateMealPlan(
        groupId: widget.groupId,
        startDate: widget.startDate,
        days: widget.days,
        people: widget.people,
        dietary: widget.dietary,
        styles: widget.styles,
        notes: widget.notes,
        regenerateDates: missingDates,
        lockedSlots: locked,
        avoidNames: _avoidNames,
        // An extra restored from cache is already in hand — asking for another
        // would pay for a generation and then discard one of the two.
        includeExtra: widget.includeExtra && _extra == null,
        lang: _lang,
      );
      final slots = [...reused, ...result.slots]..sort((a, b) => a.date.compareTo(b.date));
      _remember(result.slots);
      _startBackgroundWork(slots);
      if (!mounted) return;
      setState(() {
        _slots = slots;
        final extra = result.extra ?? _extra;
        if (extra != null) {
          _remember([extra]);
          _startBackgroundWork([extra]);
          _placeExtra(extra); // needs _slots set, so place after assigning them
          _extra = extra;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _messageFor(e));
    }
  }

  /// Fetches an "Additionally?" extra on its own (no day slots), used when the
  /// initial proposal was fully served from cache so no generation ran.
  Future<void> _ensureExtra() async {
    if (_extra != null || !widget.includeExtra) return;
    setState(() => _extraPending = true);
    try {
      final result = await generateMealPlan(
        groupId: widget.groupId,
        startDate: widget.startDate,
        days: widget.days,
        people: widget.people,
        dietary: widget.dietary,
        styles: widget.styles,
        notes: widget.notes,
        regenerateDates: [widget.startDate],
        lockedSlots: _activeSlots,
        avoidNames: _avoidNames,
        extraOnly: true,
        lang: _lang,
      );
      final extra = result.extra;
      if (!mounted) return;
      if (extra == null) {
        // Silence here reads as "the switch does nothing": the days are all
        // reused from cache, so an extra that never arrives leaves the screen
        // looking exactly as it did with the switch off.
        _snack('Could not add a side recipe this time.');
        return;
      }
      _remember([extra]);
      _startBackgroundWork([extra]);
      _placeExtra(extra);
      setState(() => _extra = extra);
    } catch (_) {
      // The plan itself is unaffected, but say so rather than leave the user
      // wondering whether the switch took effect.
      if (mounted) _snack('Could not add a side recipe this time.');
    } finally {
      if (mounted) setState(() => _extraPending = false);
    }
  }

  /// Regenerates just the "Additionally?" suggestion, avoiding everything shown
  /// so far this session.
  Future<void> _regenerateExtra() async {
    final current = _extra;
    if (current == null) return;
    setState(() => current.regenerating = true);
    try {
      final result = await generateMealPlan(
        groupId: widget.groupId,
        startDate: widget.startDate,
        days: widget.days,
        people: widget.people,
        dietary: widget.dietary,
        styles: widget.styles,
        notes: widget.notes,
        regenerateDates: [widget.startDate],
        lockedSlots: _activeSlots,
        avoidNames: _avoidNames,
        extraOnly: true,
        lang: _lang,
      );
      final extra = result.extra;
      if (extra == null || !mounted) {
        if (mounted) _snack('Could not find another extra right now.');
        return;
      }
      _remember([extra]);
      _startBackgroundWork([extra]);
      _placeExtra(extra);
      // A disabled extra stays disabled across a regenerate.
      extra.removed = current.removed;
      setState(() => _extra = extra);
    } catch (_) {
      if (mounted) _snack('Could not swap the extra. Please try again.');
    } finally {
      if (mounted && _extra == current) setState(() => current.regenerating = false);
    }
  }

  String _messageFor(Object e) {
    if (e is FirebaseFunctionsException && e.code == 'failed-precondition') {
      return 'This time window is already fully planned.';
    }
    return 'Could not generate a plan. Please try again.';
  }

  /// Kicks off the work that shouldn't wait for confirm: starting "new" idea
  /// generation immediately (so the tile reveals name → photo while the user
  /// is still browsing) and preloading public recipes (so confirm feels
  /// instant).
  void _startBackgroundWork(List<MealPlanSlot> slots) {
    for (final slot in slots) {
      if (slot.source == MealPlanSource.newIdea && slot.recipeId == null) {
        slot.recipeId = startNewIdeaGeneration(
          name: slot.name,
          servings: widget.people,
          lang: _lang,
        );
      } else if (slot.source == MealPlanSource.public && slot.publicRecipeId != null) {
        _publicPreloads.putIfAbsent(
            slot.publicRecipeId!, () => preloadPublicRecipe(slot.publicRecipeId!));
      }
    }
  }

  Future<void> _swap(MealPlanSlot slot) async {
    setState(() => slot.regenerating = true);
    try {
      final locked = _activeSlots.where((s) => s != slot).toList();
      final result = await generateMealPlan(
        groupId: widget.groupId,
        startDate: widget.startDate,
        days: widget.days,
        people: widget.people,
        dietary: widget.dietary,
        styles: widget.styles,
        notes: widget.notes,
        regenerateDates: [slot.date],
        lockedSlots: locked,
        // Avoid every name seen this session — not just the one being swapped —
        // so a swap never lands on a dish already shown for another day or an
        // earlier proposal.
        avoidNames: _avoidNames,
        lang: _lang,
      );
      if (result.slots.isEmpty || !mounted) return;
      final fresh = result.slots.first;
      _remember([fresh]);
      _startBackgroundWork([fresh]);
      // The swapped-away slot's own early-started "new idea" recipe (if any)
      // is simply discarded — it only ever lived in `public_recipes`, so
      // nothing needs cleaning up in any group.
      setState(() {
        final idx = _slots!.indexOf(slot);
        if (idx != -1) _slots![idx] = fresh;
      });
    } catch (_) {
      if (mounted) _snack('Could not swap this day. Please try again.');
    } finally {
      if (mounted) setState(() => slot.regenerating = false);
    }
  }

  void _toggleRemove(MealPlanSlot slot) {
    setState(() => slot.removed = !slot.removed);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _confirm() async {
    // Includes the "Additionally?" extra on its middle day unless disabled.
    final active = _committableSlots;
    if (active.isEmpty) return;
    setState(() => _committing = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const MealPlanBlockingDialog(text: 'Adding your plan…'),
    );
    try {
      final committed = await commitMealPlan(
        group: widget.groupDoc,
        uid: _uid,
        lang: _lang,
        people: widget.people,
        slots: active,
        publicPreloads: _publicPreloads,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close blocking dialog
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MealPlanShoppingListPage(
            groupDoc: widget.groupDoc,
            committed: committed,
            people: widget.people,
          ),
        ),
        result: const _MealPlanFlowResult(committed: true),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _snack('Something went wrong while creating your plan.');
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // The extra rides along in the cached list (flagged [isExtra]) rather
        // than in its own field: it is a MealPlanSlot like any other, and
        // [_generateInitial] splits it back out by the flag. Still null while
        // the first proposal is loading — caching an empty list there would
        // throw away a perfectly good previous proposal.
        final slots = _slots;
        Navigator.pop(
          context,
          _MealPlanFlowResult(
            slotsForCache:
                slots == null ? null : [...slots, if (_extra != null) _extra!],
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Your meal plan')),
        body: _error != null
            ? MealPlanErrorState(message: _error!, onRetry: _generateInitial)
            : _slots == null
                ? const _LoadingState()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      for (final slot in _slots!)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _MealPlanDayTile(
                            slot: slot,
                            groupId: widget.groupId,
                            groupDoc: widget.groupDoc,
                            access: widget.access,
                            onSwap: () => _swap(slot),
                            onToggleRemove: () => _toggleRemove(slot),
                            publicPreload: (id) =>
                                _publicPreloads.putIfAbsent(id, () => preloadPublicRecipe(id)),
                          ),
                        ),
                      if (_showExtra) ...[
                        const _AdditionallyHeader(),
                        _MealPlanDayTile(
                          slot: _extra!,
                          groupId: widget.groupId,
                          groupDoc: widget.groupDoc,
                          access: widget.access,
                          onSwap: _regenerateExtra,
                          onToggleRemove: () => _toggleRemove(_extra!),
                          publicPreload: (id) =>
                              _publicPreloads.putIfAbsent(id, () => preloadPublicRecipe(id)),
                        ),
                      ] else if (_extraPending) ...[
                        // The days above came from cache and rendered instantly,
                        // so without this the page looks finished while the
                        // extra is still being fetched.
                        const _AdditionallyHeader(),
                        const _ExtraPendingTile(),
                      ],
                    ],
                  ),
        bottomNavigationBar: (_slots == null || _error != null)
            ? null
            : SafeArea(
                minimum: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _committableSlots.isEmpty || _committing ? null : _confirm,
                  icon: const Icon(Icons.check),
                  label: const Text('Looks good! Add to meal plan'),
                ),
              ),
      ),
    );
  }
}

/// Placeholder under the "Additionally?" header while the extra is being
/// fetched on its own — the [_ensureExtra] path, where the day slots come from
/// cache and so appear instantly.
class _ExtraPendingTile extends StatelessWidget {
  const _ExtraPendingTile();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Finding something extra…',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingState extends StatefulWidget {
  const _LoadingState();

  @override
  State<_LoadingState> createState() => _LoadingStateState();
}

class _LoadingStateState extends State<_LoadingState> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _phraseTimer;
  int _phraseIndex = 0;

  static const _phrases = [
    'Curating your meals…',
    'Balancing your week…',
    'Mixing in some variety…',
    'Almost there…',
  ];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
    _phraseTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() => _phraseIndex = (_phraseIndex + 1) % _phrases.length);
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _phraseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Same gentle, on-brand mesh used by the recipe page's planner tiles, so
    // the flow it opens into feels continuous.
    final Color meshForeground = MealPlanMesh.foregroundOf(colorScheme);

    return Stack(
      fit: StackFit.expand,
      children: [
        const MealPlanMesh(),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: Tween(begin: 0.85, end: 1.15).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: Icon(Icons.auto_awesome, size: 48, color: meshForeground),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: Text(
                  _phrases[_phraseIndex],
                  key: ValueKey(_phraseIndex),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: meshForeground, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Separates the "Additionally?" extra from the day tiles: a bit of a gap, a
/// hairline divider and a soft label, so the extra reads as a bonus rather than
/// another day in the plan.
class _AdditionallyHeader extends StatelessWidget {
  const _AdditionallyHeader();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Row(
        children: [
          Text(
            'Additionally?',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          Expanded(child: Divider(color: colorScheme.outlineVariant, height: 1)),
        ],
      ),
    );
  }
}

class _MealPlanDayTile extends StatelessWidget {
  const _MealPlanDayTile({
    required this.slot,
    required this.groupId,
    required this.groupDoc,
    required this.access,
    required this.onSwap,
    required this.onToggleRemove,
    required this.publicPreload,
  });

  final MealPlanSlot slot;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final AiAccess access;
  final VoidCallback onSwap;

  /// Null for the "Additionally?" extra, which can't be skipped (it's never
  /// committed with the plan) — its remove action is simply hidden.
  final VoidCallback? onToggleRemove;
  final Future<PublicRecipePreload> Function(String publicRecipeId) publicPreload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (slot.removed && onToggleRemove != null) {
      return _SkippedTile(
        date: slot.date,
        onRestore: onToggleRemove!,
        title: slot.isExtra ? 'Additionally' : null,
        subtitle: slot.isExtra ? 'Not added' : null,
      );
    }

    final content = SizedBox(
      height: _kTileHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _kTileHeight,
            height: _kTileHeight,
            child: _Thumbnail(slot: slot, groupDoc: groupDoc),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // The extra now lands on a real day too, so show which one
                    // — the section header above already marks it as the extra.
                    slot.isExtra
                        ? 'Alongside ${getRelativeDateString(slot.date)}'
                        : getRelativeDateString(slot.date),
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    slot.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    slot.reason,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          _TileActions(
            regenerating: slot.regenerating,
            isExtra: slot.isExtra,
            onSwap: onSwap,
            onToggleRemove: onToggleRemove,
          ),
        ],
      ),
    );

    final card = Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: slot.regenerating
          ? content
          : (slot.source == MealPlanSource.public
              ? InkWell(onTap: () => _openPublicPreview(context), child: content)
              : (slot.recipeId == null
                  ? content
                  : InkWell(onTap: () => _openOwnPreview(context), child: content))),
    );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: slot.regenerating ? 0.5 : 1.0,
      child: card,
    );
  }

  void _openPublicPreview(BuildContext context) {
    final publicId = slot.publicRecipeId;
    if (publicId == null) return;
    openPublicRecipePreview(
      context,
      publicRecipeId: publicId,
      name: slot.name,
      image: slot.publicImage,
      publicPreload: publicPreload,
    );
  }

  void _openOwnPreview(BuildContext context) {
    final recipeId = slot.recipeId;
    if (recipeId == null) return;
    openOwnRecipePreview(
      context,
      recipeId: recipeId,
      source: slot.source,
      groupDoc: groupDoc,
      name: slot.name,
      image: slot.publicImage,
    );
  }
}

/// Trailing swap/remove actions, replaced by a spinner while a single-day
/// swap is in flight.
class _TileActions extends StatelessWidget {
  const _TileActions({
    required this.regenerating,
    required this.isExtra,
    required this.onSwap,
    required this.onToggleRemove,
  });

  final bool regenerating;
  final bool isExtra;
  final VoidCallback onSwap;
  final VoidCallback? onToggleRemove;

  @override
  Widget build(BuildContext context) {
    if (regenerating) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: isExtra ? 'Suggest a different extra' : 'Regenerate this day',
          onPressed: onSwap,
          icon: const Icon(Icons.refresh, size: 20),
        ),
        if (onToggleRemove != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: isExtra ? "Don't add this extra" : 'Skip this day',
            onPressed: onToggleRemove,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
          ),
      ],
    );
  }
}

/// A day the user chose to skip: a lighter, dismissed-looking row with a way
/// to bring it back. Same fixed height/margin as the regular tile's [Card] so
/// it lines up exactly instead of running wider.
class _SkippedTile extends StatelessWidget {
  const _SkippedTile({
    required this.date,
    required this.onRestore,
    this.title,
    this.subtitle,
  });
  final DateTime date;
  final VoidCallback onRestore;

  /// Overrides for the disabled "Additionally?" extra, which isn't a skipped
  /// day and shouldn't read like one.
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: _kTileHeight,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.remove_circle_outline, color: colorScheme.outline, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title ?? getRelativeDateString(date),
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? 'Skipped',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: onRestore, child: const Text('Restore')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Recipe-card-shaped thumbnail. For `own`/`newIdea` slots it listens to the
/// recipe doc live so the image pops in the moment generation finishes
/// (rather than the one-shot fetch [RecipeCard] does), shimmering over the
/// spot until then. Public slots already have their final image, if any.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.slot, required this.groupDoc});

  final MealPlanSlot slot;
  final DocumentReference<Map<String, dynamic>> groupDoc;

  @override
  Widget build(BuildContext context) {
    // Sized by the parent (a square [_kTileHeight]x[_kTileHeight] box flush
    // with the card's left/top/bottom edges) — the card's own clip rounds its
    // outer corners, so no extra clipping is needed here.
    return slot.source == MealPlanSource.public
        ? _publicThumbnail(context)
        : _liveThumbnail(context);
  }

  Widget _publicThumbnail(BuildContext context) {
    final image = slot.publicImage;
    if (image != null && image.isNotEmpty) {
      return StorageImage(
        storagePath: image,
        fit: BoxFit.cover,
        memCacheWidth: (_kTileHeight * MediaQuery.of(context).devicePixelRatio).round(),
      );
    }
    return _placeholder(context);
  }

  Widget _liveThumbnail(BuildContext context) {
    final recipeId = slot.recipeId;
    if (recipeId == null) return _placeholder(context);
    final isNewIdea = slot.source == MealPlanSource.newIdea;
    // A "new idea" still lives in `public_recipes` (single `image` field)
    // until the plan is confirmed; only `own` slots are already a group
    // recipe (`images` list) at this point.
    final docRef = isNewIdea
        ? FirebaseFirestore.instance.collection('public_recipes').doc(recipeId)
        : groupDoc.collection('recipes').doc(recipeId);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: docRef.snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final images = isNewIdea
            ? [if ((data?['image'] as String?)?.isNotEmpty == true) data!['image'] as String]
            : List<String>.from(data?['images'] ?? const []);
        if (images.isNotEmpty) {
          return StorageImage(
            storagePath: images.first,
            fit: BoxFit.cover,
            memCacheWidth: (_kTileHeight * MediaQuery.of(context).devicePixelRatio).round(),
          );
        }
        if (isNewIdea) {
          final pending = data?['pending'] as List?;
          final imageDone = pending != null && !pending.contains('image');
          final failed = data?['generationError'] == true;
          if (!imageDone && !failed) return const ImageShimmer();
        }
        return _placeholder(context);
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final primary = HSVColor.fromColor(colorScheme.primary);
    final primaryContainer = HSVColor.fromColor(colorScheme.primaryContainer);
    final tint = HSVColor.fromAHSV(
      1.0,
      (slot.name.hashCode % 360).toDouble(),
      primary.saturation,
      primary.value,
    );
    final containerColor = tint.withValue((primaryContainer.value + primary.value) / 2);
    return Container(
      color: containerColor.toColor(),
      alignment: Alignment.center,
      child: Icon(Icons.restaurant_menu, size: _kTileHeight / 2.2, color: tint.toColor()),
    );
  }
}
