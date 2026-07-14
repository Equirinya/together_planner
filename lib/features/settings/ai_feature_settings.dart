import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local on/off switches for AI-powered features, independent of the
/// server-side [AiAccess] entitlement (plan/quota gating) — these are plain
/// user preferences to turn a feature off even when the user's plan would
/// otherwise allow it. Mirrors [LanguageService]'s load-before-runApp
/// pattern so the first frame already reflects the stored choice, and
/// [RecipeSuggestionNotifier]'s static-singleton shape so any widget can
/// read or listen without a provider.
class AiFeatureSettings {
  AiFeatureSettings._();

  static const _kMealPlannerKey = 'ai_meal_planner_enabled';
  static const _kSearchIdeasKey = 'ai_search_ideas_enabled';
  static const _kGenerationKey = 'ai_generation_enabled';

  /// Whether the Smart Meal Planner entry points (carousel trigger, empty-
  /// state hint) are shown at all.
  static final ValueNotifier<bool> mealPlannerEnabled = ValueNotifier<bool>(true);

  /// Whether AI name/url idea tiles may show up while searching recipes.
  static final ValueNotifier<bool> searchIdeasEnabled = ValueNotifier<bool>(true);

  /// Whether the various "generate/enhance with AI" buttons (meal-plan
  /// regenerate, recipe image/ingredients/steps generation) are shown.
  static final ValueNotifier<bool> generationEnabled = ValueNotifier<bool>(true);

  /// Loads the stored values and publishes them. Call before runApp so the
  /// first frame already reflects the stored choice.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mealPlannerEnabled.value = prefs.getBool(_kMealPlannerKey) ?? true;
    searchIdeasEnabled.value = prefs.getBool(_kSearchIdeasKey) ?? true;
    generationEnabled.value = prefs.getBool(_kGenerationKey) ?? true;
  }

  static Future<void> setMealPlannerEnabled(bool value) async {
    mealPlannerEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMealPlannerKey, value);
  }

  static Future<void> setSearchIdeasEnabled(bool value) async {
    searchIdeasEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSearchIdeasKey, value);
  }

  static Future<void> setGenerationEnabled(bool value) async {
    generationEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGenerationKey, value);
  }
}
