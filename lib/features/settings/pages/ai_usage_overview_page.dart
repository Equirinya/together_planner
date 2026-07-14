import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/widgets/load_builders.dart';

// Standard-tier Gemini API list prices, used only to turn the raw token/image
// counts in `ai_usage/{month}` into a rough USD estimate for this page.
// Source: https://ai.google.dev/gemini-api/docs/pricing (checked 2026-07-13).
// Actual billing may differ (batch/flex/priority tiers, context caching,
// grounding calls, currency conversion) — treat this as an estimate, not an
// invoice. Keyed by the exact model strings in functions/src/lib/modelStrings.ts;
// keep in sync if those change.
const _perMillion = 1000000.0;

class _ModelRate {
  const _ModelRate({required this.inputPerToken, required this.outputPerToken, this.perImage = 0});

  final double inputPerToken;
  final double outputPerToken;
  final double perImage;
}

const Map<String, _ModelRate> _rates = {
  'gemini-3.1-flash-lite': _ModelRate(inputPerToken: 0.25 / _perMillion, outputPerToken: 1.50 / _perMillion),
  'gemini-3.5-flash': _ModelRate(inputPerToken: 1.50 / _perMillion, outputPerToken: 9.00 / _perMillion),
  // Priced from gemini-3.1-pro-preview's Standard tier (<=200k token prompts).
  'gemini-3.1-pro': _ModelRate(inputPerToken: 2.00 / _perMillion, outputPerToken: 12.00 / _perMillion),
  'gemini-2.5-flash-image': _ModelRate(
    inputPerToken: 0.30 / _perMillion,
    outputPerToken: 0, // image output is billed per image, not per token
    perImage: 0.039,
  ),
  'gemini-3.1-flash-lite-image': _ModelRate(
    inputPerToken: 0.25 / _perMillion,
    outputPerToken: 1.50 / _perMillion, // text/thinking output only
    perImage: 0.0336,
  ),
};

/// Estimates the USD cost of one usage bucket. Unknown models return 0 rather
/// than throwing, since the price list will lag behind new model strings.
double _estimateCostUsd(String? model, Map<String, dynamic> bucket) {
  final rate = _rates[model];
  if (rate == null) return 0;

  final promptTokens = (bucket['promptTokens'] as num?)?.toDouble() ?? 0;
  final outputTokens = ((bucket['candidatesTokens'] as num?)?.toDouble() ?? 0) +
      ((bucket['thoughtsTokens'] as num?)?.toDouble() ?? 0);
  final images = (bucket['images'] as num?)?.toDouble() ?? 0;

  return promptTokens * rate.inputPerToken + outputTokens * rate.outputPerToken + images * rate.perImage;
}

/// Admin-only overview of AI model usage and estimated cost. Reads
/// `ai_usage/{month}` directly (firestore.rules restricts this to users with
/// `viewAIUsage`) and applies the pricing table above client-side. Shows one
/// calendar month at a time, with chevrons to step through every month that
/// has recorded usage.
class AiUsageOverviewPage extends StatefulWidget {
  const AiUsageOverviewPage({super.key});

  @override
  State<AiUsageOverviewPage> createState() => _AiUsageOverviewPageState();
}

