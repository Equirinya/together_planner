import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:couple_planner/main.dart' as app;
import 'package:couple_planner/features/recipes/widgets/recipe_card.dart' show RecipeCard;

/// Screenshot test: launch → onboarding → login → every screenshot-worthy page.
///
/// Run locally (device/simulator attached, app must start signed out). Same
/// invocation CI uses in `.github/workflows/screenshots.yml`:
///
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart \
///     --dart-define=TESTER_EMAIL=... \
///     --dart-define=TESTER_PASSWORD=... \
///     --dart-define=DEVICE_LABEL=iphone \
///     -d <device-id>
///
/// Quote the password. Windows shells eat `!`, `^`, `&`, `%` and `$` from an
/// unquoted --dart-define, and the only symptom is a "wrong password" error
/// that looks like a broken account — hence the length check below.
///
/// Which pages exist depends on the tester group's `enabledFeatures`. Anything
/// that isn't reachable is logged and skipped, never fatal — only the login and
/// the recipes tab are treated as required.
const _email = String.fromEnvironment('TESTER_EMAIL');
const _password = String.fromEnvironment('TESTER_PASSWORD');
const _label = String.fromEnvironment('DEVICE_LABEL', defaultValue: 'device');

/// Recipe to open for the detail screenshot. Empty → the first card in the grid
/// (the most recently used recipe).
const _recipeName = String.fromEnvironment('RECIPE_NAME');

/// Set `--dart-define=NO_SCREENSHOTS=true` to run the navigation only. Use this
/// first when debugging a hang: if the flow completes without screenshots, the
/// problem is the screenshot machinery, not the app or the finders.
const _noScreenshots = bool.fromEnvironment('NO_SCREENSHOTS');

late final IntegrationTestWidgetsFlutterBinding _binding;

