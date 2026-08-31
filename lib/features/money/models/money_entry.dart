import 'package:couple_planner/features/money/models/split_mode.dart';

/// Whether a ledger entry is a shared cost or a payment between two people.
///
/// Both live in the same collection because they are the same arithmetic: an
/// entry says who *put money in* (`paidBy`) and who *consumed it* (`owes`),
/// and both maps sum to `amount`. A settlement is simply the degenerate case
/// where one person put the money in and exactly one person consumed it.
enum MoneyEntryType {
  expense('expense'),
  settlement('settlement');

  const MoneyEntryType(this.key);
  final String key;

  static MoneyEntryType fromKey(String? key) =>
      key == 'settlement' ? MoneyEntryType.settlement : MoneyEntryType.expense;
}

/// One row of the group's ledger. Deliberately free of any Firestore type so
/// the balance and settlement logic can be unit-tested as plain Dart; the
/// document mapping lives in `../services/money_repository.dart`.
class MoneyEntry {
  const MoneyEntry({
    required this.id,
    required this.type,
    required this.description,
    required this.amount,
    required this.currency,
    required this.date,
    required this.paidBy,
    required this.splitMode,
    required this.splitInput,
    required this.owes,
    required this.createdBy,
    this.category,
    this.note,
    this.imagePath,
    this.createdAt,
    this.updatedAt,
    this.updatedBy,
  });

  final String id;
  final MoneyEntryType type;
  final String description;

  /// Total, in minor units (cents) of [currency]. Always positive.
  final int amount;
  final String currency;
  final DateTime date;

  /// Optional category key, e.g. "groceries".
  final String? category;

  /// Free-text note the user typed.
  final String? note;

  /// Firebase Storage path of the attached photo / receipt, if any.
  final String? imagePath;

  /// Who fronted the money. Values are positive and sum to [amount].
  final Map<String, int> paidBy;

  final SplitMode splitMode;

  /// The raw per-person input for [splitMode] — kept so the edit screen can
  /// reopen in the same mode with the user's original numbers.
  final Map<String, num> splitInput;

  /// The computed per-person share. Values are >= 0 and sum to [amount].
  final Map<String, int> owes;

  final DateTime? createdAt;
  final String createdBy;
  final DateTime? updatedAt;
  final String? updatedBy;

  /// Every person id this entry mentions, in either direction.
  Set<String> get people => {...paidBy.keys, ...owes.keys};

  /// What this single entry does to [personId]'s balance: positive means they
  /// are owed for it, negative means they owe.
  int netFor(String personId) =>
      (paidBy[personId] ?? 0) - (owes[personId] ?? 0);

  /// The payer of a settlement (null for expenses).
  String? get settlementFrom =>
      type == MoneyEntryType.settlement && paidBy.isNotEmpty
          ? paidBy.keys.first
          : null;

  /// The recipient of a settlement (null for expenses).
  String? get settlementTo =>
      type == MoneyEntryType.settlement && owes.isNotEmpty
          ? owes.keys.first
          : null;

  /// The invariant that makes balances always sum to zero.
  ///
  /// The Firestore rules language has no way to fold a map's values, so this
  /// cannot be enforced on write without a Cloud Function. It is therefore
  /// enforced on *read*: an entry that fails is excluded from balances and
  /// surfaced in the UI instead of silently skewing the numbers.
  bool get isValid {
    if (amount <= 0) return false;
    if (paidBy.isEmpty || owes.isEmpty) return false;
    var paid = 0;
    for (final v in paidBy.values) {
      if (v < 0) return false;
      paid += v;
    }
    var owed = 0;
    for (final v in owes.values) {
      if (v < 0) return false;
      owed += v;
    }
    return paid == amount && owed == amount;
  }

  MoneyEntry copyWith({
    String? id,
    String? description,
    int? amount,
    DateTime? date,
    String? category,
    String? note,
    String? imagePath,
    bool clearImage = false,
    bool clearCategory = false,
    Map<String, int>? paidBy,
    SplitMode? splitMode,
    Map<String, num>? splitInput,
    Map<String, int>? owes,
  }) {
    return MoneyEntry(
      id: id ?? this.id,
      type: type,
      description: description ?? this.description,
      amount: amount ?? this.amount,
      currency: currency,
      date: date ?? this.date,
      category: clearCategory ? null : (category ?? this.category),
      note: note ?? this.note,
      imagePath: clearImage ? null : (imagePath ?? this.imagePath),
      paidBy: paidBy ?? this.paidBy,
      splitMode: splitMode ?? this.splitMode,
      splitInput: splitInput ?? this.splitInput,
      owes: owes ?? this.owes,
      createdAt: createdAt,
      createdBy: createdBy,
      updatedAt: updatedAt,
      updatedBy: updatedBy,
    );
  }
}

/// The day an entry belongs to.
///
/// `date` answers "when did this happen", which is a day and not a moment: the
/// date picker hands back midnight, while an expense entered without touching
/// the picker carries the current time. Comparing days rather than timestamps
/// keeps those two the same thing.
DateTime moneyDayOf(DateTime date) =>
    DateTime(date.year, date.month, date.day);

/// Orders entries for the activity list: newest day first, and within a day,
/// most recently entered first.
///
/// Ordering on the raw timestamp alone put an expense dated through the picker
/// at midnight, which sorted it *below* everything else recorded that day:
/// choosing "yesterday" quietly made it yesterday's oldest entry instead of
/// its newest. Days are compared as days and `createdAt` breaks the tie, so a
/// backdated expense lands at the top of the day it names.
List<MoneyEntry> sortMoneyEntriesForDisplay(List<MoneyEntry> entries) {
  entries.sort((a, b) {
    final byDay = moneyDayOf(b.date).compareTo(moneyDayOf(a.date));
    if (byDay != 0) return byDay;
    final createdA = a.createdAt;
    final createdB = b.createdAt;
    // A write that has not round-tripped yet has no server timestamp. It is by
    // definition the most recent thing that happened, so it goes first.
    if (createdA == null || createdB == null) {
      if (createdA == null && createdB == null) return b.id.compareTo(a.id);
      return createdA == null ? -1 : 1;
    }
    final byCreated = createdB.compareTo(createdA);
    return byCreated != 0 ? byCreated : b.id.compareTo(a.id);
  });
  return entries;
}
