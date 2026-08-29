import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_category.dart';
import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/money_person.dart';
import 'package:couple_planner/features/money/pages/add_expense_page.dart';
import 'package:couple_planner/features/money/pages/entry_detail_page.dart';
import 'package:couple_planner/features/money/pages/money_people_page.dart';
import 'package:couple_planner/features/money/pages/settle_up_page.dart';
import 'package:couple_planner/features/money/services/balance_engine.dart';
import 'package:couple_planner/features/money/services/money_format.dart';
import 'package:couple_planner/features/money/services/money_repository.dart';

/// The Money tab: a summary of where everyone stands, plus the group's
/// activity. Every other money screen is pushed from here.
///
/// All the state for the feature is assembled in this one place — the entries,
/// the people, the resolved balances — and handed down as a [MoneyContext], so
/// there is exactly one ledger in the app at a time.
class MoneyPage extends StatefulWidget {
  const MoneyPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<MoneyPage> createState() => _MoneyPageState();
}

class _MoneyPageState extends State<MoneyPage> {
  late final MoneyRepository _repo = MoneyRepository(widget.groupId);

  StreamSubscription<List<MoneyEntry>>? _entriesSub;
  StreamSubscription<List<MoneyPerson>>? _peopleSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _groupSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _membersSub;

  List<MoneyEntry> _entries = const [];
  List<MoneyPerson> _people = const [];
  List<String> _memberUids = const [];
  Map<String, String> _usernames = const {};
  String _currency = 'EUR';
  bool _isAdmin = false;

  bool _entriesReady = false;
  bool _membersReady = false;

