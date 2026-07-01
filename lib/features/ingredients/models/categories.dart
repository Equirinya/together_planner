// ─── Categories ───────────────────────────────────────────────────────────────
// Matches the `category` field stored on ingredient docs.
// Ordered to follow a typical supermarket walk: produce first, frozen last.
const List<String> kCategories = [
  'fruits_and_vegetables',
  'bread_and_bakery',
  'meat_and_fish',
  'dairy_and_eggs',
  'grains_and_pasta',
  'canned_and_packaged_goods',
  'baking_ingredients',
  'nuts_and_seeds',
  'snacks_and_sweets',
  'beverages',
  'frozen_foods',
  'condiments_and_sauces',
  'spices_and_herbs',
  'hygiene',
  'other',
];

/// Rank of [category] in shopping-walk order; uncategorised/unknown sorts last.
int categoryRank(String category) {
  final c = category.trim();
  final i = kCategories.indexOf(c.isEmpty ? 'other' : c);
  return i == -1 ? kCategories.length : i;
}
