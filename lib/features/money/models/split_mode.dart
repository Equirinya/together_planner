/// How an expense total is divided among the people it involves.
///
/// Every mode ends up producing the same thing: a map of person id to an
/// integer number of minor units (cents) that sums to the expense total
/// *exactly*. The conversion lives in `../services/split_calculator.dart`;
/// this enum only names the modes and describes what their raw input means.
enum SplitMode {
  /// Split evenly. Input is `{personId: 1}` for everyone included.
  equal('equal', 'Equally', 'Everyone pays the same'),

  /// Integer weights, e.g. `{alice: 2, bob: 1}` — "the couple counts double".
  shares('shares', 'Shares', 'Weighted, e.g. 2 : 1'),

  /// Basis points (hundredths of a percent). Must total exactly 10000.
  percent('percent', 'Percentage', 'Must add up to 100%'),

  /// Minor units per person. Must total exactly the expense amount.
  exact('exact', 'Amounts', 'Type each share'),

  /// Fixed extras per person; whatever is left is split equally.
  adjustment('adjustment', 'Plus / minus', 'Extras on top of an even split'),

  /// Not user-selectable — the shape a recorded payment takes in the ledger.
  settlement('settlement', 'Payment', 'A payment between two people');

  const SplitMode(this.key, this.label, this.hint);

  /// Stable string stored in Firestore. Never change these.
  final String key;
  final String label;
  final String hint;

  /// The modes offered in the split editor, in display order.
  static const List<SplitMode> selectable = [
    equal,
    shares,
    percent,
    exact,
    adjustment,
  ];

  static SplitMode fromKey(String? key) {
    for (final m in SplitMode.values) {
      if (m.key == key) return m;
    }
    return SplitMode.equal;
  }
}
