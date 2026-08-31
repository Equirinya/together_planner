import 'package:flutter/material.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_category.dart';
import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/split_mode.dart';
import 'package:couple_planner/features/money/pages/add_expense_page.dart';
import 'package:couple_planner/features/money/widgets/money_ui.dart';

/// One expense or recorded payment in full.
///
/// Deliberately the same shape as the editor: a hero carrying the two things
/// that identify the entry, titled cards for everything else, and a pinned
/// action bar. Opening an expense and editing it should feel like the same
/// screen in two states, not two different screens.
class EntryDetailPage extends StatelessWidget {
  const EntryDetailPage({super.key, required this.ctx, required this.entry});

  final MoneyContext ctx;
  final MoneyEntry entry;

  bool get _canEdit => ctx.isAdmin || entry.createdBy == ctx.myUid;

  bool get _isSettlement => entry.type == MoneyEntryType.settlement;

  // ── actions ───────────────────────────────────────────────────────────────

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

  void _edit(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => AddExpensePage(ctx: ctx, entry: entry)),
    );
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final note = entry.note ?? '';
    final image = entry.imagePath;

    return Scaffold(
      appBar: AppBar(title: Text(_isSettlement ? 'Payment' : 'Expense')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _hero(context),
                if (!entry.isValid) _invalidCard(context),
                MoneySection('PAID BY', children: [
                  for (final e in _sorted(entry.paidBy))
                    _personRow(context, e.key, e.value),
                ]),
                MoneySection(
                  _isSettlement ? 'RECEIVED BY' : 'SPLIT BETWEEN',
                  children: [
                    for (final e in _sorted(entry.owes))
                      _personRow(context, e.key, e.value,
                          hint: _isSettlement ? null : _shareHint(e.key)),
                    if (!_isSettlement)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Split ${entry.splitMode.label.toLowerCase()}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.outline),
                        ),
                      ),
                  ],
                ),
                if (note.isNotEmpty) MoneySection('NOTE', children: [Text(note)]),
                if (image != null)
                  MoneySection('PHOTO', children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: StorageImage(
                          storagePath: image,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ]),
                _meta(context),
              ],
            ),
          ),
          if (_canEdit) _actionBar(context),
        ],
      ),
    );
  }

  /// The same hero as the editor, minus the text fields: the description and
  /// the amount, then the qualifiers as quiet chips.
  Widget _hero(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final category = moneyCategory(entry.category);

    final title = _isSettlement
        ? _settlementTitle()
        : (entry.description.isEmpty ? 'Expense' : entry.description);

    return MoneyHero(
      children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: moneyHeroTitleStyle(context),
            ),
            const SizedBox(height: 16),
            Text(
              ctx.format.format(entry.amount),
              textAlign: TextAlign.center,
              style: moneyHeroAmountStyle(context),
            ),
            // The question anybody actually opens an expense to answer.
            if (ctx.involvesMe(entry)) ...[
              const SizedBox(height: 8),
              Text(
                _myLine(),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.event_outlined, size: 18),
                  label: Text(moneyDateLabel(entry.date)),
                ),
                if (category != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(category.icon, size: 18),
                    label: Text(category.label),
                  ),
              ],
            ),
      ],
    );
  }

  Widget _personRow(BuildContext context, String personId, int amount,
      {String? hint}) {
    final identity = ctx.resolve(personId);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      leading: CircleAvatar(
        radius: 16,
        child: Text(
          moneyInitial(ctx.directory.properNameFor(identity)),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      title: Text(ctx.nameFor(identity)),
      subtitle: (hint == null || hint.isEmpty)
          ? null
          : Text(hint, style: const TextStyle(fontSize: 12.5)),
      trailing: Text(
        ctx.format.format(amount),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _invalidCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      color: scheme.errorContainer,
      child: ListTile(
        leading:
            Icon(Icons.warning_amber_outlined, color: scheme.onErrorContainer),
        title: Text(
          'This entry does not add up, so it is left out of the balances.',
          style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
        ),
      ),
    );
  }

  Widget _meta(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final edited = entry.updatedBy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Text(
        'Added by ${ctx.nameFor(entry.createdBy)}'
        '${edited != null ? ', last edited by ${ctx.nameFor(edited)}' : ''}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
    );
  }

  Widget _actionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MoneyActionBar(
      child: Row(
          children: [
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: () => _delete(context),
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                child: const Icon(Icons.delete_outline),
              ),
            ),
            // A recorded payment has nothing to edit: it is two people and an
            // amount, and correcting it means deleting and recording again.
            if (!_isSettlement) ...[
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: () => _edit(context),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    label: const Text('Edit expense'),
                  ),
                ),
              ),
            ] else
              const Spacer(),
        ],
      ),
    );
  }

  // ── text ──────────────────────────────────────────────────────────────────

  String _settlementTitle() {
    final from = ctx.directory
        .properNameFor(ctx.resolve(entry.settlementFrom ?? ''));
    final to =
        ctx.directory.properNameFor(ctx.resolve(entry.settlementTo ?? ''));
    return '$from paid $to';
  }

  String _myLine() {
    final mine = ctx.myShareOf(entry);
    if (_isSettlement) {
      return mine > 0 ? 'You paid this' : 'You received this';
    }
    if (mine > 0) return 'You lent ${ctx.format.formatAbs(mine)}';
    if (mine < 0) return 'You owe ${ctx.format.formatAbs(mine)}';
    return 'You paid exactly your share';
  }

  /// The raw input behind a person's share, so an unequal split is explainable
  /// without opening the editor.
  String _shareHint(String personId) {
    final raw = entry.splitInput[personId];
    if (raw == null) return '';
    switch (entry.splitMode) {
      case SplitMode.shares:
        return '${formatShareCount(raw)} share${raw == 1 ? '' : 's'}';
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

  List<MapEntry<String, int>> _sorted(Map<String, int> amounts) {
    final list = amounts.entries.toList()
      ..sort((a, b) {
        final byAmount = b.value.compareTo(a.value);
        return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
      });
    return list;
  }
}