void main() {
  _binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log in and capture app screenshots', (tester) async {
    expect(_email, isNotEmpty, reason: 'pass TESTER_EMAIL');
    expect(_password, isNotEmpty, reason: 'pass TESTER_PASSWORD');

    // Shells mangle --dart-define values: on Windows `!`, `^`, `&`, `%` and `$`
    // are eaten before Dart sees them, which shows up as a plain "wrong
    // password". Compare this length against the real one before suspecting
    // the account.
    debugPrint('credentials: email="$_email", password length=${_password.length}');

    // ── 0. Android screenshot plumbing ──────────────────────────────────────
    // Android renders into a SurfaceView, which cannot be read back. The
    // binding swaps it for an image-backed view — but this MUST happen before
    // the app renders anything. Calling it later (lazily, at the first
    // screenshot) deadlocks: the conversion waits for a frame while the live
    // SurfaceView is already mid-flight, and the test hangs with the app
    // visibly sitting on screen doing nothing.
    if (!_noScreenshots && !kIsWeb && Platform.isAndroid) {
      _section('converting Flutter surface to image');
      await _binding.convertFlutterSurfaceToImage();
    }

    // ── 1. Launch ───────────────────────────────────────────────────────────
    // main() is async (Firebase init etc.) and is intentionally not awaited —
    // we just start pumping and wait for the first real screen.
    _section('launching app');
    app.main();

    // ── 2. Onboarding showcase ──────────────────────────────────────────────
    // The background animates forever, so pumpAndSettle would never return:
    // poll for the widget instead.
    _section('onboarding showcase');
    final loginLink = find.text('I already have an account');
    await _waitFor(tester, loginLink, describe: 'onboarding showcase');
    // The link exists a frame or two before the page is worth looking at: the
    // native splash may still be over it, and the animated background and the
    // blurred feature pills need a moment to paint. Capturing on the first
    // match yields a loading screen.
    await _pumpFor(tester, const Duration(seconds: 5));
    await _screenshot('${_label}_welcome');

    // ── 3. Login ────────────────────────────────────────────────────────────
    _section('login');
    await tester.tap(loginLink);
    await _pumpFor(tester, const Duration(seconds: 1));

    // AuthForm renders email first, then password.
    await _waitFor(tester, find.byType(TextField), describe: 'login form');
    await tester.enterText(find.byType(TextField).at(0), _email);
    await tester.enterText(find.byType(TextField).at(1), _password);
    await _pumpFor(tester, const Duration(milliseconds: 500));

    // AuthForm renders sign-in failures as plain text, so abort on those
    // instead of burning the full timeout on a login that already failed.
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
    await _waitFor(tester, find.byType(NavigationBar),
        describe: 'home screen navigation bar',
        timeout: const Duration(seconds: 120),
        abortOnText: _authErrors);

    // The bar can flip away again shortly after its first frame: the group-doc
    // snapshot and the memberships query race on a cold start. Require it to
    // stay put before trusting it.
    await _waitForStable(tester, find.byType(NavigationBar),
        describe: 'home screen navigation bar');
    debugPrint('navigation destinations: ${_navLabels()}');

    // ── 4. Shopping list ────────────────────────────────────────────────────
    // NavigationBar hides labels, so destinations are matched by icon.
    _section('shopping list');
    if (await _tapNav(tester, Icons.shopping_bag, 'shopping list tab')) {
      // Category icons come from Storage; give them time to arrive.
      await _pumpFor(tester, const Duration(seconds: 12));
      await _screenshot('${_label}_shopping_list');
    }

    // ── 5. Recipes grid ─────────────────────────────────────────────────────
    _section('recipes grid');
    if (!await _tapNav(tester, Icons.restaurant_menu, 'recipes tab')) {
      fail('The recipes tab is missing from the navigation bar. Destinations '
          'present: ${_navLabels()}. Check `enabledFeatures` on the tester '
          "account's group document.");
    }
    // The recipe page is a CustomScrollView, so the grid is a SliverGrid —
    // there is no GridView anywhere on this page. Scoping to it keeps the
    // calendar carousel's plan cards (also RecipeCards) out of the matches.
    final grid = find.byType(SliverGrid);
    await _waitFor(tester, find.descendant(of: grid, matching: find.byType(RecipeCard)),
        describe: 'recipe grid', timeout: const Duration(seconds: 60));
    await _waitForRecipeImages(tester);
    await _screenshot('${_label}_recipe');

    // ── 6. Recipe detail ────────────────────────────────────────────────────
    _section('recipe detail');
    if (_recipeName.isNotEmpty) {
      await tester.enterText(
        find.descendant(of: find.byType(SearchBar), matching: find.byType(EditableText)),
        _recipeName,
      );
      await _pumpFor(tester, const Duration(seconds: 1));
      await tester.tap(find.descendant(of: grid, matching: find.text(_recipeName)).first);
    } else {
      await tester.tap(find.descendant(of: grid, matching: find.byType(RecipeCard)).first);
    }
    await _pumpFor(tester, const Duration(seconds: 4));
    await _screenshot('${_label}_recipe_detail');

    await tester.pageBack();
    await _pumpFor(tester, const Duration(seconds: 2));

    // ── 7. Add to cooking plan ──────────────────────────────────────────────
    // Drag the first recipe onto the calendar carousel to capture the dialog
    // that follows, then drag the new plan onto the delete zone to undo it.
    _section('add to plan');
    final carousel = find.byType(CarouselView);
    if (carousel.evaluate().isEmpty) {
      debugPrint('skipping: no calendar carousel on the recipe page.');
    } else {
      final firstCard = find.descendant(of: grid, matching: find.byType(RecipeCard)).first;
      await _longPressDragTo(tester, firstCard, tester.getCenter(carousel));
      await _pumpFor(tester, const Duration(seconds: 3));

      if (find.text('Add to shopping list').evaluate().isEmpty) {
        debugPrint('skipping: the add-to-plan dialog did not appear.');
      } else {
        await _screenshot('${_label}_add_to_plan_dialog');
        await _tapIfPresent(tester, find.widgetWithText(TextButton, 'Skip'),
            describe: 'dialog Skip button');
        await _pumpFor(tester, const Duration(seconds: 1));

        // Undo: drag the plan card onto the delete zone at the bottom.
        final size = tester.getSize(find.byType(MaterialApp).first);
        final planCard =
            find.descendant(of: carousel, matching: find.byType(RecipeCard));
        if (planCard.evaluate().isNotEmpty) {
          await _longPressDragTo(
              tester, planCard.first, Offset(size.width / 2, size.height - 48));
          await _pumpFor(tester, const Duration(seconds: 2));
        } else {
          debugPrint('note: no plan card to remove — nothing was written.');
        }
      }
    }

    // ── 8. Smart Meal Planner ───────────────────────────────────────────────
    // Generates a proposal and captures the finished plan. Deliberately does
    // NOT tap "Looks good", so nothing is committed to the group.
    _section('smart meal planner');
    final smartPlanner = find.text('Smart Meal\nPlanner');
    if (smartPlanner.evaluate().isEmpty) {
      debugPrint('skipping: Smart Meal Planner entry point not shown '
          '(AI features may be off for this group).');
    } else {
      await tester.tap(smartPlanner.first);
      await _pumpFor(tester, const Duration(seconds: 3));
      await _tapIfPresent(tester, find.widgetWithText(FilledButton, 'Generate plan'),
          describe: 'Generate plan button');

      // Generation calls a cloud function and streams images in afterwards.
      final done = find.text('Looks good! Add to meal plan');
      await _waitFor(tester, done,
          describe: 'generated meal plan', timeout: const Duration(seconds: 120));
      await _pumpFor(tester, const Duration(seconds: 12)); // let images land
      await _screenshot('${_label}_smart_meal_plan');

      await tester.pageBack(); // → settings step
      await _pumpFor(tester, const Duration(seconds: 1));
      await tester.pageBack(); // → recipe grid
      await _pumpFor(tester, const Duration(seconds: 2));
    }

    // ── 9. More tab ─────────────────────────────────────────────────────────
    _section('more tab');
    if (!await _tapNav(tester, Icons.menu, 'more tab')) {
      debugPrint('skipping the rest: no More tab. '
          'Destinations present: ${_navLabels()}');
      return;
    }
    await _pumpFor(tester, const Duration(seconds: 2));
    await _screenshot('${_label}_more');

    // ── 10. Group settings ──────────────────────────────────────────────────
    _section('group settings');
    if (await _tapIfPresent(tester, find.byIcon(Icons.settings_outlined),
        describe: 'group settings button')) {
      await _pumpFor(tester, const Duration(seconds: 3));
      await _screenshot('${_label}_group_settings');
      await tester.pageBack();
      await _pumpFor(tester, const Duration(seconds: 2));
    }

    // ── 11. Dietary preferences ─────────────────────────────────────────────
    _section('dietary preferences');
    if (await _tapIfPresent(tester, find.text('Dietary preferences'),
        describe: 'dietary preferences tile')) {
      await _pumpFor(tester, const Duration(seconds: 3));
      await _screenshot('${_label}_dietary_preferences');
      await tester.pageBack();
      await _pumpFor(tester, const Duration(seconds: 2));
    }

    // ── 12. New group page ──────────────────────────────────────────────────
    // Opened for the screenshot only — no group is created.
    _section('new group');
    if (await _tapIfPresent(tester,
        find.widgetWithText(FloatingActionButton, 'New group'),
        describe: 'New group button')) {
      await _pumpFor(tester, const Duration(seconds: 3));
      await _screenshot('${_label}_new_group');
    }

    _section('done');
  });
}

