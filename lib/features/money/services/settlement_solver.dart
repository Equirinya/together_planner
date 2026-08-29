/// One suggested payment in a settle-up plan.
class Payment {
  const Payment({required this.from, required this.to, required this.amount});

  /// Resolved identity of the person who pays.
  final String from;

  /// Resolved identity of the person who receives.
  final String to;

  /// Minor units. Always positive.
  final int amount;
}

/// The result of [minimalSettlement].
class SettlementPlan {
  const SettlementPlan({required this.payments, required this.optimal});

  final List<Payment> payments;

  /// True when the plan is provably the smallest possible number of payments.
  /// False when the group was too large for the exact solver and the greedy
  /// fallback was used (which is correct, just possibly one payment longer).
  final bool optimal;

  bool get isEmpty => payments.isEmpty;
  int get length => payments.length;
}

/// The largest number of non-zero balances the exact solver will attempt.
/// Cost is O(3^n); 3^14 is about 4.8M cheap integer operations, which stays
/// comfortably inside a frame budget even in a debug build. Above this the
/// greedy fallback takes over. In practice pair cancellation (below) has
/// already collapsed real household groups far below this.
const int kMaxExactSettlementSize = 14;

/// Computes the smallest set of payments that returns every balance to zero.
///
/// This is the "minimum cash flow" / optimal-account-balancing problem. If the
/// n people with a non-zero balance can be partitioned into k disjoint subsets
/// that each sum to zero, the minimum number of payments is exactly n - k,
/// because a zero-sum subset of size m always settles internally in m - 1
/// payments. Maximising k is NP-hard in general (it reduces from subset-sum),
/// which is also why the usual "biggest debtor pays biggest creditor" greedy
/// is not optimal: it never notices that {+50, -20, -30} settles as a group.
///
/// Three tiers, each verified by the next-simpler one:
///
///   0. Cancel exact opposite pairs. A zero-sum *pair* can always be part of
///      some optimal partition, so this never costs optimality, and it usually
///      empties the problem entirely for a two-person household.
///   1. Exact optimum by bitmask DP over zero-sum subsets, for the remaining
///      n <= [kMaxExactSettlementSize].
///   2. Greedy largest-against-largest, which yields at most n - 1 payments.
///
/// The result is checked before it is returned (every balance must end at
/// zero, every payment positive); if the check ever fails the greedy plan is
/// returned instead, so a wrong plan can never reach the screen.
SettlementPlan minimalSettlement(
  Map<String, int> balances, {
  int maxExact = kMaxExactSettlementSize,
}) {
  final net = <String, int>{};
  balances.forEach((id, value) {
    if (value != 0) net[id] = value;
  });
  if (net.isEmpty) return const SettlementPlan(payments: [], optimal: true);

  // Deterministic order everywhere, so every device renders the same plan.
  final ids = net.keys.toList()..sort();

  final payments = <Payment>[];
  var optimal = true;

  // ── Tier 0: exact opposite pairs ────────────────────────────────────────
  final remaining = <String, int>{for (final id in ids) id: net[id]!};
  final debtors = ids.where((id) => remaining[id]! < 0).toList();
  final creditors = ids.where((id) => remaining[id]! > 0).toList();
  for (final debtor in debtors) {
    if (remaining[debtor] == 0) continue;
    for (final creditor in creditors) {
      if (remaining[creditor] == 0) continue;
      if (remaining[creditor] != -remaining[debtor]!) continue;
      payments.add(Payment(
        from: debtor,
        to: creditor,
        amount: remaining[creditor]!,
      ));
      remaining[debtor] = 0;
      remaining[creditor] = 0;
      break;
    }
  }

  final open = ids.where((id) => remaining[id] != 0).toList();

  // ── Tier 1 / 2 ──────────────────────────────────────────────────────────
  if (open.isNotEmpty) {
    List<List<String>>? groups;
    if (open.length <= maxExact) {
      groups = _partitionIntoZeroSumGroups(open, remaining);
    }
    if (groups == null) {
      optimal = false;
      payments.addAll(_greedy(open, remaining));
    } else {
      for (final group in groups) {
        payments.addAll(_greedy(group, remaining));
      }
    }
  }

  // ── Verification ────────────────────────────────────────────────────────
  if (!_verify(net, payments)) {
    final all = ids.toList();
    final fallback = _greedy(all, {for (final id in all) id: net[id]!});
    return SettlementPlan(payments: _ordered(fallback), optimal: false);
  }

  return SettlementPlan(payments: _ordered(payments), optimal: optimal);
}

