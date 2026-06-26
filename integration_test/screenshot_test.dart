import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:couple_planner/main.dart' as app;
import 'package:couple_planner/pages/recipe_page.dart' show RecipeCard;

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
    if (find.text('Add to shopping list').evaluate().isNotEmpty) {
      await binding.takeScreenshot('${_label}_add_to_plan_dialog');
      await tester.tap(find.widgetWithText(TextButton, 'Skip'));
      await _wait(tester, const Duration(seconds: 1));
    }

    // Remove the just-added plan by dragging its card onto the delete zone.
    final size = tester.getSize(find.byType(MaterialApp).first);
    final planCard = find.descendant(of: find.byType(CarouselView), matching: find.byType(RecipeCard)).first;
    if (planCard.evaluate().isNotEmpty) {
      await _longPressDragTo(tester, planCard, Offset(size.width / 2, size.height - 48));
      await _wait(tester, const Duration(seconds: 2));
    }

    // More tab → group overview.
    await tester.tap(find.byIcon(Icons.menu).last);
    await _wait(tester, const Duration(seconds: 2));
    await binding.takeScreenshot('${_label}_more');

    // Group settings for the active group.
    if (find.byIcon(Icons.settings_outlined).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await _wait(tester, const Duration(seconds: 3));
      await binding.takeScreenshot('${_label}_group_settings');
      await tester.pageBack();
      await _wait(tester, const Duration(seconds: 2));
    }

    // New group page (only opened for the screenshot — no group is created).
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New group'));
    await _wait(tester, const Duration(seconds: 3));
    await binding.takeScreenshot('${_label}_new_group');
  });
}

/// Launches the app and signs in. On the [first] launch the app starts signed
/// out and shows the onboarding showcase (captured here as the start screen);
/// a restart re-attaches a fresh app whose persisted session skips straight to
/// the home screen, re-attempting any images that failed to download.
Future<void> _launch(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required bool first,
}) async {
  if (first) {
    app.main();
  } else {
    runApp(const app.MyApp());
  }

  // The iPad screenshots are taken in landscape.
  if (_label == 'ipad') {
    await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
  }

  // The onboarding background animates continuously, so pumpAndSettle would
  // never return — drive the test with fixed waits instead.
  await _wait(tester, const Duration(seconds: 10));

  // A signed-out launch shows the onboarding showcase: capture the start page,
  // then open the login form and sign in. After a restart the persisted session
  // is already on the home screen, so this is skipped.
  if (find.text('I already have an account').evaluate().isNotEmpty) {
    await binding.takeScreenshot('${_label}_welcome');

    await tester.tap(find.text('I already have an account'));
    await _wait(tester, const Duration(seconds: 1));

    // Email + password, then submit.
    await tester.enterText(find.byType(TextField).at(0), _email);
    await tester.enterText(find.byType(TextField).at(1), _password);
    await _wait(tester, const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
  }

  // Wait for sign-in and the group (and its pages) to load from Firestore.
  await _wait(tester, const Duration(seconds: 5));
}

/// Whether every recipe image in the grid has finished loading. A downloading
/// image shows an [Icons.image] placeholder and a failed one [Icons.broken_image];
/// recipes without a photo show [Icons.restaurant_menu] and count as settled.
bool _recipeImagesSettled() {
  final grid = find.byType(GridView);
  if (grid.evaluate().isEmpty) return false;
  final loading = find.descendant(of: grid, matching: find.byIcon(Icons.image));
  final broken = find.descendant(of: grid, matching: find.byIcon(Icons.broken_image));
  return loading.evaluate().isEmpty && broken.evaluate().isEmpty;
}

/// Long-presses [from] and drags it to [to], gliding in steps so the drag
/// targets register the hover before the drop.
Future<void> _longPressDragTo(WidgetTester tester, Finder from, Offset to) async {
  final start = tester.getCenter(from);
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 700)); // trigger the long-press
  for (var i = 1; i <= 6; i++) {
    await gesture.moveTo(Offset.lerp(start, to, i / 6)!);
    await tester.pump(const Duration(milliseconds: 60));
  }
  await gesture.up();
  await tester.pump();
}

/// Pumps repeatedly for [total] without requiring the widget tree to settle.
Future<void> _wait(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 200);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}
