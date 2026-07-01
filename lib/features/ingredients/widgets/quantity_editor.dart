import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';

// =============================================================================
// Quantity editor (bottom sheet, floats above the number keyboard)
// =============================================================================

class QuantityEditor extends StatefulWidget {
  const QuantityEditor({
    required this.initialUnitId,
    required this.initialQty,
    required this.lang,
    required this.onChanged,
  });

  final String initialUnitId;
  final num initialQty;
  final String lang;
  // Called immediately on every action so changes survive even if the sheet is
  // dismissed via the keyboard close gesture.
  final Future<void> Function(String unitId, num? qty) onChanged;

  @override
  State<QuantityEditor> createState() => _QuantityEditorState();
}

class _QuantityEditorState extends State<QuantityEditor> {
  late final TextEditingController _ctrl;
  late String _unitId;

  StreamSubscription<bool>? _kbSub;
  bool _keyboardWasVisible = false;

  num get _qty => num.tryParse(_ctrl.text.replaceAll(',', '.')) ?? 0;

  @override
  void initState() {
    super.initState();
    _unitId = widget.initialUnitId;
    final text = fmtQty(widget.initialQty);
    _ctrl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);

    // Close the sheet when the keyboard is dismissed — only after it opened once.
    _kbSub = KeyboardVisibilityController().onChange.listen((visible) {
      if (visible) {
        _keyboardWasVisible = true;
      } else if (_keyboardWasVisible && mounted) {
        final animation = ModalRoute.of(context)?.animation;
        final closing = animation?.status == AnimationStatus.reverse
            || animation?.status == AnimationStatus.dismissed;
        if (!closing) Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _kbSub?.cancel();
    _push();
    _ctrl.dispose();
    super.dispose();
  }

  void _bump(num delta) {
    final next = (_qty + delta).clamp(0, 1 << 31);
    setState(() => _ctrl.text = fmtQty(next));
    _push();
  }

  void _push() => widget.onChanged(_unitId, _qty == 0 ? null : _qty);

  @override
  Widget build(BuildContext context) {
    final units = UnitsCache.instance.all;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).viewInsets.bottom + 12),
      child: Row(
        children: [
          IconButton.filledTonal(
              icon: const Icon(Icons.remove), onPressed: () => _bump(-1)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              textAlign: TextAlign.center,
              keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
              ],
              decoration:
              const InputDecoration(border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                _push();
                Navigator.of(context).maybePop();
              },
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: units.any((u) => u.id == _unitId) ? _unitId : null,
            items: [
              for (final u in units)
                DropdownMenuItem(
                    value: u.id,
                    child: Text(u.display(widget.lang, _qty))),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _unitId = v);
              _push();
            },
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
              icon: const Icon(Icons.add), onPressed: () => _bump(1)),
        ],
      ),
    );
  }
}
