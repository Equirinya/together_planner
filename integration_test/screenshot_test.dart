import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
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

/// Held at library level so the wait helpers can capture a diagnostic
/// screenshot when the app isn't where the test expects it to be.
late final IntegrationTestWidgetsFlutterBinding _binding;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  _binding = binding;

  testWidgets('log in and capture app screenshots', (tester) async {
    // Launch, log in and open the recipe grid, restarting the app if some recipe
    // image hasn't loaded yet so the failed ones get a second try.
    for (var attempt = 1; attempt <= _maxLaunchAttempts; attempt++) {
      await _launch(tester, binding, first: attempt == 1);

      // The nav bar is built from the group's `enabledFeatures`, so which tabs
      // exist depends on the tester account's group document.
      debugPrint('Navigation destinations: ${_navIcons()}');

      // Shopping list tab (NavigationBar hides labels, so match by icon).
      // Wait long enough for the category icons (loaded from Storage) to arrive.
      if (await _tapNav(tester, Icons.shopping_bag, 'shopping list tab')) {
        await _wait(tester, const Duration(seconds: 12));
        await _screenshot('${_label}_shopping_list');
      }

      // Recipes tab. Wait long so every recipe image finishes downloading.
      if (!await _tapNav(tester, Icons.restaurant_menu, 'recipes tab')) {
        fail('The recipes tab is missing from the navigation bar. '
            'Destinations present: ${_navIcons()}. Check `enabledFeatures` on '
            "the tester account's group document.");
      }
      await _wait(tester, const Duration(seconds: 20));

      if (_recipeImagesSettled() || attempt == _maxLaunchAttempts) break;
    }

    await _screenshot('${_label}_recipe');

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
    await _screenshot('${_label}_recipe_detail');

    // Back to the recipe grid.
    await tester.pageBack();
    await _wait(tester, const Duration(seconds: 2));

    // Drag the first recipe onto the calendar to capture the dialog that appears
    // after adding a recipe to a cooking plan, then remove the plan again.
    final firstCard = find.descendant(of: grid, matching: find.byType(RecipeCard)).first;
    await _longPressDragTo(tester, firstCard, tester.getCenter(find.byType(CarouselView)));
    await _wait(tester, const Duration(seconds: 3));
    if (find.text('Add to shopping list').evaluate().isNotEmpty) {
      await _screenshot('${_label}_add_to_plan_dialog');
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
      await _screenshot('${_label}_smart_meal_plan');
      await tester.pageBack(); // back to the settings step
      await _wait(tester, const Duration(seconds: 1));
      await tester.pageBack(); // back to the recipe grid
      await _wait(tester, const Duration(seconds: 2));
    }

    // More tab → group overview.
    if (!await _tapNav(tester, Icons.menu, 'more tab')) {
      fail('The "More" tab is missing. Destinations present: ${_navIcons()}.');
    }
    await _wait(tester, const Duration(seconds: 2));
    await _screenshot('${_label}_more');

    // Group settings for the active group.
    if (find.byIcon(Icons.settings_outlined).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await _wait(tester, const Duration(seconds: 3));
      await _screenshot('${_label}_group_settings');
      await tester.pageBack();
      await _wait(tester, const Duration(seconds: 2));
    }

    // Dietary preferences settings screen (opened from the More tab).
    final dietaryTile = find.text('Dietary preferences');
    if (dietaryTile.evaluate().isNotEmpty) {
      await tester.tap(dietaryTile);
      await _wait(tester, const Duration(seconds: 3));
      await _screenshot('${_label}_dietary_preferences');
      await tester.pageBack();
      await _wait(tester, const Duration(seconds: 2));
    }

    // New group page (only opened for the screenshot — no group is created).
    await _tap(tester, find.widgetWithText(FloatingActionButton, 'New group'),
        describe: 'new group button');
    await _wait(tester, const Duration(seconds: 3));
    await _screenshot('${_label}_new_group');
  });
}

/// Takes a screenshot, handling the Android-only surface conversion that
/// [IntegrationTestWidgetsFlutterBinding.takeScreenshot] requires. The
/// conversion is done once, lazily, and is a no-op on iOS.
bool _surfaceConverted = false;
Future<void> _screenshot(String name) async {
  if (!_surfaceConverted && !kIsWeb && Platform.isAndroid) {
    await _binding.convertFlutterSurfaceToImage();
    _surfaceConverted = true;
  }
  await _binding.takeScreenshot(name);
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
    await _screenshot('${_label}_welcome');

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
  // NavigationBar only renders while `_groupDocReady` is true, and that can flip
  // back to false shortly after the first frame (the group-doc snapshot and the
  // memberships query race on a cold start). So require the bar to stay put for
  // a few seconds rather than accepting the first frame it appears in.
  await _waitForStable(tester, navBar, const Duration(seconds: 90),
      stableFor: const Duration(seconds: 3),
      describe: 'home screen navigation bar');
}

