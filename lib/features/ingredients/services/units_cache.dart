import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';

// =============================================================================
// Unit cache (snapshot listener serves the offline cache first → instant)
// =============================================================================

class UnitsCache {
  UnitsCache._();
  static final UnitsCache instance = UnitsCache._();

  final Map<String, UnitModel> _units = {};
  bool _loaded = false;
  StreamSubscription? _sub;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _sub ??= FirebaseFirestore.instance
        .collection('units')
        .snapshots()
        .listen(_apply);
  }

  void _apply(QuerySnapshot snap) {
    for (final d in snap.docs) {
      final data = d.data()! as Map<String, dynamic>;
      _units[d.id] = UnitModel(
        d.id,
        Map<String, dynamic>.from(data['name'] ?? const {}),
        Map<String, dynamic>.from(data['synonyms'] ?? const {}),
        // Fall back to 1 if the field is absent or null
        (data['defaultIncrement'] as num?) ?? 1,
      );
    }
  }

  UnitModel? byId(String? id) => id == null ? null : _units[id];
  List<UnitModel> get all => _units.values.toList();

  UnitModel? matchWord(String word) {
    for (final u in _units.values) {
      if (u.matches(word)) return u;
    }
    return null;
  }

  /// Formats [count] with the correct singular/plural name for [unitId].
  /// Falls back to [kDefaultUnitId] then to the raw id string.
  String display(String? unitId, String lang, num count) =>
      (byId(unitId) ?? byId(kDefaultUnitId))?.display(lang, count) ??
          (unitId ?? kDefaultUnitId);

  /// Returns the step size for +/– controls for [unitId].
  /// Falls back to 1 if the unit is unknown or has no defaultIncrement set.
  num increment(String? unitId) => byId(unitId)?.defaultIncrement ?? 1;

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _loaded = false;
    _units.clear();
  }
}
