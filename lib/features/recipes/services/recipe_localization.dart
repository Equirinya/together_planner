/// Group recipes always store an English base (`name`/`description`/`tags`/
/// `steps`) plus a `translations` map for the app's other supported languages
/// (see `generateRecipeStaged` in firebase/functions/src/recipes.ts), the same
/// convention public_recipes already used. These helpers pick the right
/// language for display, falling back to the English base when no
/// translation is available yet (e.g. an older recipe, or one still mid-
/// generation) so nothing ever renders empty.
library;

/// Returns [data] with `name`/`description`/`tags`/`steps` swapped for their
/// `translations[lang]` versions when available.
Map<String, dynamic> localizeRecipeData(Map<String, dynamic> data, String lang) {
  if (lang == 'en') return data;
  final localized = (data['translations'] as Map?)?[lang] as Map?;
  if (localized == null) return data;
  return {
    ...data,
    if (localized['name'] != null) 'name': localized['name'],
    if (localized['description'] != null) 'description': localized['description'],
    if (localized['tags'] != null) 'tags': localized['tags'],
    if (localized['steps'] != null) 'steps': localized['steps'],
  };
}

/// Same idea for a single ingredient subdocument: swaps `displayName`/
/// `description` for their `translations[lang]` versions when available.
Map<String, dynamic> localizeIngredientData(Map<String, dynamic> data, String lang) {
  if (lang == 'en') return data;
  final localized = (data['translations'] as Map?)?[lang] as Map?;
  if (localized == null) return data;
  return {
    ...data,
    if (localized['displayName'] != null) 'displayName': localized['displayName'],
    if (localized['description'] != null) 'description': localized['description'],
  };
}
