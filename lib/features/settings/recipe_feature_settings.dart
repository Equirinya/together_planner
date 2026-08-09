import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local on/off switches for recipe features that are **not** AI-powered, and
/// so don't belong in [AiFeatureSettings] despite the identical shape.
///
/// Mirrors that class's load-before-runApp pattern so the first frame already
/// reflects the stored choice, and its static-singleton shape so any widget can
/// read or listen without a provider.
class RecipeFeatureSettings {
  RecipeFeatureSettings._();

  static const _kSwipeToPlanKey = 'swipe_to_plan_enabled';

  /// Whether the *Swipe to Plan* entry point is offered at all.
  ///
  /// Only hides the way to **start** a vote. A session someone else already
  /// started, that this user is a participant in, still shows its tile — the
  /// switch is a preference about clutter, not a way to silently drop out of a
  /// group decision other people are waiting on. See `_showSwipeTile` in
  /// recipe_page.dart.
  static final ValueNotifier<bool> swipeToPlanEnabled = ValueNotifier<bool>(true);

  /// Loads the stored values and publishes them. Call before runApp so the
  /// first frame already reflects the stored choice.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    swipeToPlanEnabled.value = prefs.getBool(_kSwipeToPlanKey) ?? true;
  }

  static Future<void> setSwipeToPlanEnabled(bool value) async {
    swipeToPlanEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSwipeToPlanKey, value);
  }
}
