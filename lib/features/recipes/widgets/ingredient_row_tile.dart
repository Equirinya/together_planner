import 'package:flutter/material.dart';

import 'package:couple_planner/features/ingredients/services/units_cache.dart' show UnitsCache;
import 'package:couple_planner/features/ingredients/widgets/avatar.dart' show Avatar;

/// One add/skip + quantity-display ingredient row, swipeable to toggle,
/// shared by [AddToShoppingListDialog] and [MealPlanShoppingListPage].
/// [onIncrease]/[onDecrease] are optional — pass null to hide the quantity
/// adjust buttons and just show the amount as read-only text.
class IngredientRowTile extends StatelessWidget {
  const IngredientRowTile({
    super.key,
    required this.id,
    required this.name,
    required this.description,
    required this.added,
    required this.cur,
    required this.lang,
    required this.onToggle,
    this.onIncrease,
    this.onDecrease,
    this.quantitySeparator = ', ',
  });

  final String id;
  final String name;
  final String description;
  final bool added;
  final Map<String, num?> cur;
  final String lang;
  final VoidCallback onToggle;
  final VoidCallback? onIncrease;
  final VoidCallback? onDecrease;
  final String quantitySeparator;

  static String _fmt(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final toggleIcon = Icon(added ? Icons.remove_shopping_cart : Icons.add_shopping_cart);
    final quantityText = cur.entries
        .where((e) => e.value != null && e.value! > 0)
        .map((e) => '${_fmt(e.value!)} ${UnitsCache.instance.display(e.key, lang, e.value!)}')
        .join(quantitySeparator);

    return Dismissible(
      key: ValueKey(id),
      // Swiping toggles add/skip without removing the row.
      confirmDismiss: (_) async {
        onToggle();
        return false;
      },
      background: Container(
        color: colorScheme.primaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: toggleIcon,
      ),
      secondaryBackground: Container(
        color: colorScheme.primaryContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: toggleIcon,
      ),
      child: Container(
        color: added ? null : colorScheme.errorContainer.withAlpha(80),
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 4),
          minVerticalPadding: 8,
          minTileHeight: 64,
          leading: Avatar(ingredientId: id),
          title: Text(name),
          subtitle: description.isNotEmpty ? Text(description) : null,
          trailing: onIncrease == null && onDecrease == null
              ? (quantityText.isNotEmpty
                  ? Text(quantityText,
                      textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodyLarge)
                  : Text('—',
                      style:
                          Theme.of(context).textTheme.bodyLarge?.copyWith(color: colorScheme.outline)))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (quantityText.isNotEmpty)
                      IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        icon: const Icon(Icons.remove),
                        onPressed: onDecrease,
                      ),
                    quantityText.isNotEmpty
                        ? Text(quantityText, style: Theme.of(context).textTheme.bodyLarge)
                        : Text('—',
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(color: colorScheme.outline)),
                    IconButton(
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      icon: const Icon(Icons.add),
                      onPressed: onIncrease,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
