/// A person in the money ledger who has no account yet — a "placeholder".
///
/// Real members are deliberately NOT stored in this collection: the ledger's
/// set of identities is `active member uids` + `placeholder ids`, so there is
/// nothing to keep in sync when somebody joins or leaves.
///
/// When the real person finally joins, the placeholder gets [claimedBy] set to
/// their uid. Expenses keep referencing the placeholder id forever — balances
/// are computed over *resolved* identities (see [MoneyDirectory.resolve]), so
/// claiming is a single-document, idempotent, reversible write with no history
/// rewrite anywhere.
class MoneyPerson {
  const MoneyPerson({
    required this.id,
    required this.name,
    required this.createdBy,
    this.claimedBy,
    this.claimedAt,
    this.createdAt,
    this.archived = false,
  });

  final String id;
  final String name;
  final String createdBy;

  /// uid of the member who claimed this placeholder, or null while unclaimed.
  final String? claimedBy;
  final DateTime? claimedAt;
  final DateTime? createdAt;

  /// Hidden from new-expense pickers; existing history is untouched.
  final bool archived;

  bool get isClaimed => claimedBy != null && claimedBy!.isNotEmpty;
}

/// Resolves ledger person ids to stable identities and to display names.
///
/// Two kinds of id ever appear in an entry's `paidBy` / `owes` maps:
///   * a member uid, or
///   * a placeholder id from `money_people`.
///
/// [resolve] collapses a claimed placeholder onto its claimer's uid. It is
/// always a single hop: the security rules only ever allow `claimedBy` to name
/// an active full member, so a placeholder can never point at another
/// placeholder.
class MoneyDirectory {
  MoneyDirectory({
    required this.myUid,
    required List<String> memberUids,
    required List<MoneyPerson> people,
    required Map<String, String> usernames,
  })  : memberUids = List.unmodifiable(memberUids),
        _usernames = usernames,
        _people = {for (final p in people) p.id: p};

  /// uid of the signed-in user.
  final String myUid;

  /// Active full members of the group.
  final List<String> memberUids;

  final Map<String, MoneyPerson> _people;
  final Map<String, String> _usernames;

  Iterable<MoneyPerson> get people => _people.values;

  MoneyPerson? person(String id) => _people[id];

  /// The identity [personId] belongs to. Claimed placeholders resolve to the
  /// uid that claimed them; everything else resolves to itself.
  String resolve(String personId) {
    final p = _people[personId];
    final claimed = p?.claimedBy;
    return (claimed == null || claimed.isEmpty) ? personId : claimed;
  }

  /// Whether [identity] is somebody who is no longer in the group but still
  /// appears in the ledger (a member who left, or a deleted placeholder).
  bool isFormer(String identity) =>
      !memberUids.contains(identity) && !_people.containsKey(identity);

  /// Display name for a resolved identity or a raw person id.
  String nameFor(String id) {
    if (id == myUid) return 'You';
    final p = _people[id];
    if (p != null) return p.name;
    final u = _usernames[id];
    if (u != null && u.isNotEmpty) return u;
    return 'Someone';
  }

  /// Same as [nameFor] but never returns "You" — for sentences like
  /// "Anna pays Ben".
  String properNameFor(String id) {
    final p = _people[id];
    if (p != null) return p.name;
    final u = _usernames[id];
    if (u != null && u.isNotEmpty) return u;
    return id == myUid ? 'You' : 'Someone';
  }

  /// Everyone who can be put on a new expense: the active members, plus the
  /// placeholders that are neither archived nor already claimed (a claimed
  /// placeholder is represented by the member who claimed it).
  List<String> get selectable {
    final out = <String>[...memberUids];
    final ghosts = _people.values
        .where((p) => !p.archived && !p.isClaimed)
        .map((p) => p.id)
        .toList()
      ..sort((a, b) => nameFor(a).toLowerCase().compareTo(nameFor(b).toLowerCase()));
    out.addAll(ghosts);
    return out;
  }

  /// Placeholders a newly joined member could plausibly be.
  List<MoneyPerson> get claimable =>
      _people.values.where((p) => !p.archived && !p.isClaimed).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}
