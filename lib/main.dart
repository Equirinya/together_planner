import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:couple_planner/pages/recipe_page.dart';
import 'package:couple_planner/utils.dart';
import 'package:firebase_auth/firebase_auth.dart';

// import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:system_theme/system_theme.dart';
import 'firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'pages/login_page.dart';
import 'pages/shopping_list_page.dart';

// ---------------------------------------------------------------------------
// Feature registry
// ---------------------------------------------------------------------------

/// All features the app knows about, in canonical display order.
/// The group document may reorder / subset this list via `enabledFeatures`.
const _allFeatures = ['shopping_list', 'recipes', 'todos', 'calendar'];

/// Default set shown when a group document has no `enabledFeatures` field.
const _defaultEnabledFeatures = ['shopping_list', 'recipes'];

const _featureMeta = <String, ({IconData icon, String label})>{
  'shopping_list': (icon: Icons.shopping_bag, label: 'Shopping List'),
  'recipes': (icon: Icons.restaurant_menu, label: 'Recipes'),
  'todos': (icon: Icons.checklist, label: 'To-Do\'s'),
  'calendar': (icon: Icons.calendar_month, label: 'Calendar'),
};

// ---------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemTheme.fallbackColor = const Color(0xFFB7FF5E);
  await SystemTheme.accentColor.load();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.accent)),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.dark, brightness: Brightness.dark),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  String? _selectedGroup;

  final db = FirebaseFirestore.instance;

  // ── invite / group membership stream ──────────────────────────────────────
  Stream<QuerySnapshot<Map<String, dynamic>>>? _groupsStream;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupListener;

  List<QueryDocumentSnapshot<Map<String, dynamic>>>? acceptedGroups;
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? pendingGroups;

  // ── group-document stream (features + default page) ────────────────────────
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _groupDocListener;

  /// Ordered list of feature keys that are enabled for the current group.
  List<String> _enabledFeatures = List.of(_defaultEnabledFeatures);

  /// Feature key the group wants shown on launch (may be null → first feature).
  String? _groupDefaultPage;

  /// Whether AI features are enabled for the current group.
  bool _aiEnabled = false;

  // ---------------------------------------------------------------------------
  // Init / dispose
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _testUserLoggedIn();
  }

  @override
  void dispose() {
    _groupListener?.cancel();
    _groupDocListener?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Auth check
  // ---------------------------------------------------------------------------

  Future<void> _testUserLoggedIn() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final DocumentSnapshot? userDoc = currentUser == null ? null : await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();

    if (currentUser == null || !userDoc!.exists) {
      await Future.delayed(const Duration(milliseconds: 100));
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => WelcomePage(onFinished: _testUserLoggedIn, infoText: ""),
        ),
      );
    } else {
      if (Platform.isAndroid || Platform.isIOS) {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();

        final uid = FirebaseAuth.instance.currentUser!.uid;

        // Listen to the user's invite list
        _groupsStream = db.collection('users').doc(uid).collection("invites").snapshots();
        _groupListener?.cancel();
        _groupListener = _groupsStream!.listen((snapshot) {
          final groups = snapshot.docs;
          acceptedGroups = groups.where((d) => d.data()['status'] == 'accepted').toList();
          pendingGroups = groups.where((d) => d.data()['status'] == 'pending').toList();

          final newGroupId = acceptedGroups!.firstOrNull?.id;

          // Re-subscribe to the group document when the selected group changes
          if (_selectedGroup != newGroupId) {
            _selectedGroup = newGroupId;
            _subscribeToGroupDoc(_selectedGroup);
          } else if (!acceptedGroups!.any((e) => e.id == _selectedGroup)) {
            _selectedGroup = newGroupId;
            _subscribeToGroupDoc(_selectedGroup);
          }

          setState(() {});
        });

        // Update user record
        await db.collection('users').doc(uid).update({'lastLogin': FieldValue.serverTimestamp(), 'appVersion': packageInfo.version}).catchError((
          error,
        ) {
          if (kDebugMode) print("Failed to update user: $error");
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Group document listener (features + defaultPage)
  // ---------------------------------------------------------------------------

  void _subscribeToGroupDoc(String? groupId) {
    _groupDocListener?.cancel();
    _groupDocListener = null;

    if (groupId == null) return;

    _groupDocListener = db.collection('groups').doc(groupId).snapshots().listen((snapshot) {
      if (!snapshot.exists) return;

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
        _enabledFeatures = enabled;
        _groupDefaultPage = defaultPage;
        _aiEnabled = aiEnabled;

        // Resolve selected index: honour group preference, else keep current
        // feature if it's still available, else fall back to 0.
        _selectedIndex = _resolveSelectedIndex(preferredFeature: _groupDefaultPage, currentFeature: _currentFeatureKey, features: _enabledFeatures);
      });
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
    return _enabledFeatures.map((key) {
      final meta = _featureMeta[key]!;
      return NavigationDestination(icon: Icon(meta.icon), label: meta.label);
    }).toList();
  }

  Widget _buildPage(String featureKey, {required bool shoppingListEnabled, required bool aiEnabled}) {
    switch (featureKey) {
      case 'shopping_list':
        return ShoppingListPage(groupId: _selectedGroup!);
      case 'recipes':
        return RecipePage(groupId: _selectedGroup!, shoppingListEnabled: shoppingListEnabled, aiEnabled: _aiEnabled);
      case 'todos':
        // Replace with your real TodosPage when ready
        return const _PlaceholderPage(label: 'To-Do\'s');
      case 'calendar':
        // Replace with your real CalendarPage when ready
        return const _PlaceholderPage(label: 'Calendar');
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool groupReady = _selectedGroup != null && _selectedGroup!.isNotEmpty;
    final bool noGroups = acceptedGroups != null && acceptedGroups!.isEmpty;
    final bool shoppingListEnabled = _enabledFeatures.contains('shopping_list');

    return Scaffold(
      appBar: AppBar(surfaceTintColor: Colors.transparent, backgroundColor: Colors.transparent),
      bottomNavigationBar: groupReady
          ? NavigationBar(
              height: 60,
              destinations: _buildDestinations(),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (int index) {
                setState(() => _selectedIndex = index);
              },
            )
          : null,
      body: groupReady
          ? IndexedStack(
              index: _selectedIndex,
              children: _enabledFeatures.map((key) => _buildPage(key, shoppingListEnabled: shoppingListEnabled, aiEnabled: _aiEnabled)).toList(),
            )
          : noGroups
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(64.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.group_off, size: 32),
                    SizedBox(height: 16),
                    Text(
                      'You are not a member of any groups yet. Ask Jacob to invite you!',
                      style: TextStyle(fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : const Center(child: CupertinoActivityIndicator()),
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
