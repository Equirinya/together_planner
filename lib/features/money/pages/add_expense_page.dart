import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_category.dart';
import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/split_mode.dart';
import 'package:couple_planner/features/money/services/split_calculator.dart';
import 'package:couple_planner/features/money/widgets/money_ui.dart';

/// Create or edit one expense.
///
/// The screen is deliberately a plain scrolling form of stock Material
/// widgets. The only real logic is keeping four things in agreement: the
/// amount, who paid it, who it is split between, and the numbers the chosen
/// split mode needs. Everything else — the rounding, the validation messages —
/// comes from `split_calculator.dart`, so the form never does money maths of
/// its own.
class AddExpensePage extends StatefulWidget {
  const AddExpensePage({super.key, required this.ctx, this.entry});

  final MoneyContext ctx;

  /// The expense being edited, or null when adding a new one.
  final MoneyEntry? entry;

  @override
  State<AddExpensePage> createState() => _AddExpensePageState();
}

class _AddExpensePageState extends State<AddExpensePage> {
  final _descriptionCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  /// So pressing the keyboard's "next" on the description jumps straight to
  /// the amount — the two fields are always filled in together.
  final _amountFocus = FocusNode();

  /// Per-person input for the current split mode.
  final Map<String, TextEditingController> _shareCtrls = {};

  /// Per-person input for a payment split across several payers.
  final Map<String, TextEditingController> _payerCtrls = {};

  late DateTime _date;
  String? _category;
  SplitMode _mode = SplitMode.equal;

  /// Who the expense is split between.
  final Set<String> _selected = {};

  /// Single payer; ignored when [_multiPayer] is on.
  late String _payer;
  bool _multiPayer = false;

  File? _newImage;
  String? _imagePath;
  bool _saving = false;

  /// Whether the user has edited the amount themselves. An expense opened for
  /// editing starts with one filled in, so it counts as touched from the off.
  bool _amountEdited = false;

  /// Set by the first save attempt. From then on the form says what is wrong,
  /// however little has been filled in.
  bool _submitted = false;

  MoneyContext get ctx => widget.ctx;

  bool get _isEdit => widget.entry != null;

