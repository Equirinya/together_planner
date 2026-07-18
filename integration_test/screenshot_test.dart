import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:couple_planner/main.dart' as app;
import 'package:couple_planner/features/recipes/widgets/recipe_card.dart' show RecipeCard;

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
      await _tap(tester, find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.shopping_bag),
      ), describe: 'shopping list tab');
      await _wait(tester, const Duration(seconds: 12));
      await binding.takeScreenshot('${_label}_shopping_list');

      // Recipes tab. Wait long so every recipe image finishes downloading.
      await _tap(tester, find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.restaurant_menu),
      ), describe: 'recipes tab');
      await _wait(tester, const Duration(seconds: 20));

      if (_recipeImagesSettled() || attempt == _maxLaunchAttempts) break;
    }

    await binding.takeScreenshot('${_label}_recipe');

    // Open a recipe and capture its detail page. A configured recipe name is
    // searched for and opened; otherwise the first (most recently used) card.
    final grid = find.byType(GridView);
    await _waitFor(tester, find.descendant(of: grid, matching: find.byType(RecipeCard)),
        const Duration(seconds: 30), describe: 'recipe grid');
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

    // Smart Meal Planner: open the auto-plan flow from the carousel's trigger
    // day, generate a proposal and capture the finished plan. The plan is not
    // committed (no "Looks good" tap), so nothing is written to the group.
    final smartPlanner = find.text('Smart Meal\nPlanner');
    if (smartPlanner.evaluate().isNotEmpty) {
      await tester.tap(smartPlanner.first);
      await _wait(tester, const Duration(seconds: 3));
      await tester.tap(find.widgetWithText(FilledButton, 'Generate plan'));
      // Generation calls a cloud function and streams in images, so wait until
      // the finished plan (its confirm button) appears before capturing.
      for (var i = 0; i < 30; i++) {
        if (find.text('Looks good! Add to meal plan').evaluate().isNotEmpty) break;
        await _wait(tester, const Duration(seconds: 2));
      }
      await _wait(tester, const Duration(seconds: 12));
      await binding.takeScreenshot('${_label}_smart_meal_plan');
      await tester.pageBack(); // back to the settings step
      await _wait(tester, const Duration(seconds: 1));
      await tester.pageBack(); // back to the recipe grid
      await _wait(tester, const Duration(seconds: 2));
    }

    // More tab → group overview.
    await _tap(tester, find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(Icons.menu),
    ), describe: 'more tab');
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

    // Dietary preferences settings screen (opened from the More tab).
    final dietaryTile = find.text('Dietary preferences');
    if (dietaryTile.evaluate().isNotEmpty) {
      await tester.tap(dietaryTile);
      await _wait(tester, const Duration(seconds: 3));
      await binding.takeScreenshot('${_label}_dietary_preferences');
      await tester.pageBack();
      await _wait(tester, const Duration(seconds: 2));
    }

    // New group page (only opened for the screenshot — no group is created).
    await _tap(tester, find.widgetWithText(FloatingActionButton, 'New group'),
        describe: 'new group button');
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
  // never return — poll for the widget we expect instead of settling.
  //
  // A signed-out launch shows the onboarding showcase: capture the start page,
  // then open the login form and sign in. After a restart the persisted session
  // goes straight to the home screen, so whichever of the two appears first
  // decides what happens next. A cold start on CI can take a while (Firebase
  // init + the splash), so allow a generous timeout here.
  final welcome = find.text('I already have an account');
  final navBar = find.byType(NavigationBar);
  final ready = await _waitForAny(
    tester,
    [welcome, navBar],
    const Duration(seconds: 90),
  );
  if (ready < 0) {
    fail('App never reached the welcome page or the home screen after launch.');
  }

  if (ready == 0) {
    await binding.takeScreenshot('${_label}_welcome');

    await _tap(tester, welcome, describe: 'welcome page login link');
    await _wait(tester, const Duration(seconds: 1));

    // Email + password, then submit.
    await _waitFor(tester, find.byType(TextField), const Duration(seconds: 20),
        describe: 'login form');
    await tester.enterText(find.byType(TextField).at(0), _email);
    await tester.enterText(find.byType(TextField).at(1), _password);
    await _wait(tester, const Duration(milliseconds: 500));
    await _tap(tester, find.widgetWithText(FilledButton, 'Login'),
        describe: 'login button');
  }

  // Wait for sign-in and the group (and its pages) to load from Firestore. The
  // NavigationBar only renders once the group is ready, so it is the signal
  // that the home screen is actually usable.
  await _waitFor(tester, navBar, const Duration(seconds: 90),
      describe: 'home screen navigation bar');
  await _wait(tester, const Duration(seconds: 3));
}

/// Pumps until [finder] matches at least one widget, or [timeout] elapses.
/// Fails the test with a readable message instead of a bare "No element".
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder,
  Duration timeout, {
  required String describe,
}) async {
  if (await _waitForAny(tester, [finder], timeout) < 0) {
    fail('Timed out after ${timeout.inSeconds}s waiting for $describe '
        '($finder).');
  }
}

/// Pumps until one of [finders] matches and returns its index, or -1 on timeout.
Future<int> _waitForAny(
  WidgetTester tester,
  List<Finder> finders,
  Duration timeout,
) async {
  const step = Duration(milliseconds: 200);
  for (var elapsed = Duration.zero; elapsed < timeout; elapsed += step) {
    for (var i = 0; i < finders.length; i++) {
      if (finders[i].evaluate().isNotEmpty) return i;
    }
    await tester.pump(step);
  }
  return -1;
}

/// Waits for [finder] to appear and taps its first match.
Future<void> _tap(
  WidgetTester tester,
  Finder finder, {
  required String describe,
  Duration timeout = const Duration(seconds: 30),
}) async {
  await _waitFor(tester, finder, timeout, describe: describe);
  await tester.tap(finder.first);
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
