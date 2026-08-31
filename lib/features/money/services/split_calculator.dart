import 'package:couple_planner/features/money/models/split_mode.dart';

/// Hard ceiling on a single entry, in minor units (1,000,000,000.00).
/// Mirrored in firestore.rules. Keeps `amount * weight` far inside a 64-bit
/// int even with absurd weights.
const int kMaxMoneyAmount = 100000000000;

/// Largest weight / share / percent-in-basis-points a single person may carry.
const int kMaxWeight = 1000000;

/// Shares are a plain multiplier and may be fractional: "this person counts
/// 1.5". Weights have to be whole numbers, so a share is carried internally as
/// thousandths. Scaling every weight by the same factor leaves the split
/// itself untouched, so this costs nothing but makes 1.5 mean what it says.
const int kShareScale = 1000;

/// 32-bit FNV-1a. Used only to break ties deterministically when handing out
/// leftover minor units, so every device produces the same split from the same
/// document while the "extra cent" still moves around between expenses.
/// Deliberately hand-rolled: it must never change with a package upgrade.
int _hash(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h ^= c & 0xFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Splits [amount] minor units across [weights] using the largest-remainder
/// method, so the result sums to [amount] **exactly** — no dust, ever.
///
///   W      = sum of weights
///   base_i = (amount * w_i) ~/ W
///   rem_i  = (amount * w_i) %  W
///   R      = amount - sum(base_i)
///
/// The R leftover units go one each to the largest remainders, tie-broken on
/// `hash(seed|personId)`. Passing the expense id as [seed] makes that
/// deterministic across devices but different per expense, so the same person
/// is not permanently the one paying the extra cent.
///
/// Somebody with weight 0 can never receive a leftover unit: their remainder
/// is 0, and R is always strictly smaller than the number of non-zero
/// remainders (each rem_i < W and sum(rem_i) == R * W).
Map<String, int> splitByWeights(
  int amount,
  Map<String, int> weights, {
  String seed = '',
}) {
  if (amount < 0) {
    throw ArgumentError.value(amount, 'amount', 'must not be negative');
  }
  final ids = weights.keys.toList()..sort();
  var total = 0;
  for (final id in ids) {
    final w = weights[id]!;
    if (w < 0) {
      throw ArgumentError.value(w, 'weights[$id]', 'must not be negative');
    }
    total += w;
  }
  if (total <= 0) {
    throw ArgumentError.value(weights, 'weights', 'must sum to a positive number');
  }

  final out = <String, int>{};
  final remainder = <String, int>{};
  var assigned = 0;
  for (final id in ids) {
    final product = amount * weights[id]!;
    final base = product ~/ total;
    out[id] = base;
    remainder[id] = product % total;
    assigned += base;
  }

  final leftover = amount - assigned;
  if (leftover > 0) {
    final order = List<String>.of(ids)
      ..sort((a, b) {
        final byRemainder = remainder[b]!.compareTo(remainder[a]!);
        if (byRemainder != 0) return byRemainder;
        final byHash = _hash('$seed|$a').compareTo(_hash('$seed|$b'));
        if (byHash != 0) return byHash;
        return a.compareTo(b);
      });
    for (var i = 0; i < leftover && i < order.length; i++) {
      out[order[i]] = out[order[i]]! + 1;
    }
  }
  return out;
}

/// Turns the raw per-person input of a [mode] into the final `owes` map.
///
/// Every mode funnels into [splitByWeights]; only [SplitMode.exact] and
/// [SplitMode.adjustment] need any preprocessing. Call [validateSplit] first —
/// this throws on input that does not satisfy the mode's constraint.
Map<String, int> resolveShares({
  required SplitMode mode,
  required int amount,
  required Map<String, num> input,
  String seed = '',
}) {
  final error = validateSplit(mode: mode, amount: amount, input: input);
  if (error != null) throw ArgumentError(error);

  switch (mode) {
    case SplitMode.equal:
      final weights = <String, int>{
        for (final e in input.entries)
          if (e.value > 0) e.key: 1,
      };
      return splitByWeights(amount, weights, seed: seed);

    case SplitMode.shares:
      // Scaled, so a fractional multiplier survives the trip to integers.
      final shares = <String, int>{
        for (final e in input.entries)
          if (e.value > 0) e.key: (e.value * kShareScale).round(),
      }..removeWhere((_, weight) => weight <= 0);
      return splitByWeights(amount, shares, seed: seed);

    case SplitMode.percent:
      // Percentages are already whole numbers: basis points.
      final weights = <String, int>{
        for (final e in input.entries)
          if (e.value > 0) e.key: e.value.round(),
      };
      return splitByWeights(amount, weights, seed: seed);

    case SplitMode.exact:
    case SplitMode.settlement:
      return {for (final e in input.entries) e.key: e.value.round()};

    case SplitMode.adjustment:
      // Everyone's fixed extra comes off the top; the rest is split evenly and
      // the extras are added back on.
      final adjustments = <String, int>{
        for (final e in input.entries) e.key: e.value.round(),
      };
      var fixed = 0;
      for (final v in adjustments.values) {
        fixed += v;
      }
      final rest = amount - fixed;
      final even = splitByWeights(
        rest,
        {for (final id in adjustments.keys) id: 1},
        seed: seed,
      );
      return {
        for (final id in adjustments.keys) id: even[id]! + adjustments[id]!,
      };
  }
}

/// Returns a human-readable reason the given input cannot be used, or null
/// when it is valid. Drives the disabled state (and the explanation) of the
/// Save button in the add-expense screen.
String? validateSplit({
  required SplitMode mode,
  required int amount,
  required Map<String, num> input,
}) {
  if (amount <= 0) return 'Enter an amount first.';
  if (amount > kMaxMoneyAmount) return 'That amount is too large.';
  if (input.isEmpty) return 'Pick who this is split between.';

  switch (mode) {
    case SplitMode.equal:
      final included = input.values.where((v) => v > 0).length;
      if (included == 0) return 'Pick at least one person.';
      return null;

    case SplitMode.shares:
      // Summed as a double: rounding each share first would read 0.4 and 0.6
      // as 0 and 1, and could round a perfectly good split away to nothing.
      var total = 0.0;
      for (final v in input.values) {
        if (v < 0) return 'Shares cannot be negative.';
        if (v > kMaxWeight) return 'That is too many shares.';
        total += v.toDouble();
      }
      if ((total * kShareScale).round() <= 0) {
        return 'Give at least one person a share.';
      }
      return null;

    case SplitMode.percent:
      var total = 0;
      for (final v in input.values) {
        if (v < 0) return 'Percentages cannot be negative.';
        total += v.round();
      }
      if (total != 10000) {
        final off = (total - 10000) / 100;
        return off > 0
            ? '${_trim(off)}% too much'
            : '${_trim(-off)}% still to assign';
      }
      return null;

    case SplitMode.exact:
      var total = 0;
      for (final v in input.values) {
        if (v < 0) return 'Amounts cannot be negative.';
        total += v.round();
      }
      if (total != amount) {
        // The exact amount off is added by the caller, which knows the
        // currency; this string is only the fallback wording.
        return 'The shares do not add up to the total.';
      }
      return null;

    case SplitMode.adjustment:
      var fixed = 0;
      for (final v in input.values) {
        fixed += v.round();
      }
      if (fixed > amount) return 'The extras add up to more than the total.';
      final rest = amount - fixed;
      // Everyone must end up with a non-negative share.
      final even = splitByWeights(rest, {for (final id in input.keys) id: 1});
      for (final id in input.keys) {
        if (even[id]! + input[id]!.round() < 0) {
          return 'That leaves someone with a negative share.';
        }
      }
      return null;

    case SplitMode.settlement:
      return null;
  }
}

String _trim(double v) {
  final s = v.toStringAsFixed(2);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}
