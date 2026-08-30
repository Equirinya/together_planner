import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/pages/person_detail_page.dart';
import 'package:couple_planner/features/money/services/balance_engine.dart';
import 'package:couple_planner/features/money/services/settlement_solver.dart';
import 'package:couple_planner/features/money/widgets/money_ui.dart';

/// Shows the shortest set of payments that clears every balance, and lets a
/// payment be recorded once it has actually happened.
///
/// Only the simplified plan is shown — never the raw "who owes whom", which
/// would be a second, contradictory answer to the same question. The cost of
/// that choice is that a suggested payment can be between two people who never
/// bought anything from each other, so every payment can be expanded to show
/// exactly which expenses it is settling.
class SettleUpPage extends StatefulWidget {
  const SettleUpPage({super.key, required this.ctx});

  final MoneyContext ctx;

  @override
  State<SettleUpPage> createState() => _SettleUpPageState();
}

class _SettleUpPageState extends State<SettleUpPage> {
  bool _onlyMine = true;
  bool _busy = false;

  /// Computed once, not per build: the exact solver is O(3^n) and would
  /// otherwise re-run on every frame, including each flick of the filter
  /// switch. The ledger this page was opened with does not change under it.
  late final SettlementPlan _plan = minimalSettlement(widget.ctx.ledger.net);

  MoneyContext get ctx => widget.ctx;

  Future<void> _record(Payment payment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Record this payment?'),
        content: Text(
          '${ctx.directory.properNameFor(payment.from)} pays '
          '${ctx.directory.properNameFor(payment.to)} '
          '${ctx.format.format(payment.amount)}.\n\n'
          'This only records the payment. The app does not move any money.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Record'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await ctx.repo.saveSettlement(
        from: payment.from,
        to: payment.to,
        amount: payment.amount,
        currency: ctx.currency,
        date: DateTime.now(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not record the payment.')),
      );
    }
  }

  Future<void> _recordManual() async {
    final result = await showDialog<_ManualPayment>(
      context: context,
      builder: (context) => _ManualPaymentDialog(ctx: ctx),
    );
    if (result == null) return;
    setState(() => _busy = true);
    try {
      await ctx.repo.saveSettlement(
        from: result.from,
        to: result.to,
        amount: result.amount,
        currency: ctx.currency,
        date: result.date,
        note: result.note,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not record the payment.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final visible = _onlyMine
        ? plan.payments
            .where((p) => p.from == ctx.myUid || p.to == ctx.myUid)
            .toList()
        : plan.payments;

    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ..._balances(),
          if (plan.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 48),
              child: Column(
                children: [
                  Icon(Icons.check_circle_outline, size: 40),
                  SizedBox(height: 12),
                  Text('Everyone is settled up.', textAlign: TextAlign.center),
                ],
              ),
            )
          else ...[
            // No sentence restating the plan: the cards below already say how
            // many payments there are and who makes them.
            const MoneyListHeader('PAYMENTS'),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              visualDensity: VisualDensity.compact,
              dense: true,
              title: const Text('Only payments involving me',
                  style: TextStyle(fontSize: 14)),
              value: _onlyMine,
              onChanged: (v) => setState(() => _onlyMine = v),
            ),
            if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('None of the remaining payments involve you.',
                    textAlign: TextAlign.center),
              ),
            for (final payment in visible) _paymentCard(payment, plan),
          ],
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Record a payment'),
            subtitle: const Text('For a payment that already happened'),
            onTap: _busy ? null : _recordManual,
          ),
        ],
      ),
    );
  }

  /// Who is up and who is down. This lives here rather than on the Money tab
  /// so the state and the plan that resolves it are read together.
  List<Widget> _balances() {
    final open = ctx.ledger.openIdentities;
    if (open.isEmpty) return const [];
    return [
      const MoneyListHeader('BALANCES'),
      for (final id in open)
        ListTile(
          leading: CircleAvatar(
            child: Text(moneyInitial(ctx.directory.properNameFor(id))),
          ),
          title: Text(ctx.directory.properNameFor(id)),
          subtitle: ctx.directory.isFormer(id)
              ? const Text('no longer in the group')
              : null,
          trailing: Text(
            ctx.format.formatAbs(ctx.netFor(id)),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: ctx.netFor(id) > 0
                  ? Colors.green.shade700
                  : Theme.of(context).colorScheme.error,
            ),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PersonDetailPage(ctx: ctx, identity: id),
            ),
          ),
        ),
      const Divider(height: 24),
    ];
  }

  Widget _paymentCard(Payment payment, SettlementPlan plan) {
    final from = ctx.directory.properNameFor(payment.from);
    final to = ctx.directory.properNameFor(payment.to);
    final youPay = payment.from == ctx.myUid;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Icon(youPay ? Icons.arrow_upward : Icons.arrow_downward),
            ),
            title: Text(
              youPay ? 'You pay $to' : (payment.to == ctx.myUid ? '$from pays you' : '$from pays $to'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: Text(
              ctx.format.format(payment.amount),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
          ),
          _derivation(payment, plan),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                const Spacer(),
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _record(payment),
                  child: const Text('Mark as paid'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "What does this payment cover?" — the payer's actual, un-simplified debts
  /// and credits, with the expenses that produced them.
  Widget _derivation(Payment payment, SettlementPlan plan) {
    final debtor = payment.from;
    final lines = <_DerivationLine>[];

    (ctx.ledger.owes[debtor] ?? const <String, int>{}).forEach((creditor, amount) {
      lines.add(_DerivationLine(
        text: '${_owePhrase(debtor)} ${ctx.directory.properNameFor(creditor)}',
        amount: amount,
        sources: ctx.ledger.sourcesFor(debtor, creditor),
      ));
    });
    ctx.ledger.owes.forEach((other, owed) {
      final amount = owed[debtor];
      if (other == debtor || amount == null || amount <= 0) return;
      lines.add(_DerivationLine(
        text: '${ctx.directory.properNameFor(other)} '
            '${other == ctx.myUid ? 'owe' : 'owes'} ${_youOrName(debtor)}',
        amount: -amount,
        sources: ctx.ledger.sourcesFor(other, debtor),
      ));
    });
    lines.sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));

    if (lines.isEmpty) return const SizedBox.shrink();

    final paymentsByDebtor =
        plan.payments.where((p) => p.from == debtor).length;

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('What does this cover?', style: TextStyle(fontSize: 13)),
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(line.text)),
                    Text(
                      (line.amount < 0 ? '- ' : '') +
                          ctx.format.formatAbs(line.amount),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                for (final source in line.sources.take(6))
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Text(
                      '${source.isSettlement ? 'Payment' : (source.description.isEmpty ? 'Expense' : source.description)}'
                      ' · ${ctx.format.format(source.amount)}',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                if (line.sources.length > 6)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Text('and ${line.sources.length - 6} more',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
              ],
            ),
          ),
        if (paymentsByDebtor > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Settled by this and ${paymentsByDebtor - 1} other payment'
              '${paymentsByDebtor - 1 == 1 ? '' : 's'}.',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
          ),
      ],
    );
  }

  String _owePhrase(String debtor) =>
      debtor == ctx.myUid ? 'You owe' : '${ctx.directory.properNameFor(debtor)} owes';

  String _youOrName(String id) =>
      id == ctx.myUid ? 'you' : ctx.directory.properNameFor(id);
}