  /// Everyone who gets a row. `selectable` alone would silently drop somebody
  /// who was archived (or whose placeholder was claimed) after this expense was
  /// written — their numbers would still count towards the total with no row to
  /// show them.
  List<String> get _people {
    final out = <String>[...ctx.directory.selectable];
    for (final id in [..._selected, ..._payerCtrls.keys, _payer]) {
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _payer = ctx.myUid;
    _date = entry?.date ?? DateTime.now();

    if (entry != null) {
      _descriptionCtrl.text = entry.description;
      _amountCtrl.text = ctx.format.toInput(entry.amount);
      _noteCtrl.text = entry.note ?? '';
      _category = entry.category;
      _mode = entry.splitMode == SplitMode.settlement ? SplitMode.equal : entry.splitMode;
      _imagePath = entry.imagePath;
      _selected.addAll(entry.owes.keys);
      _multiPayer = entry.paidBy.length > 1;
      _amountEdited = true;
      _payer = entry.paidBy.keys.isEmpty ? ctx.myUid : entry.paidBy.keys.first;
      for (final e in entry.paidBy.entries) {
        _payerCtrls[e.key] = TextEditingController(text: ctx.format.toInput(e.value));
      }
      for (final e in entry.splitInput.entries) {
        _shareCtrls[e.key] = TextEditingController(text: _formatInput(_mode, e.value));
      }
    } else {
      _selected.addAll(_people);
    }
    _amountCtrl.addListener(_onAmountChanged);
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _amountFocus.dispose();
    for (final c in _shareCtrls.values) {
      c.dispose();
    }
    for (final c in _payerCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Rebuilds for the live preview of the split.
  void _onAmountChanged() => setState(() {});

  // ── derived ───────────────────────────────────────────────────────────────

  int get _amount => ctx.format.parse(_amountCtrl.text) ?? 0;

  String _formatInput(SplitMode mode, num value) {
    switch (mode) {
      case SplitMode.percent:
        return (value / 100).toStringAsFixed(2);
      case SplitMode.exact:
      case SplitMode.adjustment:
        return ctx.format.toInput(value.round());
      default:
        return value.round().toString();
    }
  }

  /// The raw per-person numbers the current mode needs, read out of the form.
  Map<String, num> get _splitInput {
    final out = <String, num>{};
    for (final id in _selected) {
      switch (_mode) {
        case SplitMode.equal:
          out[id] = 1;
        case SplitMode.shares:
          out[id] = int.tryParse(_ctrlFor(id).text.trim()) ?? 0;
        case SplitMode.percent:
          final text = _ctrlFor(id).text.trim().replaceAll(',', '.');
          out[id] = ((double.tryParse(text) ?? 0) * 100).round();
        case SplitMode.exact:
        case SplitMode.adjustment:
          out[id] = ctx.format.parse(_ctrlFor(id).text) ?? 0;
        case SplitMode.settlement:
          out[id] = 0;
      }
    }
    return out;
  }

  Map<String, int> get _paidBy {
    if (!_multiPayer) return {_payer: _amount};
    final out = <String, int>{};
    for (final entry in _payerCtrls.entries) {
      final value = ctx.format.parse(entry.value.text) ?? 0;
      if (value > 0) out[entry.key] = value;
    }
    return out;
  }

  TextEditingController _ctrlFor(String id) =>
      _shareCtrls.putIfAbsent(id, () => TextEditingController());

  /// Whether to show the reason the form cannot be saved yet.
  ///
  /// Naming a field the user has not reached is nagging, not helping: typing a
  /// description used to be enough to be told off for the empty amount, before
  /// there was any chance to fill it in. So the line stays quiet until either
  /// they have actually been in both fields, or they have asked to save and
  /// deserve an answer.
  bool get _showProblem {
    if (_submitted) return true;
    if (_descriptionCtrl.text.trim().isEmpty) return false;
    return _amountEdited;
  }

  /// Null when the form can be saved; otherwise the reason it cannot.
  String? get _problem {
    if (_descriptionCtrl.text.trim().isEmpty) return 'Give the expense a name.';
    if (_amount <= 0) return 'Enter an amount.';
    if (_selected.isEmpty) return 'Pick who this is split between.';

    var paid = 0;
    for (final v in _paidBy.values) {
      paid += v;
    }
    if (paid != _amount) {
      // Naming the gap alone ("2,40 unaccounted for") makes the user do the
      // arithmetic to find out what they actually typed. Show the running
      // total against the expense total and the fix is obvious.
      return paid > _amount
          ? 'The payers add up to ${ctx.format.format(paid)}, '
              'more than the ${ctx.format.format(_amount)} total.'
          : 'The payers add up to ${ctx.format.format(paid)} '
              'of ${ctx.format.format(_amount)}.';
    }

    final input = _splitInput;
    if (_mode == SplitMode.exact) {
      var assigned = 0;
      for (final v in input.values) {
        assigned += v.round();
      }
      if (assigned != _amount) {
        final off = assigned - _amount;
        return off > 0
            ? '${ctx.format.formatAbs(off)} too much assigned.'
            : '${ctx.format.formatAbs(off)} left to assign.';
      }
    }
    return validateSplit(mode: _mode, amount: _amount, input: input);
  }

  /// The preview shown under each person, so the effect of any mode is always
  /// visible in real money.
  Map<String, int> get _preview {
    if (_amount <= 0 || _selected.isEmpty) return const {};
    final input = _splitInput;
    if (validateSplit(mode: _mode, amount: _amount, input: input) != null) {
      return const {};
    }
    try {
      return resolveShares(
        mode: _mode,
        amount: _amount,
        input: input,
        seed: widget.entry?.id ?? '',
      );
    } catch (_) {
      return const {};
    }
  }

  // ── actions ───────────────────────────────────────────────────────────────

  void _setMode(SplitMode mode) {
    setState(() {
      _mode = mode;
      _seedShareControllers();
    });
  }

  /// Pre-fills the per-person fields with an even split, so switching mode
  /// starts from something valid instead of an empty form.
  void _seedShareControllers() {
    if (_selected.isEmpty) return;
    final ids = _selected.toList()..sort();
    switch (_mode) {
      case SplitMode.shares:
        for (final id in ids) {
          _ctrlFor(id).text = '1';
        }
      case SplitMode.percent:
        final even = splitByWeights(10000, {for (final id in ids) id: 1});
        for (final id in ids) {
          _ctrlFor(id).text = (even[id]! / 100).toStringAsFixed(2);
        }
      // Money fields start empty rather than at 0,00. A pre-filled amount is
      // noise you have to clear, and tapping into one lands the caret in the
      // middle of it, which is exactly the case that is awkward to correct.
      // Empty reads as nothing assigned yet, which is the truth.
      case SplitMode.exact:
      case SplitMode.adjustment:
        for (final id in ids) {
          _ctrlFor(id).clear();
        }
      case SplitMode.equal:
      case SplitMode.settlement:
        break;
    }
  }

  void _toggleMultiPayer(bool value) {
    setState(() {
      _multiPayer = value;
      // Deliberately no pre-filled total on the first payer: it would be one
      // more amount to tap into and correct. The counter under the rows says
      // how much is still unaccounted for.
      if (value) _payerCtrls.putIfAbsent(_payer, () => TextEditingController());
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      imageQuality: 75,
    );
    if (picked == null) return;
    setState(() => _newImage = File(picked.path));
  }

  Future<void> _showImageSourceSheet() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null) await _pickImage(source);
  }

  Future<void> _save() async {
    if (_problem != null) {
      // No snackbar: the reason appears in the bar directly above the button,
      // which is where the user is already looking.
      setState(() => _submitted = true);
      return;
    }
    setState(() => _saving = true);
    try {
      final entryId = widget.entry?.id ?? ctx.repo.newEntryId();
      var imagePath = _imagePath;
      if (_newImage != null) {
        imagePath = await ctx.repo.uploadReceipt(entryId, _newImage!);
      }
      final input = _splitInput;
      await ctx.repo.saveExpense(
        entryId: entryId,
        isNew: !_isEdit,
        description: _descriptionCtrl.text.trim(),
        amount: _amount,
        currency: ctx.currency,
        date: _date,
        paidBy: _paidBy,
        splitMode: _mode,
        splitInput: input,
        owes: resolveShares(
          mode: _mode,
          amount: _amount,
          input: input,
          seed: entryId,
        ),
        category: _category,
        note: _noteCtrl.text,
        imagePath: imagePath,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the expense. $e')),
      );
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final problem = _problem;

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit expense' : 'New expense')),
      // The action bar is part of the body, not `bottomNavigationBar`.
      // A bottom navigation bar is positioned at the physical bottom of the
      // screen, so on iOS the keyboard covers it. Sitting under an Expanded
      // scroll view inside the body means it rides the shrinking viewport
      // instead, landing directly above the keyboard on every platform
      // (Scaffold.resizeToAvoidBottomInset is on by default).
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _hero(),
                MoneySection('PAID BY', children: _payerSection()),
                MoneySection('SPLIT', children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<SplitMode>(
                // Icons rather than labels: five mode names do not fit across
                // a phone, and the line underneath always spells out the
                // selected one anyway.
                segments: [
                  for (final mode in SplitMode.selectable)
                    ButtonSegment<SplitMode>(
                      value: mode,
                      icon: Icon(_modeIcon(mode)),
                      tooltip: mode.label,
                    ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => _setMode(selection.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(
                '${_mode.label}: ${_mode.hint}',
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.outline),
              ),
            ),
            for (final id in _people) _splitRow(id, preview),
          ]),
                MoneySection('DETAILS', children: [
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Note',
              ),
            ),
            const SizedBox(height: 12),
            _imageSection(),
          ]),
              ],
            ),
          ),
          _actionBar(problem),
        ],
      ),
    );
  }

  /// The two things that actually identify an expense, given the room they
  /// deserve. Everything further down the screen is a qualifier on these two,
  /// so nothing else on the page competes with them for weight.
  Widget _hero() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    InputDecoration bare(String hint, TextStyle? hintStyle) => InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: hintStyle,
        );

    final titleStyle = moneyHeroTitleStyle(context);
    final amountStyle = moneyHeroAmountStyle(context);

    return MoneyHero(
      children: [
        TextField(
          controller: _descriptionCtrl,
          // Straight into typing on a new expense; editing an existing one
          // opens without the keyboard covering half the form.
          autofocus: !_isEdit,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _amountFocus.requestFocus(),
          style: titleStyle,
          decoration: bare(
            'What was it?',
            titleStyle?.copyWith(color: scheme.outlineVariant),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        MoneyAmountField(
          controller: _amountCtrl,
          format: ctx.format,
          focusNode: _amountFocus,
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          style: amountStyle,
          onChanged: (_) {
            if (!_amountEdited) setState(() => _amountEdited = true);
          },
          decoration: bare(
            ctx.format.toInput(0),
            amountStyle?.copyWith(color: scheme.outlineVariant),
          ).copyWith(
            prefixText: '${ctx.format.symbol} ',
            prefixStyle: theme.textTheme.titleLarge
                ?.copyWith(color: scheme.outline, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 20),
        // Date and category are attributes of the expense, not questions of
        // their own, so they sit here as quiet chips instead of taking up a
        // row of full-width buttons.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [_dateChip(), _categoryChip()],
        ),
      ],
    );
  }

  Widget _actionBar(String? problem) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = problem != null;
    return MoneyActionBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blocked && _showProblem)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                problem,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isEdit ? 'Save changes' : 'Add expense'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateChip() => ActionChip(
        avatar: const Icon(Icons.event_outlined, size: 18),
        label: Text(moneyDateLabel(_date)),
        onPressed: _pickDate,
      );

  Widget _categoryChip() {
    final category = moneyCategory(_category);
    return ActionChip(
      avatar: Icon(category?.icon ?? Icons.category_outlined, size: 18),
      label: Text(category?.label ?? 'Category'),
      onPressed: _pickCategory,
    );
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('No category'),
              onTap: () => Navigator.of(context).pop(''),
            ),
            for (final c in kMoneyCategories)
              ListTile(
                leading: Icon(c.icon),
                title: Text(c.label),
                onTap: () => Navigator.of(context).pop(c.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _category = picked.isEmpty ? null : picked);
  }

  List<Widget> _payerSection() {
    var paid = 0;
    for (final v in _paidBy.values) {
      paid += v;
    }

    return [
      if (!_multiPayer)
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final id in _people)
              ChoiceChip(
                label: Text(ctx.nameFor(id)),
                selected: _payer == id,
                onSelected: (_) => setState(() => _payer = id),
              ),
          ],
        )
      else ...[
        for (final id in _people)
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(ctx.nameFor(id)),
            trailing: SizedBox(
              width: 110,
              child: MoneyAmountField(
                controller:
                    _payerCtrls.putIfAbsent(id, () => TextEditingController()),
                format: ctx.format,
                textAlign: TextAlign.end,
                decoration: InputDecoration(prefixText: '${ctx.format.symbol} '),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            paid == _amount
                ? 'Payers add up.'
                : '${ctx.format.format(paid)} of ${ctx.format.format(_amount)}',
            style: TextStyle(
              fontSize: 12.5,
              color: paid == _amount
                  ? Theme.of(context).colorScheme.outline
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        dense: true,
        title: const Text('Several people paid', style: TextStyle(fontSize: 14)),
        value: _multiPayer,
        onChanged: _toggleMultiPayer,
      ),
    ];
  }

  Widget _splitRow(String id, Map<String, int> preview) {
    final selected = _selected.contains(id);
    final share = preview[id];

    Widget? trailing;
    if (selected && _mode != SplitMode.equal) {
      final decoration = InputDecoration(
        prefixText: _mode == SplitMode.percent ? null : '${ctx.format.symbol} ',
        suffixText: _mode == SplitMode.percent
            ? '%'
            : (_mode == SplitMode.shares ? 'x' : null),
      );
      trailing = SizedBox(
        width: 110,
        // Exact amounts are money and fill from the right like the total does.
        // Shares are plain integers and percentages want a typed decimal
        // point, so those stay ordinary fields.
        child: _mode == SplitMode.exact
            ? MoneyAmountField(
                controller: _ctrlFor(id),
                format: ctx.format,
                textAlign: TextAlign.end,
                decoration: decoration,
                onChanged: (_) => setState(() {}),
              )
            : TextField(
                controller: _ctrlFor(id),
                textAlign: TextAlign.end,
                keyboardType: TextInputType.numberWithOptions(
                  decimal: _mode != SplitMode.shares,
                  signed: _mode == SplitMode.adjustment,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    _mode == SplitMode.adjustment
                        ? RegExp(r'[0-9.,-]')
                        : RegExp(r'[0-9.,]'),
                  ),
                ],
                decoration: decoration,
                onChanged: (_) => setState(() {}),
              ),
      );
    }

    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      onChanged: (value) {
        setState(() {
          if (value == true) {
            _selected.add(id);
            // A weight of 1 is a meaningful default; an amount of zero is not.
            if (_mode == SplitMode.shares && _ctrlFor(id).text.isEmpty) {
              _ctrlFor(id).text = '1';
            }
          } else {
            _selected.remove(id);
          }
        });
      },
      title: Text(ctx.nameFor(id)),
      subtitle: share == null
          ? null
          : Text('pays ${ctx.format.format(share)}',
              style: const TextStyle(fontSize: 12.5)),
      secondary: trailing,
    );
  }

  Widget _imageSection() {
    final newImage = _newImage;
    final existing = _imagePath;

    if (newImage == null && existing == null) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _showImageSourceSheet,
          icon: const Icon(Icons.add_a_photo_outlined, size: 20),
          label: const Text('Attach a photo or receipt'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 180,
            width: double.infinity,
            child: newImage != null
                ? Image.file(newImage, fit: BoxFit.cover)
                : StorageImage(storagePath: existing!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: _showImageSourceSheet,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Replace'),
            ),
            TextButton.icon(
              onPressed: () => setState(() {
                _newImage = null;
                _imagePath = null;
              }),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Icon for each split mode in the segmented button.
IconData _modeIcon(SplitMode mode) {
  switch (mode) {
    case SplitMode.equal:
      return Icons.balance;
    case SplitMode.shares:
      return Icons.pie_chart_outline;
    case SplitMode.percent:
      return Icons.percent;
    case SplitMode.exact:
      return Icons.tag;
    case SplitMode.adjustment:
      return Icons.exposure;
    case SplitMode.settlement:
      return Icons.handshake_outlined;
  }
}
