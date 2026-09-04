import 'package:flutter/material.dart';

import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_category.dart';
import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/pages/entry_detail_page.dart';

/// One person's balance and every entry they appear in.
class PersonDetailPage extends StatelessWidget {
  const PersonDetailPage({
    super.key,
    required this.ctx,
    required this.identity,
  });

  final MoneyContext ctx;

  /// A *resolved* identity — a member uid, or an unclaimed placeholder id.
  final String identity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = ctx.directory.properNameFor(identity);
    final net = ctx.netFor(identity);
    final entries =
        ctx.entries.where((e) => _involves(e)).toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    net == 0
                        ? '$name is settled up'
                        : net > 0
                            ? '$name is owed ${ctx.format.formatAbs(net)}'
                            : '$name owes ${ctx.format.formatAbs(net)}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: net == 0
                              ? scheme.onSurface
                              : (net > 0 ? Colors.green.shade700 : scheme.error),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  // No "Settle up" action here: settle-up is the only way to
                  // reach this page, so the button could never do more than
                  // go back, under a label that promised something else.
                ],
              ),
            ),
          ),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nothing recorded for this person yet.',
                  textAlign: TextAlign.center),
            ),
          for (final entry in entries) _tile(context, entry),
        ],
      ),
    );
  }

  bool _involves(MoneyEntry entry) {
    for (final person in entry.people) {
      if (ctx.resolve(person) == identity) return true;
    }
    return false;
  }

  Widget _tile(BuildContext context, MoneyEntry entry) {
    final settlement = entry.type == MoneyEntryType.settlement;
    var net = 0;
    entry.paidBy.forEach((p, a) {
      if (ctx.resolve(p) == identity) net += a;
    });
    entry.owes.forEach((p, a) {
      if (ctx.resolve(p) == identity) net -= a;
    });

    return ListTile(
      leading: CircleAvatar(
        child: Icon(
          settlement ? Icons.handshake_outlined : moneyCategoryIcon(entry.category),
          size: 20,
        ),
      ),
      title: Text(
        settlement
            ? 'Payment'
            : (entry.description.isEmpty ? 'Expense' : entry.description),
      ),
      subtitle: Text('${entry.date.day}.${entry.date.month}.${entry.date.year}'
          ' · total ${ctx.format.format(entry.amount)}'),
      trailing: Text(
        (net > 0 ? '+' : '') + ctx.format.format(net),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: net == 0
              ? null
              : (net > 0
                  ? Colors.green.shade700
                  : Theme.of(context).colorScheme.error),
        ),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EntryDetailPage(ctx: ctx, entry: entry)),
      ),
    );
  }
}
