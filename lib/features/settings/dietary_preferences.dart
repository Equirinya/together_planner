import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

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
  'Jain',
  'Low-carb',
];

class _DietaryOption {
  const _DietaryOption(this.label, this.icon);
  final String label;
  final IconData icon;
}

// Row 1: connected toggle buttons
final List<_DietaryOption> _kToggleOptions = [
  _DietaryOption('Vegan', Icons.spa),
  _DietaryOption('Vegetarian', Icons.eco),
  _DietaryOption('Pescatarian', MdiIcons.fish),
];

// Row 2: religion-related diets
final List<_DietaryOption> _kReligionOptions = [
  _DietaryOption('Halal', MdiIcons.foodHalal),
  _DietaryOption('Kosher', MdiIcons.foodKosher),
  _DietaryOption('Jain', MdiIcons.om),
];

// Row 3: dietary restrictions (smaller buttons, 4 per row)
final List<_DietaryOption> _kRestrictionOptions = [
  _DietaryOption('Gluten-free', MdiIcons.barleyOff),
  _DietaryOption('Lactose-free', MdiIcons.cowOff),
  _DietaryOption('Nut-free', MdiIcons.peanutOff),
  _DietaryOption('Low-carb', Icons.fitness_center),
];

/// Returns the icon for a dietary tag, or null if not a known dietary option.
/// Matching is case-insensitive and ignores hyphens and spaces,
/// so "Nut-free", "nut free", and "nutfree" all match.
// Maps normalized tag labels (lowercase, no spaces/hyphens) to icons.
// Keys must be pre-normalized. To add a language, append its terms here.
// Normalization strips spaces and hyphens, so "nut-free", "nut free" and
// "nutfree" all resolve to the same key "nutfree".
final Map<String, IconData> _kDietaryTagIcons = {
  // — English —
  'vegan':        Icons.spa,
  'vegetarian':   Icons.eco,
  'pescatarian':  MdiIcons.fish,
  'glutenfree':   MdiIcons.barleyOff,
  'lactosefree':  MdiIcons.cowOff,
  'nutfree':      MdiIcons.peanutOff,
  'halal':        MdiIcons.foodHalal,
  'kosher':       MdiIcons.foodKosher,
  'jain':         MdiIcons.om,
  'lowcarb':      Icons.fitness_center,
  // — German —
  'vegetarisch':      Icons.eco,
  'pescetarisch':     MdiIcons.fish,
  'glutenfrei':       MdiIcons.barleyOff,
  'laktosefrei':      MdiIcons.cowOff,
  'nussfrei':         MdiIcons.peanutOff,
  'koscher':          MdiIcons.foodKosher,
  'kohlenhydratarm':  Icons.fitness_center,
};

String _normalizeDietaryTag(String tag) =>
    tag.toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '');

/// Returns the icon for a dietary tag, or null if not recognised.
/// Matching is case-insensitive and ignores spaces and hyphens.
IconData? dietaryTagIcon(String tag) =>
    _kDietaryTagIcons[_normalizeDietaryTag(tag)];

/// Maps each canonical (English, as in [kDietaryOptions]) standard diet label
/// to every recognized synonym across supported content languages, normalized
/// via [_normalizeDietaryTag]. Used to match a `#tag` search term against a
/// recipe's `dietary` field (always stored as canonical English labels)
/// regardless of which language the search term or the recipe happen to be in.
/// To add a language, append its normalized terms to the relevant entry.
final Map<String, Set<String>> _kDietarySynonyms = {
  'Vegan': {'vegan'},
  'Vegetarian': {'vegetarian', 'vegetarisch'},
  'Pescatarian': {'pescatarian', 'pescetarisch'},
  'Gluten-free': {'glutenfree', 'glutenfrei'},
  'Lactose-free': {'lactosefree', 'laktosefrei'},
  'Nut-free': {'nutfree', 'nussfrei'},
  'Halal': {'halal'},
  'Kosher': {'kosher', 'koscher'},
  'Jain': {'jain'},
  'Low-carb': {'lowcarb', 'kohlenhydratarm'},
};

