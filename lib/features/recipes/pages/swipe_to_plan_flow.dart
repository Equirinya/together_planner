import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:appinio_swiper/appinio_swiper.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/widgets/load_builders.dart';
import 'package:couple_planner/features/recipes/pages/meal_plan_shopping_list_page.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';
import 'package:couple_planner/features/recipes/services/swipe_session_service.dart';
import 'package:couple_planner/features/recipes/widgets/meal_plan_widgets.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_preview_sheet.dart';
import 'package:couple_planner/features/recipes/widgets/swipe_card.dart';
import 'package:couple_planner/features/recipes/widgets/swipe_result_tile.dart';

/// Swipe to Plan, end to end.
///
/// One page rather than a stack of pushed routes, because which step you belong
/// on is a property of the session, not of your navigation history: someone who
/// opens a "results are in" notification should land on the results, and
/// someone still mid-deck when the last other member finishes should not be
/// yanked out of it. So this widget watches the session document and renders
/// whichever step currently applies.
class SwipeToPlanFlow extends StatefulWidget {
  const SwipeToPlanFlow({
    super.key,
    required this.groupDoc,
    required this.sessionId,
  });

  final DocumentReference<Map<String, dynamic>> groupDoc;
  final String sessionId;

  @override
  State<SwipeToPlanFlow> createState() => _SwipeToPlanFlowState();
}

class _SwipeToPlanFlowState extends State<SwipeToPlanFlow> {
  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  /// Guards [_leaveCancelled] against firing on every rebuild of the stream.
  bool _leaving = false;

  /// A cancelled session has nothing to show, so this closes the flow rather
  /// than parking the user on a dead-end screen they have to back out of
  /// themselves — whether they cancelled it or someone else did.
  ///
  /// Deferred to after the frame because it runs from inside a build.
  void _leaveCancelled() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SwipeSession>(
      stream: watchSwipeSession(widget.groupDoc, widget.sessionId),
      builder: (context, snap) {
        if (snap.hasError) {
          return _shell(MealPlanErrorState(
            message: 'Could not load this session.',
            onRetry: () => setState(() {}),
          ));
        }
        if (!snap.hasData) {
          return _shell(const Center(child: CircularProgressIndicator()));
        }
        final session = snap.data!;

        if (session.status == SwipeSessionStatus.cancelled) {
          _leaveCancelled();
          // Only ever seen when there's nothing to pop to — i.e. the flow was
          // opened straight from a notification tap.
          return _shell(const _CentredMessage(
            icon: Icons.event_busy,
            title: 'This vote was closed',
            body: 'Someone cancelled it, or it expired before everyone swiped.',
          ));
        }

        if (!session.isParticipant(_uid)) {
          return _shell(const _CentredMessage(
            icon: Icons.lock_outline,
            title: 'Not part of this vote',
            body: 'You weren\'t included when this session was started.',
          ));
        }

        // A committed plan is history: it can be looked at, but there is
        // nothing left to change or confirm.
        if (session.status == SwipeSessionStatus.committed) {
          return SwipeResultsView(
            groupDoc: widget.groupDoc,
            session: session,
            readOnly: true,
          );
        }

        if (session.status == SwipeSessionStatus.ready) {
          return SwipeResultsView(
            groupDoc: widget.groupDoc,
            session: session,
            readOnly: false,
          );
        }

        if (session.hasFinished(_uid)) {
          return _WaitingRoom(session: session, uid: _uid);
        }

        return _SwipeDeckView(session: session, uid: _uid, groupDoc: widget.groupDoc);
      },
    );
  }

  Widget _shell(Widget body) => Scaffold(
        appBar: AppBar(title: const Text('Swipe to Plan')),
        body: body,
      );
}

// ─── Deck ───────────────────────────────────────────────────────────────────

class _SwipeDeckView extends StatefulWidget {
  const _SwipeDeckView({
    required this.session,
    required this.uid,
    required this.groupDoc,
  });

  final SwipeSession session;
  final String uid;
  final DocumentReference<Map<String, dynamic>> groupDoc;

  @override
  State<_SwipeDeckView> createState() => _SwipeDeckViewState();
}

class _SwipeDeckViewState extends State<_SwipeDeckView> {
  final _controller = AppinioSwiperController();
  final Map<String, Future<PublicRecipePreload>> _publicPreloads = {};

  /// Every verdict cast so far, card id → choice. Persisted after each swipe,
  /// so closing the app mid-deck loses nothing.
  final Map<String, SwipeChoice> _choices = {};

  /// The deck minus anything already swiped in an earlier sitting, so resuming
  /// picks up where it left off instead of replaying the whole thing.
  List<SwipeCard> _remaining = const [];
  bool _loading = true;
  bool _finishing = false;