/// Waits until [finder] has matched continuously for [stableFor], so a widget
/// that appears and is then torn down again doesn't count as ready.
Future<void> _waitForStable(
  WidgetTester tester,
  Finder finder,
  Duration timeout, {
  required Duration stableFor,
  required String describe,
}) async {
  const step = Duration(milliseconds: 200);
  var stable = Duration.zero;
  var sawItAtLeastOnce = false;
  var lastLog = Duration.zero;
  for (var elapsed = Duration.zero; elapsed < timeout; elapsed += step) {
    if (finder.evaluate().isNotEmpty) {
      sawItAtLeastOnce = true;
      stable += step;
      if (stable >= stableFor) return;
    } else {
      if (stable > Duration.zero) {
        debugPrint('$describe disappeared after ${stable.inMilliseconds}ms '
            '(at ${elapsed.inSeconds}s). Visible text: ${_visibleText()}');
      }
      stable = Duration.zero;
    }
    // Periodic heartbeat so the CI log shows what the app is sitting on.
    if (elapsed - lastLog >= const Duration(seconds: 10)) {
      lastLog = elapsed;
      debugPrint('[${elapsed.inSeconds}s] waiting for $describe; '
          'visible text: ${_visibleText()}');
    }
    await tester.pump(step);
  }
  debugPrint('$describe was ${sawItAtLeastOnce ? "seen but never stable" : "never seen at all"}.');
  // Capture whatever the app is actually showing before giving up — this lands
  // in the workflow's screenshot artifacts alongside the real ones.
  try {
    await _screenshot('${_label}_FAILURE_${describe.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')}');
  } catch (e) {
    debugPrint('Could not capture failure screenshot: $e');
  }

  fail('Timed out after ${timeout.inSeconds}s waiting for $describe to stay '
      'on screen for ${stableFor.inSeconds}s.\n'
      'Visible text at timeout: ${_visibleText()}');
}

/// Every piece of text currently on screen. The single most useful thing to see
/// when the app isn't where the test expects: the no-group message, an error
/// banner and the login form all identify themselves here.
List<String> _visibleText() {
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .toList();
  // Long bodies (like the no-group explainer) get truncated so the failure
  // message stays readable in the CI log.
  return texts
      .map((s) => s.length > 80 ? '${s.substring(0, 80)}…' : s)
      .toList();
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

/// Taps the navigation destination carrying [icon], returning false (without
/// failing) when the current group doesn't have that feature enabled.
Future<bool> _tapNav(
  WidgetTester tester,
  IconData icon,
  String describe, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  // The bar can be torn down and rebuilt while the group settles, so wait for
  // it again here instead of assuming it survived since launch. Without this
  // the failure below is ambiguous: a missing bar and a missing destination
  // both report "0 widgets descending from NavigationBar".
  await _waitForStable(tester, find.byType(NavigationBar), timeout,
      stableFor: const Duration(seconds: 2),
      describe: 'navigation bar (before tapping $describe)');

  final finder = find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byIcon(icon),
  );
  if (await _waitForAny(tester, [finder], timeout) < 0) {
    debugPrint('Skipping $describe: no such navigation destination. '
        'Destinations present: ${_navIcons()}');
    return false;
  }
  await tester.tap(finder.first);
  return true;
}

/// The destinations currently shown in the navigation bar, by label, for
/// diagnostics. These come straight from the active group's `enabledFeatures`,
/// so an unexpected list means the app selected a different group than
/// intended (or that group's feature list differs).
List<String> _navIcons() {
  final bar = find.byType(NavigationBar);
  if (bar.evaluate().isEmpty) return const ['<no NavigationBar>'];
  final labels = find
      .descendant(of: bar, matching: find.byType(NavigationDestination))
      .evaluate()
      .map((e) => (e.widget as NavigationDestination).label)
      .toList();
  if (labels.isNotEmpty) return labels;
  // Fall back to raw icon codepoints if the destinations aren't matchable.
  return find
      .descendant(of: bar, matching: find.byType(Icon))
      .evaluate()
      .map((e) => 'U+${(e.widget as Icon).icon?.codePoint.toRadixString(16)}')
      .toList();
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