class _AiUsageOverviewPageState extends State<AiUsageOverviewPage> {
  bool _loading = true;
  String? _error;
  String? _month;
  List<String> _availableMonths = [];
  Map<String, dynamic> _totals = {};
  Map<String, dynamic> _byFunction = {};
  Map<String, dynamic> _byOperation = {};
  Map<String, dynamic> _byModel = {};
  Map<String, dynamic> _byUser = {};
  double _totalCostUsd = 0;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? month) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await FirebaseFirestore.instance.collection('ai_usage').orderBy('month').get();
      final availableMonths = snap.docs.map((d) => d.id).toList();
      final targetMonth = month ?? (availableMonths.isNotEmpty ? availableMonths.last : null);
      final matches = snap.docs.where((d) => d.id == targetMonth);
      final data = matches.isEmpty ? null : matches.first.data();

      final byModel = Map<String, dynamic>.from(data?['byModel'] as Map? ?? {});
      var totalCostUsd = 0.0;
      for (final entry in byModel.entries) {
        final bucket = Map<String, dynamic>.from(entry.value as Map);
        totalCostUsd += _estimateCostUsd(bucket['label'] as String?, bucket);
      }

      if (!mounted) return;
      setState(() {
        _month = targetMonth;
        _availableMonths = availableMonths;
        _totals = Map<String, dynamic>.from(data?['totals'] as Map? ?? {});
        _byFunction = Map<String, dynamic>.from(data?['byFunction'] as Map? ?? {});
        _byOperation = Map<String, dynamic>.from(data?['byOperation'] as Map? ?? {});
        _byModel = byModel;
        _byUser = Map<String, dynamic>.from(data?['byUser'] as Map? ?? {});
        _totalCostUsd = totalCostUsd;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load usage data: $e';
        _loading = false;
      });
    }
  }

  int get _monthIndex => _month == null ? -1 : _availableMonths.indexOf(_month!);
  bool get _hasPrevious => _monthIndex > 0;
  bool get _hasNext => _monthIndex >= 0 && _monthIndex < _availableMonths.length - 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI usage')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : RefreshIndicator(
                  onRefresh: () => _load(_month),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _MonthSelector(
                        month: _month,
                        onPrevious: _hasPrevious ? () => _load(_availableMonths[_monthIndex - 1]) : null,
                        onNext: _hasNext ? () => _load(_availableMonths[_monthIndex + 1]) : null,
                      ),
                      const SizedBox(height: 16),
                      _TotalsCard(totals: _totals, costUsd: _totalCostUsd),
                      const SizedBox(height: 24),
                      _BreakdownSection(title: 'By model', buckets: _byModel, costEstimator: _estimateCostUsd),
                      const SizedBox(height: 24),
                      _BreakdownSection(title: 'By function', buckets: _byFunction),
                      const SizedBox(height: 24),
                      _BreakdownSection(title: 'By operation', buckets: _byOperation),
                      const SizedBox(height: 24),
                      _BreakdownSection(title: 'By user', buckets: _byUser, labelBuilder: _userLabel),
                    ],
                  ),
                ),
    );
  }
}

class _MonthSelector extends StatelessWidget {
  const _MonthSelector({required this.month, this.onPrevious, this.onNext});

  final String? month;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: onPrevious),
        Text(month ?? '—', style: Theme.of(context).textTheme.titleMedium),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: onNext),
      ],
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.costUsd});

  final Map<String, dynamic> totals;
  final double costUsd;

  @override
  Widget build(BuildContext context) {
    final calls = totals['calls'] ?? 0;
    final promptTokens = totals['promptTokens'] ?? 0;
    final candidatesTokens = totals['candidatesTokens'] ?? 0;
    final images = totals['images'] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Estimated cost', style: Theme.of(context).textTheme.labelLarge),
            Text('\$${costUsd.toStringAsFixed(2)}', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text('$calls calls · ${_formatTokens(promptTokens)} in · ${_formatTokens(candidatesTokens)} out · $images images'),
          ],
        ),
      ),
    );
  }
}

class _BreakdownSection extends StatelessWidget {
  const _BreakdownSection({required this.title, required this.buckets, this.costEstimator, this.labelBuilder});

  final String title;
  final Map<String, dynamic> buckets;
  final double Function(String? model, Map<String, dynamic> bucket)? costEstimator;
  final Widget Function(String label)? labelBuilder;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) return const SizedBox.shrink();

    final entries = buckets.entries.toList()
      ..sort((a, b) => ((b.value['calls'] ?? 0) as num).compareTo((a.value['calls'] ?? 0) as num));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 4),
        Card(
          child: Column(
            children: entries.map((entry) {
              final bucket = Map<String, dynamic>.from(entry.value as Map);
              final label = bucket['label'] as String? ?? entry.key;
              final calls = bucket['calls'] ?? 0;
              final costUsd = costEstimator?.call(bucket['label'] as String?, bucket);
              return ListTile(
                title: labelBuilder?.call(label) ?? Text(label),
                subtitle: Text('$calls calls · ${_formatTokens(bucket['promptTokens'] ?? 0)} in · '
                    '${_formatTokens(bucket['candidatesTokens'] ?? 0)} out · ${bucket['images'] ?? 0} images'),
                trailing: costUsd != null ? Text('\$${costUsd.toStringAsFixed(2)}') : null,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

/// Resolves a `byUser` bucket's uid label to a display name via
/// `users_public/{uid}`. Falls back to the raw label (e.g. "unknown" for
/// calls made outside an authenticated request) if it isn't a real uid.
Widget _userLabel(String uid) {
  if (uid == 'unknown') return const Text('Unknown');
  return LoadDocumentBuilder(
    docRef: FirebaseFirestore.instance.collection('users_public').doc(uid),
    builder: (data) => Text((data['username'] ?? uid).toString()),
  );
}

String _formatTokens(dynamic tokens) {
  final n = (tokens as num?)?.toInt() ?? 0;
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}
