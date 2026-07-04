import 'package:flutter/foundation.dart';

/// Incremented whenever something that affects recipe suggestions changes
/// (dietary preferences saved, dismissed suggestions reset). RecipePage
/// listens and reloads its suggested row.
class RecipeSuggestionNotifier {
  RecipeSuggestionNotifier._();
  static final ValueNotifier<int> instance = ValueNotifier<int>(0);
  static void notify() => instance.value++;
}
