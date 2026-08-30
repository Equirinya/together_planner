import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:couple_planner/features/money/services/money_format.dart';

/// The shared visual vocabulary of the money screens.
///
/// The editor and the detail view look the same on purpose, but they are NOT
/// one screen behind a `readOnly` flag: one owns text controllers, focus order,
/// live validation and a save path, the other owns delete, provenance and the
/// invalid-entry warning. Merging them would mean a conditional at nearly every
/// line, which reads worse than the duplication it removes.
///
/// What genuinely was duplicated is the chrome: the hero card, the titled
/// block, the pinned bar, the date label. Those live here, so the two screens
/// share their look by construction and cannot drift apart.

/// The card at the top of an expense screen, holding the two things that
/// identify it. Same padding and margins wherever it is used.
class MoneyHero extends StatelessWidget {
  const MoneyHero({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 18),
        child: Column(children: children),
      ),
    );
  }
}

/// Typography for the hero, shared so an editable field and a plain label are
/// pixel-identical.
TextStyle? moneyHeroTitleStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .headlineSmall
    ?.copyWith(fontWeight: FontWeight.w600);

TextStyle? moneyHeroAmountStyle(BuildContext context) =>
    Theme.of(context).textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        );

/// A titled block. The label is small and quiet: it orients, it does not
/// compete.
class MoneySection extends StatelessWidget {
  const MoneySection(this.title, {super.key, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: moneyLabelStyle(context)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// The same label, for list screens where the content is not inside a card.
class MoneyListHeader extends StatelessWidget {
  const MoneyListHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Text(title, style: moneyLabelStyle(context)),
    );
  }
}

TextStyle? moneyLabelStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        );

/// The bar pinned below the scroll view.
///
/// Belongs in the body under an [Expanded], never in
/// `Scaffold.bottomNavigationBar`: a navigation bar is positioned at the
/// physical bottom of the screen, so the keyboard covers it on iOS. Sitting in
/// the body means it rides the shrinking viewport and lands directly above the
/// keyboard on every platform.
class MoneyActionBar extends StatelessWidget {
  const MoneyActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: child,
      ),
    );
  }
}

String moneyInitial(String name) =>
    name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today", "Yesterday", "5 Mar", or "5 Mar 2025" outside the current year.
String moneyDateLabel(DateTime date) {
  final now = DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  final label = '${date.day} ${_months[date.month - 1]}';
  return date.year == now.year ? label : '$label ${date.year}';
}

/// Types money the way a till does: digits fill from the right, past the
/// decimal separator, so 5 euros is "500" rather than "5", a comma, "00".
///
/// Every keystroke is re-read as a whole number of minor units and re-rendered,
/// which also means backspace walks back down (5,00 -> 0,50 -> 0,05) and the
/// field can never hold something [MoneyFormat.parse] would read differently
/// from what is on screen.
class MinorUnitsFormatter extends TextInputFormatter {
  const MinorUnitsFormatter(this.format);

  final MoneyFormat format;

  /// Enough for any real expense, and far inside a 64-bit int.
  static const int _maxDigits = 12;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    // Cleared: hand back an empty field so the hint shows through.
    if (digits.isEmpty) return const TextEditingValue();
    if (digits.length > _maxDigits) {
      // Refuse the keystroke rather than silently dropping a digit.
      if (oldValue.text.isNotEmpty) return oldValue;
      digits = digits.substring(0, _maxDigits);
    }
    final text = format.toInput(int.parse(digits));
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// A field that holds an amount of money.
///
/// Fills from the right (see [MinorUnitsFormatter]) until the user places a
/// caret anywhere but the end, at which point it becomes an ordinary text
/// field for the rest of the edit. Clearing it starts over.
///
/// That escape hatch is why the mode switch lives in a widget rather than in
/// one screen's State: every money field in the feature needs it, not just the
/// big one at the top.
class MoneyAmountField extends StatefulWidget {
  const MoneyAmountField({
    super.key,
    required this.controller,
    required this.format,
    this.decoration,
    this.style,
    this.focusNode,
    this.textAlign = TextAlign.start,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final MoneyFormat format;
  final InputDecoration? decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final TextAlign textAlign;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<MoneyAmountField> createState() => _MoneyAmountFieldState();
}

class _MoneyAmountFieldState extends State<MoneyAmountField> {
  bool _freeform = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_watchCaret);
  }

  @override
  void didUpdateWidget(covariant MoneyAmountField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_watchCaret);
      widget.controller.addListener(_watchCaret);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_watchCaret);
    super.dispose();
  }

  /// A selection change alone still notifies the controller, which is what
  /// makes this detectable: the formatter always leaves the caret at the end,
  /// so anywhere else is the user's own doing.
  void _watchCaret() {
    final value = widget.controller.value;
    var freeform = _freeform;
    if (value.text.isEmpty) {
      freeform = false;
    } else if (!freeform && value.selection.baseOffset >= 0) {
      // Only a collapsed caret counts. Selecting a range is what somebody does
      // to retype the whole amount, and that should keep filling from the
      // right rather than silently switching modes underneath them.
      final selection = value.selection;
      if (selection.isCollapsed && selection.baseOffset != value.text.length) {
        freeform = true;
      }
    }
    if (freeform != _freeform && mounted) {
      setState(() => _freeform = freeform);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      textAlign: widget.textAlign,
      style: widget.style,
      decoration: widget.decoration,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      keyboardType: TextInputType.numberWithOptions(decimal: _freeform),
      inputFormatters: _freeform
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
          : [MinorUnitsFormatter(widget.format)],
    );
  }
}