/// Returns the canonical (English) dietary label that [tag] refers to (e.g.
/// "glutenfrei" or "gluten-free" -> "Gluten-free"), or null if [tag] isn't a
/// recognized dietary synonym in any supported language.
String? canonicalDietaryLabel(String tag) {
  final normalized = _normalizeDietaryTag(tag);
  for (final entry in _kDietarySynonyms.entries) {
    if (entry.value.contains(normalized)) return entry.key;
  }
  return null;
}

/// All recognized synonyms (across every supported content language) for a
/// canonical dietary label such as "Gluten-free" (matched case-insensitively),
/// e.g. "gluten-free" -> {"glutenfree", "glutenfrei"}; empty if [label] isn't
/// a recognized standard diet. Used to make free-text recipe search find a
/// recipe's `dietary` labels regardless of which language the query is in.
Set<String> dietarySynonyms(String label) {
  final lower = label.toLowerCase();
  for (final entry in _kDietarySynonyms.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return const {};
}

/// Lets the user pick preset dietary preferences and add their own. Controlled:
/// reports the full list (presets + custom) via [onChanged].
class DietaryPreferencesSelector extends StatefulWidget {
  const DietaryPreferencesSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.showCustomEntriesInfo = true,
  });

  final List<String> value;
  final ValueChanged<List<String>> onChanged;

  /// Whether to show the "Custom entries aren't considered for suggestions…"
  /// note below the custom-entry chips. Only true for suggestions-driven
  /// contexts (the normal dietary settings page) — not relevant where custom
  /// entries ARE fully considered, e.g. the meal-plan flow.
  final bool showCustomEntriesInfo;

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

  // Vegan implies Vegetarian; Vegan or Vegetarian implies Pescatarian.
  // Implied options appear muted but are still tappable to switch the selection down.
  bool _isChecked(String option) {
    if (option == 'Vegetarian' && _selected.contains('Vegan')) return true;
    if (option == 'Pescatarian' &&
        (_selected.contains('Vegan') || _selected.contains('Vegetarian'))) return true;
    return _selected.contains(option);
  }

  // Returns true when the option is active only because a stricter option implies it.
  bool _isImplied(String option) => _isChecked(option) && !_selected.contains(option);

  bool _isDisabled(String option) => false;

  void _toggle(String option) {
    setState(() {
      if (_selected.contains(option)) {
        _selected.remove(option);
      } else if (option == 'Vegetarian' && _selected.contains('Vegan')) {
        // Switch down: Vegan → Vegetarian
        _selected.remove('Vegan');
        _selected.add('Vegetarian');
      } else if (option == 'Pescatarian' &&
          (_selected.contains('Vegan') || _selected.contains('Vegetarian'))) {
        // Switch down: Vegan/Vegetarian → Pescatarian
        _selected.remove('Vegan');
        _selected.remove('Vegetarian');
        _selected.add('Pescatarian');
      } else {
        _selected.add(option);
        if (option == 'Vegan') {
          _selected.remove('Vegetarian');
          _selected.remove('Pescatarian');
        } else if (option == 'Vegetarian') {
          _selected.remove('Pescatarian');
        }
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
        // Row 1: connected Vegan / Vegetarian toggle
        _ConnectedToggleRow(
          options: _kToggleOptions,
          isChecked: _isChecked,
          isImplied: _isImplied,
          onTap: _toggle,
        ),
        const SizedBox(height: 12),
        // Row 2: religion-related diets
        _OptionRow(
          options: _kReligionOptions,
          isChecked: _isChecked,
          isDisabled: _isDisabled,
          onTap: _toggle,
        ),
        const SizedBox(height: 12),
        // Row 3: restrictions (smaller, 4 items)
        _OptionRow(
          options: _kRestrictionOptions,
          isChecked: _isChecked,
          isDisabled: _isDisabled,
          onTap: _toggle,
          small: true,
        ),
        const SizedBox(height: 24),
        // Custom entries
        if (custom.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in custom)
                InputChip(
                  avatar: Icon(Icons.restaurant_outlined,
                      size: 16, color: Theme.of(context).colorScheme.onPrimary),
                  label: Text(entry),
                  showCheckmark: false,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary),
                  deleteIconColor: Theme.of(context).colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  onDeleted: () => _remove(entry),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // Info text
        if (widget.showCustomEntriesInfo) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Custom entries aren\'t considered for suggestions, but are used when generating recipes.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        // Custom entry input
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customCtrl,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: 'e.g. "no shellfish", "avoids cilantro"…',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                onSubmitted: (_) => _addCustom(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.add),
              tooltip: 'Add',
              onPressed: _addCustom,
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Row widgets
// ---------------------------------------------------------------------------

class _ConnectedToggleRow extends StatelessWidget {
  const _ConnectedToggleRow({
    required this.options,
    required this.isChecked,
    required this.isImplied,
    required this.onTap,
  });

  final List<_DietaryOption> options;
  final bool Function(String) isChecked;
  final bool Function(String) isImplied;
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        children: [
          for (int i = 0; i < options.length; i++) ...[
            Expanded(
              child: _ConnectedOptionButton(
                label: options[i].label,
                icon: options[i].icon,
                checked: isChecked(options[i].label),
                implied: isImplied(options[i].label),
                onTap: () => onTap(options[i].label),
                borderRadius: _radiusFor(i, options.length),
              ),
            ),
            if (i < options.length - 1)
              VerticalDivider(
                width: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }

  static BorderRadius _radiusFor(int i, int total) {
    const r = Radius.circular(16);
    if (total == 1) return BorderRadius.circular(16);
    if (i == 0) return const BorderRadius.only(topLeft: r, bottomLeft: r);
    if (i == total - 1) return const BorderRadius.only(topRight: r, bottomRight: r);
    return BorderRadius.zero;
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.options,
    required this.isChecked,
    required this.isDisabled,
    required this.onTap,
    this.small = false,
  });

  final List<_DietaryOption> options;
  final bool Function(String) isChecked;
  final bool Function(String) isDisabled;
  final void Function(String) onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < options.length; i++) ...[
          Expanded(
            child: DietaryOptionButton(
              label: options[i].label,
              icon: options[i].icon,
              checked: isChecked(options[i].label),
              disabled: isDisabled(options[i].label),
              onTap: () => onTap(options[i].label),
              small: small,
            ),
          ),
          if (i < options.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Button widgets
// ---------------------------------------------------------------------------

class _ConnectedOptionButton extends StatelessWidget {
  const _ConnectedOptionButton({
    required this.label,
    required this.icon,
    required this.checked,
    required this.implied,
    required this.onTap,
    required this.borderRadius,
  });

  final String label;
  final IconData icon;
  final bool checked;
  final bool implied;
  final VoidCallback onTap;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final Color cardColor = implied
        ? colorScheme.primaryContainer
        : checked
            ? colorScheme.primary
            : colorScheme.surfaceContainerHighest;

    final Color contentColor = implied
        ? colorScheme.onPrimaryContainer
        : checked
            ? colorScheme.onPrimary
            : colorScheme.onSurfaceVariant;

    return ClipRRect(
      borderRadius: borderRadius,
      child: Material(
        color: cardColor,
        child: InkWell(
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 32, color: contentColor),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(color: contentColor, fontSize: 13),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
    );
  }
}

/// A rounded, icon-led selectable card button. Used for the dietary
/// restriction row below and reused as-is by the meal-plan style selector
/// (lib/features/recipes/pages/meal_plan_flow.dart) so both pickers share the
/// same playful visual language.
class DietaryOptionButton extends StatelessWidget {
  const DietaryOptionButton({
    required this.label,
    required this.icon,
    required this.checked,
    required this.disabled,
    required this.onTap,
    this.small = false,
  });

  final String label;
  final IconData icon;
  final bool checked;
  final bool disabled;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final Color cardColor = disabled
        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
        : checked
            ? colorScheme.primary
            : colorScheme.surfaceContainerHighest;

    final Color contentColor = disabled
        ? colorScheme.onSurface.withValues(alpha: 0.38)
        : checked
            ? colorScheme.onPrimary
            : colorScheme.onSurfaceVariant;

    return Card(
      color: cardColor,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: small
              ? const EdgeInsets.symmetric(vertical: 10, horizontal: 4)
              : const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: small ? 22 : 32, color: contentColor),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: contentColor, fontSize: small ? 11 : 13),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
