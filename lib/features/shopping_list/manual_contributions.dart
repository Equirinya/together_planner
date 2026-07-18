// Per-user attribution for the parts of a shopping-list item that were added
// by hand rather than by a cooking plan.
//
// Stored on the shopping-list item document as
//   manualQuantities: { <uid>: { <unitId>: <amount> } }
// — the same `{unitId: amount}` shape as the item's own `quantity` field, so
// the existing formatting helpers work on it unchanged.
//
// Cooking-plan contributions are *not* recorded here; they already live on the
// plan documents (itemIds/quantities) and are read back by the item's
// long-press dialog.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

const String kManualQuantitiesField = 'manualQuantities';

String? _currentUid() => FirebaseAuth.instance.currentUser?.uid;

/// The document data for a brand-new item that [uid] is adding by hand.
/// An item added without a quantity still records the user (with an empty
/// amount map), so the item can be shown as theirs without inventing a number.
/// Returns null when there is no signed-in user to attribute it to.
Map<String, dynamic>? manualQuantitiesSeed(String? unitId, num? qty,
    {String? uid}) {
  final u = uid ?? _currentUid();
  if (u == null) return null;
  return {
    u: (unitId == null || qty == null || qty <= 0)
        ? <String, double>{}
        : {unitId: qty.toDouble()},
  };
}

/// A Firestore `update()` payload attributing [delta] of [unitId] to [uid]
/// (the signed-in user by default). Dotted field paths mean only that one
/// user's bucket is touched, and [FieldValue.increment] keeps concurrent adds
/// from two devices from clobbering each other.
///
/// Returns an empty map when there is nothing to record, so it can always be
/// spread into an update: `{...other, ...manualDelta(u, d)}`.
Map<String, dynamic> manualDelta(String? unitId, num delta, {String? uid}) {
  final u = uid ?? _currentUid();
  if (u == null || unitId == null || delta == 0) return const {};
  return {
    '$kManualQuantitiesField.$u.$unitId': FieldValue.increment(delta.toDouble()),
  };
}

/// Moves a manual contribution from one unit to another — used when a hand
/// edit changes the unit, where a plain delta would be meaningless.
Map<String, dynamic> manualUnitSwitch({
  required String? fromUnitId,
  required num fromQty,
  required String? toUnitId,
  required num toQty,
  String? uid,
}) =>
    {
      ...manualDelta(fromUnitId, -fromQty, uid: uid),
      ...manualDelta(toUnitId, toQty, uid: uid),
    };

/// Parses the stored map into `{uid: {unitId: amount}}`, dropping units whose
/// amount has fallen to zero or below (a user can edit a quantity back down).
/// A user with no amounts left is kept — either they added the item without a
/// quantity, or someone else has since edited the amount away; both still mean
/// "this user put it on the list".
Map<String, Map<String, num>> readManualQuantities(Object? raw) {
  final out = <String, Map<String, num>>{};
  if (raw is! Map) return out;
  raw.forEach((uid, byUnit) {
    if (byUnit is! Map) return;
    final units = <String, num>{};
    byUnit.forEach((unitId, amount) {
      if (amount is num && amount > 0) units[unitId.toString()] = amount;
    });
    out[uid.toString()] = units;
  });
  return out;
}
