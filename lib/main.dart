import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:couple_planner/features/recipes/pages/recipe_page.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:system_theme/system_theme.dart';
import 'package:couple_planner/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'package:app_links/app_links.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:quick_actions/quick_actions.dart';

import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/groups/invite_links.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart';
import 'package:couple_planner/features/shopping_list/pages/shopping_list_page.dart';
import 'package:couple_planner/features/groups/pages/join_group_page.dart';
import 'package:couple_planner/features/groups/pages/group_overview_page.dart';
import 'package:couple_planner/features/groups/pages/create_group_page.dart';
import 'package:couple_planner/features/settings/pages/settings_page.dart';
import 'package:couple_planner/features/settings/pages/profile_page.dart';
import 'package:couple_planner/features/settings/pages/notification_info_page.dart';
import 'package:couple_planner/features/settings/notification_feature_settings.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/restart_widget.dart';
import 'package:couple_planner/features/settings/ai_feature_settings.dart';
import 'package:couple_planner/features/auth/pages/login_page.dart' show animatedBackground;
import 'package:couple_planner/features/ai/ai_access.dart';

// ---------------------------------------------------------------------------
// Feature registry
// ---------------------------------------------------------------------------

/// All features the app knows about, in canonical display order.
/// The group document may reorder / subset this list via `enabledFeatures`.
const _allFeatures = ['shopping_list', 'recipes', 'todos', 'calendar', 'money'];

/// Default set shown when a group document has no `enabledFeatures` field.
const _defaultEnabledFeatures = ['shopping_list', 'recipes'];

const _featureMeta = <String, ({IconData icon, String label})>{
  'shopping_list': (icon: Icons.shopping_bag, label: 'Shopping List'),
  'recipes': (icon: Icons.restaurant_menu, label: 'Recipes'),
  'todos': (icon: Icons.checklist, label: 'To-Do\'s'),
  'calendar': (icon: Icons.calendar_month, label: 'Calendar'),
  'money': (icon: Icons.account_balance_wallet, label: 'Money splitting'),
};

// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemTheme.fallbackColor = const Color(0xFF2E7D5B);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);
  await LanguageService.instance.load();
  await AiFeatureSettings.load();
  await NotificationFeatureSettings.load();
  runApp(const RestartWidget(child: MyApp()));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    SystemTheme.accentColor.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(SystemTheme.accentColor.accent, Brightness.light),
      darkTheme: _buildTheme(SystemTheme.accentColor.dark, Brightness.dark),
      home: const HomePage(),
    );
  }
}

