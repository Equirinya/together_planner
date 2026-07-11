import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/core/date_utils.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/recipes/pages/meal_plan_shopping_list_page.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';
import 'package:couple_planner/features/settings/dietary_preferences.dart';

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

String _dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ─── Settings step ──────────────────────────────────────────────────────────

/// First step of the auto meal-plan flow: lets the user set how many days/
/// people to plan for, plus dietary and style preferences, then generates a
/// proposal on [MealPlanOverviewPage].
class MealPlanSettingsPage extends StatefulWidget {
  const MealPlanSettingsPage({
    super.key,
    required this.groupId,
    required this.groupDoc,
    required this.startDate,
    required this.maxDays,
    required this.aiEnabled,
  });

  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final DateTime startDate;
  final int maxDays;
  final bool aiEnabled;

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

  /// Proposals from previous, uncommitted visits to [MealPlanOverviewPage]
  /// this session, keyed by [_signature] (dietary + styles + notes — not
  /// days/people, so a plan generated for 5 days/2 people can still be
  /// reused, trimmed or grown, after the user only changes those two
  /// numbers). Cleared entirely once a plan is actually committed, or once
  /// the target window is no longer free (see [_windowStillFree]) — either
  /// way the cached days are no longer a safe basis to propose again.
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

    final prefs = await prefsFuture;
    final dietary = await dietaryFuture;
    if (!mounted) return;
    setState(() {
      _days = (prefs.getInt(_kPrefDays) ?? _days).clamp(1, widget.maxDays);
      _people = (prefs.getInt(_kPrefPeople) ?? 2).clamp(1, 12);
      _styles.addAll((prefs.getStringList(_kPrefStyles) ?? const []).where(kMealPlanStyles.contains));
      _dietary = dietary;
      _notesCtrl.text = prefs.getString(_kPrefNotes) ?? '';
      _loading = false;
    });
  }

  Future<void> _generate() async {
    final notes = _notesCtrl.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPrefDays, _days);
    await prefs.setInt(_kPrefPeople, _people);
    await prefs.setStringList(_kPrefStyles, _styles.toList());
    await prefs.setString(_kPrefNotes, notes);

    final sig = _signature();
    var cached = _planCache[sig];
    if (cached != null && !(await _windowStillFree())) {
      _planCache.clear();
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
          aiEnabled: widget.aiEnabled,
          initialSlots: cached,
        ),
      ),
    );
    if (!mounted) return;
    if (result?.committed == true) {
      setState(() => _planCache.clear());
    } else if (result?.slotsForCache != null) {
      setState(() => _planCache[sig] = result!.slotsForCache!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plan the next days')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                const _SectionLabel('How many days?'),
                _StepperRow(
                  icon: Icons.calendar_month,
                  value: _days,
                  min: 1,
                  max: widget.maxDays,
                  onChanged: (v) => setState(() => _days = v),
                ),
                const SizedBox(height: 20),
                const _SectionLabel('For how many people?'),
                _StepperRow(
                  icon: Icons.people_outline,
                  value: _people,
                  min: 1,
                  max: 12,
                  onChanged: (v) => setState(() => _people = v),
                ),
                const SizedBox(height: 24),
                const _SectionLabel('Style'),
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
                  decoration: InputDecoration(
                    hintText: 'Anything else? e.g. "use up the zucchini"…',
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 24),
                const _SectionLabel('Dietary preferences'),
                DietaryPreferencesSelector(
                  value: _dietary,
                  onChanged: (v) => setState(() => _dietary = v),
                  showCustomEntriesInfo: false,
                ),
                const SizedBox(height: 88),
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _loading ? null : _generate,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Generate plan'),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final IconData icon;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text('$value', style: Theme.of(context).textTheme.titleLarge)),
          IconButton.filledTonal(
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
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
    required this.aiEnabled,
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
  final bool aiEnabled;

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

  /// Recipe docs created early by [_startBackgroundWork] for "new idea" slots
  /// (see that method's doc comment), tracked so any that never made it into
  /// the final committed plan — because the flow was aborted, a day was
  /// skipped, or a day was swapped away from — can be cleaned up in
  /// [dispose] instead of lingering as orphaned recipes. Ones still present in
  /// [_slots] when disposing are spared, since they're being handed back to
  /// [MealPlanSettingsPage] for possible reuse (see [dispose]).
  final Set<String> _ownedNewIdeaRecipeIds = {};
  final Set<String> _committedRecipeIds = {};

  String get _lang => LanguageService.instance.code.value;
  String get _uid => FirebaseAuth.instance.currentUser!.uid;
  List<MealPlanSlot> get _activeSlots => (_slots ?? []).where((s) => !s.removed).toList();

  @override
  void initState() {
    super.initState();
    _generateInitial();
  }

  @override
  void dispose() {
    final keep = <String>{
      for (final s in _slots ?? const <MealPlanSlot>[])
        if (s.source == MealPlanSource.newIdea && s.recipeId != null) s.recipeId!,
    };
    for (final id in _ownedNewIdeaRecipeIds) {
      if (!_committedRecipeIds.contains(id) && !keep.contains(id)) {
        widget.groupDoc.collection('recipes').doc(id).delete().ignore();
      }
    }
    super.dispose();
  }

  /// Builds the proposal for [widget.days] starting [widget.startDate],
  /// reusing any day already covered by [widget.initialSlots] and only
  /// calling `generateMealPlan` for the remaining, still-missing dates.
  Future<void> _generateInitial() async {
    final dates = List.generate(
      widget.days,
      (i) => DateTime(widget.startDate.year, widget.startDate.month, widget.startDate.day + i),
    );
    final cache = {for (final s in widget.initialSlots ?? const <MealPlanSlot>[]) _dateKey(s.date): s};
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

    if (missingDates.isEmpty) {
      _startBackgroundWork(reused);
      setState(() {
        _slots = reused;
        _error = null;
      });
      return;
    }

    setState(() {
      _slots = null;
      _error = null;
    });
    try {
      final locked = reused.where((s) => !s.removed).toList();
      final generated = await generateMealPlan(
        groupId: widget.groupId,
        startDate: widget.startDate,
        days: widget.days,
        people: widget.people,
        dietary: widget.dietary,
        styles: widget.styles,
        notes: widget.notes,
        regenerateDates: missingDates,
        lockedSlots: locked,
        avoidNames: [for (final s in locked) s.name],
        lang: _lang,
      );
      final slots = [...reused, ...generated]..sort((a, b) => a.date.compareTo(b.date));
      _startBackgroundWork(slots);
      if (!mounted) return;
      setState(() => _slots = slots);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _messageFor(e));
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
          group: widget.groupDoc,
          uid: _uid,
          name: slot.name,
          servings: widget.people,
          lang: _lang,
        );
        _ownedNewIdeaRecipeIds.add(slot.recipeId!);
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
        avoidNames: [slot.name],
        lang: _lang,
      );
      if (result.isEmpty || !mounted) return;
      final fresh = result.first;
      _startBackgroundWork([fresh]);
      // The swapped-away slot's own early-started "new idea" recipe (if any)
      // is now discarded — clean it up right away instead of waiting for
      // dispose's final sweep.
      if (slot.source == MealPlanSource.newIdea &&
          slot.recipeId != null &&
          _ownedNewIdeaRecipeIds.remove(slot.recipeId)) {
        widget.groupDoc.collection('recipes').doc(slot.recipeId).delete().ignore();
      }
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
    final active = _activeSlots;
    if (active.isEmpty) return;
    // Marked as committed up front (rather than after commitMealPlan
    // resolves) so a partial failure inside its Future.wait — where this
    // slot's own write already landed but a different slot's threw — can't
    // make dispose's cleanup sweep delete an already-committed recipe.
    _committedRecipeIds.addAll([
      for (final s in active)
        if (s.source == MealPlanSource.newIdea && s.recipeId != null) s.recipeId!,
    ]);
    setState(() => _committing = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _MealPlanBlockingDialog(text: 'Adding your plan…'),
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
        Navigator.pop(context, _MealPlanFlowResult(slotsForCache: _slots));
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Your meal plan')),
        body: _error != null
            ? _ErrorState(message: _error!, onRetry: _generateInitial)
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
                            aiEnabled: widget.aiEnabled,
                            onSwap: () => _swap(slot),
                            onToggleRemove: () => _toggleRemove(slot),
                            publicPreload: (id) =>
                                _publicPreloads.putIfAbsent(id, () => preloadPublicRecipe(id)),
                          ),
                        ),
                    ],
                  ),
        bottomNavigationBar: (_slots == null || _error != null)
            ? null
            : SafeArea(
                minimum: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _activeSlots.isEmpty || _committing ? null : _confirm,
                  icon: const Icon(Icons.check),
                  label: const Text('Looks good! Add to meal plan'),
                ),
              ),
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
    // Same gentle, on-brand mesh used by the recipe page's Smart Meal Planner
    // tap area, so the flow it opens into feels continuous.
    final meshColors = [
      Color.lerp(colorScheme.surface, colorScheme.primary, 0.35)!,
      Color.lerp(colorScheme.surface, colorScheme.tertiary, 0.4)!,
      Color.lerp(colorScheme.surface, colorScheme.secondary, 0.35)!,
      Color.lerp(colorScheme.surface, colorScheme.primaryContainer, 0.75)!,
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedMeshGradient(
          colors: meshColors,
          options: AnimatedMeshGradientOptions(speed: 0.15),
        ),
        Container(color: Colors.black.withOpacity(0.1)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: Tween(begin: 0.85, end: 1.15).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: const Icon(Icons.auto_awesome, size: 48, color: Colors.white),
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
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// Short non-dismissible wait, mirroring RecipePage's private
/// `_GeneratingDialog` (kept as a small local duplicate rather than an
/// extraction — see the plan's "not doing" section).
class _MealPlanBlockingDialog extends StatelessWidget {
  const _MealPlanBlockingDialog({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 16),
            Flexible(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _MealPlanDayTile extends StatelessWidget {
  const _MealPlanDayTile({
    required this.slot,
    required this.groupId,
    required this.groupDoc,
    required this.aiEnabled,
    required this.onSwap,
    required this.onToggleRemove,
    required this.publicPreload,
  });

  final MealPlanSlot slot;
  final String groupId;
  final DocumentReference<Map<String, dynamic>> groupDoc;
  final bool aiEnabled;
  final VoidCallback onSwap;
  final VoidCallback onToggleRemove;
  final Future<PublicRecipePreload> Function(String publicRecipeId) publicPreload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (slot.removed) {
      return _SkippedTile(date: slot.date, onRestore: onToggleRemove);
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
                    getRelativeDateString(slot.date),
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
          _TileActions(regenerating: slot.regenerating, onSwap: onSwap, onToggleRemove: onToggleRemove),
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _PublicRecipeSheet(
        name: slot.name,
        image: slot.publicImage,
        preload: publicPreload(publicId),
      ),
    );
  }

  void _openOwnPreview(BuildContext context) {
    final recipeId = slot.recipeId;
    if (recipeId == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _OwnIdeaRecipeSheet(
        name: slot.name,
        recipeDoc: groupDoc.collection('recipes').doc(recipeId),
      ),
    );
  }
}

/// Trailing swap/remove actions, replaced by a spinner while a single-day
/// swap is in flight.
class _TileActions extends StatelessWidget {
  const _TileActions({required this.regenerating, required this.onSwap, required this.onToggleRemove});

  final bool regenerating;
  final VoidCallback onSwap;
  final VoidCallback onToggleRemove;

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
          tooltip: 'Regenerate this day',
          onPressed: onSwap,
          icon: const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Skip this day',
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
  const _SkippedTile({required this.date, required this.onRestore});
  final DateTime date;
  final VoidCallback onRestore;

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
                    Text(getRelativeDateString(date), style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Skipped',
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
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: groupDoc.collection('recipes').doc(recipeId).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final images = List<String>.from(data?['images'] ?? const []);
        if (images.isNotEmpty) {
          return StorageImage(
            storagePath: images.first,
            fit: BoxFit.cover,
            memCacheWidth: (_kTileHeight * MediaQuery.of(context).devicePixelRatio).round(),
          );
        }
        if (slot.source == MealPlanSource.newIdea) {
          final pending = data?['pending'] as List?;
          final imageDone = pending != null && !pending.contains('image');
          final failed = data?['generationError'] == true;
          if (!imageDone && !failed) return const _ImageShimmer();
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

/// Bottom sheet previewing a not-yet-adopted public recipe (image,
/// description, steps) so it can be inspected before the plan is confirmed.
class _PublicRecipeSheet extends StatelessWidget {
  const _PublicRecipeSheet({required this.name, required this.image, required this.preload});

  final String name;
  final String? image;
  final Future<PublicRecipePreload> preload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => FutureBuilder<PublicRecipePreload>(
        future: preload,
        builder: (context, snap) {
          final data = snap.data?.data;
          final steps = List<String>.from(data?['steps'] ?? const []);
          final description = (data?['description'] ?? '').toString();
          final time = (data?['time'] as num?)?.toInt() ?? 0;
          final loading = snap.connectionState != ConnectionState.done;
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              if (image != null && image!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: StorageImage(storagePath: image!, fit: BoxFit.cover),
                  ),
                ),
              if (image != null && image!.isNotEmpty) const SizedBox(height: 16),
              Text(name, style: Theme.of(context).textTheme.headlineSmall),
              if (time > 0) ...[
                const SizedBox(height: 8),
                _SheetTimeRow(minutes: time),
              ],
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 20),
              if (loading)
                for (int i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _Shimmer(
                      child: Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  )
              else if (steps.isEmpty)
                Text('No steps available.', style: TextStyle(color: colorScheme.onSurfaceVariant))
              else
                for (int i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(fontSize: 12, color: colorScheme.onPrimaryContainer),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(steps[i], style: Theme.of(context).textTheme.bodyMedium)),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// Small "Xh Ym" row with a clock icon, shared by the meal-plan recipe
/// preview sheets.
class _SheetTimeRow extends StatelessWidget {
  const _SheetTimeRow({required this.minutes});
  final int minutes;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule, size: 18, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          hours > 0 ? '${hours}h ${mins}m' : '${mins}m',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Bottom sheet previewing an own/new-idea recipe live from Firestore
/// (mirrors [_PublicRecipeSheet] for public-recipe slots, kept as a separate
/// small widget rather than a shared abstraction — see this file's other
/// small-duplicate notes) so a still-generating "new" idea's name/image/steps
/// pop in as they land, before the plan is confirmed.
class _OwnIdeaRecipeSheet extends StatelessWidget {
  const _OwnIdeaRecipeSheet({required this.name, required this.recipeDoc});

  final String name;
  final DocumentReference<Map<String, dynamic>> recipeDoc;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: recipeDoc.snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data();
          final images = List<String>.from(data?['images'] ?? const []);
          final steps = List<String>.from(data?['steps'] ?? const []);
          final description = (data?['description'] ?? '').toString();
          final time = (data?['time'] as num?)?.toInt() ?? 0;
          final pending = data?['pending'] as List?;
          final stepsDone = pending == null || !pending.contains('steps');
          final displayName = (data?['name'] as String?)?.isNotEmpty == true ? data!['name'] as String : name;
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: images.isNotEmpty
                      ? StorageImage(storagePath: images.first, fit: BoxFit.cover)
                      : _Shimmer(child: Container(color: colorScheme.surfaceContainerHighest)),
                ),
              ),
              const SizedBox(height: 16),
              Text(displayName, style: Theme.of(context).textTheme.headlineSmall),
              if (time > 0) ...[
                const SizedBox(height: 8),
                _SheetTimeRow(minutes: time),
              ],
              if (description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  description,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 20),
              if (!stepsDone)
                for (int i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _Shimmer(
                      child: Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  )
              else if (steps.isEmpty)
                Text('No steps available.', style: TextStyle(color: colorScheme.onSurfaceVariant))
              else
                for (int i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(fontSize: 12, color: colorScheme.onPrimaryContainer),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Text(steps[i], style: Theme.of(context).textTheme.bodyMedium)),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// Square shimmer standing in for a thumbnail while its image generates,
/// filling whatever space the parent (a fixed [_kTileHeight]x[_kTileHeight]
/// box) gives it.
class _ImageShimmer extends StatelessWidget {
  const _ImageShimmer();

  @override
  Widget build(BuildContext context) {
    return _Shimmer(
      child: Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
    );
  }
}

// =============================================================================
// Shimmer
// =============================================================================

/// Local duplicate of RecipeDetailPage's private `_Shimmer` (see this file's
/// other small-duplicate notes) — a sliding-gradient shader over its child.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            cs.surfaceContainerHighest,
            cs.surfaceContainerLow,
            cs.surfaceContainerHighest,
          ],
          stops: const [0.1, 0.5, 0.9],
          transform: _SlidingGradient(_c.value),
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}

class _SlidingGradient extends GradientTransform {
  const _SlidingGradient(this.t);
  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
}
