import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:couple_planner/features/money/models/money_entry.dart';
import 'package:couple_planner/features/money/models/money_person.dart';
import 'package:couple_planner/features/money/models/split_mode.dart';

/// Firestore access for one group's money feature. Everything that knows about
/// documents lives here; the models, the balance engine and the settlement
/// solver stay plain Dart so they can be unit-tested without Firebase.
class MoneyRepository {
  MoneyRepository(this.groupId);

  final String groupId;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DocumentReference<Map<String, dynamic>> get groupRef =>
      _db.collection('groups').doc(groupId);

  CollectionReference<Map<String, dynamic>> get entriesRef =>
      groupRef.collection('money_entries');

  CollectionReference<Map<String, dynamic>> get peopleRef =>
      groupRef.collection('money_people');

  // ── reads ─────────────────────────────────────────────────────────────────

  Stream<List<MoneyEntry>> watchEntries() => entriesRef
      .orderBy('date', descending: true)
      .snapshots()
      .map((snap) => sortMoneyEntriesForDisplay(snap.docs.map(entryFromDoc).toList()));

  Stream<List<MoneyPerson>> watchPeople() => peopleRef
      .snapshots()
      .map((snap) => snap.docs.map(personFromDoc).toList());

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchGroup() =>
      groupRef.snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchMembers() =>
      groupRef.collection('members').snapshots();

  /// Display names for [uids], read from the public profile collection.
  Future<Map<String, String>> loadUsernames(Iterable<String> uids) async {
    final out = <String, String>{};
    await Future.wait(uids.map((id) async {
      try {
        final doc = await _db.collection('users_public').doc(id).get();
        final name = doc.data()?['username'];
        if (name is String && name.isNotEmpty) out[id] = name;
      } catch (_) {
        // A missing or unreadable profile just falls back to "Someone".
      }
    }));
    return out;
  }

  // ── writes: entries ───────────────────────────────────────────────────────

  /// Reserves an id up front so a receipt photo can be uploaded to its final
  /// Storage path before the document itself exists.
  String newEntryId() => entriesRef.doc().id;

  Future<void> saveExpense({
    required String entryId,
    required bool isNew,
    required String description,
    required int amount,
    required String currency,
    required DateTime date,
    required Map<String, int> paidBy,
    required SplitMode splitMode,
    required Map<String, num> splitInput,
    required Map<String, int> owes,
    String? category,
    String? note,
    String? imagePath,
  }) async {
    final data = <String, dynamic>{
      'type': MoneyEntryType.expense.key,
      'description': description,
      'amount': amount,
      'currency': currency,
      'date': Timestamp.fromDate(moneyDayOf(date)),
      'paidBy': paidBy,
      'splitMode': splitMode.key,
      'splitInput': splitInput.map((k, v) => MapEntry(k, v)),
      'owes': owes,
      if (category != null && category.isNotEmpty) 'category': category,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      if (imagePath != null && imagePath.isNotEmpty) 'image': imagePath,
    };

    if (isNew) {
      data['createdAt'] = FieldValue.serverTimestamp();
      data['createdBy'] = uid;
      await entriesRef.doc(entryId).set(data);
    } else {
      data['updatedAt'] = FieldValue.serverTimestamp();
      data['updatedBy'] = uid;
      // Fields the user cleared have to be removed explicitly, since a `set`
      // with merge would leave the old value behind.
      if (category == null || category.isEmpty) {
        data['category'] = FieldValue.delete();
      }
      if (note == null || note.trim().isEmpty) data['note'] = FieldValue.delete();
      if (imagePath == null || imagePath.isEmpty) {
        data['image'] = FieldValue.delete();
      }
      await entriesRef.doc(entryId).update(data);
    }
  }