/// Expressive Material You theme: green-seeded tonal palette with soft, rounded
/// surfaces. Pages keep using default widgets, so the feel is set here once.
ThemeData _buildTheme(Color seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  // Light mode reads brightest on the top surface tone; dark keeps the dim one.
  final Color background =
      brightness == Brightness.dark ? scheme.surfaceDim : scheme.surfaceBright;

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    appBarTheme: AppBarThemeData(
      centerTitle: true,
      backgroundColor: background,
      surfaceTintColor: scheme.surfaceTint,
      scrolledUnderElevation: 3,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.primaryContainer,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  final Set<int> _visitedIndices = {};
  final RecipePageController _recipePageController = RecipePageController();
  String? _selectedGroup;
  String? _cachedGroupId;
  bool _groupDocReady = false;

  // ── deep links (invite links) ──────────────────────────────────────────────
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  // ── shared recipe links (from other apps' share sheet) ─────────────────────
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  static final RegExp _urlRe = RegExp(r'https?://\S+', caseSensitive: false);

  /// A recipe URL shared before the group/AI were ready (e.g. cold start), held
  /// in memory and replayed once the group document loads.
  String? _pendingSharedUrl;

  /// A recipe image shared before the group/AI were ready (e.g. cold start),
  /// held in memory and replayed once the group document loads.
  ({List<int> bytes, String mimeType})? _pendingSharedImage;

  /// A single-recipe share link tapped before a group was ready (e.g. cold
  /// start), held in memory and replayed once the group document loads.
  ({String groupId, String recipeId})? _pendingSharedRecipe;

  /// A public-recipe share link tapped before a group was ready, held in memory
  /// and replayed once the group document loads.
  String? _pendingPublicRecipe;

  /// Whether the instant shimmering placeholder for a pending shared link is
  /// currently on screen, awaiting the real [RecipeDetailPage] to replace it.
  bool _shareSkeletonShown = false;

  /// An invite tapped while signed-out, held until the account exists so we can
  /// open the join screen right after onboarding.
  ({String groupId, String inviteId})? _pendingInvite;

  // ── session ────────────────────────────────────────────────────────────────
  StreamSubscription<User?>? _authStateSub;
  bool _wasAuthed = false;

  // ── push notifications (FCM token) ──────────────────────────────────────────
  StreamSubscription<String>? _fcmTokenSub;

  /// Guards the notification priming check so it runs at most once per app
  /// session. This is what makes the prompt appear only on a *startup* where the
  /// user is already in a multi-member group — never the moment someone joins
  /// while the app is open (that snapshot is ignored until the next launch).
  bool _notifPrimingChecked = false;

  final db = FirebaseFirestore.instance;

  // ── invite / group membership stream ──────────────────────────────────────
  Stream<QuerySnapshot<Map<String, dynamic>>>? _groupsStream;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupListener;

  List<QueryDocumentSnapshot<Map<String, dynamic>>>? acceptedGroups;

  // ── group-document stream (features + default page) ────────────────────────
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _groupDocListener;

  /// Ordered list of feature keys that are enabled for the current group.
  List<String> _enabledFeatures = List.of(_defaultEnabledFeatures);

  /// Feature key the group wants shown on launch (may be null → first feature).
  String? _groupDefaultPage;

  /// Per-user AI tier and monthly usage, read from the user document.
  Map<String, dynamic>? _userDocData;

  /// Whether the current group has the smart meal planner unlocked by a
  /// Smart-or-higher member (denormalized `mealPlannerUnlocked` on the group).
  bool _mealPlannerUnlocked = false;

  /// Combined AI entitlement for the current user + selected group. Drives which
  /// AI affordances the UI offers; every call is re-verified server-side.
  AiAccess get _aiAccess => AiAccess.fromUserData(
        _userDocData,
        mealPlannerGroupUnlocked: _mealPlannerUnlocked,
      );

  /// Server-set profile flag granting ingredient editing (admin tab).
  bool _canEditIngredients = false;

  /// Server-set profile flag granting public recipe deletion.
  bool _canEditPublicRecipes = false;

  /// Server-set profile flag granting access to the AI usage overview page.
  bool _viewAIUsage = false;

  // ── home screen shortcuts (Android App Shortcuts / iOS Quick Actions) ──────
  final QuickActions _quickActions = const QuickActions();

  /// Cached {name, enabledFeatures} per group id, so shortcuts can be built
  /// for every group the user belongs to, not just the selected one.
  final Map<String, ({String name, List<String> enabledFeatures})> _groupInfoCache = {};

  /// Feature to jump to once a shortcut's target group finishes loading.
  String? _pendingShortcutFeature;

  /// Signature of the shortcut list last pushed to the OS, so unchanged
  /// lists aren't re-registered and don't disturb the launcher's ordering.
  List<String>? _lastShortcutSignature;

  // ---------------------------------------------------------------------------
  // Init / dispose
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _restoreCachedGroup();
    _testUserLoggedIn();
    _initDeepLinks();
    _watchSession();
    _listenForTokenRefresh();
    _quickActions.initialize(_handleQuickAction);
    LanguageService.instance.code.addListener(_persistLanguage);
  }

  /// Mirror the effective language to the user document so the backend can use
  /// it for future operations. No-op while signed out.
  void _persistLanguage() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    db.collection('users').doc(uid).update({'language': LanguageService.instance.code.value}).catchError((_) {});
  }

  /// Returns the device's FCM token **only if** notification permission has
  /// already been granted, without ever prompting the user. The permission
  /// request itself now lives behind the priming screen
  /// ([NotificationInfoPage], shown from [_maybeShowNotificationPriming]) so it
  /// no longer fires on every cold start.
  Future<String?> _fetchFcmToken() async {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      final authed = settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!authed) return null;
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  /// Fetches the FCM token (permission assumed granted) and mirrors it onto the
  /// user document. Called after the user grants permission from the priming
  /// screen. No-op while signed out.
  Future<void> _storeFcmToken() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await db.collection('users').doc(uid).update({'fcmToken': token}).catchError((_) {});
    } catch (_) {}
  }

  /// Decides whether to show the notification priming/info screen on this
  /// startup. It appears only when: the user is in a group with more than one
  /// member, the OS permission is still undecided, and they haven't dismissed
  /// the priming before. Runs at most once per session (see [_notifPrimingChecked]),
  /// so a group crossing into "more than one member" while the app is open is
  /// intentionally deferred to the next launch. If the user grants permission,
  /// the FCM token is fetched and stored.
  Future<void> _maybeShowNotificationPriming(List<String> groupIds) async {
    if (_notifPrimingChecked) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (groupIds.isEmpty) return;
    _notifPrimingChecked = true;

    // Only prompt while the OS decision is still pending.
    try {
      final current = await FirebaseMessaging.instance.getNotificationSettings();
      if (current.authorizationStatus != AuthorizationStatus.notDetermined) return;
    } catch (_) {
      return;
    }

    // Respect an earlier dismissal so we don't nag on every launch.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('notif_priming_dismissed') ?? false) return;

    if (!await _isInMultiMemberGroup(groupIds)) return;

    if (!mounted) return;
    final granted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NotificationInfoPage()),
    );
    if (granted == true) {
      await _storeFcmToken();
    } else {
      await prefs.setBool('notif_priming_dismissed', true);
    }
  }

  /// Whether any of [groupIds] has more than one active member — i.e. the user
  /// actually shares a group with someone. Short-circuits on the first match.
  Future<bool> _isInMultiMemberGroup(List<String> groupIds) async {
    for (final id in groupIds) {
      try {
        final snap = await db.collection('groups').doc(id).collection('members').get();
        final active = snap.docs.where((d) => d.data()['status'] != 'left').length;
        if (active > 1) return true;
      } catch (_) {
        // Ignore unreadable groups and keep checking the rest.
      }
    }
    return false;
  }

  /// Keep the stored FCM token in sync if it rotates while the app is
  /// running. No-op while signed out.
  void _listenForTokenRefresh() {
    _fcmTokenSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      db.collection('users').doc(uid).update({'fcmToken': token}).catchError((_) {});
    });
  }

  /// Detect a mid-session logout (token revoked — e.g. password changed
  /// elsewhere or the account was disabled) and route back to sign in.
  void _watchSession() {
    _authStateSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      final isAuthed = user != null;
      if (_wasAuthed && !isAuthed && mounted) {
        // Drop the previous account's group before routing to sign in, so a
        // subsequent login can't inherit it.
        _clearGroupState().then((_) {
          if (mounted) _testUserLoggedIn();
        });
      }
      _wasAuthed = isAuthed;
    });
  }

  /// Listen for invite links (initial launch + while running) and open the
  /// join screen. Also listen for recipe links shared from other apps.
  Future<void> _initDeepLinks() async {
    _linkSub = _appLinks.uriLinkStream.listen(_handleUri, onError: (_) {});
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleUri(initial);
    } catch (_) {}

    // A recipe link shared into the app via the OS share sheet.
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedMedia, onError: (_) {});
    try {
      final initialShare = await ReceiveSharingIntent.instance.getInitialMedia();
      _handleSharedMedia(initialShare);
      ReceiveSharingIntent.instance.reset();
    } catch (_) {}
  }

  /// Extracts a URL or an image from a shared payload and starts a recipe
  /// from it.
  void _handleSharedMedia(List<SharedMediaFile> shared) {
    if (shared.isEmpty || !mounted) return;
    for (final file in shared) {
      if (file.type == SharedMediaType.image) {
        _openRecipeFromImage(file);
        return;
      }
      final url = _urlRe.firstMatch(file.path)?.group(0);
      if (url != null) {
        _openRecipeFromUrl(url);
        return;
      }
    }
  }

  /// Creates a recipe in the active group from a shared link and opens it in
  /// generating mode while the backend fills it in. Requires a signed-in user,
  /// a selected group, and a plan that allows recipe generation.
  Future<void> _openRecipeFromUrl(String url) async {
    if (!mounted) return;
    // A shared single-recipe link opens the preview flow, not the URL importer.
    final publicRecipe = parsePublicRecipeShareUri(Uri.parse(url));
    if (publicRecipe != null) {
      _openPublicRecipe(publicRecipe);
      return;
    }
    final sharedRecipe = parseRecipeShareUri(Uri.parse(url));
    if (sharedRecipe != null) {
      _openSharedRecipe(sharedRecipe.groupId, sharedRecipe.recipeId);
      return;
    }
    // Show the shimmering placeholder immediately so something appears on
    // screen the moment the link arrives, even before we know the doc id.
    if (!_shareSkeletonShown) {
      _shareSkeletonShown = true;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const RecipeDetailSkeleton(),
      ));
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (_selectedGroup == null || !_aiAccess.canGenerateRecipes || uid == null) {
      // Not ready yet (cold start): remember it and replay once the group loads.
      _pendingSharedUrl = url;
      return;
    }
    final recipes = db.collection('groups').doc(_selectedGroup).collection('recipes');
    final ref = await recipes.add({
      'name': '',
      'description': '',
      'creator': uid,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': null,
      'preparationTime': 0,
      'time': 0,
      'servings': 2,
      'tags': <String>[],
      'images': <String>[],
      'steps': <String>[],
      'attribution': url,
    });
    if (!mounted) return;
    _shareSkeletonShown = false;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => RecipeDetailPage(
        groupId: _selectedGroup!,
        recipeId: ref.id,
        access: _aiAccess,
        generating: true,
        initialData: {
          'name': '',
          'description': '',
          'images': const <String>[],
          'steps': const <String>[],
          'tags': const <String>[],
          'servings': 2,
          'time': 0,
          'preparationTime': 0,
          'attribution': url,
        },
      ),
    ));
    FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('recipes-generateRecipeStaged')
        .call(<String, dynamic>{
      'groupId': _selectedGroup,
      'recipeId': ref.id,
      'source': 'url',
      'url': url,
      'lang': LanguageService.instance.code.value,
    }).ignore();
  }

  /// Reads a shared image file and starts a recipe from it.
  Future<void> _openRecipeFromImage(SharedMediaFile file) async {
    if (!mounted) return;
    final List<int> bytes;
    try {
      bytes = await File(file.path).readAsBytes();
    } catch (_) {
      return;
    }
    await _openRecipeFromImageBytes(bytes, file.mimeType ?? 'image/jpeg');
  }

  /// Creates a recipe in the active group from a shared image and opens it in
  /// generating mode while the backend fills it in, via the same
  /// `generateRecipeStaged` photo flow used when picking a photo from the
  /// create menu. Requires a signed-in user, a selected group, and a plan that
  /// allows recipe generation.
  Future<void> _openRecipeFromImageBytes(List<int> bytes, String mimeType) async {
    if (!mounted) return;
    // Show the shimmering placeholder immediately so something appears on
    // screen the moment the image arrives, even before we know the doc id.
    if (!_shareSkeletonShown) {
      _shareSkeletonShown = true;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const RecipeDetailSkeleton(),
      ));
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (_selectedGroup == null || !_aiAccess.canGenerateRecipes || uid == null) {
      // Not ready yet (cold start): remember it and replay once the group loads.
      _pendingSharedImage = (bytes: bytes, mimeType: mimeType);
      return;
    }
    final recipes = db.collection('groups').doc(_selectedGroup).collection('recipes');
    final ref = await recipes.add({
      'name': '',
      'description': '',
      'creator': uid,
      'createdAt': FieldValue.serverTimestamp(),
      'lastUsedAt': null,
      'preparationTime': 0,
      'time': 0,
      'servings': 2,
      'tags': <String>[],
      'images': <String>[],
      'steps': <String>[],
    });
    if (!mounted) return;
    _shareSkeletonShown = false;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => RecipeDetailPage(
        groupId: _selectedGroup!,
        recipeId: ref.id,
        access: _aiAccess,
        generating: true,
        initialData: {
          'name': '',
          'description': '',
          'images': const <String>[],
          'steps': const <String>[],
          'tags': const <String>[],
          'servings': 2,
          'time': 0,
          'preparationTime': 0,
        },
      ),
    ));
    FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('recipes-generateRecipeStaged')
        .call(<String, dynamic>{
      'groupId': _selectedGroup,
      'recipeId': ref.id,
      'source': 'photo',
      'imageBase64': base64Encode(bytes),
      'imageMimeType': mimeType,
      'lang': LanguageService.instance.code.value,
    }).ignore();
  }

  void _handleUri(Uri uri) {
    // A single-recipe share link opens a read-only preview with a "save in own
    // recipes" button, before the invite/import fallbacks below.
    final publicRecipe = parsePublicRecipeShareUri(uri);
    if (publicRecipe != null) {
      _openPublicRecipe(publicRecipe);
      return;
    }
    final sharedRecipe = parseRecipeShareUri(uri);
    if (sharedRecipe != null) {
      _openSharedRecipe(sharedRecipe.groupId, sharedRecipe.recipeId);
      return;
    }
    final invite = parseInviteUri(uri);
    if (invite == null) {
      // Not an invite — a shared/opened http(s) link becomes a recipe.
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        _openRecipeFromUrl(uri.toString());
      }
      return;
    }
    if (!mounted) return;
    if (FirebaseAuth.instance.currentUser == null) {
      // Not signed in yet: remember the invite and switch onboarding into join
      // mode (no group creation). The join screen opens automatically once the
      // account exists (see _testUserLoggedIn).
      _pendingInvite = invite;
      _openOnboarding();
    } else {
      _openJoinPage(invite);
    }
  }

  /// Opens a single shared recipe. If the recipe belongs to the active group it
  /// opens normally; otherwise it opens as a read-only preview offering to save
  /// it into the active group's own recipes. Held until a group is ready if
  /// tapped during a cold start.
  void _openSharedRecipe(String sourceGroupId, String recipeId) {
    if (!mounted) return;
    if (_selectedGroup == null || !_groupDocReady) {
      _pendingSharedRecipe = (groupId: sourceGroupId, recipeId: recipeId);
      return;
    }
    if (sourceGroupId == _selectedGroup) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          groupId: sourceGroupId,
          recipeId: recipeId,
          access: _aiAccess,
        ),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecipeDetailPage(
        groupId: _selectedGroup!,
        recipeId: recipeId,
        sharedSourceGroupId: sourceGroupId,
      ),
    ));
  }

  /// Opens a shared public recipe as a read-only preview offering to save it
  /// into the active group's own recipes. Held until a group is ready if tapped
  /// during a cold start.
  void _openPublicRecipe(String publicId) {
    if (!mounted) return;
    if (_selectedGroup == null || !_groupDocReady) {
      _pendingPublicRecipe = publicId;
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecipeDetailPage(
        groupId: _selectedGroup!,
        recipeId: '',
        access: _aiAccess,
        publicRecipeId: publicId,
        canEditPublicRecipes: _canEditPublicRecipes,
      ),
    ));
  }

  void _openJoinPage(({String groupId, String inviteId}) invite) {
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => JoinGroupPage(
        groupId: invite.groupId,
        inviteId: invite.inviteId,
        onJoined: _selectGroup,
      ),
    ));
  }

  /// Shows the onboarding flow, replacing anything currently above HomePage.
  /// Runs in join mode when an invite is pending.
  void _openOnboarding() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(
      builder: (_) => WelcomePage(onFinished: _testUserLoggedIn, joinMode: _pendingInvite != null),
    ));
  }

  /// Make a group the active one (from the overview or after joining a link).
  void _selectGroup(String groupId) {
    if (_selectedGroup == groupId) return;
    setState(() {
      _selectedGroup = groupId;
      _cachedGroupId = groupId;
    });
    _subscribeToGroupDoc(groupId);
  }

  // ---------------------------------------------------------------------------
  // Home screen shortcuts
  // ---------------------------------------------------------------------------

  /// Most launchers only show a handful of home-screen shortcuts (commonly 4),
  /// so once every group's features are combined we cap the list and let the
  /// most-recently-used groups keep their slot.
  static const int _maxShortcuts = 4;

  /// Handles a tap on a home screen shortcut, identified by a
  /// `group:<groupId>:<featureKey>` type string.
  void _handleQuickAction(String type) {
    if (!type.startsWith('group:')) return;
    final rest = type.substring('group:'.length);
    final sep = rest.lastIndexOf(':');
    if (sep == -1) return;
    final groupId = rest.substring(0, sep);
    final featureKey = rest.substring(sep + 1);
    if (groupId.isEmpty || featureKey.isEmpty) return;

    if (_selectedGroup == groupId && _groupDocReady) {
      final i = _enabledFeatures.indexOf(featureKey);
      if (i != -1 && mounted) setState(() => _selectedIndex = i);
    } else {
      _pendingShortcutFeature = featureKey;
      _selectGroup(groupId);
    }
  }

  /// Parses the {name, enabledFeatures} shortcut-relevant fields out of a
  /// group document, mirroring the parsing in [_subscribeToGroupDoc].
  ({String name, List<String> enabledFeatures}) _groupInfoFromDoc(Map<String, dynamic> data) {
    final raw = data['enabledFeatures'];
    final parsed = raw is List ? raw.map((e) => e.toString()).where(_allFeatures.contains).toList() : List<String>.of(_defaultEnabledFeatures);
    return (
      name: (data['name'] ?? 'Group').toString(),
      enabledFeatures: parsed.isNotEmpty ? parsed : List<String>.of(_defaultEnabledFeatures),
    );
  }

  /// Rebuilds the home screen shortcuts from every group the user belongs to,
  /// most-recently-used first, capped at [_maxShortcuts].
  Future<void> _refreshShortcuts() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final groups = acceptedGroups;
    if (groups == null) return;

    final sorted = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(groups)
      ..sort((a, b) {
        final at = a.data()['lastUsed'] as Timestamp?;
        final bt = b.data()['lastUsed'] as Timestamp?;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });

    final missing = sorted.map((d) => d.id).where((id) => !_groupInfoCache.containsKey(id));
    await Future.wait(missing.map((id) async {
      final snap = await db.collection('groups').doc(id).get();
      if (snap.exists) _groupInfoCache[id] = _groupInfoFromDoc(snap.data()!);
    }));
    if (!mounted) return;

    final items = <ShortcutItem>[];
    for (final doc in sorted) {
      if (items.length >= _maxShortcuts) break;
      final info = _groupInfoCache[doc.id];
      if (info == null) continue;
      for (final key in info.enabledFeatures) {
        if (items.length >= _maxShortcuts) break;
        final meta = _featureMeta[key];
        if (meta == null) continue;
        items.add(ShortcutItem(
          type: 'group:${doc.id}:$key',
          localizedTitle: '${meta.label} · ${info.name}',
        ));
      }
    }

    final signature = items.map((item) => '${item.type}|${item.localizedTitle}').toList();
    if (listEquals(signature, _lastShortcutSignature)) return;
    _lastShortcutSignature = signature;

    await _quickActions.setShortcutItems(items);
  }

  Future<void> _createGroup() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    );
    if (newId != null && mounted) _selectGroup(newId);
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  void _openProfile() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfilePage()));
  }

  void _openOverview() {
    final ids = acceptedGroups?.map((d) => d.id).toList() ?? <String>[];
    if (_selectedGroup != null && _selectedGroup!.isNotEmpty && !ids.contains(_selectedGroup)) {
      ids.insert(0, _selectedGroup!);
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GroupOverviewPage(
        groupIds: ids,
        selectedGroup: _selectedGroup,
        onSelect: _selectGroup,
        canEditIngredients: _canEditIngredients,
        canEditPublicRecipes: _canEditPublicRecipes,
        viewAIUsage: _viewAIUsage,
      ),
    ));
  }

  /// Subscribe to the last-used group's document straight away so its cached
  /// pages render while auth and invite membership are verified in parallel.
  Future<void> _restoreCachedGroup() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = FirebaseAuth.instance.currentUser?.uid;

    // The cache is tagged with the uid that wrote it. After a logout + login
    // into a different account the stale group would otherwise survive (and,
    // for an account with no groups at all, be kept forever by the fallback in
    // the membership listener). Drop it when it belongs to someone else.
    final cachedUid = prefs.getString('selected_group_uid');
    if (uid == null || (cachedUid != null && cachedUid != uid)) {
      await prefs.remove('selected_group');
      await prefs.remove('selected_group_uid');
      _cachedGroupId = null;
      return;
    }

    final cached = prefs.getString('selected_group');
    _cachedGroupId = (cached != null && cached.isNotEmpty) ? cached : null;
    if (cached != null && cached.isNotEmpty && _selectedGroup == null) {
      setState(() => _selectedGroup = cached);
      _subscribeToGroupDoc(cached);
    }
  }

  /// Wipe every trace of the previous account's group so the next sign-in
  /// starts from a clean slate rather than rendering the old group's pages.
  Future<void> _clearGroupState() async {
    _groupListener?.cancel();
    _groupListener = null;
    _groupsStream = null;
    _groupDocListener?.cancel();
    _groupDocListener = null;
    _groupInfoCache.clear();
    _pendingShortcutFeature = null;
    acceptedGroups = null;
    _selectedGroup = null;
    _cachedGroupId = null;
    _groupDocReady = false;
    _groupDefaultPage = null;
    _mealPlannerUnlocked = false;
    _enabledFeatures = List.of(_defaultEnabledFeatures);
    _selectedIndex = 0;
    _notifPrimingChecked = false;
    if (mounted) setState(() {});

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('selected_group');
    await prefs.remove('selected_group_uid');
  }

  @override
  void dispose() {
    _groupListener?.cancel();
    _groupDocListener?.cancel();
    _linkSub?.cancel();
    _shareSub?.cancel();
    _authStateSub?.cancel();
    _fcmTokenSub?.cancel();
    LanguageService.instance.code.removeListener(_persistLanguage);
    super.dispose();
  }

  /// Returns the OS version, e.g. "15" (Android) or "17.4.1" (iOS).
  ///
  /// `Platform.operatingSystemVersion` isn't usable for this: on Android OEMs
  /// put arbitrary build fingerprints there (e.g. "BP2A.250605.031.A3...")
  /// instead of the actual Android version. device_info_plus gives the real
  /// version on both platforms.
  Future<String> _majorOsVersion() async {
    final deviceInfo = DeviceInfoPlugin();
    return Platform.isAndroid ? (await deviceInfo.androidInfo).version.release : (await deviceInfo.iosInfo).systemVersion;
  }

  // ---------------------------------------------------------------------------
  // Auth check
  // ---------------------------------------------------------------------------

  Future<void> _testUserLoggedIn() async {
    final currentUser = FirebaseAuth.instance.currentUser;

    DocumentSnapshot<Map<String, dynamic>>? userDoc;
    if (currentUser != null) {
      final userRef = FirebaseFirestore.instance.collection('users').doc(currentUser.uid);
      try {
        userDoc = await userRef.get(const GetOptions(source: Source.cache));
      } catch (_) {
        userDoc = null;
      }
      if (userDoc == null || !userDoc.exists) {
        userDoc = await userRef.get();
      } else {
        _refreshUserDoc(userRef);
      }
    }

    if (currentUser == null || !userDoc!.exists) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openOnboarding());
    } else {
      _canEditIngredients = (userDoc.data())?['editIngredients'] == true;
      _canEditPublicRecipes = (userDoc.data())?['editPublicRecipes'] == true;
      _viewAIUsage = (userDoc.data())?['viewAIUsage'] == true;
      _userDocData = userDoc.data();

      // Adopt the notification opt-outs stored on the profile (source of truth
      // for the backend). Fire-and-forget: a backfill write must not stall
      // startup, and Firestore replays it if we're offline.
      NotificationFeatureSettings.syncFromUserDoc(userDoc.data()).ignore();

      // If the user just signed up/in after tapping an invite link, open the
      // join screen now that they have an account.
      if (_pendingInvite != null) {
        final invite = _pendingInvite!;
        _pendingInvite = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => _openJoinPage(invite));
      }

      // Adopt a group created during onboarding (cached but not yet mirrored
      // by the membership function below).
      await _restoreCachedGroup();

      if (Platform.isAndroid || Platform.isIOS) {
        final uid = FirebaseAuth.instance.currentUser!.uid;

        // Listen to the user's group memberships (server-maintained mirror at
        // users/{uid}/groups). One doc per group the user belongs to.
        _groupsStream = db.collection('users').doc(uid).collection("groups").snapshots();
        _groupListener?.cancel();
        _groupListener = _groupsStream!.listen((snapshot) {
          acceptedGroups = snapshot.docs;

          final ids = acceptedGroups!.map((d) => d.id).toList();

          // Keep the current group if we're still a member (or it's the freshly
          // cached/onboarded group whose mirror may not have synced yet);
          // otherwise fall back to the first membership, then the cached group.
          String? newGroupId;
          if (_selectedGroup != null && (ids.contains(_selectedGroup) || _selectedGroup == _cachedGroupId)) {
            newGroupId = _selectedGroup;
          } else if (ids.isNotEmpty) {
            newGroupId = ids.first;
          } else {
            newGroupId = _cachedGroupId;
          }

          if (_selectedGroup != newGroupId) {
            _selectedGroup = newGroupId;
            _subscribeToGroupDoc(_selectedGroup);
          }

          setState(() {});
          _refreshShortcuts();

          // On this startup only (guarded to once per session), offer the
          // notification priming screen if the user is already in a group with
          // more than one member.
          _maybeShowNotificationPriming(ids);
        });

        // Update user record
        final packageInfo = await PackageInfo.fromPlatform();
        final fcmToken = await _fetchFcmToken();
        final osVersion = await _majorOsVersion();
        await db.collection('users').doc(uid).update({
          'lastLogin': FieldValue.serverTimestamp(),
          'appVersion': packageInfo.version,
          'os': Platform.operatingSystem,
          'osVersion': osVersion,
          'language': LanguageService.instance.code.value,
          if (fcmToken != null) 'fcmToken': fcmToken,
        }).catchError((
          error,
        ) {
          if (kDebugMode) print("Failed to update user: $error");
        });
      }
    }
  }

  /// Re-fetch the user doc from the server after the cached copy was used, so a
  /// server-side change to the ingredient-edit flag is picked up this session.
  Future<void> _refreshUserDoc(DocumentReference<Map<String, dynamic>> userRef) async {
    try {
      final fresh = await userRef.get(const GetOptions(source: Source.server));
      if (!mounted || !fresh.exists) return;
      // Pick up notification opt-outs changed on another device this session.
      NotificationFeatureSettings.syncFromUserDoc(fresh.data()).ignore();
      final canEdit = fresh.data()?['editIngredients'] == true;
      if (canEdit != _canEditIngredients) {
        setState(() => _canEditIngredients = canEdit);
      }
      final canEditPublic = fresh.data()?['editPublicRecipes'] == true;
      if (canEditPublic != _canEditPublicRecipes) {
        setState(() => _canEditPublicRecipes = canEditPublic);
      }
      final viewAIUsage = fresh.data()?['viewAIUsage'] == true;
      if (viewAIUsage != _viewAIUsage) {
        setState(() => _viewAIUsage = viewAIUsage);
      }
      // Pick up a server-side tier change or updated usage counter this session.
      final freshAccess = AiAccess.fromUserData(fresh.data(), mealPlannerGroupUnlocked: _mealPlannerUnlocked);
      if (freshAccess != _aiAccess) {
        setState(() => _userDocData = fresh.data());
      }
    } catch (_) {}
  }

  /// Record the group as the most recently used one for this user. Updates the
  /// membership mirror only when it exists (never creates a stray doc).
  void _touchGroupLastUsed(String groupId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    db.collection('users').doc(uid).collection('groups').doc(groupId).update({'lastUsed': FieldValue.serverTimestamp()}).catchError((_) {});
  }

  // ---------------------------------------------------------------------------
  // Group document listener (features + defaultPage)
  // ---------------------------------------------------------------------------

  void _subscribeToGroupDoc(String? groupId) {
    _groupDocListener?.cancel();
    _groupDocListener = null;
    _groupDocReady = false;

    if (groupId == null) {
      // No group left: reset the feature list and tab index so the shell can't
      // keep rendering the previous group's pages.
      _enabledFeatures = List.of(_defaultEnabledFeatures);
      _groupDefaultPage = null;
      _mealPlannerUnlocked = false;
      _selectedIndex = 0;
      return;
    }

    _touchGroupLastUsed(groupId);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    SharedPreferences.getInstance().then((p) {
      p.setString('selected_group', groupId);
      // Tag the cache with its owner so another account can't restore it.
      if (uid != null) p.setString('selected_group_uid', uid);
    });

    _groupDocListener = db.collection('groups').doc(groupId).snapshots().listen((snapshot) {
      if (!snapshot.exists) {
        // The selected/cached group no longer exists. If it isn't among our
        // memberships either, drop the selection so the no-group screen shows
        // instead of hanging on the loading spinner.
        final ids = acceptedGroups?.map((d) => d.id).toList() ?? const <String>[];
        if (!ids.contains(groupId)) {
          setState(() {
            _selectedGroup = null;
            _cachedGroupId = null;
            _groupDocReady = false;
          });
          _subscribeToGroupDoc(null);
        }
        return;
      }

      final data = snapshot.data()!;

      // --- enabled features ---------------------------------------------------
      // The group document stores an ordered list like:
      //   enabledFeatures: ["shopping_list", "recipes"]
      // Unknown keys are silently ignored; known keys keep the document's order.
      final raw = data['enabledFeatures'];
      final List<String> parsed = raw is List ? raw.map((e) => e.toString()).where(_allFeatures.contains).toList() : List.of(_defaultEnabledFeatures);

      final enabled = parsed.isNotEmpty ? parsed : List.of(_defaultEnabledFeatures);

      // --- default startup page -----------------------------------------------
      final String? defaultPage = data['defaultPage'] as String?;

      final bool mealPlannerUnlocked = data['mealPlannerUnlocked'] as bool? ?? false;

      // A shortcut tap targeting this group takes priority over the group's
      // own default page, but only for the tap that requested it.
      final String? shortcutFeature = _pendingShortcutFeature;
      _pendingShortcutFeature = null;

      setState(() {
        _groupDocReady = true;
        _enabledFeatures = enabled;
        _groupDefaultPage = defaultPage;
        _mealPlannerUnlocked = mealPlannerUnlocked;

        // Resolve selected index: honour a pending shortcut, then the group
        // preference, else keep current feature if it's still available, else
        // fall back to 0.
        _selectedIndex = _resolveSelectedIndex(preferredFeature: shortcutFeature ?? _groupDefaultPage, currentFeature: _currentFeatureKey, features: _enabledFeatures);
      });

      _groupInfoCache[groupId] = _groupInfoFromDoc(data);
      _refreshShortcuts();

      // Replay a recipe link that was shared before the group was ready.
      if (_aiAccess.canGenerateRecipes && _pendingSharedUrl != null) {
        final url = _pendingSharedUrl!;
        _pendingSharedUrl = null;
        _openRecipeFromUrl(url);
      }
      // Replay a recipe image that was shared before the group was ready.
      if (_aiAccess.canGenerateRecipes && _pendingSharedImage != null) {
        final pending = _pendingSharedImage!;
        _pendingSharedImage = null;
        _openRecipeFromImageBytes(pending.bytes, pending.mimeType);
      }
      // Replay a shared recipe link tapped before a group was ready.
      if (_pendingSharedRecipe != null) {
        final pending = _pendingSharedRecipe!;
        _pendingSharedRecipe = null;
        _openSharedRecipe(pending.groupId, pending.recipeId);
      }
      // Replay a public-recipe link tapped before a group was ready.
      if (_pendingPublicRecipe != null) {
        final pending = _pendingPublicRecipe!;
        _pendingPublicRecipe = null;
        _openPublicRecipe(pending);
      }
    }, onError: (Object e) {
      debugPrint('Group doc listener error: $e');
      // A permission denial means we're not a member of this group (e.g. a
      // group cached by a previously signed-in account). Drop it so the
      // no-group screen shows instead of the previous account's pages.
      final denied = e is FirebaseException && e.code == 'permission-denied';
      if (!denied || !mounted) return;
      final ids = acceptedGroups?.map((d) => d.id).toList() ?? const <String>[];
      if (ids.contains(groupId)) return;
      setState(() {
        _selectedGroup = null;
        _cachedGroupId = null;
        _groupDocReady = false;
      });
      _subscribeToGroupDoc(null);
    });
  }

  /// Returns the feature key that is currently visible, or null.
  String? get _currentFeatureKey {
    if (_selectedIndex < _enabledFeatures.length) {
      return _enabledFeatures[_selectedIndex];
    }
    return null;
  }

  static int _resolveSelectedIndex({required String? preferredFeature, required String? currentFeature, required List<String> features}) {
    if (features.isEmpty) return 0;

    // 1. Group-defined default page
    if (preferredFeature != null) {
      final i = features.indexOf(preferredFeature);
      if (i != -1) return i;
    }

    // 2. Keep current tab if still available
    if (currentFeature != null) {
      final i = features.indexOf(currentFeature);
      if (i != -1) return i;
    }

    // 3. First available
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Widget helpers
  // ---------------------------------------------------------------------------

  List<NavigationDestination> _buildDestinations() {
    final dests = _enabledFeatures.map((key) {
      final meta = _featureMeta[key]!;
      return NavigationDestination(icon: Icon(meta.icon), label: meta.label);
    }).toList();
    // Trailing entry for group switching + app settings (replaces the app bar).
    dests.add(const NavigationDestination(icon: Icon(Icons.menu), label: 'More'));
    return dests;
  }

  Widget _buildPage(String featureKey, {required bool shoppingListEnabled}) {
    switch (featureKey) {
      case 'shopping_list':
        return ShoppingListPage(groupId: _selectedGroup!);
      case 'recipes':
        return RecipePage(groupId: _selectedGroup!, shoppingListEnabled: shoppingListEnabled, access: _aiAccess, canEditPublicRecipes: _canEditPublicRecipes, controller: _recipePageController);
      case 'todos':
        // Replace with your real TodosPage when ready
        return const _PlaceholderPage(label: 'To-Do\'s');
      case 'calendar':
        // Replace with your real CalendarPage when ready
        return const _PlaceholderPage(label: 'Calendar');
      case 'money':
        // Replace with your real MoneyPage when ready
        return const _PlaceholderPage(label: 'Money splitting');
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool groupReady = _selectedGroup != null && _selectedGroup!.isNotEmpty && _groupDocReady;
    final bool noGroups = acceptedGroups != null && acceptedGroups!.isEmpty && (_selectedGroup == null || _selectedGroup!.isEmpty);
    final bool shoppingListEnabled = _enabledFeatures.contains('shopping_list');

    return AnimatedBuilder(
      animation: Listenable.merge(
          [_recipePageController.hasSearch, _recipePageController.keyboardVisible]),
      builder: (context, child) {
        final hasSearch = _recipePageController.hasSearch.value;
        final keyboardVisible = _recipePageController.keyboardVisible.value;
        final onRecipes = _currentFeatureKey == 'recipes';
        return PopScope(
          // On the recipes tab, back first dismisses the keyboard if it's
          // open; only once it's closed does back clear an active search,
          // before finally falling through to the normal back/exit behaviour.
          canPop: !(onRecipes && (keyboardVisible || hasSearch)),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (keyboardVisible) {
              FocusManager.instance.primaryFocus?.unfocus();
              return;
            }
            _recipePageController.clearSearchIfActive();
          },
          child: child!,
        );
      },
      child: Scaffold(
      bottomNavigationBar: groupReady
          ? NavigationBar(
              height: 60,
              destinations: _buildDestinations(),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (int index) {
                if (index < _enabledFeatures.length) {
                  setState(() => _selectedIndex = index);
                } else {
                  _openOverview(); // trailing "More" entry → groups + settings
                }
              },
            )
          : null,
      body: SafeArea(
        child: groupReady
          ? IndexedStack(
              index: _selectedIndex,
              children: List.generate(_enabledFeatures.length, (i) {
                if (i == _selectedIndex) _visitedIndices.add(i);
                return _visitedIndices.contains(i)
                    ? _buildPage(_enabledFeatures[i], shoppingListEnabled: shoppingListEnabled)
                    : const SizedBox.shrink();
              }),
            )
          : noGroups
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(48.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.group_off, size: 32),
                    const SizedBox(height: 16),
                    const Text(
                      'You are not a member of any group yet. Ask someone to send you an invite link to their group — or create your own below.',
                      style: TextStyle(fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 260,
                      height: 72,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            animatedBackground(),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _createGroup,
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add, color: Colors.white, size: 28),
                                    SizedBox(width: 8),
                                    Text(
                                      'New group',
                                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _openProfile,
                      child: const Text('Profile Settings'),
                    ),
                    TextButton(
                      onPressed: _openSettings,
                      child: const Text('App Settings'),
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CupertinoActivityIndicator()),
      ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholder page for features not yet implemented
// ---------------------------------------------------------------------------

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.construction, size: 40),
          const SizedBox(height: 12),
          Text('$label coming soon', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