/// Full-screen routes the app pushes over the home screen on a fresh install,
/// identified by their AppBar title.
///
/// These are opaque routes, so while one is up the Overlay stops building
/// everything below it — `find.byType(NavigationBar)` genuinely matches
/// nothing, which is why the waits below dismiss them instead of just
/// out-waiting them.
///
/// Dismissed with a back navigation, never by tapping their call-to-action:
/// "Yes, keep me in the loop!" fires a real OS permission dialog, which is a
/// native window the test framework cannot see or answer.
const _interstitialTitles = <String>[
  'Stay in the loop', // NotificationInfoPage — notification priming
];

/// Pops the first interstitial currently on screen. Returns whether one was
/// dismissed.
Future<bool> _dismissInterstitials(WidgetTester tester) async {
  for (final title in _interstitialTitles) {
    if (find.text(title).evaluate().isEmpty) continue;
    debugPrint('dismissing interstitial: "$title".');
    await tester.pageBack();
    await _pumpFor(tester, const Duration(seconds: 2));
    return true;
  }
  return false;
}

/// Sign-in failures rendered by AuthForm. Waiting for the home screen aborts on
/// any of these rather than burning the whole timeout.
const _authErrors = [
  'Wrong email address or password.',
  'No account found with this email address.',
  'Invalid email address.',
  'This account has been disabled.',
  'Too many attempts. Please try again later.',
  "You're not connected to the internet.",
  'Sign-in failed. Please try again.',
];

