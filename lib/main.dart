import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:couple_planner/features/recipes/pages/recipe_page.dart';
import 'package:firebase_auth/firebase_auth.dart';

// import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:system_theme/system_theme.dart';
import 'package:couple_planner/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:app_links/app_links.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/groups/invite_links.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart';
import 'package:couple_planner/features/shopping_list/pages/shopping_list_page.dart';
import 'package:couple_planner/features/groups/pages/join_group_page.dart';
import 'package:couple_planner/features/groups/pages/group_overview_page.dart';
import 'package:couple_planner/features/groups/pages/create_group_page.dart';
import 'package:couple_planner/features/settings/pages/settings_page.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/auth/pages/login_page.dart' show animatedBackground;

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
  runApp(const MyApp());
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

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surfaceDim,
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    appBarTheme: const AppBarThemeData(
      centerTitle: true,
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

  /// An invite tapped while signed-out, held until the account exists so we can
  /// open the join screen right after onboarding.
  ({String groupId, String inviteId})? _pendingInvite;

  // ── session ────────────────────────────────────────────────────────────────
  StreamSubscription<User?>? _authStateSub;
  bool _wasAuthed = false;

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

  /// Whether AI features are enabled for the current group.
  bool _aiEnabled = false;

  /// Server-set profile flag granting ingredient editing (admin tab).
  bool _canEditIngredients = false;

  /// Server-set profile flag granting public recipe deletion.
  bool _canEditPublicRecipes = false;

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
    LanguageService.instance.code.addListener(_persistLanguage);
  }

  /// Mirror the effective language to the user document so the backend can use
  /// it for future operations. No-op while signed out.
  void _persistLanguage() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    db.collection('users').doc(uid).update({'language': LanguageService.instance.code.value}).catchError((_) {});
  }

  /// Detect a mid-session logout (token revoked — e.g. password changed
  /// elsewhere or the account was disabled) and route back to sign in.
  void _watchSession() {
    _authStateSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      final isAuthed = user != null;
      if (_wasAuthed && !isAuthed && mounted) {
        _testUserLoggedIn();
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

  /// Extracts the first URL from a shared payload and starts a recipe from it.
  void _handleSharedMedia(List<SharedMediaFile> shared) {
    if (shared.isEmpty || !mounted) return;
    for (final file in shared) {
      final url = _urlRe.firstMatch(file.path)?.group(0);
      if (url != null) {
        _openRecipeFromUrl(url);
        return;
      }
    }
  }

  /// Creates a recipe in the active group from a shared link and opens it in
  /// generating mode while the backend fills it in. Requires a signed-in user,
  /// a selected group, and AI enabled for that group.
  Future<void> _openRecipeFromUrl(String url) async {
    if (!mounted) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (_selectedGroup == null || !_aiEnabled || uid == null) {
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
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecipeDetailPage(
        groupId: _selectedGroup!,
        recipeId: ref.id,
        aiEnabled: true,
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

  void _handleUri(Uri uri) {
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

  Future<void> _createGroup() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CreateGroupPage()),
    );
    if (newId != null && mounted) _selectGroup(newId);
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
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
      ),
    ));
  }

  /// Subscribe to the last-used group's document straight away so its cached
  /// pages render while auth and invite membership are verified in parallel.
  Future<void> _restoreCachedGroup() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('selected_group');
    _cachedGroupId = (cached != null && cached.isNotEmpty) ? cached : null;
    if (cached != null && cached.isNotEmpty && _selectedGroup == null) {
      setState(() => _selectedGroup = cached);
      _subscribeToGroupDoc(cached);
    }
  }

  @override
  void dispose() {
    _groupListener?.cancel();
    _groupDocListener?.cancel();
    _linkSub?.cancel();
    _shareSub?.cancel();
    _authStateSub?.cancel();
    LanguageService.instance.code.removeListener(_persistLanguage);
    super.dispose();
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
        });

        // Update user record
        final packageInfo = await PackageInfo.fromPlatform();
        await db.collection('users').doc(uid).update({'lastLogin': FieldValue.serverTimestamp(), 'appVersion': packageInfo.version, 'language': LanguageService.instance.code.value}).catchError((
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
      final canEdit = fresh.data()?['editIngredients'] == true;
      if (canEdit != _canEditIngredients) {
        setState(() => _canEditIngredients = canEdit);
      }
      final canEditPublic = fresh.data()?['editPublicRecipes'] == true;
      if (canEditPublic != _canEditPublicRecipes) {
        setState(() => _canEditPublicRecipes = canEditPublic);
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

    if (groupId == null) return;

    _touchGroupLastUsed(groupId);
    SharedPreferences.getInstance().then((p) => p.setString('selected_group', groupId));

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

      final bool aiEnabled = data['ai'] as bool? ?? false;

      setState(() {
        _groupDocReady = true;
        _enabledFeatures = enabled;
        _groupDefaultPage = defaultPage;
        _aiEnabled = aiEnabled;

        // Resolve selected index: honour group preference, else keep current
        // feature if it's still available, else fall back to 0.
        _selectedIndex = _resolveSelectedIndex(preferredFeature: _groupDefaultPage, currentFeature: _currentFeatureKey, features: _enabledFeatures);
      });

      // Replay a recipe link that was shared before the group was ready.
      if (_aiEnabled && _pendingSharedUrl != null) {
        final url = _pendingSharedUrl!;
        _pendingSharedUrl = null;
        _openRecipeFromUrl(url);
      }
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

  Widget _buildPage(String featureKey, {required bool shoppingListEnabled, required bool aiEnabled}) {
    switch (featureKey) {
      case 'shopping_list':
        return ShoppingListPage(groupId: _selectedGroup!);
      case 'recipes':
        return RecipePage(groupId: _selectedGroup!, shoppingListEnabled: shoppingListEnabled, aiEnabled: _aiEnabled, canEditPublicRecipes: _canEditPublicRecipes);
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

    return Scaffold(
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
                    ? _buildPage(_enabledFeatures[i], shoppingListEnabled: shoppingListEnabled, aiEnabled: _aiEnabled)
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
                      onPressed: _openSettings,
                      child: const Text('App Settings'),
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CupertinoActivityIndicator()),
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
