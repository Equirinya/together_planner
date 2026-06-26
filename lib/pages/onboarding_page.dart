import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../dietary_preferences.dart';
import '../firebase_options.dart';
import 'login_page.dart';

// Hosted on GitHub Pages (see /docs). jekyll-relative-links serves these as .html.
const String _termsUrl = 'https://equirinya.github.io/together_planner/terms.html';
const String _privacyUrl = 'https://equirinya.github.io/together_planner/privacy.html';

/// Canonical feature list for onboarding. `implemented == false` features are
/// shown as "coming soon": greyed out and not selectable. Keys match
/// `enabledFeatures` in the group document and the feature registry in main.dart.
const List<FeatureSpec> kOnboardingFeatures = [
  FeatureSpec('shopping_list', Icons.shopping_bag, 'Shopping List', true),
  FeatureSpec('recipes', Icons.restaurant_menu, 'Recipes', true),
  FeatureSpec('todos', Icons.checklist, "To-Do's", false),
  FeatureSpec('calendar', Icons.calendar_month, 'Calendar', false),
  FeatureSpec('money', Icons.account_balance_wallet, 'Money Splitting', false),
];

class FeatureSpec {
  const FeatureSpec(this.key, this.icon, this.label, this.implemented);

  final String key;
  final IconData icon;
  final String label;
  final bool implemented;
}

const Map<String, String> _featureBlurbs = {
  'shopping_list': 'Shared lists that stay in sync for everyone.',
  'recipes': 'Collect recipes and plan meals together.',
  'todos': 'Split chores and tasks with your group.',
  'calendar': 'Keep shared events in one place.',
  'money': 'Track and split shared expenses.',
};