// ───────────────────────────────────────────────────────────────────────────
// Timing helpers
//
// IMPORTANT: the integration_test binding runs on the real clock, but
// `tester.pump(d)` does NOT wait `d` — it just draws one frame. Summing pump
// durations therefore measures nothing: a "20 second" loop of pumps finishes in
// about a second and a half. Every wait below is driven by a Stopwatch, i.e.
// real wall-clock time, which is what Firebase, network calls, image downloads
// and long-press recognisers all need.
// ───────────────────────────────────────────────────────────────────────────

/// Pumps frames for [total] of real time.
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < total) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps until [finder] matches, or fails after [timeout] of real time with a
/// dump of what is actually on screen.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String describe,
  Duration timeout = const Duration(seconds: 90),
  List<String> abortOnText = const [],
}) async {
  final sw = Stopwatch()..start();
  var lastLog = Duration.zero;
  var lastSweep = Duration.zero;
  while (sw.elapsed < timeout) {
    if (finder.evaluate().isNotEmpty) return;
    for (final message in abortOnText) {
      if (find.text(message).evaluate().isNotEmpty) {
        await _screenshotOrLog('${_label}_FAILURE');
        fail('Gave up waiting for $describe: the app is showing "$message".');
      }
    }
    // Cheap enough at twice a second; a full-tree text search every frame is
    // not worth it.
    if (sw.elapsed - lastSweep >= const Duration(milliseconds: 500)) {
      lastSweep = sw.elapsed;
      await _dismissInterstitials(tester);
    }
    if (sw.elapsed - lastLog >= const Duration(seconds: 5)) {
      lastLog = sw.elapsed;
      debugPrint('[${sw.elapsed.inSeconds}s] waiting for $describe; '
          'on screen: ${_visibleText()}');
    }
    await tester.pump(const Duration(milliseconds: 16));
  }

  await _screenshotOrLog('${_label}_FAILURE');
  fail('Timed out after ${timeout.inSeconds}s waiting for $describe.\n'
      'On screen: ${_visibleText()}');
}