  /// Records a payment from one person to another. In the ledger this is just
  /// an entry where [from] put the money in and [to] consumed it, which is why
  /// it needs no separate collection or separate balance arithmetic.
  Future<void> saveSettlement({
    required String from,
    required String to,
    required int amount,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    await entriesRef.doc(newEntryId()).set({
      'type': MoneyEntryType.settlement.key,
      'description': '',
      'amount': amount,
      'currency': currency,
      'date': Timestamp.fromDate(moneyDayOf(date)),
      'paidBy': {from: amount},
      'splitMode': SplitMode.settlement.key,
      'splitInput': {to: amount},
      'owes': {to: amount},
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
    });
  }

  Future<void> deleteEntry(MoneyEntry entry) async {
    await entriesRef.doc(entry.id).delete();
    final path = entry.imagePath;
    if (path != null && path.isNotEmpty) {
      try {
        await FirebaseStorage.instance.ref(path).delete();
      } catch (_) {
        // An orphaned image is harmless; a failed delete must not block the
        // document delete the user actually asked for.
      }
    }
  }

  // ── writes: people ────────────────────────────────────────────────────────

  Future<String> addPerson(String name) async {
    final ref = peopleRef.doc();
    await ref.set({
      'name': name.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
      'archived': false,
    });
    return ref.id;
  }

  Future<void> renamePerson(String personId, String name) =>
      peopleRef.doc(personId).update({'name': name.trim()});

  Future<void> setPersonArchived(String personId, bool archived) =>
      peopleRef.doc(personId).update({'archived': archived});

  /// Links a placeholder to a member. Passing null unlinks it (admins only,
  /// per the security rules).
  Future<void> setPersonClaim(String personId, String? memberUid) =>
      peopleRef.doc(personId).update({
        'claimedBy': memberUid,
        'claimedAt': memberUid == null ? null : FieldValue.serverTimestamp(),
      });

  Future<void> deletePerson(String personId) =>
      peopleRef.doc(personId).delete();

  // ── receipts ──────────────────────────────────────────────────────────────

  /// Uploads a receipt photo for [entryId] and returns its Storage path.
  Future<String> uploadReceipt(String entryId, File file) async {
    final ref = FirebaseStorage.instance.ref().child(
        'groups/$groupId/money_entries/$entryId/${DateTime.now().millisecondsSinceEpoch}.jpg');
    await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
    return ref.fullPath;
  }

  // ── document mapping ──────────────────────────────────────────────────────

  static MoneyEntry entryFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return MoneyEntry(
      id: doc.id,
      type: MoneyEntryType.fromKey(data['type'] as String?),
      description: (data['description'] ?? '').toString(),
      amount: _int(data['amount']),
      currency: (data['currency'] ?? 'EUR').toString(),
      date: _date(data['date']) ?? DateTime.now(),
      category: data['category'] as String?,
      note: data['note'] as String?,
      imagePath: data['image'] as String?,
      paidBy: _intMap(data['paidBy']),
      splitMode: SplitMode.fromKey(data['splitMode'] as String?),
      splitInput: _numMap(data['splitInput']),
      owes: _intMap(data['owes']),
      createdAt: _date(data['createdAt']),
      createdBy: (data['createdBy'] ?? '').toString(),
      updatedAt: _date(data['updatedAt']),
      updatedBy: data['updatedBy'] as String?,
    );
  }

  static MoneyPerson personFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final claimed = data['claimedBy'];
    return MoneyPerson(
      id: doc.id,
      name: (data['name'] ?? '').toString(),
      createdBy: (data['createdBy'] ?? '').toString(),
      claimedBy: claimed is String && claimed.isNotEmpty ? claimed : null,
      claimedAt: _date(data['claimedAt']),
      createdAt: _date(data['createdAt']),
      archived: data['archived'] == true,
    );
  }

  static int _int(Object? value) =>
      value is int ? value : (value is num ? value.round() : 0);

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  static Map<String, int> _intMap(Object? value) {
    if (value is! Map) return const {};
    final out = <String, int>{};
    value.forEach((key, v) {
      if (v is num) out[key.toString()] = v.round();
    });
    return out;
  }

  static Map<String, num> _numMap(Object? value) {
    if (value is! Map) return const {};
    final out = <String, num>{};
    value.forEach((key, v) {
      if (v is num) out[key.toString()] = v;
    });
    return out;
  }
}
