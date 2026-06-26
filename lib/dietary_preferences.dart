import 'package:flutter/material.dart';

/// Preset dietary preference labels. Stored as-is in users/{uid}.dietaryPreferences
/// alongside any free-text entries the user adds.
const List<String> kDietaryOptions = [
  'Vegetarian',
  'Vegan',
  'Pescatarian',
  'Gluten-free',
  'Lactose-free',
  'Nut-free',
  'Halal',
  'Kosher',
  'Low-carb',
];

/// Lets the user pick preset dietary preferences and add their own. Controlled:
/// reports the full list (presets + custom) via [onChanged].
class DietaryPreferencesSelector extends StatefulWidget {
  const DietaryPreferencesSelector({super.key, required this.value, required this.onChanged});

  final List<String> value;
  final ValueChanged<List<String>> onChanged;

  @override
  State<DietaryPreferencesSelector> createState() => _DietaryPreferencesSelectorState();
}

class _DietaryPreferencesSelectorState extends State<DietaryPreferencesSelector> {
  late List<String> _selected = List.of(widget.value);
  final TextEditingController _customCtrl = TextEditingController();

  @override
  void didUpdateWidget(covariant DietaryPreferencesSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _selected = List.of(widget.value);
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(List.of(_selected));

  void _toggle(String option) {
    setState(() {
      if (_selected.contains(option)) {
        _selected.remove(option);
      } else {
        _selected.add(option);
      }
    });
    _emit();
  }

  void _addCustom() {
    final text = _customCtrl.text.trim();
    if (text.isEmpty) return;
    if (!_selected.any((e) => e.toLowerCase() == text.toLowerCase())) {
      setState(() => _selected.add(text));
      _emit();
    }
    _customCtrl.clear();
  }

  void _remove(String entry) {
    setState(() => _selected.remove(entry));
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final custom = _selected.where((e) => !kDietaryOptions.contains(e)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final option in kDietaryOptions)
              FilterChip(
                label: Text(option),
                showCheckmark: false,
                selected: _selected.contains(option),
                onSelected: (_) => _toggle(option),
                side: BorderSide.none,
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: _selected.contains(option)
                    ? TextStyle(color: Theme.of(context).colorScheme.onPrimary)
                    : null,
              ),
            for (final entry in custom)
              InputChip(
                label: Text(entry),
                showCheckmark: false,
                side: BorderSide.none,
                backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                onDeleted: () => _remove(entry),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customCtrl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'Add your own…',
                  isDense: true,
                ),
                onSubmitted: (_) => _addCustom(),
              ),
            ),
            IconButton(icon: const Icon(Icons.add), tooltip: 'Add', onPressed: _addCustom),
          ],
        ),
      ],
    );
  }
}
