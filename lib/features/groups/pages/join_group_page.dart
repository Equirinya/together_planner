import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/features/groups/invite_links.dart';
import 'package:couple_planner/features/recipes/pages/shared_recipes_page.dart';
import 'package:couple_planner/features/auth/pages/onboarding_page.dart' show kOnboardingFeatures, FeatureSpec;

/// Landing screen shown when a user opens an invite link. It previews the group
/// (name, features, members) without joining, then lets the user join.
class JoinGroupPage extends StatefulWidget {
  const JoinGroupPage({super.key, required this.groupId, required this.inviteId, this.onJoined});

  final String groupId;
  final String inviteId;

  /// Called with the group id after a successful join, so the host can select it.
  final void Function(String groupId)? onJoined;

  @override
  State<JoinGroupPage> createState() => _JoinGroupPageState();
}

class _JoinGroupPageState extends State<JoinGroupPage> {
  Map<String, dynamic>? _preview;
  String? _error;
  bool _loading = true;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await previewInvite(widget.groupId, widget.inviteId);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'This invite link could not be opened.';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong opening this invite.';
        _loading = false;
      });
    }
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await joinGroupViaInvite(widget.groupId, widget.inviteId);
      final isRecipeViewer = _preview?['type'] == 'recipe_viewer';
      if (!mounted) return;
      if (isRecipeViewer) {
        // A recipe viewer never becomes the active group; the group appears in
        // the "groups you can view recipes from" section instead. Open it now.
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => SharedRecipesPage(sourceGroupId: widget.groupId),
        ));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_group', widget.groupId);
      if (!mounted) return;
      widget.onJoined?.call(widget.groupId);
      Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = e.message ?? 'Could not join the group.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Could not join the group.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final showHeroAppBar = _preview != null;
    return Scaffold(
      extendBodyBehindAppBar: showHeroAppBar,
      appBar: showHeroAppBar
          ? AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: Colors.white)
          : AppBar(title: const Text('Join group')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadPreview)
              : _buildPreview(context),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final preview = _preview!;
    final name = (preview['name'] as String?) ?? 'Group';
    final features = ((preview['enabledFeatures'] as List?) ?? const []).map((e) => e.toString()).toList();
    final members = ((preview['members'] as List?) ?? const []).cast<dynamic>();
    final alreadyMember = preview['alreadyMember'] == true;
    final isRecipeViewer = preview['type'] == 'recipe_viewer';

    if (isRecipeViewer) {
      return _buildRecipeViewerPreview(context, name, alreadyMember);
    }

    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        _RecipeCardsBackground(groupId: widget.groupId, rowCount: 2, topFlex: 4, bottomFlex: 1),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.45, 1.0],
              colors: [Color(0xCC000000), Color(0x88000000), Color(0xDD000000)],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.group, size: 64, color: Colors.white),
              const SizedBox(height: 20),
              Text(
                "You've been invited to join",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    if (features.isNotEmpty) ...[
                      Text('Features',
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final key in features)
                            Chip(
                              backgroundColor: Colors.white.withValues(alpha: 0.15),
                              avatar: Icon(_featureFor(key).icon, size: 18, color: Colors.white),
                              label: Text(_featureFor(key).label, style: const TextStyle(color: Colors.white)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                    ],
                    Text('Members (${members.length})',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white70)),
                    const SizedBox(height: 8),
                    for (final m in members)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person)),
                          title: Text((m['username'] ?? 'Member').toString(),
                              style: const TextStyle(color: Colors.white)),
                          trailing: (m['role'] == 'admin')
                              ? const Text('admin', style: TextStyle(color: Colors.white70))
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _joining ? null : _join,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    child: _joining
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(alreadyMember ? 'Open group' : 'Join group'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecipeViewerPreview(BuildContext context, String name, bool alreadyMember) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        _RecipeCardsBackground(groupId: widget.groupId),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.45, 1.0],
              colors: [Color(0xCC000000), Color(0x88000000), Color(0xDD000000)],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.restaurant_menu, size: 64, color: Colors.white),
              const SizedBox(height: 20),
              Text(
                "You've been invited to view recipes from",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _joining ? null : _join,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    child: _joining
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(alreadyMember ? 'Open recipes' : 'View recipes'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  FeatureSpec _featureFor(String key) {
    return kOnboardingFeatures.firstWhere(
      (f) => f.key == key,
      orElse: () => FeatureSpec(key, Icons.widgets, key, true),
    );
  }
}

// ─── Recipe cards animated background ────────────────────────────────────────

class _RecipeCardsBackground extends StatefulWidget {
  const _RecipeCardsBackground({
    required this.groupId,
    this.rowCount = 3,
    this.topFlex = 3,
    this.bottomFlex = 2,
  });

  final String groupId;

  /// How many scrolling rows to show (1-3); fewer rows leave more room for
  /// content shown on top, e.g. the general join page's features/members list.
  final int rowCount;

  /// Relative empty space above/below the rows; raise topFlex to push the rows
  /// further down the screen.
  final int topFlex;
  final int bottomFlex;

  @override
  State<_RecipeCardsBackground> createState() => _RecipeCardsBackgroundState();
}

class _RecipeCardsBackgroundState extends State<_RecipeCardsBackground> {
  List<Map<String, dynamic>> _recipes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .collection('recipes')
          .limit(15)
          .get();
      if (mounted) setState(() => _recipes = snap.docs.map((d) => d.data()).toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Use placeholders until recipes load, so the animation starts immediately.
    final items = _recipes.isEmpty
        ? List.generate(6, (_) => <String, dynamic>{})
        : _recipes;

    // Split into up to 3 rows with different subsets, speeds and vertical offsets.
    final rowRecipes = [
      items,
      [...items.skip(items.length ~/ 3), ...items.take(items.length ~/ 3)],
      [...items.skip(2 * items.length ~/ 3), ...items.take(2 * items.length ~/ 3)],
    ];
    const rowDurations = [22, 30, 25];
    const rowReverse = [false, true, false];
    final rowCount = widget.rowCount.clamp(1, 3);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Spacer(flex: widget.topFlex),
        for (var i = 0; i < rowCount; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _RecipeScrollRow(
            recipes: rowRecipes[i],
            cardWidth: 120,
            cardHeight: 90,
            durationSeconds: rowDurations[i],
            reverse: rowReverse[i],
          ),
        ],
        Spacer(flex: widget.bottomFlex),
      ],
    );
  }
}

