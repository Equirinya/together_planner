import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:couple_planner/features/recipes/services/meal_plan_service.dart';

/// Swipe to Plan: the group votes a meal plan into existence instead of the AI
/// proposing one.
///
/// The deck is built server-side (`recipes-createSwipeSession`) and frozen, so
/// everyone rates the same cards — a ranked score across different decks would
/// be meaningless. Everything after that is client-side: the ranking is a pure
/// function of the deck plus the vote docs, so any client can compute it and
/// two clients computing at once necessarily agree.

final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

// Deck sizing, mirrored from `swipeSession.ts` (DECK_BASE, CARDS_PER_DAY,
// MIN_DECK, MAX_DECK). Duplicated rather than fetched because the setup page
// has to tell the user how big a deck they're about to get *before* asking the
// server to build one — see the thin-collection warning on MealPlanSettingsPage.
// Keep the two in step; the server remains the authority on the actual deck.
const int kSwipeDeckBase = 8;
const int kSwipeCardsPerDay = 4;
const int kSwipeMinDeck = 12;
const int kSwipeMaxDeck = 40;

/// How many cards a session over [days] days aims for.
int swipeDeckSize(int days) =>
    (kSwipeDeckBase + days * kSwipeCardsPerDay).clamp(kSwipeMinDeck, kSwipeMaxDeck);

String swipeDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _parseDateKey(String s) {
  final parts = s.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

enum SwipeSessionStatus { collecting, ready, committed, cancelled }

SwipeSessionStatus _statusFrom(String? s) => switch (s) {
      'ready' => SwipeSessionStatus.ready,
      'committed' => SwipeSessionStatus.committed,
      'cancelled' => SwipeSessionStatus.cancelled,
      _ => SwipeSessionStatus.collecting,
    };

String statusToString(SwipeSessionStatus s) => switch (s) {
      SwipeSessionStatus.collecting => 'collecting',
      SwipeSessionStatus.ready => 'ready',
      SwipeSessionStatus.committed => 'committed',
      SwipeSessionStatus.cancelled => 'cancelled',
    };

/// How a swipe was cast. Deliberately three-valued rather than a bool: in a
/// two-person group plain like/dislike yields only three possible scores, so
/// [love] is what gives the ranking any resolution at all.
enum SwipeChoice { dislike, like, love }

/// One card in the frozen deck.
class SwipeCard {
  const SwipeCard({
    required this.cardId,
    required this.source,
    this.recipeId,
    this.publicRecipeId,
    required this.name,
    this.image,
    this.dietary = const [],
    this.time,
    this.usageHint,
  });

  final String cardId;
  final MealPlanSource source;
  final String? recipeId;
  final String? publicRecipeId;
  final String name;
  final String? image;
  final List<String> dietary;
  final int? time;

  /// Short "Never cooked" / "Cooked 3x" hint, own recipes only.
  final String? usageHint;

  factory SwipeCard.fromJson(Map<String, dynamic> json) => SwipeCard(
        cardId: (json['cardId'] ?? '').toString(),
        source: json['source'] == 'own' ? MealPlanSource.own : MealPlanSource.public,
        recipeId: json['recipeId'] as String?,
        publicRecipeId: json['publicRecipeId'] as String?,
        name: (json['name'] ?? '').toString(),
        image: json['image'] as String?,
        dietary: List<String>.from(json['dietary'] ?? const []),
        time: (json['time'] as num?)?.toInt(),
        usageHint: json['usageHint'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'cardId': cardId,
        'source': source == MealPlanSource.own ? 'own' : 'public',
        'recipeId': recipeId,
        'publicRecipeId': publicRecipeId,
        'name': name,
        'image': image,
        'dietary': dietary,
        'time': time,
        'usageHint': usageHint,
      };

  /// Converts a winning card into the same [MealPlanSlot] the AI planner
  /// produces, so the whole commit path downstream is shared verbatim.
  MealPlanSlot toSlot(DateTime date, {String reason = ''}) => MealPlanSlot(
        date: date,
        source: source,
        recipeId: recipeId,
        publicRecipeId: publicRecipeId,
        publicImage: image,
        name: name,
        reason: reason,
        dietary: dietary,
      );
}

/// A swipe session as stored under `groups/{id}/swipe_sessions/{id}`.
class SwipeSession {
  const SwipeSession({
    required this.id,
    required this.ref,
    required this.createdBy,
    required this.status,
    required this.dates,
    required this.people,
    required this.dietary,
    required this.participants,
    required this.finished,
    required this.deck,
    this.approvedBy,
    this.assignment,
    this.expiresAt,
  });

  final String id;
  final DocumentReference<Map<String, dynamic>> ref;
  final String createdBy;
  final SwipeSessionStatus status;
  final List<DateTime> dates;
  final int people;
  final List<String> dietary;
  final List<String> participants;
  final List<String> finished;
  final List<SwipeCard> deck;
  final String? approvedBy;

  /// Card ids in date order, written at approval — the record of what was
  /// actually decided, after any dragging.
  final List<String>? assignment;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && expiresAt!.isBefore(DateTime.now());
  bool get everyoneFinished => participants.every(finished.contains);
  int get remainingCount => participants.where((p) => !finished.contains(p)).length;
  bool hasFinished(String uid) => finished.contains(uid);
  bool isParticipant(String uid) => participants.contains(uid);

  /// True for a one-person session, where an approval step would just be a
  /// second confirm tap on the user's own choices.
  bool get isSolo => participants.length <= 1;

  factory SwipeSession.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data() ?? const {};
    return SwipeSession(
      id: snap.id,
      ref: snap.reference,
      createdBy: (data['createdBy'] ?? '').toString(),
      status: _statusFrom(data['status'] as String?),
      dates: [
        for (final d in List<dynamic>.from(data['dates'] ?? const []))
          _parseDateKey(d.toString()),
      ],
      people: (data['people'] as num?)?.toInt() ?? 2,
      dietary: List<String>.from(data['dietary'] ?? const []),
      participants: List<String>.from(data['participants'] ?? const []),
      finished: List<String>.from(data['finished'] ?? const []),
      deck: [
        for (final c in List<dynamic>.from(data['deck'] ?? const []))
          SwipeCard.fromJson(Map<String, dynamic>.from(c as Map)),
      ],
      approvedBy: data['approvedBy'] as String?,
      assignment: data['assignment'] == null
          ? null
          : List<String>.from(data['assignment'] as List),
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// One member's swipes. Stored per-user so security rules stay trivial
/// (`request.auth.uid == docId`) and concurrent voters never collide.
class SwipeVote {
  const SwipeVote({
    required this.uid,
    required this.choices,
    required this.seen,
    required this.finished,
  });

  final String uid;
  final Map<String, SwipeChoice> choices;
  final Set<String> seen;
  final bool finished;

  factory SwipeVote.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data() ?? const {};
    final choices = <String, SwipeChoice>{
      for (final id in List<String>.from(data['dislikes'] ?? const []))
        id: SwipeChoice.dislike,
      for (final id in List<String>.from(data['likes'] ?? const [])) id: SwipeChoice.like,
      for (final id in List<String>.from(data['loves'] ?? const [])) id: SwipeChoice.love,
    };
    return SwipeVote(
      uid: snap.id,
      choices: choices,
      seen: Set<String>.from(data['seen'] ?? const []),
      finished: data['finishedAt'] != null,
    );
  }
}

/// A card plus what the group thought of it.
class SwipeRanked {
  const SwipeRanked({
    required this.card,
    required this.score,
    required this.likedBy,
    required this.lovedBy,
    required this.dislikedBy,
    required this.seenBy,
  });

  final SwipeCard card;
  final double score;

  /// Everyone who swiped right or up — loves are also listed in [lovedBy], so
  /// the results screen can render them differently without a second lookup.
  final List<String> likedBy;
  final List<String> lovedBy;
  final List<String> dislikedBy;
  final int seenBy;

  bool get hasAnyLike => likedBy.isNotEmpty;
}

/// Ranks a session's deck from its votes.
///
/// `score = (2·loves + likes) / seenBy`. Normalising by [SwipeRanked.seenBy]
/// matters: if someone abandons the deck halfway, cards deep in the deck would
/// otherwise be structurally unable to win, because they'd be divided by a
/// participant count they never had a chance to earn.
///
/// Ties break on fewer dislikes, then on the deck's own (already random but
/// stable) order — so the result is deterministic and every client agrees.
List<SwipeRanked> rankSwipeSession(SwipeSession session, List<SwipeVote> votes) {
  final deckOrder = {
    for (var i = 0; i < session.deck.length; i++) session.deck[i].cardId: i,
  };

  final ranked = <SwipeRanked>[];
  for (final card in session.deck) {
    final likedBy = <String>[];
    final lovedBy = <String>[];
    final dislikedBy = <String>[];
    var seenBy = 0;
    var points = 0.0;

    for (final vote in votes) {
      final choice = vote.choices[card.cardId];
      if (choice == null && !vote.seen.contains(card.cardId)) continue;
      seenBy++;
      switch (choice) {
        case SwipeChoice.love:
          points += 2;
          likedBy.add(vote.uid);
          lovedBy.add(vote.uid);
        case SwipeChoice.like:
          points += 1;
          likedBy.add(vote.uid);
        case SwipeChoice.dislike:
          dislikedBy.add(vote.uid);
        case null:
          break;
      }
    }

    ranked.add(SwipeRanked(
      card: card,
      score: points / math.max(1, seenBy),
      likedBy: likedBy,
      lovedBy: lovedBy,
      dislikedBy: dislikedBy,
      seenBy: seenBy,
    ));
  }

  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byDislikes = a.dislikedBy.length.compareTo(b.dislikedBy.length);
    if (byDislikes != 0) return byDislikes;
    return (deckOrder[a.card.cardId] ?? 0).compareTo(deckOrder[b.card.cardId] ?? 0);
  });
  return ranked;
}

/// Chooses which recipes fill the plan, best score first, breaking ties so the
/// loves — and then the yeses — land as evenly across the group as possible.
///
/// Score alone leaves a lot undecided: several recipes routinely tie, and
/// taking whichever happened to sort first can hand every day to the same two
/// people while somebody else gets nothing they loved. So within each block of
/// equally-scored candidates this picks the one that most improves the person
/// currently doing worst.
///
/// "Doing worst" is decided by **leximin**: for each candidate, imagine picking
/// it, list how many loves each participant would then have, sort that list
/// ascending, and prefer the candidate whose list is lexicographically
/// greatest. Comparing sorted-ascending distributions is exactly "raise the
/// worst-off first, then the next worst-off" — the whole fairness rule in one
/// comparison, with no weights to tune. Yeses settle any remaining tie the
/// same way.
///
/// Worked example, 4 days: the first three go to recipes scoring 5, and after
/// them one participant still has no loved recipe. Among the recipes scoring 4,
/// the ones that person loves give a loves distribution of [1,1,1,1] where the
/// others give [0,1,1,2] — and [1,…] beats [0,…] on the first element, so the
/// fourth day goes to them.
///
/// Deterministic: [ranked] and [participants] are both in a fixed order and
/// only a strictly better candidate displaces the incumbent, so every client
/// computes the same plan from the same votes.
List<SwipeRanked> selectFairPlan({
  required List<SwipeRanked> ranked,
  required List<String> participants,
  required int slots,
}) {
  final pool = [
    for (final r in ranked)
      if (r.hasAnyLike) r,
  ];
  final loves = {for (final p in participants) p: 0};
  final likes = {for (final p in participants) p: 0};
  final chosen = <SwipeRanked>[];

  while (chosen.length < slots && pool.isNotEmpty) {
    // `pool` stays in score order, so the head is always the best remaining.
    final topScore = pool.first.score;
    final tied = [
      for (final r in pool)
        if ((r.score - topScore).abs() < 1e-9) r,
    ];

    var best = tied.first;
    for (final candidate in tied.skip(1)) {
      if (_compareFairness(candidate, best, loves, likes, participants) > 0) {
        best = candidate;
      }
    }

    for (final uid in best.lovedBy) {
      if (loves.containsKey(uid)) loves[uid] = loves[uid]! + 1;
    }
    for (final uid in best.likedBy) {
      if (likes.containsKey(uid)) likes[uid] = likes[uid]! + 1;
    }
    chosen.add(best);
    pool.remove(best);
  }
  return chosen;
}

/// Positive when [a] leaves the group better off than [b] would.
int _compareFairness(
  SwipeRanked a,
  SwipeRanked b,
  Map<String, int> loves,
  Map<String, int> likes,
  List<String> participants,
) {
  final byLoves = _compareLeximin(
    _distributionWith(loves, a.lovedBy, participants),
    _distributionWith(loves, b.lovedBy, participants),
  );
  if (byLoves != 0) return byLoves;
  // A love is also a yes, so `likedBy` already contains everyone who loved it;
  // this second pass only separates candidates the loves couldn't.
  return _compareLeximin(
    _distributionWith(likes, a.likedBy, participants),
    _distributionWith(likes, b.likedBy, participants),
  );
}

/// Per-participant counts as they would be after taking a candidate, sorted
/// ascending so the worst-off comes first.
List<int> _distributionWith(
  Map<String, int> counts,
  List<String> beneficiaries,
  List<String> participants,
) {
  final result = [
    for (final p in participants) (counts[p] ?? 0) + (beneficiaries.contains(p) ? 1 : 0),
  ];
  result.sort();
  return result;
}

int _compareLeximin(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}

// ─── Reads ──────────────────────────────────────────────────────────────────

CollectionReference<Map<String, dynamic>> _sessions(
        DocumentReference<Map<String, dynamic>> groupDoc) =>
    groupDoc.collection('swipe_sessions');

/// Watches the group's single open session (collecting or ready), or null.
/// Expired sessions are treated as absent so a stale vote nobody finished
/// doesn't block the entry tile forever.
Stream<SwipeSession?> watchOpenSwipeSession(DocumentReference<Map<String, dynamic>> groupDoc) {
  return _sessions(groupDoc)
      .where('status', whereIn: ['collecting', 'ready'])
      .limit(1)
      .snapshots()
      .map((snap) {
    if (snap.docs.isEmpty) return null;
    final session = SwipeSession.fromSnapshot(snap.docs.first);
    return session.isExpired ? null : session;
  });
}

/// One-shot equivalent of [watchOpenSwipeSession], for the places a live
/// stream can't be relied on — returning from the swipe flow, resuming the app,
/// or reviving a listener that died on an error.
Future<SwipeSession?> fetchOpenSwipeSession(
    DocumentReference<Map<String, dynamic>> groupDoc) async {
  final snap = await _sessions(groupDoc)
      .where('status', whereIn: ['collecting', 'ready'])
      .limit(1)
      .get();
  if (snap.docs.isEmpty) return null;
  final session = SwipeSession.fromSnapshot(snap.docs.first);
  return session.isExpired ? null : session;
}

Stream<SwipeSession> watchSwipeSession(
  DocumentReference<Map<String, dynamic>> groupDoc,
  String sessionId,
) =>
    _sessions(groupDoc).doc(sessionId).snapshots().map(SwipeSession.fromSnapshot);

Future<SwipeSession?> fetchSwipeSession(
  DocumentReference<Map<String, dynamic>> groupDoc,
  String sessionId,
) async {
  final snap = await _sessions(groupDoc).doc(sessionId).get();
  if (!snap.exists) return null;
  return SwipeSession.fromSnapshot(snap);
}

/// Watches every vote in a session.
///
/// Rules only permit reading other members' votes once everyone has finished,
/// so before that this effectively yields just the caller's own vote — which is
/// all the swipe screen needs, and is what stops anyone peeking mid-session.
Stream<List<SwipeVote>> watchSwipeVotes(SwipeSession session) => session.ref
    .collection('votes')
    .snapshots()
    .map((s) => s.docs.map(SwipeVote.fromSnapshot).toList());

Future<SwipeVote?> fetchOwnVote(SwipeSession session, String uid) async {
  final snap = await session.ref.collection('votes').doc(uid).get();
  if (!snap.exists) return null;
  return SwipeVote.fromSnapshot(snap);
}

// ─── Writes ─────────────────────────────────────────────────────────────────

/// Asks the server to build a deck and open a session. Returns the new id.
Future<String> createSwipeSession({
  required String groupId,
  required List<DateTime> dates,
  required int people,
  required List<String> dietary,
  required List<String> participants,
  bool includeOwn = true,
  bool includePublic = true,
}) async {
  final result = await _functions.httpsCallable('recipes-createSwipeSession').call({
    'groupId': groupId,
    'dates': dates.map(swipeDateKey).toList(),
    'people': people,
    'dietary': dietary,
    'participants': participants,
    'includeOwn': includeOwn,
    'includePublic': includePublic,
  });
  return (result.data as Map)['sessionId'].toString();
}

/// Persists progress after each swipe, so closing the app mid-deck loses
/// nothing. Written as a merge so the three choice arrays stay independent.
Future<void> saveSwipeProgress({
  required SwipeSession session,
  required String uid,
  required Map<String, SwipeChoice> choices,
}) async {
  await session.ref.collection('votes').doc(uid).set({
    'likes': [
      for (final e in choices.entries)
        if (e.value == SwipeChoice.like) e.key,
    ],
    'loves': [
      for (final e in choices.entries)
        if (e.value == SwipeChoice.love) e.key,
    ],
    'dislikes': [
      for (final e in choices.entries)
        if (e.value == SwipeChoice.dislike) e.key,
    ],
    'seen': choices.keys.toList(),
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

/// Marks this member's deck as done.
///
/// Also arrayUnions into the session's `finished` list for an instant UI
/// update; `onSwipeVoteWritten` reconciles the same field server-side (and
/// flips the session to `ready` when everyone is in), so a client that dies
/// between these two writes doesn't strand the session.
Future<void> finishSwiping({
  required SwipeSession session,
  required String uid,
  required Map<String, SwipeChoice> choices,
}) async {
  await saveSwipeProgress(session: session, uid: uid, choices: choices);
  await session.ref.collection('votes').doc(uid).set(
    {'finishedAt': FieldValue.serverTimestamp()},
    SetOptions(merge: true),
  );
  await session.ref.update({
    'finished': FieldValue.arrayUnion([uid]),
  }).catchError((_) {
    // The trigger will reconcile it; a failed optimistic write is not fatal.
  });
}

/// Closes voting even though some members never swiped — their empty votes
/// simply don't count. Offered to the host from the waiting room so one person
/// ghosting can't hold the plan indefinitely.
Future<void> closeSwipeVotingEarly(SwipeSession session) async {
  await session.ref.update({
    'status': 'ready',
    'readyAt': FieldValue.serverTimestamp(),
    'closedEarly': true,
  });
}

Future<void> cancelSwipeSession(SwipeSession session) async {
  await session.ref.update({'status': 'cancelled'});
}

/// Claims the approval for [uid] and records what was decided.
///
/// The approve button is live for everyone once the last person finishes, so
/// two members can tap at the same moment; the transaction makes it
/// first-tap-wins rather than last-write-wins. Returns false when someone else
/// got there first, so the caller can flip to the committed view instead of
/// writing a second plan.
Future<bool> claimSwipeApproval({
  required SwipeSession session,
  required String uid,
  required List<String> assignment,
}) async {
  return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
    final snap = await tx.get(session.ref);
    final status = _statusFrom(snap.data()?['status'] as String?);
    if (status != SwipeSessionStatus.ready) return false;
    tx.update(session.ref, {
      'approvedBy': uid,
      'approvedAt': FieldValue.serverTimestamp(),
      'assignment': assignment,
      'status': 'committed',
    });
    return true;
  });
}

/// Undoes [claimSwipeApproval] when the plan write that followed it failed, so
/// the group isn't left with a session marked committed and no actual plan.
Future<void> releaseSwipeApproval(SwipeSession session) async {
  await session.ref.update({
    'status': 'ready',
    'approvedBy': FieldValue.delete(),
    'approvedAt': FieldValue.delete(),
    'assignment': FieldValue.delete(),
  });
}
