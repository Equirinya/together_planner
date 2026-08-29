import 'package:flutter/material.dart';

/// Optional tag on an expense. Purely cosmetic today (icon + label); kept as a
/// stable key so a later "spending by category" view needs no migration.
class MoneyCategory {
  const MoneyCategory(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

const List<MoneyCategory> kMoneyCategories = [
  MoneyCategory('groceries', 'Groceries', Icons.shopping_basket_outlined),
  MoneyCategory('eatingOut', 'Eating out', Icons.restaurant_outlined),
  MoneyCategory('home', 'Home', Icons.home_outlined),
  MoneyCategory('utilities', 'Bills', Icons.receipt_long_outlined),
  MoneyCategory('transport', 'Transport', Icons.directions_car_outlined),
  MoneyCategory('travel', 'Travel', Icons.flight_outlined),
  MoneyCategory('fun', 'Fun', Icons.celebration_outlined),
  MoneyCategory('health', 'Health', Icons.favorite_outline),
  MoneyCategory('gifts', 'Gifts', Icons.card_giftcard_outlined),
  MoneyCategory('other', 'Other', Icons.category_outlined),
];

MoneyCategory? moneyCategory(String? key) {
  if (key == null || key.isEmpty) return null;
  for (final c in kMoneyCategories) {
    if (c.key == key) return c;
  }
  return null;
}

IconData moneyCategoryIcon(String? key) =>
    moneyCategory(key)?.icon ?? Icons.receipt_outlined;