/// Largest debtor pays largest creditor, repeatedly. Correct for any zero-sum
/// input and never needs more than n - 1 payments, since every payment zeroes
/// at least one person.
List<Payment> _greedy(List<String> ids, Map<String, int> balances) {
  final debtors = ids.where((id) => balances[id]! < 0).toList()
    ..sort((a, b) {
      final byAmount = balances[a]!.compareTo(balances[b]!);
      return byAmount != 0 ? byAmount : a.compareTo(b);
    });
  final creditors = ids.where((id) => balances[id]! > 0).toList()
    ..sort((a, b) {
      final byAmount = balances[b]!.compareTo(balances[a]!);
      return byAmount != 0 ? byAmount : a.compareTo(b);
    });

  final owed = {for (final id in debtors) id: -balances[id]!};
  final due = {for (final id in creditors) id: balances[id]!};

  final out = <Payment>[];
  var di = 0;
  var ci = 0;
  while (di < debtors.length && ci < creditors.length) {
    final debtor = debtors[di];
    final creditor = creditors[ci];
    final amount = owed[debtor]! < due[creditor]! ? owed[debtor]! : due[creditor]!;
    if (amount > 0) {
      out.add(Payment(from: debtor, to: creditor, amount: amount));
      owed[debtor] = owed[debtor]! - amount;
      due[creditor] = due[creditor]! - amount;
    }
    if (owed[debtor] == 0) di++;
    if (due[creditor] == 0) ci++;
  }
  return out;
}

/// Partitions [ids] into the largest possible number of disjoint zero-sum
/// groups, which is what minimises the payment count. Returns null if [ids] is
/// too large or (impossibly, for a zero-sum input) cannot be partitioned.
///
/// dp[mask] = the most zero-sum groups the people in mask can be split into,
/// or -1 when they cannot be split at all. Fixing the lowest set bit of each
/// mask halves the sub-mask enumeration and removes duplicate work.
List<List<String>>? _partitionIntoZeroSumGroups(
  List<String> ids,
  Map<String, int> balances,
) {
  final n = ids.length;
  if (n == 0) return const [];
  if (n > 20) return null; // guards the 1 << n allocations
  final values = [for (final id in ids) balances[id]!];
  final full = (1 << n) - 1;

  final sums = List<int>.filled(1 << n, 0);
  for (var mask = 1; mask <= full; mask++) {
    final lowest = mask & -mask;
    sums[mask] = sums[mask ^ lowest] + values[_bitIndex(lowest)];
  }

  final dp = List<int>.filled(1 << n, -1);
  final choice = List<int>.filled(1 << n, 0);
  dp[0] = 0;
  for (var mask = 1; mask <= full; mask++) {
    final lowest = mask & -mask;
    var best = -1;
    var bestSub = 0;
    for (var sub = mask; sub > 0; sub = (sub - 1) & mask) {
      if (sub & lowest == 0) continue;
      if (sums[sub] != 0) continue;
      final rest = dp[mask ^ sub];
      if (rest < 0) continue;
      if (rest + 1 > best) {
        best = rest + 1;
        bestSub = sub;
      }
    }
    dp[mask] = best;
    choice[mask] = bestSub;
  }

  if (dp[full] < 0) return null;

  final groups = <List<String>>[];
  var mask = full;
  while (mask != 0) {
    final sub = choice[mask];
    if (sub == 0) return null;
    final group = <String>[];
    for (var i = 0; i < n; i++) {
      if (sub & (1 << i) != 0) group.add(ids[i]);
    }
    groups.add(group);
    mask ^= sub;
  }
  return groups;
}

/// Index of the single set bit in [lowest] (a power of two).
int _bitIndex(int lowest) {
  var index = 0;
  var value = lowest;
  while (value > 1) {
    value >>= 1;
    index++;
  }
  return index;
}

/// Applying [payments] must zero every balance, and no payment may be
/// non-positive. This is what makes the clever path safe: it is always checked
/// by the obvious one.
bool _verify(Map<String, int> net, List<Payment> payments) {
  final after = Map<String, int>.of(net);
  for (final p in payments) {
    if (p.amount <= 0) return false;
    if (p.from == p.to) return false;
    after[p.from] = (after[p.from] ?? 0) + p.amount;
    after[p.to] = (after[p.to] ?? 0) - p.amount;
  }
  return after.values.every((v) => v == 0);
}

List<Payment> _ordered(List<Payment> payments) {
  final out = List<Payment>.of(payments)
    ..sort((a, b) {
      final byAmount = b.amount.compareTo(a.amount);
      if (byAmount != 0) return byAmount;
      final byFrom = a.from.compareTo(b.from);
      return byFrom != 0 ? byFrom : a.to.compareTo(b.to);
    });
  return out;
}
