/// The single-category classification carried by every generated recipe.
///
/// Mirrors `RECIPE_CATEGORIES` in
/// `firebase/functions/src/recipes/types.ts` — the stored value is always one
/// of these stable English keys (never a translated label), so both ends must
/// be changed together.
///
/// The field is deliberately hidden from the app for now: nothing renders or
/// filters by it outside the public-recipes admin page. Recipes created before
/// the field existed have `category == null` until the admin backfill runs.
library;

const kRecipeCategories = <String>[
  'mainDish',
  'sideDish',
  'breakfast',
  'snack',
  'baking',
  'dessert',
  'sauce',
  'drink',
  'other',
];

/// Admin-facing English labels. Intentionally not localized: the only screen
/// that shows a category is the moderation page, which is English throughout.
const kRecipeCategoryLabels = <String, String>{
  'mainDish': 'Main dish',
  'sideDish': 'Side dish',
  'breakfast': 'Breakfast',
  'snack': 'Snack',
  'baking': 'Baking',
  'dessert': 'Dessert',
  'sauce': 'Sauce & dip',
  'drink': 'Drink',
  'other': 'Other',
};

/// The stored key coerced to a known category, or null when the recipe has
/// never been classified (or carries something unrecognised).
String? recipeCategoryOf(Object? value) {
  if (value is! String) return null;
  final key = value.trim();
  return kRecipeCategories.contains(key) ? key : null;
}

/// A display label for a stored category value, falling back to a dash for
/// recipes that haven't been classified yet.
String recipeCategoryLabel(Object? value) {
  final key = recipeCategoryOf(value);
  return key == null ? '—' : (kRecipeCategoryLabels[key] ?? key);
}