class _DerivationLine {
  const _DerivationLine({
    required this.text,
    required this.amount,
    required this.sources,
  });

  final String text;
  final int amount;
  final List<DebtSource> sources;
}

// ── manual payment ──────────────────────────────────────────────────────────

class _ManualPayment {
  const _ManualPayment({
    required this.from,
    required this.to,
    required this.amount,
    required this.date,
    this.note,
  });

  final String from;
  final String to;
  final int amount;
  final DateTime date;
  final String? note;
}

class _ManualPaymentDialog extends StatefulWidget {
  const _ManualPaymentDialog({required this.ctx});

  final MoneyContext ctx;

  @override
  State<_ManualPaymentDialog> createState() => _ManualPaymentDialogState();
}

class _ManualPaymentDialogState extends State<_ManualPaymentDialog> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  late String _from = widget.ctx.myUid;
  late String _to;
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    final others = widget.ctx.directory.selectable
        .where((id) => id != widget.ctx.myUid)
        .toList();
    _to = others.isEmpty ? widget.ctx.myUid : others.first;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final people = ctx.directory.selectable;
    final amount = ctx.format.parse(_amountCtrl.text) ?? 0;
    final valid = amount > 0 && _from != _to;

    return AlertDialog(
      title: const Text('Record a payment'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _from,
              decoration: const InputDecoration(labelText: 'From'),
              items: [
                for (final id in people)
                  DropdownMenuItem(value: id, child: Text(ctx.nameFor(id))),
              ],
              onChanged: (v) => setState(() => _from = v ?? _from),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _to,
              decoration: const InputDecoration(labelText: 'To'),
              items: [
                for (final id in people)
                  DropdownMenuItem(value: id, child: Text(ctx.nameFor(id))),
              ],
              onChanged: (v) => setState(() => _to = v ?? _to),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '${ctx.format.symbol} ',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text('${_date.day}.${_date.month}.${_date.year}'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.of(context).pop(_ManualPayment(
                    from: _from,
                    to: _to,
                    amount: amount,
                    date: _date,
                    note: _noteCtrl.text,
                  ))
              : null,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