class _RecipeScrollRow extends StatefulWidget {
  const _RecipeScrollRow({
    required this.recipes,
    required this.cardWidth,
    required this.cardHeight,
    required this.durationSeconds,
    this.reverse = false,
  });

  final List<Map<String, dynamic>> recipes;
  final double cardWidth;
  final double cardHeight;
  final int durationSeconds;
  final bool reverse;

  @override
  State<_RecipeScrollRow> createState() => _RecipeScrollRowState();
}

class _RecipeScrollRowState extends State<_RecipeScrollRow> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.durationSeconds),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gap = 10.0;
    final itemWidth = widget.cardWidth + gap;
    // Duplicate list for seamless loop.
    final items = [...widget.recipes, ...widget.recipes];
    final totalWidth = itemWidth * widget.recipes.length;

    return SizedBox(
      height: widget.cardHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final offset = widget.reverse
              ? (_controller.value * totalWidth) % totalWidth
              : (totalWidth - _controller.value * totalWidth) % totalWidth;
          return OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(-offset, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final data in items)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _RecipeThumb(data: data, width: widget.cardWidth, height: widget.cardHeight),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RecipeThumb extends StatelessWidget {
  const _RecipeThumb({required this.data, required this.width, required this.height});

  final Map<String, dynamic> data;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final images = List<String>.from(data['images'] ?? []);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: width,
        height: height,
        child: images.isNotEmpty
            ? StorageImage(storagePath: images.first, fit: BoxFit.cover)
            : const ColoredBox(
                color: Color(0x44FFFFFF),
                child: Center(child: Icon(Icons.restaurant_menu, color: Colors.white54)),
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 40),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
