import 'package:flutter/material.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_category.dart';
import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/split_mode.dart';
import 'package:couple_planner/features/money/pages/add_expense_page.dart';

/// One expense or recorded payment in full: who paid, how it was split, the
/// note and the photo, plus edit and delete.
class EntryDetailPage extends StatelessWidget {
  const EntryDetailPage({super.key, required this.ctx, required this.entry});

  final MoneyContext ctx;
  final MoneyEntry entry;

  bool get _canEdit => ctx.isAdmin || entry.createdBy == ctx.myUid;

  bool get _isSettlement => entry.type == MoneyEntryType.settlement;

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_isSettlement ? 'Delete this payment?' : 'Delete this expense?'),
        content: const Text('Balances will be recalculated without it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ctx.repo.deleteEntry(entry);
      if (context.mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete it.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _isSettlement
        ? 'Payment'
        : (entry.description.isEmpty ? 'Expense' : entry.description);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_canEdit && !_isSettlement)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => AddExpensePage(ctx: ctx, entry: entry),
                ),
              ),
            ),
          if (_canEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => _delete(context),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ctx.format.format(entry.amount),
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '${entry.date.day}.${entry.date.month}.${entry.date.year}'
                  '${entry.category != null ? ' · ${moneyCategory(entry.category)?.label ?? ''}' : ''}',
                  style: TextStyle(color: scheme.outline),
                ),
              ],
            ),
          ),

          if (!entry.isValid)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(Icons.warning_amber_outlined,
                    color: scheme.onErrorContainer),
                title: Text(
                  'This entry does not add up and is left out of the balances.',
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ),

          const _Header('Paid by'),
          for (final e in entry.paidBy.entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_upward),
              title: Text(ctx.nameFor(ctx.resolve(e.key))),
              trailing: Text(ctx.format.format(e.value)),
            ),

          _Header(_isSettlement ? 'Received by' : 'Split between'),
          for (final e in _sortedOwes())
            ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_downward),
              title: Text(ctx.nameFor(ctx.resolve(e.key))),
              subtitle: _isSettlement
                  ? null
                  : Text(_shareHint(e.key), style: const TextStyle(fontSize: 12)),
              trailing: Text(ctx.format.format(e.value)),
            ),

          if (!_isSettlement)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('Split ${entry.splitMode.label.toLowerCase()}',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),

          if ((entry.note ?? '').isNotEmpty) ...[
            const _Header('Note'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(entry.note!),
            ),
          ],

          if (entry.imagePath != null) ...[
            const _Header('Photo'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: StorageImage(
                  storagePath: entry.imagePath!,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Added by ${ctx.nameFor(entry.createdBy)}'
              '${entry.updatedBy != null ? ', last edited by ${ctx.nameFor(entry.updatedBy!)}' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  List<MapEntry<String, int>> _sortedOwes() {
    final list = entry.owes.entries.toList()
      ..sort((a, b) {
        final byAmount = b.value.compareTo(a.value);
        return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
      });
    return list;
  }

  /// The raw input behind a person's share, so an unequal split is explainable
  /// without opening the editor.
  String _shareHint(String personId) {
    final raw = entry.splitInput[personId];
    if (raw == null) return '';
    switch (entry.splitMode) {
      case SplitMode.shares:
        return '${raw.round()} share${raw.round() == 1 ? '' : 's'}';
      case SplitMode.percent:
        return '${(raw / 100).toStringAsFixed(2)}%';
      case SplitMode.adjustment:
        if (raw == 0) return 'even share';
        return raw > 0
            ? '+${ctx.format.formatAbs(raw.round())} on top'
            : '-${ctx.format.formatAbs(raw.round())} off';
      case SplitMode.equal:
      case SplitMode.exact:
      case SplitMode.settlement:
        return '';
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

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