  /// Live drag state, published without `setState`.
  ///
  /// `onCardPositionChanged` fires on every pointer move; routing that through
  /// `setState` rebuilt the whole screen each frame and made the drag stutter.
  /// Only the badge listens to this, so a drag now repaints one widget.
  final ValueNotifier<SwipeDragState> _drag =
      ValueNotifier<SwipeDragState>(const SwipeDragState());

  void _resetDragState() => _drag.value = const SwipeDragState();

  /// Guards the restore in `onSwipeEnd` against re-entering itself.
  bool _undoingDownSwipe = false;

  int get _total => widget.session.deck.length;
  int get _done => _choices.length;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final vote = await fetchOwnVote(widget.session, widget.uid);
    if (!mounted) return;
    setState(() {
      if (vote != null) _choices.addAll(vote.choices);
      _remaining =
          widget.session.deck.where((c) => !_choices.containsKey(c.cardId)).toList();
      _loading = false;
    });
    if (_remaining.isEmpty && _choices.isNotEmpty) _finish();
  }

  Future<void> _record(SwipeCard card, SwipeChoice choice) async {
    _choices[card.cardId] = choice;
    setState(() {});
    // Fire-and-forget: the deck must not stall behind a write, and the final
    // [finishSwiping] call rewrites the whole map anyway.
    unawaited(saveSwipeProgress(
      session: widget.session,
      uid: widget.uid,
      choices: _choices,
    ).catchError((_) {}));
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await finishSwiping(
        session: widget.session,
        uid: widget.uid,
        choices: _choices,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _finishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save your picks. Please try again.')),
      );
    }
    // On success the session stream flips this view to the waiting room, so
    // there is nothing to do here.
  }

  /// Buttons go through the controller, which raises the same `onSwipeEnd`
  /// with the matching direction — so a tapped verdict and a dragged one travel
  /// exactly the same path, and neither needs a special case when recording.
  void _swipeByButton(SwipeChoice choice) {
    switch (choice) {
      case SwipeChoice.dislike:
        _controller.swipeLeft();
      case SwipeChoice.like:
        _controller.swipeRight();
      case SwipeChoice.love:
        _controller.swipeUp();
    }
  }

  void _openPreview(SwipeCard card) {
    if (card.source == MealPlanSource.public && card.publicRecipeId != null) {
      openPublicRecipePreview(
        context,
        publicRecipeId: card.publicRecipeId!,
        name: card.name,
        image: card.image,
        publicPreload: (id) =>
            _publicPreloads.putIfAbsent(id, () => preloadPublicRecipe(id)),
      );
    } else if (card.recipeId != null) {
      openOwnRecipePreview(
        context,
        recipeId: card.recipeId!,
        source: card.source,
        groupDoc: widget.groupDoc,
        name: card.name,
        image: card.image,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Swipe to Plan')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_remaining.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Swipe to Plan')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Swipe to Plan'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _total == 0 ? 0 : _done / _total,
            minHeight: 4,
            backgroundColor: colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Text(
                  '$_done of $_total',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const Spacer(),
                Text(
                  'Swipe up to love it',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: AppinioSwiper(
              controller: _controller,
              cardCount: _remaining.length,
              loop: false,
              backgroundCardCount: _remaining.length >= 3 ? 2 : 0,
              backgroundCardOffset: const Offset(0, 32),
              maxAngle: 12,
              threshold: kSwipeThresholdPx,
              // All four directions are permitted, including down — not because
              // down means anything, but because disallowing it clamps the
              // card's *movement* on that axis, so after dragging up you could
              // no longer pull back toward centre. Down is neutralised below
              // instead, where it costs nothing.
              swipeOptions: const SwipeOptions.all(),
              // Pixel offsets, so the badge is computed from the same geometry
              // the user sees and the swiper resolves against.
              // Strength is measured off the raw pixel distance rather than the
              // swiper's own progress value, which grew at different rates per
              // direction — "Yes" arrived almost immediately while "No" and
              // "Love it" stayed nearly invisible. Distance over the same
              // threshold is symmetric by construction.
              onCardPositionChanged: (position) {
                _drag.value = SwipeDragState(
                  choice: swipeChoiceForOffset(position.offset),
                  strength: (position.offset.distance / kSwipeThresholdPx).clamp(0.0, 1.0),
                  index: position.index,
                );
              },
              // Fires the moment the swipe is committed, carrying the direction
              // the card is about to travel — so the vote recorded is by
              // definition the one the animation is showing.
              onSwipeEnd: (previousIndex, targetIndex, activity) {
                if (activity is! Swipe) return;
                _resetDragState();
                final choice = swipeChoiceForAxis(activity.direction);
                // Downward has no verdict attached, so a card that leaves that
                // way is put straight back. Cheaper than forbidding the
                // direction, which would also freeze the drag itself.
                if (choice == null) {
                  if (!_undoingDownSwipe) {
                    _undoingDownSwipe = true;
                    _controller.unswipe().whenComplete(() => _undoingDownSwipe = false);
                  }
                  return;
                }
                if (previousIndex < 0 || previousIndex >= _remaining.length) return;
                _record(_remaining[previousIndex], choice);
              },
              onSwipeCancelled: (_) => _resetDragState(),
              onEnd: _finish,
              cardBuilder: (context, index) => Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: SwipeCardView(
                  card: _remaining[index],
                  index: index,
                  drag: _drag,
                  onTap: () => _openPreview(_remaining[index]),
                ),
              ),
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _SwipeButton(
                  icon: Icons.close_rounded,
                  color: colorScheme.error,
                  tooltip: 'No',
                  onTap: _finishing
                      ? null
                      : () => _swipeByButton(SwipeChoice.dislike),
                ),
                _SwipeButton(
                  icon: Icons.favorite,
                  color: colorScheme.tertiary,
                  tooltip: 'Love it',
                  large: true,
                  onTap: _finishing
                      ? null
                      : () => _swipeByButton(SwipeChoice.love),
                ),
                _SwipeButton(
                  icon: Icons.check_rounded,
                  color: Colors.green.shade600,
                  tooltip: 'Yes',
                  onTap: _finishing
                      ? null
                      : () => _swipeByButton(SwipeChoice.like),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeButton extends StatelessWidget {
  const _SwipeButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.large = false,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? 68.0 : 56.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color.withOpacity(onTap == null ? 0.05 : 0.14),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: large ? 32 : 26,
              color: onTap == null ? color.withOpacity(0.35) : color,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Waiting room ───────────────────────────────────────────────────────────

class _WaitingRoom extends StatelessWidget {
  const _WaitingRoom({required this.session, required this.uid});

  final SwipeSession session;
  final String uid;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isHost = session.createdBy == uid;
    final done = session.finished.length;
    final total = session.participants.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Swipe to Plan')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(MdiIcons.timerSandComplete, size: 44, color: colorScheme.primary),
              const SizedBox(height: 18),
              Text(
                'Your picks are in',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '$done of $total have swiped. We\'ll let you know when the '
                'results are ready.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (final p in session.participants)
                    _ParticipantChip(uid: p, done: session.finished.contains(p)),
                ],
              ),
              if (isHost && session.remainingCount > 0) ...[
                const SizedBox(height: 32),
                Text(
                  'Waiting on someone who isn\'t swiping?',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _confirmCloseEarly(context),
                  icon: const Icon(Icons.how_to_vote_outlined),
                  label: const Text('Close voting now'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmCloseEarly(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close voting?'),
        content: Text(
          '${session.remainingCount} ${session.remainingCount == 1 ? "person hasn't" : "people haven't"} '
          'swiped yet. Their picks won\'t count.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close')),
        ],
      ),
    );
    if (ok == true) await closeSwipeVotingEarly(session);
  }
}

class _ParticipantChip extends StatelessWidget {
  const _ParticipantChip({required this.uid, required this.done});
  final String uid;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        done ? Icons.check_circle : Icons.hourglass_empty,
        size: 18,
        color: done ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      label: LoadDocumentBuilder(
        docRef: FirebaseFirestore.instance.collection('users_public').doc(uid),
        builder: (data) => Text((data['username'] ?? 'Member').toString()),
      ),
      backgroundColor: done ? colorScheme.primaryContainer.withOpacity(0.4) : null,
      side: done ? BorderSide.none : null,
    );
  }
}

// ─── Results ────────────────────────────────────────────────────────────────

/// The voted plan, ranked and assigned to days.
///
/// Editable while the session is `ready` — drag to reassign which recipe lands
/// on which date, drop one to pull the next-ranked card up, promote a runner-up.
/// Once someone approves, [readOnly] locks all of that: a committed plan is a
/// record of what the group decided, not a draft.
class SwipeResultsView extends StatefulWidget {
  const SwipeResultsView({
    super.key,
    required this.groupDoc,
    required this.session,
    required this.readOnly,
  });

  final DocumentReference<Map<String, dynamic>> groupDoc;
  final SwipeSession session;
  final bool readOnly;

  @override
  State<SwipeResultsView> createState() => _SwipeResultsViewState();
}

class _SwipeResultsViewState extends State<SwipeResultsView> {
  final Map<String, Future<PublicRecipePreload>> _publicPreloads = {};

  List<SwipeRanked>? _ranked;
  String? _error;
  bool _committing = false;

  /// What sits on each day, by index into `session.dates`. Null means that day
  /// has no pick.
  ///
  /// Together with [_pool] this replaced a single positional list where "the
  /// plan" was just the first N entries. That model had a fault no amount of
  /// index arithmetic could fix: with more liked recipes than days, dismissing
  /// repeatedly had to rotate through them, so the recipe you rejected two taps
  /// ago came back. Days and recipes are now separate things — days are fixed
  /// frames, recipes move between them and the pool — and a recipe only ever
  /// goes where it is dragged.
  ///
  /// Local until approval: two people rearranging at once are not synced, and
  /// the approver's arrangement is the one that commits.
  List<String?> _slots = [];

  /// Everything the group liked that isn't on a day, best first.
  List<String> _pool = [];

  /// True once the first snapshot has laid the plan out, so later snapshots
  /// update the ranking without resetting what the user has arranged.
  bool _arranged = false;

  StreamSubscription<List<SwipeVote>>? _votesSub;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _lang => LanguageService.instance.code.value;

  int get _filledDays => _slots.where((s) => s != null).length;

  // ── Auto-scroll while dragging ───────────────────────────────────────────
  //
  // A [Draggable] inside a scroll view does not scroll it: the pointer is
  // captured by the drag, so nothing reaches the scrollable. Without this,
  // picking a recipe out of the pool at the bottom of a seven-day plan means
  // there is no way to reach the days — you'd have to drop it, scroll, and
  // start again. So the drag position is watched directly and the view is
  // nudged whenever the pointer sits near an edge.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  double _autoScrollPerTick = 0;

  /// How close to an edge the pointer has to get, and the fastest it may scroll.
  static const double _autoScrollEdge = 96;
  static const double _autoScrollMaxSpeed = 16;

  void _onDragUpdate(DragUpdateDetails details) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final dy = box.globalToLocal(details.globalPosition).dy;

    double overshoot = 0;
    if (dy < _autoScrollEdge) {
      overshoot = dy - _autoScrollEdge; // negative → scroll up
    } else if (dy > box.size.height - _autoScrollEdge) {
      overshoot = dy - (box.size.height - _autoScrollEdge); // positive → down
    }

    if (overshoot == 0) {
      _stopAutoScroll();
      return;
    }
    // Ramp with distance past the edge, so a small overlap creeps and holding
    // the card at the very edge moves properly.
    final ratio = (overshoot / _autoScrollEdge).clamp(-1.0, 1.0);
    _autoScrollPerTick = ratio * _autoScrollMaxSpeed;
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = (position.pixels + _autoScrollPerTick)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (target == position.pixels) return;
      _scrollController.jumpTo(target);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _votesSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Subscribes to the votes rather than reading them once.
  ///
  /// This used to `await watchSwipeVotes(...).first`, which was wrong in a way
  /// that looked like it worked: Firestore emits the **cached** snapshot first
  /// and the server's a moment later, and a device's cache only holds the vote
  /// it wrote itself. So every member saw a tally built from their own vote
  /// alone and never anyone else's. Staying subscribed also means a vote that
  /// arrives while the screen is open is picked up instead of ignored.
  void _load() {
    _votesSub?.cancel();
    _votesSub = watchSwipeVotes(widget.session).listen(
      _applyVotes,
      onError: (Object _) {
        if (mounted) setState(() => _error = 'Could not load the results.');
      },
    );
  }

  void _applyVotes(List<SwipeVote> votes) {
    if (!mounted) return;
    final ranked = rankSwipeSession(widget.session, votes);
    // Only recipes somebody actually swiped right on are candidates at all.
    // The rest of the deck is noise here: nobody wants to scroll past twenty
    // rejected cards to find one they'd like to swap in.
    final liked = [
      for (final r in ranked)
        if (r.hasAnyLike) r.card.cardId,
    ];
    final dayCount = widget.session.dates.length;

    setState(() {
      _ranked = ranked;
      _error = null;

      if (!_arranged) {
        _arranged = true;
        final approved = widget.session.assignment;
        if (approved == null) {
          // Not simply the top N by score: within each block of equally-scored
          // recipes, [selectFairPlan] takes the one that best evens out who has
          // had something they loved. See its doc comment.
          final plan = selectFairPlan(
            ranked: ranked,
            participants: widget.session.participants,
            slots: dayCount,
          );
          _slots = [
            for (var i = 0; i < dayCount; i++)
              i < plan.length ? plan[i].card.cardId : null,
          ];
        } else {
          // A committed session replays exactly what was approved. Empty days
          // are stored as blanks so the day → recipe mapping survives gaps.
          _slots = [
            for (var i = 0; i < dayCount; i++)
              (i < approved.length && approved[i].isNotEmpty) ? approved[i] : null,
          ];
        }
        _pool = [
          for (final id in liked)
            if (!_slots.contains(id)) id,
        ];
        return;
      }

      // A later snapshot must not throw away an arrangement the user is in the
      // middle of. Newly-liked recipes join the pool; ones that are no longer
      // liked by anyone drop out of it.
      _pool = [
        for (final id in liked)
          if (!_slots.contains(id)) id,
      ];
      for (var i = 0; i < _slots.length; i++) {
        final id = _slots[i];
        if (id != null && !liked.contains(id)) _slots[i] = null;
      }
    });
  }

  @override
  void didUpdateWidget(SwipeResultsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Once someone approves, everyone's view must show *their* arrangement —
    // not the local rearranging this device happened to be playing with.
    final approved = widget.session.assignment;
    if (approved != null && oldWidget.session.assignment == null) {
      setState(() {
        _slots = [
          for (var i = 0; i < widget.session.dates.length; i++)
            (i < approved.length && approved[i].isNotEmpty) ? approved[i] : null,
        ];
        _pool = _pool.where((id) => !_slots.contains(id)).toList();
      });
    }
  }

  SwipeRanked? _rankedFor(String cardId) {
    for (final r in _ranked ?? const <SwipeRanked>[]) {
      if (r.card.cardId == cardId) return r;
    }
    return null;
  }

  /// Keeps the pool in score order, so a recipe returning to it lands where it
  /// belongs rather than wherever it was dropped from.
  void _sortPool() {
    final order = <String, int>{
      for (var i = 0; i < (_ranked?.length ?? 0); i++) _ranked![i].card.cardId: i,
    };
    _pool.sort((a, b) => (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30));
  }

  /// The single move primitive: put [cardId] on day [targetDay], or back in the
  /// pool when it's null.
  ///
  /// Dropping onto an occupied day swaps: the recipe already there takes the
  /// dragged one's old place, whether that was another day or the pool. Every
  /// outcome is therefore something the user can see and immediately undo by
  /// dragging back — there is no hidden "and then we picked the next best one"
  /// step, which is where the old model went wrong.
  void _move(String cardId, int? targetDay) {
    setState(() {
      final fromDay = _slots.indexOf(cardId);

      if (targetDay == null) {
        if (fromDay == -1) return; // already in the pool
        _slots[fromDay] = null;
        _pool.add(cardId);
        _sortPool();
        return;
      }

      final displaced = _slots[targetDay];
      if (displaced == cardId) return;

      if (fromDay != -1) {
        _slots[fromDay] = displaced; // may be null — that's a plain move
      } else {
        _pool.remove(cardId);
        if (displaced != null) _pool.add(displaced);
        _sortPool();
      }
      _slots[targetDay] = cardId;
    });
  }

  void _openPreview(SwipeCard card) {
    if (card.source == MealPlanSource.public && card.publicRecipeId != null) {
      openPublicRecipePreview(
        context,
        publicRecipeId: card.publicRecipeId!,
        name: card.name,
        image: card.image,
        publicPreload: (id) =>
            _publicPreloads.putIfAbsent(id, () => preloadPublicRecipe(id)),
      );
    } else if (card.recipeId != null) {
      openOwnRecipePreview(
        context,
        recipeId: card.recipeId!,
        source: card.source,
        groupDoc: widget.groupDoc,
        name: card.name,
        image: card.image,
      );
    }
  }

  Future<void> _approve() async {
    if (_committing || _filledDays == 0) return;
    setState(() => _committing = true);

    // Blanks keep the day → recipe mapping intact through a gap, so a plan with
    // nothing on Tuesday still puts Wednesday's pick on Wednesday.
    final assignment = [for (final s in _slots) s ?? ''];

    // Claim first, write second. The approve button is live for everyone the
    // moment the last person finishes, so two members can tap at the same
    // instant; the claim makes that first-tap-wins instead of writing the plan
    // twice.
    final claimed = await claimSwipeApproval(
      session: widget.session,
      uid: _uid,
      assignment: assignment,
    );
    if (!mounted) return;
    if (!claimed) {
      setState(() => _committing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Someone else just confirmed the plan.')),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const MealPlanBlockingDialog(text: 'Adding your plan…'),
    );

    final slots = <MealPlanSlot>[
      for (var i = 0; i < _slots.length; i++)
        if (_slots[i] case final cardId?)
          if (_rankedFor(cardId) case final ranked?)
            ranked.card.toSlot(widget.session.dates[i], reason: _reasonFor(ranked)),
    ];

    try {
      final committed = await commitMealPlan(
        group: widget.groupDoc,
        uid: _uid,
        lang: _lang,
        people: widget.session.people,
        slots: slots,
        publicPreloads: _publicPreloads,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // blocking dialog
      // Pushed, not replaced: backing out of the shopping list should land on
      // the plan that was just approved (the flow re-renders it read-only now
      // the session is committed), not drop the user out of the flow entirely.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MealPlanShoppingListPage(
            groupDoc: widget.groupDoc,
            committed: committed,
            people: widget.session.people,
          ),
        ),
      );
    } catch (_) {
      // Hand the approval back, so the group isn't left with a session marked
      // committed and no plan to show for it.
      await releaseSwipeApproval(widget.session).catchError((_) {});
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _committing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong while creating your plan.')),
      );
    }
  }

  /// Throws the whole vote away without planning anything.
  ///
  /// Needed because a session the group has decided against would otherwise sit
  /// there until it expires, blocking the one-open-session rule and leaving the
  /// planner tile stuck on "Results are in". Open to any participant, matching
  /// approval — but unlike approval it destroys everyone's swiping, so it asks
  /// first and says how many people's picks are about to go.
  Future<void> _discard() async {
    final others = widget.session.finished.length - 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this vote?'),
        content: Text(
          others > 0
              ? 'Nothing will be planned, and the picks from you and '
                  '$others ${others == 1 ? "other person" : "other people"} are gone. '
                  'You can always start a new round.'
              : 'Nothing will be planned and your picks are gone. You can always '
                  'start a new round.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      // The flow pops itself once the session turns up cancelled, so there's
      // nothing to navigate here.
      await cancelSwipeSession(widget.session);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not discard the vote. Please try again.')),
      );
    }
  }

  /// A short, user-facing note in place of the AI planner's generated reason.
  String _reasonFor(SwipeRanked ranked) {
    final everyone = widget.session.participants.length;
    if (ranked.lovedBy.isNotEmpty && ranked.lovedBy.length == everyone) {
      return 'Everyone loved it';
    }
    if (ranked.likedBy.length == everyone) return 'Everyone liked it';
    if (ranked.lovedBy.isNotEmpty) return 'A favourite';
    return '${ranked.likedBy.length} liked it';
  }

  /// A results card wired up for dragging onto a day or back into the pool.
  Widget _draggableTile({
    required String cardId,
    required SwipeRanked ranked,
    required double maxScore,
    bool dimmed = false,
    BorderRadius? borderRadius,
  }) {
    return _DraggableRecipeTile(
      key: ValueKey('drag-$cardId'),
      cardId: cardId,
      ranked: ranked,
      maxScore: maxScore,
      participantCount: widget.session.participants.length,
      dimmed: dimmed,
      borderRadius: borderRadius,
      onTap: () => _openPreview(ranked.card),
      onDragUpdate: _onDragUpdate,
      onDragStopped: _stopAutoScroll,
    );
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.readOnly;
    final colorScheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: MealPlanErrorState(
          message: _error!,
          onRetry: () {
            setState(() => _error = null);
            _load();
          },
        ),
      );
    }
    if (_ranked == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final maxScore = _ranked!.isEmpty ? 0.0 : _ranked!.first.score;
    final dates = widget.session.dates;
    final participantCount = widget.session.participants.length;
    final nothingLiked = _slots.every((s) => s == null) && _pool.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(readOnly ? 'The plan' : 'Results'),
        actions: [
          // Only while the vote is still live: a committed plan is history, and
          // discarding it here wouldn't unpick the days already written.
          if (!readOnly)
            IconButton(
              tooltip: 'Discard this vote',
              onPressed: _committing ? null : _discard,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Column(
        children: [
          if (readOnly) _CommittedBanner(session: widget.session),
          if (nothingLiked)
            const Expanded(
              child: _CentredMessage(
                icon: Icons.sentiment_neutral,
                title: 'No agreement this time',
                body: 'Nobody swiped right on anything, so there\'s nothing to '
                    'plan. Start another round whenever you like.',
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                key: _viewportKey,
                controller: _scrollController,
                // Narrow side padding so the day frames get as much width as
                // possible; extra bottom room while the approve bar is there,
                // so the last row can grow to two lines without hiding behind
                // the button.
                padding: EdgeInsets.fromLTRB(10, 12, 10, readOnly ? 24 : 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── The days: fixed frames, recipes move between them
                    for (var i = 0; i < dates.length; i++)
                      DragTarget<String>(
                        onWillAcceptWithDetails: (_) => !readOnly,
                        onAcceptWithDetails: (d) => _move(d.data, i),
                        builder: (context, candidate, rejected) {
                          final cardId = _slots[i];
                          final ranked = cardId == null ? null : _rankedFor(cardId);
                          return SwipeDaySlot(
                            date: dates[i],
                            highlighted: candidate.isNotEmpty,
                            child: ranked == null
                                ? SwipeEmptySlot(canDrag: !readOnly)
                                : readOnly
                                    ? SwipeResultTile(
                                        ranked: ranked,
                                        maxScore: maxScore,
                                        participantCount: participantCount,
                                        borderRadius: _slotCardRadius,
                                        onTap: () => _openPreview(ranked.card),
                                      )
                                    : _draggableTile(
                                        cardId: cardId!,
                                        ranked: ranked,
                                        maxScore: maxScore,
                                        // Flush to the frame's left, right and
                                        // bottom, so only the bottom corners
                                        // round.
                                        borderRadius: _slotCardRadius,
                                      ),
                          );
                        },
                      ),
                    // ── Everything else the group liked. Also a drop target, so
                    //    dragging a recipe down here takes it off its day.
                    DragTarget<String>(
                      onWillAcceptWithDetails: (_) => !readOnly,
                      onAcceptWithDetails: (d) => _move(d.data, null),
                      builder: (context, candidate, rejected) {
                        if (_pool.isEmpty && candidate.isEmpty) {
                          return const SizedBox(height: 8);
                        }
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.only(top: 6),
                          padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                          decoration: BoxDecoration(
                            color: candidate.isNotEmpty
                                ? colorScheme.surfaceContainerHighest
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _PoolHeader(count: _pool.length, readOnly: readOnly),
                              if (_pool.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                  child: Text(
                                    'Drop a recipe here to take it off its day',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                              for (final cardId in _pool)
                                if (_rankedFor(cardId) case final ranked?)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: readOnly
                                        ? SwipeResultTile(
                                            ranked: ranked,
                                            maxScore: maxScore,
                                            participantCount: participantCount,
                                            dimmed: true,
                                            onTap: () => _openPreview(ranked.card),
                                          )
                                        : _draggableTile(
                                            cardId: cardId,
                                            ranked: ranked,
                                            maxScore: maxScore,
                                            dimmed: true,
                                          ),
                                  ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: readOnly
          ? null
          : SafeArea(
              minimum: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: _committing || _filledDays == 0 ? null : _approve,
                icon: _committing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(MdiIcons.cardsHeartOutline),
                label: Text(
                  widget.session.isSolo
                      ? 'Add $_filledDays ${_filledDays == 1 ? "day" : "days"} to the plan'
                      : 'Approve for everyone',
                ),
              ),
            ),
    );
  }
}

/// Divider between the days and the recipes that didn't land on one.
class _PoolHeader extends StatelessWidget {
  const _PoolHeader({required this.count, required this.readOnly});
  final int count;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                count == 0 ? 'Also liked' : 'Also liked ($count)',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: colorScheme.outlineVariant, height: 1)),
            ],
          ),
          if (!readOnly) ...[
            const SizedBox(height: 4),
            Text(
              'Drag by the handle to swap in.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Corner rounding for a card sitting flush inside a [SwipeDaySlot]: the bottom
/// follows the frame's own radius, the top stays a normal card corner so it
/// still reads as a card sitting in a frame rather than a filled-in panel.
const BorderRadius _slotCardRadius = BorderRadius.vertical(
  top: Radius.circular(16),
  bottom: Radius.circular(19),
);

/// A results card that can be picked up two ways: dragged straight from its
/// handle, or long-pressed anywhere on the card.
///
/// Both behave identically, and in both the dragged card stays pinned to the
/// horizontal centre of the screen while following the finger vertically — see
/// [_DraggableRecipeTileState._horizontalPin]. Flutter's default
/// `childDragAnchorStrategy` couldn't do either: it keeps the pointer at the
/// same spot *within the dragged child*, which is fine when child and feedback
/// are the same widget but sent the card flying sideways when the child was a
/// 40px handle and the feedback a full-width card.
class _DraggableRecipeTile extends StatefulWidget {
  const _DraggableRecipeTile({
    super.key,
    required this.cardId,
    required this.ranked,
    required this.maxScore,
    required this.participantCount,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragStopped,
    this.dimmed = false,
    this.borderRadius,
  });

  final String cardId;
  final SwipeRanked ranked;
  final double maxScore;
  final int participantCount;
  final VoidCallback onTap;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragStopped;
  final bool dimmed;
  final BorderRadius? borderRadius;

  @override
  State<_DraggableRecipeTile> createState() => _DraggableRecipeTileState();
}

class _DraggableRecipeTileState extends State<_DraggableRecipeTile> {
  /// Measures the laid-out card, so the feedback's width and the drag anchor
  /// come from the real thing rather than a guess about screen width.
  final GlobalKey _cardKey = GlobalKey();

  /// Horizontal correction applied to the feedback, updated on every drag
  /// update. See [_horizontalPin].
  final ValueNotifier<double> _xCorrection = ValueNotifier<double>(0);

  /// Global x of the pointer when the drag began.
  double _startX = 0;

  Size get _cardSize {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.hasSize == true
        ? box!.size
        : const Size(320, kSwipeResultTileMinHeight);
  }

  double get _pinnedLeft =>
      (MediaQuery.of(context).size.width - _cardSize.width) / 2;

  /// Pins the dragged card to the horizontal centre of the screen while letting
  /// it follow the finger vertically.
  ///
  /// This can't be done with [dragAnchorStrategy] alone: the anchor is computed
  /// once and Flutter then positions the feedback at `pointer - anchor` on
  /// *both* axes, so the card would always drift sideways with the thumb. The
  /// anchor therefore only sets the starting x, and [_xCorrection] cancels out
  /// each frame's horizontal movement — leaving `left` constant at
  /// [_pinnedLeft] no matter where the finger goes.
  Offset _horizontalPin(Draggable<Object> _, BuildContext __, Offset position) {
    _startX = position.dx;
    _xCorrection.value = 0;
    return Offset(position.dx - _pinnedLeft, _cardSize.height / 2);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _xCorrection.value = _startX - details.globalPosition.dx;
    widget.onDragUpdate(details);
  }

  void _onDragStopped() {
    _xCorrection.value = 0;
    widget.onDragStopped();
  }

  Widget _buildFeedback(BuildContext context) {
    // Built lazily at drag start, so [_cardSize] is already measured.
    final width = _cardSize.width;
    return ValueListenableBuilder<double>(
      valueListenable: _xCorrection,
      builder: (context, dx, child) => Transform.translate(
        offset: Offset(dx, 0),
        child: child,
      ),
      child: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: width,
          child: SwipeResultTile(
            ranked: widget.ranked,
            maxScore: widget.maxScore,
            participantCount: widget.participantCount,
            borderRadius: BorderRadius.circular(16),
            elevated: true,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _xCorrection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedback = Builder(builder: _buildFeedback);

    final card = SwipeResultTile(
      key: _cardKey,
      ranked: widget.ranked,
      maxScore: widget.maxScore,
      participantCount: widget.participantCount,
      dimmed: widget.dimmed,
      borderRadius: widget.borderRadius,
      onTap: widget.onTap,
      // Dragging by the handle starts immediately — no press-and-wait for the
      // gesture people will reach for most.
      dragHandle: Draggable<String>(
        data: widget.cardId,
        feedback: feedback,
        dragAnchorStrategy: _horizontalPin,
        onDragUpdate: _onDragUpdate,
        onDragEnd: (_) => _onDragStopped(),
        onDraggableCanceled: (_, __) => _onDragStopped(),
        onDragCompleted: _onDragStopped,
        childWhenDragging: const Opacity(opacity: 0.4, child: SwipeDragHandle()),
        child: const SwipeDragHandle(),
      ),
    );

    // Long-pressing anywhere on the card does the same thing, for people who
    // don't spot the handle. It loses the arena to the handle's immediate
    // recognizer, so a drag that starts on the handle never triggers both.
    return LongPressDraggable<String>(
      data: widget.cardId,
      feedback: feedback,
      dragAnchorStrategy: _horizontalPin,
      onDragUpdate: _onDragUpdate,
      onDragEnd: (_) => _onDragStopped(),
      onDraggableCanceled: (_, __) => _onDragStopped(),
      onDragCompleted: _onDragStopped,
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }
}

/// Header shown on an already-committed plan, so it's obvious why nothing on
/// the screen can be changed.
class _CommittedBanner extends StatelessWidget {
  const _CommittedBanner({required this.session});
  final SwipeSession session;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final approver = session.approvedBy;
    return Container(
      width: double.infinity,
      color: colorScheme.primaryContainer.withOpacity(0.5),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: colorScheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: approver == null
                ? const Text('This plan has been added to your calendar.')
                : LoadDocumentBuilder(
                    docRef: FirebaseFirestore.instance.collection('users_public').doc(approver),
                    builder: (data) => Text(
                      '${data['username'] ?? 'Someone'} confirmed this plan. '
                      'It\'s already in your calendar.',
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CentredMessage extends StatelessWidget {
  const _CentredMessage({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
