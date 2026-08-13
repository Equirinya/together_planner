import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Fallback store links, used when `config/app` doesn't override them.
const String _kIosAppId = '6758244336';
const String _kAndroidPackage = 'de.equirinya.couple_planner';

/// Compares two dot-separated version strings numerically.
///
/// Returns a negative number when [a] is older than [b], 0 when they are
/// equivalent, positive when [a] is newer. A trailing build number ("1.2.7+42")
/// is ignored, missing components count as 0 ("1.2" == "1.2.0"), and
/// non-numeric junk is treated as 0 rather than throwing — a malformed value in
/// Firestore must never be able to hard-lock the app.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .trim()
      .split('.')
      .map((p) => int.tryParse(RegExp(r'\d+').firstMatch(p)?.group(0) ?? '') ?? 0)
      .toList();

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Blocks the app behind a mandatory-update screen when the installed version is
/// older than `config/app.minRequiredVersion`.
///
/// Best-effort by design: while the version is unknown, the document is missing,
/// the field is absent, or the read fails, [child] is shown untouched. Only a
/// successfully read value that is strictly newer than the installed version
/// gates the app. The listener stays live, so raising the minimum while someone
/// has the app open locks it on the spot; lowering it releases them again.
class VersionGate extends StatefulWidget {
  const VersionGate({super.key, required this.child});

  final Widget child;

  @override
  State<VersionGate> createState() => _VersionGateState();
}

class _VersionGateState extends State<VersionGate> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _configSub;

  String? _installedVersion;
  String? _minRequiredVersion;
  String? _storeUrlOverride;

  @override
  void initState() {
    super.initState();
    _loadInstalledVersion();
    _watchConfig();
  }

  Future<void> _loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _installedVersion = info.version);
    } catch (error) {
      if (kDebugMode) print('Version gate: failed to read package info: $error');
    }
  }

  void _watchConfig() {
    _configSub = FirebaseFirestore.instance
        .collection('config')
        .doc('app')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final data = snapshot.data() ?? const <String, dynamic>{};
      final min = data['minRequiredVersion'];
      final url = Platform.isIOS ? data['iosStoreUrl'] : data['androidStoreUrl'];
      setState(() {
        _minRequiredVersion = min is String && min.trim().isNotEmpty ? min : null;
        _storeUrlOverride = url is String && url.trim().isNotEmpty ? url : null;
      });
    }, onError: (Object error) {
      // Unreadable config must not lock anyone out.
      if (kDebugMode) print('Version gate: config read failed: $error');
    });
  }

  @override
  void dispose() {
    _configSub?.cancel();
    super.dispose();
  }

  /// True only when both versions are known and the installed one is older.
  bool get _updateRequired {
    final installed = _installedVersion;
    final min = _minRequiredVersion;
    if (installed == null || min == null) return false;
    return compareVersions(installed, min) < 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!_updateRequired) return widget.child;
    return UpdateRequiredPage(
      installedVersion: _installedVersion,
      requiredVersion: _minRequiredVersion,
      storeUrl: _storeUrlOverride,
    );
  }
}

/// Full-screen, non-dismissible "please update" screen with a button into the
/// platform's app store.
class UpdateRequiredPage extends StatelessWidget {
  const UpdateRequiredPage({
    super.key,
    this.installedVersion,
    this.requiredVersion,
    this.storeUrl,
  });

  final String? installedVersion;
  final String? requiredVersion;

  /// Server-provided store link; falls back to the platform default below.
  final String? storeUrl;

  String get _resolvedStoreUrl {
    final override = storeUrl;
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isIOS) return 'https://apps.apple.com/app/id$_kIosAppId';
    return 'https://play.google.com/store/apps/details?id=$_kAndroidPackage';
  }

  Future<void> _openStore(BuildContext context) async {
    final uri = Uri.parse(_resolvedStoreUrl);
    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text("Couldn't open the store")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final storeName = Platform.isIOS ? 'App Store' : 'Play Store';

    // Back must not escape the gate — on Android it would otherwise pop straight
    // out of the screen and reveal the app underneath.
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.system_update, size: 56, color: scheme.primary),
                  const SizedBox(height: 24),
                  Text(
                    'Update required',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This version of the app is no longer supported. '
                    'Please update to continue.',
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (installedVersion != null && requiredVersion != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Installed $installedVersion · required $requiredVersion',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: () => _openStore(context),
                    icon: const Icon(Icons.open_in_new),
                    label: Text('Open $storeName'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(220, 52),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
