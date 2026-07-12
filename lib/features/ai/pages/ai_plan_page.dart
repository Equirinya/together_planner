import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/features/ai/ai_access.dart';

/// Shows the signed-in user their current AI plan: the tier they're on, how
/// much of their monthly generation quota is left, and the full feature/tier
/// table. Reads the live user document so the quota updates as it's spent.
class AiPlanPage extends StatelessWidget {
  const AiPlanPage({super.key});

  /// Feature rows of the comparison table. Each value is either a [bool]
  /// (rendered as a check/dash) or a [String] (rendered verbatim), one per tier
  /// in ascending order (Basic, Smart, Plus, Unlimited).
  static const List<(String, List<Object>)> _features = [
    ('Copy public recipes', [true, true, true, true]),
    ('AI ingredient resolution', [false, true, true, true]),
    ('Recipe generation', [false, '5/mo', '30/mo', '∞']),
    ('Smart meal planner *', [false, true, true, true]),
    ('New recipes in meal plans', [false, false, true, true]),
    ('Search ideas', [false, true, true, true]),
    ('Step & ingredient assist', [false, true, true, true]),
    ('Image generation', [false, true, true, true]),
    ('Image enhancement', [false, false, true, true]),
  ];

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('AI plan')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: uid == null
            ? null
            : FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
        builder: (context, snapshot) {
          final access = AiAccess.fromUserData(snapshot.data?.data());
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _planCard(context, access),
              const SizedBox(height: 24),
              Text('Plans', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _featureTable(context, access),
              const SizedBox(height: 16),
              Text(
                '* If anyone in your group is on Smart or higher, the smart meal '
                'planner is unlocked for everyone in that group.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _planCard(BuildContext context, AiAccess access) {
    final theme = Theme.of(context);
    final limit = access.monthlyLimit;
    final used = access.monthlyUsed;
    final remaining = access.generationsRemaining;

    final String quotaLine;
    if (limit == null) {
      quotaLine = 'Unlimited generations — $used used this month';
    } else if (limit == 0) {
      quotaLine = 'This plan has no AI recipe generation';
    } else {
      quotaLine = '$remaining of $limit generations left this month';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your plan', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(access.tierName, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text(quotaLine, style: theme.textTheme.bodyMedium),
            if (limit != null && limit > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (used / limit).clamp(0.0, 1.0)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _featureTable(BuildContext context, AiAccess access) {
    // The Unlimited plan is an internal/comp tier — only surface it to users who
    // are actually on it; everyone else just sees Basic / Smart / Plus.
    final tiers = [
      for (var t = 0; t < AiAccess.tierNames.length; t++)
        if (t != AiAccess.tierUnlimited || access.tier == AiAccess.tierUnlimited) t,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        horizontalMargin: 12,
        columns: [
          const DataColumn(label: Text('Feature')),
          for (final t in tiers)
            DataColumn(
              label: Text(
                t == access.tier ? '${AiAccess.tierNames[t]} • You' : AiAccess.tierNames[t],
                style: t == access.tier
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
        ],
        rows: [
          for (final (label, values) in _features)
            DataRow(cells: [
              DataCell(Text(label)),
              for (final t in tiers) DataCell(Center(child: _cell(context, values[t]))),
            ]),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, Object value) {
    if (value is bool) {
      return Icon(
        value ? Icons.check : Icons.remove,
        color: value ? null : Theme.of(context).disabledColor,
        size: 20,
      );
    }
    return Text(value.toString());
  }
}
