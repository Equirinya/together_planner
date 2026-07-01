import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:couple_planner/main.dart' as app;
import 'package:couple_planner/features/recipes/pages/recipe_page.dart' show RecipeCard;

// Tester credentials and the device label are injected via --dart-define from
// the workflow (TESTER_EMAIL / TESTER_PASSWORD / DEVICE_LABEL).
const _email = String.fromEnvironment('TESTER_EMAIL');
const _password = String.fromEnvironment('TESTER_PASSWORD');
const _label = String.fromEnvironment('DEVICE_LABEL', defaultValue: 'device');

// Recipe to open for the detail screenshot. When empty the most recently used
// recipe (the first card in the grid) is used instead.
const _recipeName = String.fromEnvironment('RECIPE_NAME');

// How many times to (re)launch the app while waiting for every recipe image to
// finish downloading. A single image occasionally fails on first load, so the
// app is restarted to give the missing ones another try.
const _maxLaunchAttempts = 3;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log in and capture app screenshots', (tester) async {
    // Launch, log in and open the recipe grid, restarting the app if some recipe
    // image hasn't loaded yet so the failed ones get a second try.
    for (var attempt = 1; attempt <= _maxLaunchAttempts; attempt++) {
      await _launch(tester, binding, first: attempt == 1);

      // Shopping list tab (NavigationBar hides labels, so match by icon).
      // Wait long enough for the category icons (loaded from Storage) to arrive.
      await tester.tap(find.byIcon(Icons.shopping_bag).last);
      await _wait(tester, const Duration(seconds: 12));
      await binding.takeScreenshot('${_label}_shopping_list');

      // Recipes tab. Wait long so every recipe image finishes downloading.
      await tester.tap(find.byIcon(Icons.restaurant_menu).last);
      await _wait(tester, const Duration(seconds: 20));

      if (_recipeImagesSettled() || attempt == _maxLaunchAttempts) break;
    }

    await binding.takeScreenshot('${_label}_recipe');

    // Open a recipe and capture its detail page. A configured recipe name is
    // searched for and opened; otherwise the first (most recently used) card.
    final grid = find.byType(GridView);
    if (_recipeName.isNotEmpty) {
      await tester.enterText(
        find.descendant(of: find.byType(SearchBar), matching: find.byType(EditableText)),
        _recipeName,
      );
      await _wait(tester, const Duration(seconds: 1));
      await tester.tap(find.descendant(of: grid, matching: find.text(_recipeName)).first);
    } else {
      await tester.tap(find.descendant(of: grid, matching: find.byType(RecipeCard)).first);
    }
    await _wait(tester, const Duration(seconds: 4));
    await binding.takeScreenshot('${_label}_recipe_detail');

    // Back to the recipe grid.
    await tester.pageBack();
    await _wait(tester, const Duration(seconds: 2));

    // Drag the first recipe onto the calendar to capture the dialog that appears
    // after adding a recipe to a cooking plan, then remove the plan again.
    final firstCard = find.descendant(of: grid, matching: find.byType(RecipeCard)).first;
    await _longPressDragTo(tester, firstCard, tester.getCenter(find.byType(CarouselView)));
    await _wait(tester, const Duration(seconds: 3));
    if (find