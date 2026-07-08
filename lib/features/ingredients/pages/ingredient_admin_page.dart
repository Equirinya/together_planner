import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/models/categories.dart' show kCategories;
import 'package:couple_planner/features/ingredients/services/units_cache.dart' show UnitsCache;
import 'package:couple_planner/features/ingredients/widgets/avatar.dart' show Avatar;

DocumentReference<Map<String, dynamic>> _ingRef(String id) =>
    FirebaseFirestore.instance.collection('ingredients').doc(id);

Future<bool> _confirmDelete(BuildContext context, String id) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Delete ingredient?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await _ingRef(id).delete();
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    return false;
  }
}

Future<void> _regenerateIcon(BuildContext context, String id) async {
  try {
    await _ingRef(id).update({'avatarVersion': 0}); // shows the loading spinner until the new icon lands
    await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('ingredientsIcon-regenerateIcon')
        .call({'ingredientId': id});
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Icon regenerating…')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
  }
}

class IngredientAdminPage extends StatefulWidget {
  const IngredientAdminPage({super.key});

  @override
  State<IngredientAdminPage> createState() => _IngredientAdminPageState();
}

class _IngredientAdminPageState extends State<IngredientAdminPage> {
  static const _pageSize = 30;

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _loading = false;
  bool _hasMore = true;
  bool _loadingAll = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    var query = FirebaseFirestore.instance
        .collection('ingredients')
        .orderBy('createdAt', descending: true)
        .limit(_pageSize);
    if (_lastDoc != null) query = query.startAfterDocument(_lastDoc!);
    final snap = await query.get();
    if (!mounted) return;
    setState(() {
      _docs.addAll(snap.docs);
      if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
      _hasMore = snap.docs.length == _pageSize;
      _loading = false;
    });
  }

  /// Search only matches what's already loaded, so pull in every remaining
  /// page once the user starts typing.
  Future<void> _loadAll() async {
    if (_loadingAll) return;
    _loadingAll = true;
    try {
      while (_hasMore) {
        await _loadMore();
      }
    } finally {
      _loadingAll = false;
    }
  }

  String _nameFor(QueryDocumentSnapshot<Map<String, dynamic>> d) =>
      (d.data()['name'] as Map?)?.values.firstOrNull?.toString() ?? d.id;

  @override
  Widget build(BuildContext context) {
    final filteredDocs = _query.isEmpty
        ? _docs
        : _docs.where((d) => _nameFor(d).toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Ingredients')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) {
                setState(() => _query = v);
                if (v.isNotEmpty) _loadAll();
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: filteredDocs.length + (_query.isEmpty && _hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= filteredDocs.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final d = filteredDocs[i];
                final name = _nameFor(d);
                final category = (d.data()['category'] ?? '').toString();
                return ListTile(
                  leading: Avatar(ingredientId: d.id),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: category.isEmpty
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 9,
                              child: StorageImage(
                                storagePath: 'categories/$category.png',
                                fit: BoxFit.contain,
                                memCacheWidth: 64,
                                memCacheHeight: 64,
                                errorWidget: const SizedBox.shrink(),
                                placeholder: const SizedBox.shrink(),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(child: Text(category, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(icon: const Icon(Icons.refresh), onPressed: () => _regenerateIcon(context, d.id)),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          final deleted = await _confirmDelete(context, d.id);
                          if (deleted && mounted) setState(() => _docs.removeWhere((doc) => doc.id == d.id));
                        },
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => IngredientEditPage(id: d.id)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class IngredientEditPage extends StatefulWidget {
  const IngredientEditPage({super.key, required this.id});

  final String id;

  @override
  State<IngredientEditPage> createState() => _IngredientEditPageState();
}

class _IngredientEditPageState extends State<IngredientEditPage> {
  final Map<String, TextEditingController> _nameCtrls = {};
  final Map<String, TextEditingController> _synCtrls = {};
  String? _category;
  String? _defaultUnit;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    UnitsCache.instance.ensureLoaded();
    _load();
  }

  @override
  void dispose() {
    for (final c in [..._nameCtrls.values, ..._synCtrls.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final data = (await _ingRef(widget.id).get()).data() ?? {};
    final names = Map<String, dynamic>.from(data['name'] ?? {});
    final syns = Map<String, dynamic>.from(data['synonyms'] ?? {});
    for (final lang in {...names.keys, ...syns.keys}) {
      _nameCtrls[lang] = TextEditingController(text: (names[lang] ?? '').toString());
      _synCtrls[lang] = TextEditingController(text: (syns[lang] as List? ?? []).join(', '));
    }
    _category = data['category'] as String?;
    _defaultUnit = data['defaultUnit'] as String?;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = <String, String>{};
    final synonyms = <String, List<String>>{};
    for (final lang in _nameCtrls.keys) {
      final n = _nameCtrls[lang]!.text.trim();
      if (n.isNotEmpty) name[lang] = n;
      final s = _synCtrls[lang]!.text
          .split(',')
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
      if (s.isNotEmpty) synonyms[lang] = s;
    }
    try {
      await _ingRef(widget.id).update({
        'name': name,
        'synonyms': synonyms,
        'category': _category,
        'defaultUnit': _defaultUnit,
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = LanguageService.instance.code.value;
    final units = UnitsCache.instance.all;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit ingredient'),
        actions: [IconButton(onPressed: _save, icon: const Icon(Icons.save))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(child: Avatar(ingredientId: widget.id, radius: 40)),
                const SizedBox(height: 16),
                for (final l in _nameCtrls.keys) ...[
                  TextField(
                    controller: _nameCtrls[l],
                    decoration: InputDecoration(labelText: 'Name (${l.toUpperCase()})'),
                  ),
                  TextField(
                    controller: _synCtrls[l],
                    decoration: InputDecoration(labelText: 'Synonyms (${l.toUpperCase()})'),
                  ),
                  const SizedBox(height: 16),
                ],
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [for (final c in kCategories) DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (v) => setState(() => _category = v),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: units.any((u) => u.id == _defaultUnit) ? _defaultUnit : null,
                  decoration: const InputDecoration(labelText: 'Default unit'),
                  items: [
                    for (final u in units) DropdownMenuItem(value: u.id, child: Text(u.display(lang, 1))),
                  ],
                  onChanged: (v) => setState(() => _defaultUnit = v),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await _confirmDelete(context, widget.id);
                          if (mounted) Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.delete),
                        label: const Text('Delete'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _regenerateIcon(context, widget.id),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Regenerate icon'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
