import 'dart:async';
import 'dart:io';

import 'package:couple_planner/pages/ingredient_search.dart';
import 'package:couple_planner/pages/shopping_list_page.dart' show QuantityEditor, categoryRank;
import 'package:couple_planner/utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

// =============================================================================
// Page
// =============================================================================

class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({
    super.key,
    required this.groupId,
    required this.recipeId,
    this.editMode = false,
    this.aiEnabled = false,
    this.initialData,
  });

  final String groupId;
  final String recipeId;
  final bool editMode;
  final bool aiEnabled;

  /// Already-loaded recipe data, used to paint the page (image, title) right
  /// away during the open transition instead of flashing a loading spinner.
  final Map<String, dynamic>? initialData;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  bool edit = false;

  TextEditingController? nameController;
  TextEditingController? descriptionController;
  List<TextEditingController>? stepsControllers;
  TextEditingController? tagsController;

  Map<String, dynamic>? recipeData;
  late DocumentReference<Map<String, dynamic>> docRef;
  late CollectionReference<Map<String, dynamic>> ingredientsRef;

  late String lang;

  late List<String> images;
  late List<String> steps;
  late List<String> tags;
  String? attribution;
  late int totalHour;
  late int totalMinute;
  late int prepHour;
  late int prepMinute;

  // ── servings / scaling ────────────────────────────────────────────────────
  int servings = 2;
  int? _baseServings;
  bool _autoScale = false;

  // ── ingredients (live stream) ─────────────────────────────────────────────
  List<Map<String, dynamic>> ingredients = [];
  StreamSubscription? _ingredientsSub;

  // ── image carousel ─────────────────────────────────────────────────────────
  final PageController _imageController =
      PageController(viewportFraction: 7 / 9);

  // ── image upload / generation placeholders ────────────────────────────────
  // Each in-flight upload gets a unique key so multiple concurrent uploads
  // each show their own shimmer tile.
  int _uploadingCount = 0;
  bool _generatingImage = false;

  // ── AI state ──────────────────────────────────────────────────────────────
  final Set<String> _enhancing = {};
  bool _loadingIngredients = false;
  bool _loadingSteps = false;

  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

  // ── lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    edit = widget.editMode;
    lang = sanitizeLang(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode);
    UnitsCache.instance.ensureLoaded();

    final db = FirebaseFirestore.instance;
    docRef = db
        .collection('groups')
        .doc(widget.groupId)
        .collection('recipes')
        .doc(widget.recipeId);
    ingredientsRef = docRef.collection('ingredients');

    if (widget.initialData != null) _applyData(widget.initialData!);

    _startIngredientsSubscription();
    _loadRecipe();
  }

  @override
  void dispose() {
    _ingredientsSub?.cancel();
    _imageController.dispose();
    nameController?.dispose();
    descriptionController?.dispose();
    tagsController?.dispose();
    for (final c in stepsControllers ?? const <TextEditingController>[]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── data loading ──────────────────────────────────────────────────────────

  void _applyData(Map<String, dynamic> data) {
    recipeData = data;

    images = List<String>.from(data['images'] ?? []);
    steps = List<String>.from(data['steps'] ?? []);
    if (steps.isEmpty) steps = [''];
    tags = List<String>.from(data['tags'] ?? []);
    attribution = data['attribution']?.toString();
    totalHour = ((data['time'] ?? 0) / 60).floor();
    totalMinute = (data['time'] ?? 0) % 60;
    prepHour = ((data['preparationTime'] ?? 0) / 60).floor();
    prepMinute = (data['preparationTime'] ?? 0) % 60;
    servings = ((data['servings'] ?? 2) as num).toInt().clamp(1, 999);
    _baseServings ??= servings;

    nameController ??= TextEditingController(text: data['name']);
    descriptionController ??=
        TextEditingController(text: data['description']);
    stepsControllers ??=
        steps.map((s) => TextEditingController(text: s)).toList();
    tagsController ??=
        TextEditingController(text: tags.map((e) => '#$e ').join(''));
  }

  Future<void> _loadRecipe() async {
    final doc = await docRef.get();
    if (!doc.exists || !mounted) return;
    setState(() => _applyData(doc.data()!));
  }

  void _startIngredientsSubscription() {
    _ingredientsSub = ingredientsRef.snapshots().listen((snap) {
      if (!mounted) return;
      final list = snap.docs
          .map((d) => <String, dynamic>{...d.data(), 'id': d.id})
          .toList();
      list.sort((a, b) => categoryRank((a['category'] as String?) ?? '')
          .compareTo(categoryRank((b['category'] as String?) ?? '')));
      setState(() => ingredients = list);
      for (final item in list) {
        if (item['ingredientId'] == kPendingIngredient) {
          resolvePendingItem(
            ingredientsRef.doc(item['id'] as String),
            (item['displayName'] ?? '').toString(),
            lang,
          );
        }
      }
    });
  }

  Future<void> _reloadStepsOnly() async {
    final doc = await docRef.get();
    if (!mounted) return;
    steps = List<String>.from(doc.data()?['steps'] ?? []);
    if (steps.isEmpty) steps = [''];
    for (final c in stepsControllers ?? const <TextEditingController>[]) {
      c.dispose();
    }
    stepsControllers =
        steps.map((s) => TextEditingController(text: s)).toList();
    setState(() {});
  }

  // ── servings / scaling ────────────────────────────────────────────────────

  void _changeServings(int newVal) {
    newVal = newVal.clamp(1, 999);
    if (newVal == servings) return;
    setState(() => servings = newVal);
    docRef.update({'servings': newVal});
    if (_autoScale &&
        ingredients.isNotEmpty &&
        _baseServings != null &&
        newVal != _baseServings) {
      _applyScale(newVal);
    }
  }

  Future<void> _applyScale(int target) async {
    final base = _baseServings;
    if (base == null || base == 0) return;
    final factor = target / base;
    final batch = FirebaseFirestore.instance.batch();
    for (final ing in ingredients) {
      final raw = ing['quantity'];
      if (raw == null) continue;
      final q = Map<String, dynamic>.from(raw as Map);
      if (q.isEmpty) continue;
      final scaled =
      q.map((k, v) => MapEntry(k, (v as num).toDouble() * factor));
      batch.update(ingredientsRef.doc(ing['id'] as String), {'quantity': scaled});
    }
    await batch.commit();
    _baseServings = target;
  }

  Future<void> _clearIngredients() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final ing in ingredients) {
      batch.delete(ingredientsRef.doc(ing['id'] as String));
    }
    await batch.commit();
  }

  void _clearSteps() {
    for (final c in stepsControllers ?? const <TextEditingController>[]) {
      c.dispose();
    }
    setState(() {
      steps = [''];
      stepsControllers = [TextEditingController()];
    });
  }

  // ── ingredient mutations ──────────────────────────────────────────────────

  void _addIngredient() {
    IngredientSearchSheet.show(
      context,
      targetRef: ingredientsRef,
      lang: lang,
      hintText: 'Add ingredient…',
    );
  }

  Future<void> _removeIngredient(String docId) =>
      ingredientsRef.doc(docId).delete();

  void _openQuantityEditor(Map<String, dynamic> ing) {
    final q = readQuantity(ing['quantity']);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => QuantityEditor(
        initialUnitId: q?.unitId ?? kDefaultUnitId,
        initialQty: q?.qty ?? 0,
        lang: lang,
        onChanged: (unitId, qty) => ingredientsRef
            .doc(ing['id'] as String)
            .update({'quantity': qty == null ? null : {unitId: qty.toDouble()}}),
      ),
    );
  }

  // ── image upload ──────────────────────────────────────────────────────────

  Future<void> _pickAndUploadImage() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null) return;
    // Show shimmer immediately — before the upload even starts.
    setState(() => _uploadingCount++);
    try {
      final ref = FirebaseStorage.instance.ref().child(
          'groups/${widget.groupId}/recipes/${widget.recipeId}/${DateTime.now().millisecondsSinceEpoch}');
      await ref.putFile(File(image.path));
      await docRef.update({
        'images': FieldValue.arrayUnion([ref.fullPath]),
      });
      await _loadRecipe();
    } finally {
      if (mounted) setState(() => _uploadingCount--);
    }
  }

  // ── AI: image enhance / generate ─────────────────────────────────────────

  bool _isAiImage(String path) => path.split('/').last.startsWith('ai_');

  Map<String, dynamic> _buildRecipeContext() {
    return {
      'name': nameController?.text ?? recipeData?['name'] ?? '',
      'description': descriptionController?.text ?? recipeData?['description'] ?? '',
      'tags': tagsController?.text
          .split('#')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList() ??
          tags,
      'steps': stepsControllers
          ?.map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList() ??
          steps,
      'images': images,
      'servings': servings,
      'ingredients': ingredients
          .map((ing) => {
        'name': ing['displayName'] ?? ing['ingredientId'] ?? '',
        'description': ing['description'] ?? '',
        'quantity': ing['quantity'],
      })
          .toList(),
    };
  }

  Future<void> _enhanceImage(String path) async {
    setState(() => _enhancing.add(path));
    try {
      final res = await _functions.httpsCallable('recipesEnhancement-enhanceRecipeImage').call({
        ..._buildRecipeContext(),
        'groupId': widget.groupId,
        'recipeId': widget.recipeId,
        'imagePath': path,
      });
      final newPath = (res.data as Map)['path'] as String;
      await docRef.update({
        'images': FieldValue.arrayUnion([newPath]),
      });
      await _loadRecipe();
    } catch (e) {
      _snack('Could not enhance image: $e');
    } finally {
      if (mounted) setState(() => _enhancing.remove(path));
    }
  }

  Future<void> _generateImageWithAI() async {
    setState(() => _generatingImage = true);
    try {
      await _functions.httpsCallable('recipesEnhancement-generateRecipeImage').call({
        ..._buildRecipeContext(),
        'groupId': widget.groupId,
        'recipeId': widget.recipeId,
      });
      await _loadRecipe();
    } catch (e) {
      _snack('Could not generate image: $e');
    } finally {
      if (mounted) setState(() => _generatingImage = false);
    }
  }

  // ── AI: ingredients / steps ───────────────────────────────────────────────

  Future<void> _generateIngredients() async {
    setState(() => _loadingIngredients = true);
    try {
      await _functions.httpsCallable('recipesEnhancement-generateRecipeIngredients').call({
        ..._buildRecipeContext(),
        'groupId': widget.groupId,
        'recipeId': widget.recipeId,
      });
    } catch (e) {
      _snack('Could not generate ingredients: $e');
    } finally {
      if (mounted) setState(() => _loadingIngredients = false);
    }
  }

  Future<void> _generateSteps() async {
    setState(() => _loadingSteps = true);
    try {
      await _functions.httpsCallable('recipesEnhancement-generateRecipeSteps').call({
        ..._buildRecipeContext(),
        'groupId': widget.groupId,
        'recipeId': widget.recipeId,
      });
      await _reloadStepsOnly();
    } catch (e) {
      _snack('Could not generate steps: $e');
    } finally {
      if (mounted) setState(() => _loadingSteps = false);
    }
  }

  bool _isRecipeEmpty() {
    final name = nameController?.text.trim() ?? '';
    final desc = descriptionController?.text.trim() ?? '';
    final hasSteps = stepsControllers?.any((c) => c.text.trim().isNotEmpty) ?? false;
    final hasTags = tagsController?.text
            .split('#')
            .map((t) => t.trim())
            .any((t) => t.isNotEmpty) ??
        false;
    return name.isEmpty && desc.isEmpty && !hasSteps && !hasTags && ingredients.isEmpty && images.isEmpty;
  }

  Future<void> _saveAndExit() async {
    var name = nameController!.text.trim();
    if (name.isEmpty) name = 'New Recipe';
    await docRef.update({
      'name': name,
      'description': descriptionController!.text,
      'steps': stepsControllers!
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      'tags': tagsController!.text
          .split('#')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(),
      'servings': servings,
    });
    if (_isRecipeEmpty()) {
      await docRef.delete();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    setState(() {
      edit = false;
      _autoScale = false;
      _baseServings = servings;
    });
    _loadRecipe();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (recipeData == null) {
      return const Scaffold(body: Center(child: CupertinoActivityIndicator()));
    }

    final bool hasIngredients = ingredients.isNotEmpty;
    final bool hasSteps = steps.any((s) => s.isNotEmpty);

    return PopScope(
      canPop: !edit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && edit) {
          _saveAndExit();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: edit
            ? IconButton(
                icon: const Icon(Icons.save),
                onPressed: _saveAndExit,
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                icon: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
                title: const Text("Delete Recipe"),
                content: const Text(
                    "Are you sure you want to delete this recipe? This action cannot be undone."),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text("Cancel")),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(ctx).colorScheme.error),
                    onPressed: () async {
                      await docRef.delete();
                      Navigator.of(ctx).pop();
                      Navigator.of(context).pop();
                    },
                    child: const Text("Delete"),
                  ),
                ],
              ),
            ),
          ),
          if (!edit)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                setState(() {
                  edit = true;
                  _autoScale = false;
                  _baseServings = servings;
                });
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Images ──────────────────────────────────────────────────
            if (edit || images.isNotEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.3,
                child: edit ? _editImageCarousel() : _viewImageCarousel(),
              ),

            const SizedBox(height: 16),

            // ── Title ────────────────────────────────────────────────────
            edit
                ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: nameController,
                style: Theme.of(context).textTheme.headlineMedium,
                decoration: const InputDecoration(hintText: 'Recipe name'),
              ),
            )
                : Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              child: Text(
                recipeData?['name'] ?? 'Unnamed Recipe',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),

            // ── Tags + times ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: edit
                        ? TextField(
                      controller: tagsController,
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: const InputDecoration(hintText: '#tag1 #tag2…'),
                    )
                        : Wrap(
                      spacing: 8,
                      children: tags
                          .map((tag) => Chip(
                        label: Text(tag,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer)),
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        side: BorderSide.none,
                      ))
                          .toList(),
                    ),
                  ),
                  _timeTile(Icons.schedule, totalHour, totalMinute, 'time'),
                  _timeTile(
                      Icons.blender, prepHour, prepMinute, 'preparationTime'),
                ],
              ),
            ),

            if (attribution != null && attribution!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: _AttributionText(attribution!),
              ),

            const SizedBox(height: 20),

            // ── Ingredients + servings (hidden in view mode when empty) ──
            if (edit || hasIngredients) _ingredientsSection(),

            if (edit || hasIngredients) const SizedBox(height: 20),

            // ── Steps (hidden in view mode when empty) ───────────────────
            if (edit || hasSteps) _stepsSection(),

            const SizedBox(height: 32),
          ],
        ),
      ),
      ),
    );
  }

  // ── image carousels ───────────────────────────────────────────────────────
  Widget _viewImageCarousel() {
    final cacheWidth =
        (MediaQuery.of(context).size.width * MediaQuery.of(context).devicePixelRatio)
            .round();
    return PageView.builder(
      controller: _imageController,
      itemCount: images.length,
      itemBuilder: (context, index) => GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                _FullscreenImagePage(paths: images, initialIndex: index),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: StorageImage(
              storagePath: images[index],
              fit: BoxFit.cover,
              memCacheWidth: cacheWidth,
            ),
          ),
        ),
      ),
    );
  }

  Widget _editImageCarousel() {
    return ReorderableListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onReorder: (oldIdx, newIdx) {
        images.insert(
            newIdx > oldIdx ? newIdx - 1 : newIdx, images.removeAt(oldIdx));
        docRef.update({'images': images});
        setState(() {});
      },
      footer: _editImageFooter(),
      children: [
        // Real images
        ...images.map(_editImageTile),
        // One shimmer per in-flight upload
        for (int i = 0; i < _uploadingCount; i++)
          _shimmerImageTile(ValueKey('upload_$i')),
        // One shimmer per in-flight enhance
        for (final path in _enhancing)
          _shimmerImageTile(ValueKey('enhancing_$path')),
        // One shimmer while AI is generating
        if (_generatingImage)
          _shimmerImageTile(const ValueKey('generating')),
      ],
    );
  }

  /// Footer for the edit carousel: "add photo" always, "generate with AI"
  /// below it when aiEnabled. Buttons are stacked vertically and share the
  /// same width as an image tile so the list feels uniform.
  Widget _editImageFooter() {
    final cs = Theme.of(context).colorScheme;
    final tileWidth = MediaQuery.of(context).size.width * 0.4;

    ButtonStyle tileButtonStyle(Color bg) => ElevatedButton.styleFrom(
      elevation: 0,
      backgroundColor: bg,
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      minimumSize: const Size(double.infinity, 0),
      padding: EdgeInsets.zero,
    );

    return SizedBox(
      width: tileWidth,
      height: double.infinity,
      child: Column(
        children: [
          Expanded(
            child: ElevatedButton(
              style: tileButtonStyle(cs.primaryContainer),
              onPressed: _pickAndUploadImage,
              child: const Icon(Icons.add_a_photo),
            ),
          ),
          if (widget.aiEnabled) ...[
            const SizedBox(height: 4),
            Expanded(
              child: ElevatedButton(
                style: tileButtonStyle(cs.secondaryContainer),
                onPressed:
                _generatingImage ? null : _generateImageWithAI,
                child: Icon(Icons.auto_awesome,
                    color: _generatingImage
                        ? cs.onSurface.withOpacity(0.38)
                        : null),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── ingredients section ───────────────────────────────────────────────────

  Widget _ingredientsSection() {
    final cs = Theme.of(context).colorScheme;
    final showScaleButton = edit &&
        !_autoScale &&
        _baseServings != null &&
        servings != _baseServings &&
        ingredients.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text("Ingredients",
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              const Spacer(),
              if (edit && widget.aiEnabled && !_loadingIngredients)
                IconButton(
                  icon: const Icon(Icons.auto_awesome),
                  tooltip: 'Generate with AI',
                  onPressed: _generateIngredients,
                ),
              if (edit && ingredients.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: 'Clear all',
                  onPressed: _clearIngredients,
                ),
            ],
          ),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Servings ────────────────────────────────────────────
                if (!edit)
                // View mode: "🍽 2 Servings" as a ListTile
                  ListTile(
                    leading: const Icon(Icons.restaurant_menu),
                    title: Text(
                      '$servings ${servings == 1 ? 'Serving' : 'Servings'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  )
                else
                // Edit mode: stepper + optional scale button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.restaurant_menu),
                            const SizedBox(width: 12),
                            Text("Servings",
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium),
                            const Spacer(),
                            IconButton.filledTonal(
                              icon: const Icon(Icons.remove),
                              onPressed: () =>
                                  _changeServings(servings - 1),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              child: Text("$servings",
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge),
                            ),
                            IconButton.filledTonal(
                              icon: const Icon(Icons.add),
                              onPressed: () =>
                                  _changeServings(servings + 1),
                            ),
                          ],
                        ),
                        if (showScaleButton)
                          Padding(
                            padding: const EdgeInsets.only(
                                top: 8, right: 8),
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.straighten),
                              label: Text(
                                  "Scale amounts to $servings servings"),
                              onPressed: () async {
                                await _applyScale(servings);
                                if (mounted)
                                  setState(() => _autoScale = true);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),

                // ── Ingredient list ──────────────────────────────────────
                if (_loadingIngredients)
                  _skeletonInCard(3)
                else if (ingredients.isNotEmpty) ...[
                  Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: cs.outlineVariant),
                  for (int i = 0; i < ingredients.length; i++)
                    _RecipeIngredientTile(
                      key: ValueKey(ingredients[i]['id']),
                      ing: ingredients[i],
                      lang: lang,
                      editMode: edit,
                      onQuantityTap: () =>
                          _openQuantityEditor(ingredients[i]),
                      onRemove: () => _removeIngredient(
                          ingredients[i]['id'] as String),
                      onDescriptionSave: (desc) => ingredientsRef
                          .doc(ingredients[i]['id'] as String)
                          .update({'description': desc}),
                    ),
                ],

                // ── Add ingredient row (edit) ────────────────────────────
                if (edit) ...[
                  Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: cs.outlineVariant),
                  ListTile(
                    leading: Icon(Icons.add, color: cs.primary),
                    title: Text("Add ingredient",
                        style: TextStyle(color: cs.primary)),
                    onTap: _addIngredient,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── steps section ─────────────────────────────────────────────────────────

  Widget _stepsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
          child: Row(
            children: [
              Text("Steps:",
                  style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              if (edit && widget.aiEnabled && !_loadingSteps)
                IconButton(
                  icon: const Icon(Icons.auto_awesome),
                  tooltip: 'Generate with AI',
                  onPressed: _generateSteps,
                ),
              if (edit && steps.any((s) => s.isNotEmpty))
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: 'Clear all',
                  onPressed: _clearSteps,
                ),
            ],
          ),
        ),
        if (_loadingSteps)
          _skeleton(3)
        else ...[
          for (var (index, step) in steps.indexed)
            if (edit || step.isNotEmpty)
              Card(
                margin: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 4),
                elevation: 0,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text("${index + 1}:",
                          style:
                          Theme.of(context).textTheme.titleMedium),
                    ),
                    Expanded(
                      child: edit
                          ? TextField(
                        controller: stepsControllers![index],
                        maxLines: null,
                        style:
                        Theme.of(context).textTheme.bodyMedium,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(8),
                        ),
                      )
                          : Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 16),
                        child: Text(step,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium),
                      ),
                    ),
                  ],
                ),
              ),
          if (edit)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    steps.add('');
                    stepsControllers!.add(TextEditingController());
                  }),
                  child: const Text("Add Step"),
                ),
              ),
            ),
        ],
      ],
    );
  }

  // ── component helpers ─────────────────────────────────────────────────────

  Widget _timeTile(IconData icon, int hour, int minute, String field) {
    return GestureDetector(
      onTap: edit
          ? () async {
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: hour, minute: minute),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
          initialEntryMode: TimePickerEntryMode.inputOnly,
        );
        if (time != null) {
          await docRef.update({field: time.hour * 60 + time.minute});
          _loadRecipe();
        }
      }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(icon),
            Text(" ${hour}h ${minute}m",
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _editImageTile(String imgPath) {
    final isAi = _isAiImage(imgPath);
    final enhancing = _enhancing.contains(imgPath);
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      key: ValueKey(imgPath),
      width: MediaQuery.of(context).size.width * 0.4,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              StorageImage(storagePath: imgPath, fit: BoxFit.cover),

              // Top-right: [enhance?]  [delete]
              // Both are plain IconButton — same style as the original delete
              // button: no background, just the coloured icon on the image.
              Align(
                alignment: Alignment.topRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.aiEnabled && !isAi && !enhancing)
                      IconButton(
                        icon: Icon(Icons.auto_awesome,
                            color: cs.primary),
                        onPressed: () => _enhanceImage(imgPath),
                        tooltip: 'Enhance with AI',
                      ),
                    IconButton(
                      icon: Icon(Icons.cancel, color: cs.error),
                      onPressed: enhancing
                          ? null
                          : () {
                        docRef.update({
                          'images': FieldValue.arrayRemove([imgPath])
                        });
                        FirebaseStorage.instance
                            .ref()
                            .child(imgPath)
                            .delete();
                        _loadRecipe();
                      },
                    ),
                  ],
                ),
              ),

              // Bottom-left: AI badge on AI-generated images
              if (isAi)
                const Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: _AiBadge(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A shimmer tile the same size as a real image tile, used as a placeholder
  /// while an image is uploading or being AI-generated.
  Widget _shimmerImageTile(Key key) {
    return SizedBox(
      key: key,
      width: MediaQuery.of(context).size.width * 0.4,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _Shimmer(
            child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest),
          ),
        ),
      ),
    );
  }

  Widget _skeletonInCard(int rows) {
    return AbsorbPointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (int i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                child: _Shimmer(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _skeleton(int rows) {
    return AbsorbPointer(
      child: Column(
        children: [
          for (int i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 4),
              child: _Shimmer(
                child: Container(
                  height: 60,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Fullscreen image viewer
// =============================================================================

class _FullscreenImagePage extends StatelessWidget {
  const _FullscreenImagePage({
    required this.paths,
    required this.initialIndex,
  });

  final List<String> paths;
  final int initialIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        shadowColor: Colors.transparent,
      ),
      body: PageView.builder(
        controller: PageController(initialPage: initialIndex),
        itemCount: paths.length,
        itemBuilder: (_, index) => InteractiveViewer(
          minScale: 0.8,
          maxScale: 5,
          child: Center(
            child: StorageImage(
              storagePath: paths[index],
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Ingredient tile  (no Card — lives inside the shared ingredients card)
// =============================================================================

class _RecipeIngredientTile extends StatefulWidget {
  const _RecipeIngredientTile({
    super.key,
    required this.ing,
    required this.lang,
    required this.editMode,
    required this.onQuantityTap,
    required this.onRemove,
    required this.onDescriptionSave,
  });

  final Map<String, dynamic> ing;
  final String lang;
  final bool editMode;
  final VoidCallback onQuantityTap;
  final VoidCallback onRemove;
  final void Function(String) onDescriptionSave;

  @override
  State<_RecipeIngredientTile> createState() =>
      _RecipeIngredientTileState();
}

class _RecipeIngredientTileState extends State<_RecipeIngredientTile> {
  late final TextEditingController _descCtrl;
  late final FocusNode _descFocus;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(
        text: (widget.ing['description'] as String?) ?? '');
    _descFocus = FocusNode()
      ..addListener(() {
        if (!_descFocus.hasFocus) {
          widget.onDescriptionSave(_descCtrl.text.trim());
        }
      });
  }

  @override
  void didUpdateWidget(_RecipeIngredientTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editMode && !widget.editMode) {
      widget.onDescriptionSave(_descCtrl.text.trim());
    }
  }

  @override
  void dispose() {
    widget.onDescriptionSave(_descCtrl.text.trim());
    _descFocus.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = readQuantity(widget.ing['quantity']);
    final ingId =
    (widget.ing['ingredientId'] ?? kUnknownIngredient).toString();
    final name =
    ((widget.ing['displayName'] as String?)?.isNotEmpty == true
        ? widget.ing['displayName'] as String
        : ingId);
    final description =
    (widget.ing['description'] as String?)?.isNotEmpty == true
        ? widget.ing['description'] as String
        : null;
    final qtyLabel = q != null
        ? '${fmtQty(q.qty)} ${UnitsCache.instance.display(q.unitId, widget.lang, q.qty)}'
        : '';

    if (!widget.editMode) {
      return ListTile(
        minVerticalPadding: 8,
        minTileHeight:64,
        leading: Avatar(ingredientId: ingId),
        title: Text(name),
        subtitle: Text(description ?? ''),
        trailing: q == null
            ? null
            : Text(qtyLabel,
                style: Theme.of(context).textTheme.titleMedium),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Avatar(ingredientId: ingId),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: Theme.of(context).textTheme.bodyLarge),
                TextField(
                  controller: _descCtrl,
                  focusNode: _descFocus,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    hintText: 'preparation note…',
                    hintStyle: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withOpacity(0.5)),
                  ),
                ),
              ],
            ),
          ),
          q == null
              ? IconButton(
                  icon: Icon(Icons.add,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  onPressed: widget.onQuantityTap,
                )
              : GestureDetector(
                  onTap: widget.onQuantityTap,
                  child: Padding(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      qtyLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
          IconButton(
            icon: Icon(Icons.close,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Attribution text with clickable links
// =============================================================================

class _AttributionText extends StatelessWidget {
  const _AttributionText(this.text);
  final String text;

  static final _urlRegex = RegExp(
    r'https?://[^\s]+',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final linkStyle = style?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: Theme.of(context).colorScheme.primary,
    );

    final spans = <InlineSpan>[];
    int last = 0;
    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: style));
      }
      final url = match.group(0)!;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Text(url, style: linkStyle),
        ),
      ));
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }

    return Text.rich(TextSpan(children: spans));
  }
}

// =============================================================================
// AI badge
// =============================================================================

class _AiBadge extends StatelessWidget {
  const _AiBadge();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 14, color: cs.onSecondaryContainer),
          const SizedBox(width: 4),
          Text("AI",
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: cs.onSecondaryContainer)),
        ],
      ),
    );
  }
}

// =============================================================================
// Shimmer
// =============================================================================

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            cs.surfaceContainerHighest,
            cs.surfaceContainerLow,
            cs.surfaceContainerHighest,
          ],
          stops: const [0.1, 0.5, 0.9],
          transform: _SlidingGradient(_c.value),
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}

class _SlidingGradient extends GradientTransform {
  const _SlidingGradient(this.t);
  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
}