/// Waits until [finder] has matched continuously for [stableFor], so a widget
/// that appears and is torn down again doesn't count as ready.
Future<void> _waitForStable(
  WidgetTester tester,
  Finder finder, {
  required String describe,
  Duration timeout = const Duration(seconds: 90),
  Duration stableFor = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  Stopwatch? stable;
  var lastSweep = Duration.zero;
  while (sw.elapsed < timeout) {
    if (finder.evaluate().isNotEmpty) {
      stable ??= Stopwatch()..start();
      if (stable.elapsed >= stableFor) return;
    } else {
      if (stable != null) {
        debugPrint('$describe disappeared again after '
            '${stable.elapsedMilliseconds}ms (at ${sw.elapsed.inSeconds}s).');
      }
      stable = null;
      // The usual reason it vanished: an interstitial was pushed over it.
      if (sw.elapsed - lastSweep >= const Duration(milliseconds: 500)) {
        lastSweep = sw.elapsed;
        await _dismissInterstitials(tester);
      }
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  await _screenshotOrLog('${_label}_FAILURE');
  fail('Timed out after ${timeout.inSeconds}s waiting for $describe to stay on '
      'screen for ${stableFor.inSeconds}s.\nOn screen: ${_visibleText()}');
}

/// Waits until every recipe image in the grid has loaded, or gives up quietly.
/// A downloading image shows an [Icons.image] placeholder and a failed one
/// [Icons.broken_image]; recipes without a photo show [Icons.restaurant_menu]
/// and count as settled.
Future<void> _waitForRecipeImages(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final grid = find.byType(SliverGrid);
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final loading = find.descendant(of: grid, matching: find.byIcon(Icons.image));
    final broken = find.descendant(of: grid, matching: find.byIcon(Icons.broken_image));
    if (loading.evaluate().isEmpty && broken.evaluate().isEmpty) {
      debugPrint('recipe images settled after ${sw.elapsed.inSeconds}s.');
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  debugPrint('note: some recipe images were still loading or broken after '
      '${timeout.inSeconds}s; capturing anyway.');
}

// ───────────────────────────────────────────────────────────────────────────
// Interaction helpers
// ───────────────────────────────────────────────────────────────────────────

/// Taps the navigation destination carrying [icon]. Returns false (without
/// failing) when the current group doesn't have that feature enabled.
Future<bool> _tapNav(WidgetTester tester, IconData icon, String describe) async {
  // The bar can be torn down and rebuilt while the group settles, so wait for
  // it again rather than assuming it survived. Without this, a missing bar and
  // a missing destination produce the same ambiguous "0 widgets" error.
  await _waitForStable(tester, find.byType(NavigationBar),
      describe: 'navigation bar (before tapping $describe)',
      stableFor: const Duration(seconds: 2));

  final finder = find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byIcon(icon),
  );
  if (finder.evaluate().isEmpty) {
    debugPrint('skipping $describe: no such destination. '
        'Destinations present: ${_navLabels()}');
    return false;
  }
  await tester.tap(finder.first);
  await _pumpFor(tester, const Duration(milliseconds: 500));
  return true;
}

/// Taps [finder] if it is on screen; logs and returns false if it isn't.
Future<bool> _tapIfPresent(
  WidgetTester tester,
  Finder finder, {
  required String describe,
}) async {
  if (finder.evaluate().isEmpty) {
    debugPrint('skipping: $describe is not on screen.');
    return false;
  }
  await tester.tap(finder.first);
  await _pumpFor(tester, const Duration(milliseconds: 300));
  return true;
}

/// Long-presses [from] and drags it to [to], gliding in steps so drag targets
/// register the hover before the drop.
///
/// The hold uses real time on purpose: [LongPressGestureRecognizer] arms a real
/// timer, and `tester.pump(700ms)` would not advance it — the press would be
/// released before the long-press ever fired.
Future<void> _longPressDragTo(WidgetTester tester, Finder from, Offset to) async {
  final start = tester.getCenter(from);
  final gesture = await tester.startGesture(start);
  await _pumpFor(tester, const Duration(milliseconds: 800));
  for (var i = 1; i <= 6; i++) {
    await gesture.moveTo(Offset.lerp(start, to, i / 6)!);
    await _pumpFor(tester, const Duration(milliseconds: 80));
  }
  await gesture.up();
  await _pumpFor(tester, const Duration(milliseconds: 300));
}

// ───────────────────────────────────────────────────────────────────────────
// Diagnostics
// ───────────────────────────────────────────────────────────────────────────

void _section(String name) => debugPrint('══ $name ══');

/// Every string currently rendered — the fastest way to see where the app
/// actually is when it isn't where the test expects.
List<String> _visibleText() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .whereType<String>()
    .where((s) => s.trim().isNotEmpty)
    .map((s) => s.length > 60 ? '${s.substring(0, 60)}…' : s)
    .toList();

/// The destinations currently in the navigation bar. These come straight from
/// the active group's `enabledFeatures`, so an unexpected list means the app
/// selected a different group than intended.
List<String> _navLabels() {
  final bar = find.byType(NavigationBar);
  if (bar.evaluate().isEmpty) return const ['<no NavigationBar>'];
  final labels = find
      .descendant(of: bar, matching: find.byType(NavigationDestination))
      .evaluate()
      .map((e) => (e.widget as NavigationDestination).label)
      .toList();
  if (labels.isNotEmpty) return labels;
  return find
      .descendant(of: bar, matching: find.byType(Icon))
      .evaluate()
      .map((e) => 'U+${(e.widget as Icon).icon?.codePoint.toRadixString(16)}')
      .toList();
}

// ───────────────────────────────────────────────────────────────────────────
// Screenshots
// ───────────────────────────────────────────────────────────────────────────

/// Captures [name]. The surface conversion Android needs already happened at
/// the top of the test — do not move it in here.
///
/// Guarded by a timeout so a stuck capture fails the run with a readable error
/// instead of stalling until the job is killed.
Future<void> _screenshot(String name) async {
  if (_noScreenshots) {
    debugPrint('(screenshot skipped: $name)');
    return;
  }
  debugPrint('capturing $name…');
  await _binding.takeScreenshot(name).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw StateError('takeScreenshot("$name") hung.'),
      );
  debugPrint('captured $name.');
}

/// Best-effort capture on the failure path — a broken screenshot must not mask
/// the real error.
Future<void> _screenshotOrLog(String name) async {
  try {
    await _screenshot(name);
  } catch (e) {
    debugPrint('Could not capture failure screenshot: $e');
  }
}
