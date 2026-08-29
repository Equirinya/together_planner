import 'package:couple_planner/features/money/models/money_entry.dart';

/// One entry's contribution to what a person owes another person. Used by the
/// "what does this payment cover?" expander on the settle-up screen.
class DebtSource {
  const DebtSource({
    required this.entryId,
    required this.description,
    required this.date,
    required this.amount,
    required this.isSettlement,
  });

  final String entryId;
  final String description;
  final DateTime date;

  /// Minor units this entry contributed to the debt, always positive.
  final int amount;
  final bool isSettlement;
}

/// The computed state of a group's money: who is up, who is down, who owes
/// whom, and which entries produced each of those debts.
class Ledger {
  const Ledger({
    required this.net,
    required this.owes,
    required this.sources,
    required this.invalid,
  });

  /// Resolved identity -> net minor units. Positive means they are owed money.
  /// Sums to zero by construction, because every entry balances internally.
  final Map<String, int> net;

  /// debtor -> creditor -> minor units, after cancelling opposite directions.
  /// This is the *raw* pairwise truth; it is never shown as the settle-up
  /// plan, only used to explain one (see [sourcesFor]).
  final Map<String, Map<String, int>> owes;

  /// `<debtor>|<creditor>` -> the entries that produced that debt, newest
  /// first. Kept un-netted, so both directions of a pair are present.
  final Map<String, List<DebtSource>> sources;

  /// Entries whose `paidBy` / `owes` do not sum to their amount. Excluded from
  /// every number above and surfaced in the UI instead.
  final List<MoneyEntry> invalid;

  int netFor(String identity) => net[identity] ?? 0;

  List<DebtSource> sourcesFor(String debtor, String creditor) =>
      sources['$debtor|$creditor'] ?? const [];

  /// Everyone with a non-zero balance, largest creditor first.
  List<String> get openIdentities {
    final ids = net.entries.where((e) => e.value != 0).map((e) => e.key).toList()
      ..sort((a, b) {
        final byAmount = net[b]!.compareTo(net[a]!);
        return byAmount != 0 ? byAmount : a.compareTo(b);
      });
    return ids;
  }

  bool get isSettled => net.values.every((v) => v == 0);
}

/// Folds a list of entries into a [Ledger].
///
/// [resolve] maps a raw person id onto its identity — this is where a claimed
/// placeholder collapses onto the uid of the member who claimed it, without
/// any of the stored entries being touched.
Ledger buildLedger(
  List<MoneyEntry> entries,
  String Function(String personId) resolve,
) {
  final net = <String, int>{};
  final raw = <String, Map<String, int>>{};
  final sources = <String, List<DebtSource>>{};
  final invalid = <MoneyEntry>[];

  // Oldest first, so each debt's source list ends up in chronological order.
  final ordered = List<MoneyEntry>.of(entries)
    ..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });

  for (final entry in ordered) {
    if (!entry.isValid) {
      invalid.add(entry);
      continue;
    }

    // What this entry does to each identity: positive means "owes for it".
    final delta = <String, int>{};
    entry.paidBy.forEach((person, amount) {
      final id = resolve(person);
      delta[id] = (delta[id] ?? 0) - amount;
    });
    entry.owes.forEach((person, amount) {
      final id = resolve(person);
      delta[id] = (delta[id] ?? 0) + amount;
    });

    delta.forEach((id, d) {
      net[id] = (net[id] ?? 0) - d;
    });

    // Turn this entry's deltas into concrete debtor -> creditor edges so the
    // debt can be explained later. Deterministic ordering (largest first, then
    // by id) means every device derives the same edges.
    final debtors = delta.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) {
        final byAmount = b.value.compareTo(a.value);
        return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
      });
    final creditors = delta.entries.where((e) => e.value < 0).toList()
      ..sort((a, b) {
        final byAmount = a.value.compareTo(b.value);
        return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
      });

    var di = 0;
    var ci = 0;
    var owedByDebtor = debtors.isEmpty ? 0 : debtors[0].value;
    var owedToCreditor = creditors.isEmpty ? 0 : -creditors[0].value;
    while (di < debtors.length && ci < creditors.length) {
      final amount = owedByDebtor < owedToCreditor ? owedByDebtor : owedToCreditor;
      if (amount > 0) {
        final debtor = debtors[di].key;
        final creditor = creditors[ci].key;
        final bucket = raw.putIfAbsent(debtor, () => <String, int>{});
        bucket[creditor] = (bucket[creditor] ?? 0) + amount;
        sources.putIfAbsent('$debtor|$creditor', () => <DebtSource>[]).add(
              DebtSource(
                entryId: entry.id,
                description: entry.description,
                date: entry.date,
                amount: amount,
                isSettlement: entry.type == MoneyEntryType.settlement,
              ),
            );
      }
      owedByDebtor -= amount;
      owedToCreditor -= amount;
      if (owedByDebtor == 0) {
        di++;
        if (di < debtors.length) owedByDebtor = debtors[di].value;
      }
      if (owedToCreditor == 0) {
        ci++;
        if (ci < creditors.length) owedToCreditor = -creditors[ci].value;
      }
    }
  }

  // Cancel opposite directions of each pair, so "you owe Anna 12, Anna owes
  // you 5" reads as "you owe Anna 7".
  for (final debtor in raw.keys.toList()) {
    for (final creditor in raw[debtor]!.keys.toList()) {
      final forward = raw[debtor]?[creditor] ?? 0;
      final backward = raw[creditor]?[debtor] ?? 0;
      if (forward <= 0 || backward <= 0) continue;
      final cancelled = forward < backward ? forward : backward;
      raw[debtor]![creditor] = forward - cancelled;
      raw[creditor]![debtor] = backward - cancelled;
    }
  }
  for (final debtor in raw.keys.toList()) {
    raw[debtor]!.removeWhere((_, v) => v <= 0);
    if (raw[debtor]!.isEmpty) raw.remove(debtor);
  }

  net.removeWhere((_, v) => v == 0);

  for (final list in sources.values) {
    list.sort((a, b) => b.date.compareTo(a.date));
  }

  return Ledger(net: net, owes: raw, sources: sources, invalid: invalid);
}

/// What a single entry does to one resolved [identity]: positive means the
/// entry left them up (they paid more than their share), negative means down.
int entryNetFor(
  MoneyEntry entry,
  String identity,
  String Function(String personId) resolve,
) {
  var net = 0;
  entry.paidBy.forEach((person, amount) {
    if (resolve(person) == identity) net += amount;
  });
  entry.owes.forEach((person, amount) {
    if (resolve(person) == identity) net -= amount;
  });
  return net;
}

/// Whether [identity] appears in [entry] at all.
bool entryInvolves(
  MoneyEntry entry,
  String identity,
  String Function(String personId) resolve,
) {
  for (final person in entry.people) {
    if (resolve(person) == identity) return true;
  }
  return false;
}
