import 'package:shared_preferences/shared_preferences.dart';

/// Tracks how often the user shares individual recipes so we can, once they
/// share several in quick succession, educate them that a recipe viewer can be
/// invited to the whole group instead of sharing recipes one by one. Once that
/// hint has been dismissed it stays hidden for a long cooldown.
class RecipeShareEducation {
  RecipeShareEducation._();

  static const _timesKey = 'recipe_share_times';
  static const _dismissedKey = 'recipe_share_edu_dismissed_at';

  /// Shares counted within this window are treated as "in quick succession".
  static const _window = Duration(minutes: 15);

  /// Number of shares within [_window] that triggers the hint.
  static const _threshold = 3;

  /// How long the hint stays hidden after being dismissed.
  static const _cooldown = Duration(days: 60);

  /// Records that a recipe was just shared and returns whether the recipe-viewer
  /// education hint should be shown now.
  static Future<bool> recordShareAndShouldEducate() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    final dismissedAt = prefs.getInt(_dismissedKey);
    if (dismissedAt != null && now - dismissedAt < _cooldown.inMilliseconds) {
      return false;
    }

    final windowStart = now - _window.inMilliseconds;
    final recent = (prefs.getStringList(_timesKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .where((t) => t >= windowStart)
        .toList()
      ..add(now);
    await prefs.setStringList(_timesKey, recent.map((t) => t.toString()).toList());

    return recent.length >= _threshold;
  }

  /// Remembers that the hint was dismissed so it stays hidden for [_cooldown].
  static Future<void> markDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dismissedKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.remove(_timesKey);
  }
}