  /// Group ids for which this user dismissed the "are you one of these people?"
  /// banner. Per device, same idea as the recipe feature's local settings.
  bool _claimDismissed = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get _claimPrefKey => 'money_claim_dismissed_${widget.groupId}';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _entriesSub = _repo.watchEntries().listen((entries) {
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _entriesReady = true;
      });
    }, onError: (Object e) => debugPrint('money entries: $e'));

    _peopleSub = _repo.watchPeople().listen((people) {
      if (!mounted) return;
      setState(() => _people = people);
    }, onError: (Object e) => debugPrint('money people: $e'));

    _groupSub = _repo.watchGroup().listen((doc) {
      final currency = doc.data()?['currency'];
      if (!mounted || currency is! String || currency.isEmpty) return;
      setState(() => _currency = currency);
    }, onError: (Object e) => debugPrint('money group: $e'));

    _membersSub = _repo.watchMembers().listen((snap) async {
      final uids = <String>[];
      var admin = false;
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['status'] == 'left') continue;
        if (data['role'] == 'recipe_viewer') continue;
        uids.add(doc.id);
        if (doc.id == _uid && data['role'] == 'admin') admin = true;
      }
      final missing = uids.where((u) => !_usernames.containsKey(u));
      final names = missing.isEmpty
          ? const <String, String>{}
          : await _repo.loadUsernames(missing);
      if (!mounted) return;
      setState(() {
        _memberUids = uids;
        _isAdmin = admin;
        _usernames = {..._usernames, ...names};
        _membersReady = true;
      });
    }, onError: (Object e) => debugPrint('money members: $e'));
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _claimDismissed = prefs.getBool(_claimPrefKey) ?? false);
  }

  @override
  void dispose() {
    _entriesSub?.cancel();
    _peopleSub?.cancel();
    _groupSub?.cancel();
    _membersSub?.cancel();
    super.dispose();
  }

  // ── derived state ─────────────────────────────────────────────────────────

  MoneyContext get _ctx {
    final directory = MoneyDirectory(
      myUid: _uid,
      memberUids: _memberUids,
      people: _people,
      usernames: _usernames,
    );
    return MoneyContext(
      repo: _repo,
      format: MoneyFormat(_currency),
      directory: directory,
      entries: _entries,
      ledger: buildLedger(_entries, directory.resolve),
      isAdmin: _isAdmin,
    );
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _dismissClaim() async {
    setState(() => _claimDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_claimPrefKey, true);
  }

  Future<void> _claim(MoneyPerson person) async {
    try {
      await _repo.setPersonClaim(person.id, _uid);
      await _dismissClaim();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Linked you to ${person.name}.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not link you to that person.')),
      );
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_entriesReady || !_membersReady) {
      return const Center(child: CircularProgressIndicator());
    }

    final ctx = _ctx;
    final claimable = _claimDismissed ? const <MoneyPerson>[] : ctx.directory.claimable;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(AddExpensePage(ctx: ctx)),
        icon: const Icon(Icons.add),
        label: const Text('Expense'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (claimable.isNotEmpty) _claimBanner(claimable),
          if (ctx.ledger.invalid.isNotEmpty) _invalidBanner(ctx),
          _summaryCard(ctx),
          ..._activity(ctx),
        ],
      ),
    );
  }

  // ── banners ───────────────────────────────────────────────────────────────

  Widget _claimBanner(List<MoneyPerson> claimable) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Are you one of these people?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Someone added them before you joined. Picking yourself moves '
              'their expenses onto your account.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final person in claimable)
                  ActionChip(
                    avatar: const Icon(Icons.person_outline, size: 18),
                    label: Text("I'm ${person.name}"),
                    onPressed: () => _claim(person),
                  ),
                TextButton(
                  onPressed: _dismissClaim,
                  child: const Text('None of these'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _invalidBanner(MoneyContext ctx) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_outlined, color: scheme.onErrorContainer),
        title: Text(
          '${ctx.ledger.invalid.length} entr'
          '${ctx.ledger.invalid.length == 1 ? 'y does' : 'ies do'} not add up',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: Text(
          'They are left out of the balances. Tap to fix.',
          style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
        ),
        onTap: () => _open(EntryDetailPage(ctx: ctx, entry: ctx.ledger.invalid.first)),
      ),
    );
  }

  // ── summary ───────────────────────────────────────────────────────────────

  Widget _summaryCard(MoneyContext ctx) {
    final scheme = Theme.of(context).colorScheme;
    final net = ctx.myNet;
    final settled = ctx.ledger.isSettled;

    final String headline;
    final Color color;
    if (settled || net == 0) {
      headline = settled ? 'Everyone is settled up' : "You're settled up";
      color = scheme.onSurface;
    } else if (net > 0) {
      headline = 'You are owed ${ctx.format.formatAbs(net)}';
      color = Colors.green.shade700;
    } else {
      headline = 'You owe ${ctx.format.formatAbs(net)}';
      color = scheme.error;
    }

    // The card is the way into settle-up: the balances used to sit on this
    // screen, and now they live on that page together with the plan for
    // clearing them. Managing people is a different kind of action, so its
    // button sits outside the card rather than on top of the tap target.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              child: InkWell(
                onTap: () => _open(SettleUpPage(ctx: ctx)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(color: color, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(Icons.handshake_outlined,
                              size: 16, color: scheme.outline),
                          const SizedBox(width: 6),
                          Text(
                            settled ? 'Balances and payments' : 'Settle up',
                            style: TextStyle(fontSize: 13, color: scheme.outline),
                          ),
                          const Spacer(),
                          Icon(Icons.chevron_right,
                              size: 18, color: scheme.outline),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.manage_accounts_outlined),
            tooltip: 'People',
            onPressed: () => _open(MoneyPeoplePage(ctx: ctx)),
          ),
        ],
      ),
    );
  }

  // ── activity ──────────────────────────────────────────────────────────────

  List<Widget> _activity(MoneyContext ctx) {
    if (ctx.entries.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            children: [
              Icon(Icons.account_balance_wallet_outlined, size: 40),
              SizedBox(height: 12),
              Text(
                'No expenses yet. Add the first one and it will be split '
                'between the people you pick.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ];
    }

    final widgets = <Widget>[const _SectionHeader('Activity')];
    String? lastMonth;
    for (final entry in ctx.entries) {
      final month = _monthLabel(entry.date);
      if (month != lastMonth) {
        lastMonth = month;
        widgets.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(month,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.outline,
              )),
        ));
      }
      widgets.add(_entryTile(ctx, entry));
    }
    return widgets;
  }

  Widget _entryTile(MoneyContext ctx, MoneyEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final settlement = entry.type == MoneyEntryType.settlement;
    final mine = ctx.myShareOf(entry);

    String title;
    if (settlement) {
      final from = ctx.directory.properNameFor(ctx.resolve(entry.settlementFrom ?? ''));
      final to = ctx.directory.properNameFor(ctx.resolve(entry.settlementTo ?? ''));
      title = '$from paid $to';
    } else {
      title = entry.description.isEmpty ? 'Expense' : entry.description;
    }

    final String subtitle;
    if (!ctx.involvesMe(entry)) {
      subtitle = 'not involving you';
    } else if (settlement) {
      subtitle = mine > 0 ? 'you paid' : 'you received';
    } else if (mine > 0) {
      subtitle = 'you lent ${ctx.format.formatAbs(mine)}';
    } else if (mine < 0) {
      subtitle = 'your share ${ctx.format.formatAbs(mine)}';
    } else {
      subtitle = 'your share is nothing';
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: settlement ? scheme.tertiaryContainer : scheme.secondaryContainer,
        foregroundColor: settlement ? scheme.onTertiaryContainer : scheme.onSecondaryContainer,
        child: Icon(
          settlement ? Icons.handshake_outlined : moneyCategoryIcon(entry.category),
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
          if (entry.imagePath != null)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.image_outlined, size: 16),
            ),
        ],
      ),
      subtitle: Text('${_dayLabel(entry.date)} · $subtitle'),
      trailing: Text(
        ctx.format.format(entry.amount),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      onTap: () => _open(EntryDetailPage(ctx: ctx, entry: entry)),
    );
  }
}

// ── shared bits ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

const List<String> _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _monthLabel(DateTime date) {
  final now = DateTime.now();
  final name = _months[date.month - 1];
  return date.year == now.year ? name : '$name ${date.year}';
}

/// "Today", "Yesterday", or "5 Mar".
String _dayLabel(DateTime date) {
  final now = DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${date.day} ${_months[date.month - 1].substring(0, 3)}';
}
