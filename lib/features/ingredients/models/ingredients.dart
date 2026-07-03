// Data models and small pure helpers shared across ingredient search, recipes
// and the shopping list. Kept free of Firebase/Flutter imports so they stay
// trivially testable.

// ─── Configure these ─────────────────────────────────────────────────────────
const String kDefaultUnitId = 'QDXQ6Du2gQgEOoRIRsqJ'; // pcs / Stk unit doc id
const String kPendingIngredient = '0'; // newly added, resolution in progress
const String kUnknownIngredient = '1'; // could not be matched at all

// =============================================================================
// Small shared helpers
// =============================================================================

/// Reads the single `{unitId: qty}` entry from a Firestore `quantity` map.
/// Returns null when the field is null or empty — meaning "no quantity".
({String unitId, num qty})? readQuantity(Object? quantity) {
  if (quantity == null) return null;
  final q = Map<String, dynamic>.from(quantity as Map);
  if (q.isEmpty) return null;
  return (unitId: q.keys.first, qty: q.values.first as num);
}

String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String fmtQty(num q) =>
    q == q.roundToDouble() ? q.toInt().toString() : q.toString();

// =============================================================================
// Models
// =============================================================================

class MatchedIngredient {
  MatchedIngredient(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;

  String get defaultUnit => (data['defaultUnit'] ?? kDefaultUnitId).toString();

  String displayName(String lang) {
    final n = data['name'];
    return n is Map ? (n[lang] ?? n['en'] ?? '').toString() : '';
  }

  /// Returns the category string to store on list items for sorting.
  /// Handles both plain strings and localized maps.
  String category(String lang) {
    final cat = data['category'];
    if (cat is Map) return (cat[lang] ?? cat['en'] ?? '').toString();
    return (cat ?? '').toString();
  }
}

class Suggestion {
  Suggestion({
    required this.ingredientId,
    required this.displayName,
    required this.description,
    required this.unitId,
    this.quantity,   // null → no quantity (hidden in UI; counts as 1 when combining)
    this.category = '',
    this.isFallback = false,
    this.isRestoreDone = false,
    this.docId,
  });

  final String ingredientId;
  final String displayName;
  final String description;
  final String unitId; // always set; defaults to kDefaultUnitId
  final num? quantity;
  final String category;
  final bool isFallback;
  final bool isRestoreDone;
  final String? docId;

  /// null when there is no quantity — stored as null in Firestore too.
  Map<String, double>? get quantityMap =>
      quantity == null ? null : {unitId: quantity!.toDouble()};

  factory Suggestion.fromMap(Map<String, dynamic> m,
      {bool isRestoreDone = false, bool keepQuantity = true}) {
    final q = keepQuantity ? readQuantity(m['quantity']) : null;
    return Suggestion(
      ingredientId: (m['ingredientId'] ?? kUnknownIngredient).toString(),
      displayName: (m['displayName'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      unitId: q?.unitId ?? kDefaultUnitId,
      quantity: q?.qty,
      category: (m['category'] ?? '').toString(),
      isRestoreDone: isRestoreDone,
      docId: m['id']?.toString(),
    );
  }
}

class UnitModel {
  final String id;

  /// { "en": { "singular": "cup", "plural": "cups" }, "de": { … } }
  final Map<String, dynamic> name;

  /// { "en": ["c."], "de": ["Ts."] }
  final Map<String, dynamic> synonyms;

  /// How much one +/– tap changes the amount for this unit.
  /// Defaults to 1 if not set in Firestore.
  /// Examples: 1 for pieces/grams/ml, 5 for grams when editing in bulk, 0.25 for cups.
  final num defaultIncrement;

  UnitModel(this.id, this.name, this.synonyms, [this.defaultIncrement = 1]);

  // ── Display ──────────────────────────────────────────────────────────────

  /// Returns the localised unit name only (singular or plural).
  /// The caller is responsible for formatting and prepending the amount.
  String display(String lang, num count) {
    final langMap =
    (name[lang] ?? name['en'] ?? const {}) as Map<dynamic, dynamic>;
    final singular = (langMap['singular'] ?? id).toString();
    final plural = (langMap['plural'] ?? singular).toString();
    return count == 1 ? singular : plural;
  }

  // ── Matching (used by recipe parsing / search) ───────────────────────────

  /// Returns true if [word] matches any singular, plural, or synonym for
  /// any language.
  bool matches(String word) {
    final lower = word.toLowerCase();
    for (final entry in name.values) {
      if (entry is Map) {
        if ((entry['singular'] ?? '').toString().toLowerCase() == lower) {
          return true;
        }
        if ((entry['plural'] ?? '').toString().toLowerCase() == lower) {
          return true;
        }
      }
    }
    for (final list in synonyms.values) {
      if (list is List) {
        if (list.any((s) => s.toString().toLowerCase() == lower)) return true;
      }
    }
    return false;
  }
}

class ParsedInput {
  ParsedInput(this.quantity, this.unitId, this.remaining);
  final num? quantity;
  final String? unitId;
  final List<String> remaining; // tokens that form name + optional description
}
