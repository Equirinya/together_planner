/// The user's AI entitlement, derived from their per-user tier plus the group's
/// meal-planner unlock flag. This mirrors the server rules in
/// firebase/functions/src/lib/aiAccess.ts one-to-one; the client uses it purely
/// to decide what UI to show, while the backend re-verifies every call.
///
/// Tiers: 0 basic, 1 smart, 2 higher, 3 unlimited. See the tier table in the
/// AI access design for what each unlocks.
class AiAccess {
  const AiAccess({
    required this.tier,
    this.mealPlannerGroupUnlocked = false,
    this.monthlyUsed = 0,
  });

  /// Locked default used before the user document has loaded.
  static const AiAccess locked = AiAccess(tier: tierBasic);

  static const int tierBasic = 0;
  static const int tierSmart = 1;
  static const int tierHigher = 2;
  static const int tierUnlimited = 3;

  /// Assigned to users whose document has no `aiTier` yet (invite-only phase).
  static const int defaultTier = tierHigher;

  /// Human-readable tier names, indexed by tier value.
  static const List<String> tierNames = ['Basic', 'Smart', 'Plus', 'Unlimited'];

  /// The current tier's display name.
  String get tierName => tierNames[tier];

  /// Monthly generation cap per tier; null means unlimited.
  static const Map<int, int?> _monthlyLimit = {
    tierBasic: 0,
    tierSmart: 5,
    tierHigher: 30,
    tierUnlimited: null,
  };

  final int tier;
  final bool mealPlannerGroupUnlocked;
  final int monthlyUsed;

  /// Builds access from a `users/{uid}` document and the active group's unlock
  /// flag. Usage older than the current calendar month counts as zero.
  factory AiAccess.fromUserData(
    Map<String, dynamic>? data, {
    bool mealPlannerGroupUnlocked = false,
  }) {
    final rawTier = data?['aiTier'];
    var tier = rawTier is num ? rawTier.round() : defaultTier;
    if (tier < tierBasic) tier = tierBasic;
    if (tier > tierUnlimited) tier = tierUnlimited;

    var used = 0;
    final usage = data?['aiUsage'];
    if (usage is Map && usage['month'] == _currentMonth()) {
      final count = usage['count'];
      if (count is num) used = count.toInt();
    }

    return AiAccess(
      tier: tier,
      mealPlannerGroupUnlocked: mealPlannerGroupUnlocked,
      monthlyUsed: used,
    );
  }

  /// Current UTC calendar-month key ("YYYY-MM"), matching the server bucket.
  static String _currentMonth() {
    final now = DateTime.now().toUtc();
    final mm = now.month.toString().padLeft(2, '0');
    return '${now.year}-$mm';
  }

  // ── Capabilities (kept in lockstep with the server predicates) ────────────

  bool get canGenerateRecipes => tier >= tierSmart;
  bool get canUseMealPlanner => tier >= tierSmart || mealPlannerGroupUnlocked;
  bool get mealPlannerAllowsNewRecipes => tier >= tierHigher;
  bool get canUseSearchIdeas => tier >= tierSmart;
  bool get canResolveIngredientsViaLlm => tier >= tierSmart;
  bool get canEnhanceText => tier >= tierSmart;
  bool get canGenerateImage => tier >= tierSmart;
  bool get canEnhanceImage => tier >= tierHigher;

  /// Monthly generation allowance, or null when unlimited.
  int? get monthlyLimit => _monthlyLimit[tier];

  /// Remaining generations this month, or null when unlimited.
  int? get generationsRemaining {
    final limit = monthlyLimit;
    if (limit == null) return null;
    final left = limit - monthlyUsed;
    return left < 0 ? 0 : left;
  }

  /// Whether the user still has generation quota (always true when unlimited).
  bool get hasGenerationQuota {
    final remaining = generationsRemaining;
    return remaining == null || remaining > 0;
  }

  /// Copy with an updated group unlock flag (tier/usage come from the user doc).
  AiAccess withGroupUnlock(bool unlocked) => AiAccess(
        tier: tier,
        mealPlannerGroupUnlocked: unlocked,
        monthlyUsed: monthlyUsed,
      );

  @override
  bool operator ==(Object other) =>
      other is AiAccess &&
      other.tier == tier &&
      other.mealPlannerGroupUnlocked == mealPlannerGroupUnlocked &&
      other.monthlyUsed == monthlyUsed;

  @override
  int get hashCode => Object.hash(tier, mealPlannerGroupUnlocked, monthlyUsed);
}