enum _Step { showcase, login, details, createGroup, register }

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.onFinished, this.joinMode = false});

  final VoidCallback onFinished;

  /// When true the user arrived via an invite link: skip group creation and
  /// just collect a name + account. The host opens the join screen afterwards.
  final bool joinMode;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  _Step step = _Step.showcase;

  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _groupCtrl = TextEditingController();
  final GlobalKey _nameFieldKey = GlobalKey();
  bool _groupEdited = false;

  final Set<String> _selected = {};
  final List<String> _dietary = [];
  bool _joinOnly = false;

  Timer? _dietaryTimer;
  bool _showDietary = false;

  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _pass2Ctrl = TextEditingController();
  final FocusNode _emailNode = FocusNode();
  final FocusNode _passNode = FocusNode();
  final FocusNode _pass2Node = FocusNode();
  bool _passVisible = false;

  bool _loading = false;
  String? _error;
  StreamSubscription<User?>? _authSub;

  bool get _joinMode => widget.joinMode;

  @override
  void initState() {
    super.initState();
    if (widget.joinMode) _joinOnly = true; // arriving via invite: no group creation
    _usernameCtrl.addListener(_onUsernameChanged);
    for (final c in [_emailCtrl, _passCtrl, _pass2Ctrl]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _dietaryTimer?.cancel();
    _usernameCtrl.dispose();
    _groupCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _pass2Ctrl.dispose();
    _emailNode.dispose();
    _passNode.dispose();
    _pass2Node.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    var text = _usernameCtrl.text;
    if (text.length > 127) {
      text = text.substring(0, 127);
      _usernameCtrl.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }
    if (!_groupEdited) {
      final base = text.trim();
      _groupCtrl.text = base.isEmpty ? '' : "$base's Group";
    }
    _dietaryTimer?.cancel();
    if (text.trim().isEmpty) {
      _showDietary = false;
    } else {
      _dietaryTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => _showDietary = true);
      });
    }
    if (mounted) setState(() {});
  }

  // ── navigation ─────────────────────────────────────────────────────────────

  void _goLogin() {
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (FirebaseAuth.instance.currentUser != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('userCreated', true);
        _authSub?.cancel();
        _finish();
      }
    });
    setState(() => step = _Step.login);
  }

  void _back() {
    _authSub?.cancel();
    setState(() {
      _error = null;
      switch (step) {
        case _Step.login:
        case _Step.details:
          step = _Step.showcase;
          break;
        case _Step.createGroup:
          step = _Step.details;
          break;
        case _Step.register:
          step = _joinOnly ? _Step.details : _Step.createGroup;
          break;
        case _Step.showcase:
          break;
      }
    });
  }

  void _forward() {
    if (step == _Step.details && _joinMode && _detailsValid) {
      setState(() => step = _Step.register);
    } else if (step == _Step.createGroup && _createGroupValid) {
      setState(() => step = _Step.register);
    } else if (step == _Step.register && _registerValid) {
      _finishRegistration();
    }
  }

  void _finish() {
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onFinished();
  }

  // ── validation ───────────────────────────────────────────────────────────--

  bool get _detailsValid => _usernameCtrl.text.trim().length >= 3;

  bool get _createGroupValid => _selected.isNotEmpty;

  List<(String, bool)> get _passwordChecks {
    final p = _passCtrl.text;
    return [
      ('At least 8 characters', p.length >= 8),
      ('An uppercase letter', p.contains(RegExp(r'[A-Z]'))),
      ('A lowercase letter', p.contains(RegExp(r'[a-z]'))),
      ('A number', p.contains(RegExp(r'[0-9]'))),
    ];
  }

  bool get _registerValid {
    final email = _emailCtrl.text.trim();
    return email.contains('@') &&
        email.contains('.') &&
        _passwordChecks.every((c) => c.$2) &&
        _passCtrl.text == _pass2Ctrl.text;
  }

  // ── account / group creation ─────────────────────────────────────────────--

  Future<void> _finishRegistration() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await _createEverything();
    if (err != null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = err;
        });
      }
      return;
    }
    TextInput.finishAutofillContext();
    if (_joinOnly && !_joinMode) await _showInviteInfo();
    _finish();
  }

  Future<void> _showInviteInfo() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Almost there!'),
        content: const Text(
          'To join a group, one of your friends has to invite you. '
              'Ask them to send you an invite link, then open it to join their group.',
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Got it')),
        ],
      ),
    );
  }

  Future<String?> _createEverything() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }

    final auth = FirebaseAuth.instance;
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text;

    try {
      await auth.createUserWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'weak-password':
          return 'That password is too weak.';
        case 'email-already-in-use':
          return 'An account with this email already exists.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'network-request-failed':
          return "You're not connected to the internet.";
        default:
          return 'Sign up failed. Please try again.';
      }
    } catch (_) {
      return 'An unknown error occurred.';
    }

    // Wait for the auth user to be available before writing Firestore docs.
    var uid = auth.currentUser?.uid;
    var tries = 0;
    while (uid == null && tries < 40) {
      await Future.delayed(const Duration(milliseconds: 100));
      uid = auth.currentUser?.uid;
      tries++;
    }
    if (uid == null) return 'Could not complete sign up. Please try again.';

    final db = FirebaseFirestore.instance;
    final username = _usernameCtrl.text.trim();

    // Name is display-only now: no usernames directory claim, no uniqueness.
    final userDoc = <String, dynamic>{
      'username': username,
      'createdAt': FieldValue.serverTimestamp(),
      'lastLogin': FieldValue.serverTimestamp(),
    };
    if (_dietary.isNotEmpty) userDoc['dietaryPreferences'] = _dietary;
    db.collection('users').doc(uid).set(userDoc);
    db.collection('users_public').doc(uid).set({
      'username': username,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    String? groupId;
    if (!_joinOnly) {
      final ordered = kOnboardingFeatures.where((f) => _selected.contains(f.key)).map((f) => f.key).toList();
      final groupName = _groupCtrl.text.trim().isEmpty ? "$username's Group" : _groupCtrl.text.trim();
      final groupRef = db.collection('groups').doc();
      groupId = groupRef.id;
      groupRef.set({
        'name': groupName,
        'enabledFeatures': ordered,
        'defaultPage': ordered.first,
      });
      groupRef.collection('members').doc(uid).set({
        'role': 'admin',
        'joinedAt': FieldValue.serverTimestamp(),
        'lastActive': FieldValue.serverTimestamp(),
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('userCreated', true);
    if (groupId != null) {
      await prefs.setString('selected_group', groupId);
    }
    return null;
  }

  Future<void> _openLink(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return PopScope(
      canPop: step == _Step.showcase,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: Theme(
          data: onboardingTheme(),
          child: Stack(
            children: [
              SizedBox(width: size.width, height: size.height, child: animatedBackground()),
              Container(width: size.width, height: size.height, color: Colors.black.withAlpha(50)),
              SafeArea(
                child: Column(
                  children: [
                    if (!(step == _Step.details && !_joinMode)) _logo(context),
                    Expanded(child: _content()),
                    _bottomBar(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logo(BuildContext context) {
    final smaller = min(MediaQuery.of(context).size.width, MediaQuery.of(context).size.height);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: smaller / 7,
            width: smaller / 7,
            child: Image.asset("assets/icon/icon_transparent.png"),
          ),
          Text(
            "Together Planner",
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    switch (step) {
      case _Step.showcase:
        return _ShowcasePage(onLogin: _goLogin, onStart: () => setState(() => step = _Step.details), joinMode: _joinMode);
      case _Step.login:
        return const SingleChildScrollView(padding: EdgeInsets.symmetric(vertical: 16), child: LoginPage());
      case _Step.details:
        return _detailsPage();
      case _Step.createGroup:
        return _createGroupPage();
      case _Step.register:
        return _registerPage();
    }
  }

  Widget _detailsPage() {
    if (_joinMode) {
      // Invite flow: only a display name is needed before signing up; the group
      // already exists, so no group creation is shown.
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose the name the others in the group will see:',
              style: TextStyle(color: Colors.black87, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameCtrl,
              enabled: !_loading,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.person_outline),
                labelText: 'Your name',
              ),
            ),
          ],
        ),
      );
    }
    final showRest = _showDietary && _usernameCtrl.text.trim().isNotEmpty;
    final nameField = Padding(
      key: _nameFieldKey,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: TextField(
        controller: _usernameCtrl,
        enabled: !_loading,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {
          _dietaryTimer?.cancel();
          if (_usernameCtrl.text.trim().isNotEmpty) setState(() => _showDietary = true);
        },
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.person_outline),
          labelText: 'Your name',
          hintText: 'The name others will see',
        ),
      ),
    );
    final dietarySection = Column(
      key: const ValueKey('dietary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: const Text(
            'Any dietary preferences? (optional)',
            style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: DietaryPreferencesSelector(
            value: _dietary,
            onChanged: (v) => setState(() {
              _dietary
                ..clear()
                ..addAll(v);
            }),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _logo(context),
                const SizedBox(height: 24),
                nameField,
                AnimatedSize(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    switchInCurve: Curves.easeOut,
                    child: showRest ? dietarySection : const SizedBox(width: double.infinity),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _createGroupPage() {
    const minBubbleHeight = 300.0;
    final header = [
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: const Text(
          "You can later create more groups — with friends, family or anyone else. "
              "But let's start with your first one:",
          style: TextStyle(color: Colors.black87, fontSize: 14),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: TextField(
          controller: _groupCtrl,
          enabled: !_loading,
          onChanged: (_) {
            if (!_groupEdited) setState(() => _groupEdited = true);
          },
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.group_outlined),
            labelText: 'Group name',
          ),
        ),
      ),
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: const Text(
          'Which features would you like to use with this group?',
          style: TextStyle(color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 8),
    ];
    // Approximate height of the header widgets above the bubble field, used to
    // size the field so it fills the remaining space without an Expanded (which
    // can't live inside the scroll view).
    const headerHeight = 190.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bubbleHeight = max(minBubbleHeight, constraints.maxHeight - headerHeight);
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...header,
              FeatureBubbleField(
                height: bubbleHeight,
                features: kOnboardingFeatures,
                selected: _selected,
                onToggle: (key) => setState(() {
                  if (_selected.contains(key)) {
                    _selected.remove(key);
                  } else {
                    _selected.add(key);
                  }
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _registerPage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
              child: AutofillGroup(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _emailCtrl,
                      focusNode: _emailNode,
                      enabled: !_loading,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username, AutofillHints.email],
                      onSubmitted: (_) => _passNode.requestFocus(),
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.email_outlined), labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passCtrl,
                      focusNode: _passNode,
                      enabled: !_loading,
                      obscureText: !_passVisible,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _pass2Node.requestFocus(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline),
                        labelText: 'Password',
                        suffixIcon: ExcludeFocus(
                          child: IconButton(
                            icon: Icon(_passVisible ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _passVisible = !_passVisible),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._passwordChecks.map((c) => _criterionRow(c.$1, c.$2)),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass2Ctrl,
                      focusNode: _pass2Node,
                      enabled: !_loading,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) {
                        if (_registerValid) _finishRegistration();
                      },
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.lock_outline), labelText: 'Confirm password'),
                    ),
                    if (_pass2Ctrl.text.isNotEmpty && _pass2Ctrl.text != _passCtrl.text)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text("Passwords don't match.", style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    const SizedBox(height: 16),
                    _termsText(),
                    if (_error != null && _error!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _criterionRow(String label, bool met) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: met ? const Color(0xFF1B9E3E) : Colors.black45,
          ),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: met ? const Color(0xFF1B9E3E) : Colors.black54, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _termsText() {
    final base = const TextStyle(color: Colors.black87, fontSize: 13);
    final link = const TextStyle(color: Color(0xFF0A6CD6), fontSize: 13, decoration: TextDecoration.underline);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          const TextSpan(text: 'By signing up to Together Planner you agree to the '),
          TextSpan(text: 'Terms & Conditions', style: link, recognizer: TapGestureRecognizer()..onTap = () => _openLink(_termsUrl)),
          const TextSpan(text: ' and the '),
          TextSpan(text: 'Privacy Policy', style: link, recognizer: TapGestureRecognizer()..onTap = () => _openLink(_privacyUrl)),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _bottomBar() {
    if (step == _Step.showcase) return const SizedBox(height: 8);

    if (step == _Step.details && !_joinMode) {
      final enabled = _detailsValid && _showDietary && !_loading;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: _loading ? null : _back,
              icon: const Icon(Icons.arrow_back, color: Colors.black),
              tooltip: 'Back',
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled
                    ? () => setState(() {
                  _joinOnly = true;
                  step = _Step.register;
                })
                    : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  foregroundColor: Colors.black,
                ).copyWith(
                  side: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.disabled)
                        ? BorderSide(color: Colors.black.withOpacity(0.12))
                        : const BorderSide(color: Colors.black),
                  ),
                ),
                icon: const Icon(Icons.login),
                label: const Text('Join group'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled
                    ? () => setState(() {
                  _joinOnly = false;
                  step = _Step.createGroup;
                })
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('New group'),
              ),
            ),
          ],
        ),
      );
    }

    if (step == _Step.createGroup) {
      final enabled = _createGroupValid && !_loading;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: _loading ? null : _back,
              icon: const Icon(Icons.arrow_back, color: Colors.black),
              tooltip: 'Back',
            ),
            Expanded(
              child: FilledButton(
                onPressed: enabled
                    ? () => setState(() => step = _Step.register)
                    : null,
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      );
    }

    if (step == _Step.register) {
      final enabled = _registerValid && !_loading;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: _loading ? null : _back,
              icon: const Icon(Icons.arrow_back, color: Colors.black),
              tooltip: 'Back',
            ),
            Expanded(
              child: FilledButton(
                onPressed: enabled ? _finishRegistration : null,
                child: _loading ? const CupertinoActivityIndicator() : const Text('Register'),
              ),
            ),
          ],
        ),
      );
    }

    final forwardVisible = (step == _Step.details && _joinMode && _detailsValid) ||
        (step == _Step.register && _registerValid);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: [
          IconButton(
            onPressed: _loading ? null : _back,
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            tooltip: 'Back',
          ),
          const Spacer(),
          SizedBox(
            width: 48,
            height: 48,
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : AnimatedOpacity(
              opacity: forwardVisible ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: IconButton(
                onPressed: forwardVisible ? _forward : null,
                icon: const Icon(Icons.arrow_forward, color: Colors.black),
                tooltip: 'Continue',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

ThemeData onboardingTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.white,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      brightness: Brightness.light,
    ).copyWith(
      onSurfaceVariant: Colors.black,
      onSurface: Colors.black,
      secondary: Colors.black,
      outline: Colors.black,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      fillColor: Colors.white.withAlpha(230),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Showcase page: large feature pills + the two entry buttons.
// ───────────────────────────────────────────────────────────────────────────

class _ShowcasePage extends StatelessWidget {
  const _ShowcasePage({required this.onLogin, required this.onStart, this.joinMode = false});

  final VoidCallback onLogin;
  final VoidCallback onStart;
  final bool joinMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (joinMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              "You've been invited to a group — create an account or sign in to join.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black87, fontSize: 14),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            children: [
              for (final f in kOnboardingFeatures) _FeaturePill(feature: f),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
          child: Column(
            children: [
              FilledButton(onPressed: onStart, child: Text(joinMode ? 'Create an account to join' : "Let's plan together")),
              const SizedBox(height: 8),
              TextButton(onPressed: onLogin, child: const Text('I already have an account')),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({required this.feature});

  final FeatureSpec feature;

  @override
  Widget build(BuildContext context) {
    final blurb = _featureBlurbs[feature.key] ?? '';
    final enabled = feature.implemented;
    final iconColor = enabled ? Colors.black87 : Colors.black38;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(enabled ? 0.28 : 0.16),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withOpacity(0.4), width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: Colors.black.withOpacity(enabled ? 0.06 : 0.04), shape: BoxShape.circle),
                  child: Icon(feature.icon, color: iconColor, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              feature.label,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: enabled ? Colors.black : Colors.black54,
                              ),
                            ),
                          ),
                          if (!enabled) ...[
                            const SizedBox(width: 8),
                            _comingSoonChip(),
                          ],
                        ],
                      ),
                      if (blurb.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(blurb, style: TextStyle(fontSize: 13, color: enabled ? Colors.black54 : Colors.black38)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _comingSoonChip() {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8)),
    child: const Text('coming soon', style: TextStyle(fontSize: 11, color: Colors.black54)),
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Floating glassy feature bubbles.
//
// Bubbles launch upward with momentum, then a simple physics loop takes over:
// gravity ramps in from the accelerometer so the bubbles drift toward the
// direction the phone is tilted, settling and bouncing inside the field.
// ───────────────────────────────────────────────────────────────────────────

class FeatureBubbleField extends StatefulWidget {
  const FeatureBubbleField({
    super.key,
    required this.features,
    required this.selected,
    required this.onToggle,
    this.height = 450,
  });

  final List<FeatureSpec> features;
  final Set<String> selected;
  final void Function(String key) onToggle;
  final double? height;

  @override
  State<FeatureBubbleField> createState() => _FeatureBubbleFieldState();
}

class _Bubble {
  _Bubble(this.spec, this.pos, this.vel, this.radius);

  final FeatureSpec spec;
  Offset pos;
  Offset vel;
  double radius;
}

class _FeatureBubbleFieldState extends State<FeatureBubbleField> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  StreamSubscription<AccelerometerEvent>? _accSub;

  final List<_Bubble> _bubbles = [];
  Size _size = Size.zero;
  bool _placed = false;
  double _age = 0;
  Duration _last = Duration.zero;

  // Smoothed accelerometer reading. Upright at rest: (0, 9.8, 0).
  double _ax = 0;
  double _ay = 9.8;

  final _rng = Random();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _ticker = createTicker(_onTick)..start();
    try {
      _accSub = accelerometerEventStream().listen(
            (e) {
          // low-pass filter to keep motion smooth
          _ax = _ax * 0.2 + e.x * 0.8;
          _ay = _ay * 0.2 + e.y * 0.8;
        },
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _ticker.dispose();
    _accSub?.cancel();
    super.dispose();
  }

  void _place() {
    _bubbles.clear();
    final w = _size.width;
    final h = _size.height;
    final r = (min(w / (widget.features.length), h) * 0.42).clamp(63.0, 94.0);
    // stagger into two rows so large bubbles don't spawn on top of each other
    final perRow = (widget.features.length / 2).ceil();
    for (var i = 0; i < widget.features.length; i++) {
      final row = i ~/ perRow;
      final colCount = row == 0 ? perRow : widget.features.length - perRow;
      final col = i % perRow;
      final x = (w / (colCount + 1)) * (col + 1);
      final y = r + 4 + row * (r * 2 + 10);
      final vx = (_rng.nextDouble() - 0.5) * 120;
      final vy = 200 + _rng.nextDouble() * 100;
      _bubbles.add(_Bubble(widget.features[i], Offset(x, y), Offset(vx, vy), r));
    }
    _placed = true;
    _age = 0;
  }

  void _onTick(Duration elapsed) {
    if (!_placed || _size == Size.zero) {
      _last = elapsed;
      return;
    }
    var dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    if (dt > 0.05) dt = 0.05;
    _age += dt;

    final w = _size.width;
    final h = _size.height;

    // Gravity in screen space: inverted so bubbles float upward. Ramps in after the initial momentum phase.
    final tilt = ((_age - 0.6) / 0.9).clamp(0.0, 1.0);
    final g = Offset(-_ax, -_ay) * (55.0 * tilt);

    for (final b in _bubbles) {
      var v = b.vel + g * dt;
      v = v * (1 - 3.5 * dt); // damping
      // kill micro-jiggle when nearly settled
      if (v.distance < 2.0) v = Offset.zero;
      var p = b.pos + v * dt;

      // walls
      if (p.dx < b.radius) {
        p = Offset(b.radius, p.dy);
        v = Offset(-v.dx * 0.35, v.dy);
      } else if (p.dx > w - b.radius) {
        p = Offset(w - b.radius, p.dy);
        v = Offset(-v.dx * 0.35, v.dy);
      }
      if (p.dy < b.radius) {
        p = Offset(p.dx, b.radius);
        v = Offset(v.dx, -v.dy * 0.35);
      } else if (p.dy > h - b.radius) {
        p = Offset(p.dx, h - b.radius);
        v = Offset(v.dx, -v.dy * 0.35);
      }

      b.pos = p;
      b.vel = v;
    }

    // separation — three passes; velocity deflection on first pass only
    for (var pass = 0; pass < 3; pass++) {
      for (var i = 0; i < _bubbles.length; i++) {
        for (var j = i + 1; j < _bubbles.length; j++) {
          final a = _bubbles[i];
          final b = _bubbles[j];
          final delta = b.pos - a.pos;
          final dist = delta.distance;
          final minDist = a.radius + b.radius;
          if (dist > 0 && dist < minDist) {
            final push = (minDist - dist) / 2;
            final dir = delta / dist;
            a.pos = a.pos - dir * push;
            b.pos = b.pos + dir * push;
            if (pass == 0) {
              // elastic-ish deflection
              final vRel = b.vel - a.vel;
              final approach = vRel.dx * dir.dx + vRel.dy * dir.dy;
              if (approach < 0) {
                final impulse = dir * (approach * 0.9);
                a.vel = a.vel + impulse;
                b.vel = b.vel - impulse;
              }
            }
          }
        }
      }
      // re-clamp to walls after separation so pushed bubbles can't escape
      for (final b in _bubbles) {
        b.pos = Offset(
          b.pos.dx.clamp(b.radius, w - b.radius),
          b.pos.dy.clamp(b.radius, h - b.radius),
        );
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final inner = LayoutBuilder(
      builder: (context, constraints) {
        final newSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (newSize != _size) {
          _size = newSize;
          if (!_placed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(_place);
            });
          }
        }
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final b in _bubbles)
              Positioned(
                left: b.pos.dx - b.radius,
                top: b.pos.dy - b.radius,
                width: b.radius * 2,
                height: b.radius * 2,
                child: _BubbleWidget(
                  spec: b.spec,
                  selected: widget.selected.contains(b.spec.key),
                  onTap: b.spec.implemented ? () => widget.onToggle(b.spec.key) : null,
                ),
              ),
          ],
        );
      },
    );
    final h = widget.height;
    return h != null ? SizedBox(height: h, child: inner) : inner;
  }
}

class _BubbleWidget extends StatelessWidget {
  const _BubbleWidget({required this.spec, required this.selected, this.onTap});

  final FeatureSpec spec;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = spec.implemented;
    // White glass against the colorful background; selection reads as a more
    // solid, brighter bubble rather than a colour change.
    final whiteTop = enabled ? (selected ? 0.7 : 0.4) : 0.28;
    final whiteBottom = enabled ? (selected ? 0.45 : 0.16) : 0.1;

    return GestureDetector(
      onTap: onTap,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.4, -0.5),
                radius: 1.1,
                colors: [
                  Colors.white.withOpacity(whiteTop),
                  Colors.white.withOpacity(whiteBottom),
                ],
              ),
              border: Border.all(
                color: Colors.white.withOpacity(selected ? 0.95 : 0.55),
                width: selected ? 3 : 1.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(spec.icon, color: enabled ? Colors.white : Colors.white60, size: 46),
                  const SizedBox(height: 4),
                  Flexible(
                    child: Text(
                      spec.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: enabled ? Colors.white : Colors.white60,
                      ),
                    ),
                  ),
                  if (!enabled)
                    const Text('coming soon', style: TextStyle(fontSize: 10, color: Colors.white54)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
