import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/money_person.dart';
import 'package:couple_planner/features/money/services/balance_engine.dart';
import 'package:couple_planner/features/money/services/money_format.dart';
import 'package:couple_planner/features/money/services/money_repository.dart';

/// Everything the money screens need, assembled once by [MoneyPage] and handed
/// down. Keeping it in one object means each child page takes a single
/// argument instead of eight, and there is exactly one place where the ledger
/// is built.
class MoneyContext {
  const MoneyContext({
    required this.repo,
    required this.format,
    required this.directory,
    required this.entries,
    required this.ledger,
    required this.isAdmin,
  });

  final MoneyRepository repo;
  final MoneyFormat format;
  final MoneyDirectory directory;

  /// Newest first.
  final List<MoneyEntry> entries;
  final Ledger ledger;
  final bool isAdmin;

  String get groupId => repo.groupId;
  String get myUid => directory.myUid;
  String get currency => format.currency;

  String resolve(String personId) => directory.resolve(personId);

  String nameFor(String id) => directory.nameFor(id);

  int netFor(String identity) => ledger.netFor(identity);

  int get myNet => ledger.netFor(myUid);

  int myShareOf(MoneyEntry entry) => entryNetFor(entry, myUid, resolve);

  bool involvesMe(MoneyEntry entry) => entryInvolves(entry, myUid, resolve);
}
