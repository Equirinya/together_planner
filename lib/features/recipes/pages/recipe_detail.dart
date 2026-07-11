import 'dart:async';
import 'dart:io';

import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/models/categories.dart' show categoryRank;
import 'package:couple_planner/features/ingredients/services/units_cache.dart';
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart';
import 'package:couple_planner/features/ingredients/widgets/avatar.dart';
import 'package:couple_planner/features/ingredients/widgets/ingredient_search_sheet.dart';
import 'package:couple_planner/features/ingredients/widgets/quantity_editor.dart' show QuantityEditor;
import 'package:couple_planner/core/widgets/storage_image.dart';
import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/copy_group_recipe.dart';
import 'package:couple_planner/features/recipes/services/recipe_localization.dart';
import 'package:couple_planner/features/settings/dietary_preferences.dart' show dietaryTagIcon;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    this.generating = false,
    this.initialData,
    this.publicRecipeId,
    this.sharedSourceGroupId,
    this.canEditPublicRecipes = false,
    this.onTagTap,
  });

  final String groupId;
  final String recipeId;
  final bool editMode;
  final bool aiEnabled;

  /// Called instead of the default behaviour when a tag chip is tapped (view
  /// mode only). The caller is responsible for closing this page and acting on
  /// the tag (e.g. entering it into a search field).
  final void Function(String tag)? onTagTap;

  /// When set, the page opens as a read-only preview of the public recipe with
  /// this id (localized), showing a "Save in own recipes" button instead of the
  /// edit/delete actions. Saving adopts it into the group and switches the same
  /// page over to the freshly created local recipe in place. [recipeId] is empty
  /// until then.
  final String? publicRecipeId;

  /// When set, the page opens as a read-only preview of a recipe belonging to
  /// another group (the recipe-viewer flow): [recipeId] is the source recipe's
  /// id inside this group. Saving copies it into [groupId] and switches the same
  /// page over to the freshly created local recipe in place. Reuses the same
  /// preview/adopt mechanism as [publicRecipeId].
  final String? sharedSourceGroupId;

  /// When true, a delete action is shown while previewing a public recipe.
  final bool canEditPublicRecipes;

  /// When true the recipe is being generated in the background: the page
  /// streams the document and shows shimmering placeholders for each part
  /// (title, steps, ingredients, image) until it arrives.
  final bool generating;

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

  // ── public preview / adoption ─────────────────────────────────────────────
  // While previewing a public recipe [_publicId] is set and the page reads from
  // the public_recipes collection. After the user saves it, [_savedRecipeId]
  // holds the new group recipe id and [_publicId] is cleared, so the page acts
  // like any other local recipe. [recipeId] resolves to whichever is active.
  String? _publicId;
  String? _sharedGroupId;
  String? _savedRecipeId;
  String? _destGroupName;
  bool _saving = false;
  bool get _isPublicPreview => _publicId != null;
  bool get _isSharedPreview => _sharedGroupId != null;
  // Any read-only preview (public recipe or another group's recipe) that offers
  // a "Save in own recipes" button instead of edit/delete.
  bool get _isPreview => _isPublicPreview || _isSharedPreview;
  String get recipeId => _savedRecipeId ?? widget.recipeId;

  late String lang;

  late List<String> images;
  late List<String> steps;
  late List<String> tags;
  // Standard diet labels the recipe satisfies (public recipes only — not
  // shown/edited as a regular tag, see _dietaryChipsToShow).
  List<String> dietary = [];
  List<String> _userDietaryPrefs = [];
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

  // ── staged generation ─────────────────────────────────────────────────────
  // The set of parts still being generated, mirrored from the doc's `pending`
  // field. While non-empty the page streams the doc and shimmers those parts.
  Set<String> _pending = {};
  StreamSubscription? _docSub;
  bool get _isGenerating => _pending.isNotEmpty;

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
    lang = LanguageService.instance.code.value;
    UnitsCache.instance.ensureLoaded();

    _publicId = widget.publicRecipeId;
    _sharedGroupId = widget.sharedSourceGroupId;

    if (widget.initialData != null) _applyData(widget.initialData!);

    if (_isPublicPreview) {
      _loadPublicPreview();
      _loadUserDietaryPrefs();
      return;
    }
    if (_isSharedPreview) {
      _loadSharedPreview();
      _loadDestGroupName();
      return;
    }

    _bindLocalRefs(widget.recipeId);

    _startIngredientsSubscription();
    if (widget.generating) {
      // Show every part as pending up front so shimmers appear immediately,
      // then let the document stream clear them one by one.
      _pending = {'title', 'steps', 'ingredients', 'image'};
      _docSub = docRef.snapshots().listen(_onDocSnap);
    } else {
      _loadRecipe();
    }
  }

  void _bindLocalRefs(String id) {
    docRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('recipes')
        .doc(id);
    ingredientsRef = docRef.collection('ingredients');
  }

  @override
  void dispose() {
    _ingredientsSub?.cancel();
    _docSub?.cancel();
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

  void _applyData(Map<String, dynamic> rawData) {
    final data = localizeRecipeData(rawData, lang);
    recipeData = data;

    images = List<String>.from(data['images'] ?? []);
    steps = List<String>.from(data['steps'] ?? []);
    if (steps.isEmpty) steps = [''];
    tags = List<String>.from(data['tags'] ?? []);
    dietary = List<String>.from(data['dietary'] ?? []);
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

  /// Loads a public recipe (localized to [lang], English base otherwise) into
  /// the page for a read-only preview. Mirrors the localization done when
  /// adopting so the previewed content matches what gets saved.
  Future<void> _loadPublicPreview() async {
    final publicRef = FirebaseFirestore.instance.doc('public_recipes/$_publicId');
    final snap = await publicRef.get();
    if (!snap.exists || !mounted) return;
    final p = snap.data()!;
    final localized = lang == 'en'
        ? null
        : (p['translations'] as Map<String, dynamic>?)?[lang] as Map<String, dynamic>?;
    T field<T>(String key, T fallback) =>
        (localized?[key] ?? p[key] ?? fallback) as T;

    final imagePath = p['image'];
    final data = <String, dynamic>{
      'name': field<String>('name', ''),
      'description': field<String>('description', ''),
      'tags': field<List<dynamic>>('tags', const []),
      'dietary': List<dynamic>.from(p['dietary'] ?? const []),
      'steps': field<List<dynamic>>('steps', const []),
      'images': (imagePath is String && imagePath.isNotEmpty)
          ? <String>[imagePath]
          : <String>[],
      'servings': p['servings'] ?? 2,
      'time': p['time'] ?? 0,
      'preparationTime': p['preparationTime'] ?? 0,
      if (p['attribution'] != null) 'attribution': p['attribution'],
    };

    final ingSnap = await publicRef.collection('ingredients').get();
    final ings = <Map<String, dynamic>>[];
    for (final d in ingSnap.docs) {
      final dd = d.data();
      final il = lang == 'en'
          ? null
          : (dd['translations'] as Map<String, dynamic>?)?[lang]
              as Map<String, dynamic>?;
      ings.add({
        'id': d.id,
        'ingredientId': (dd['ingredientId'] as String?) ?? kUnknownIngredient,
        'displayName': il?['displayName'] ?? dd['displayName'] ?? '',
        'description': il?['description'] ?? dd['description'] ?? '',
        'quantity': Map<String, dynamic>.from(dd['quantity'] ?? const {}),
      });
    }

    if (!mounted) return;
    setState(() {
      _applyData(data);
      ingredients = ings;
    });
  }

  /// Loads the signed-in user's own dietary preferences, used to decide which
  /// of a public recipe's [dietary] labels are worth calling out as chips.
  Future<void> _loadUserDietaryPrefs() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final prefs = List<String>.from(snap.data()?['dietaryPreferences'] ?? []);
    if (mounted) setState(() => _userDietaryPrefs = prefs);
  }

  /// Loads another group's recipe (the recipe-viewer flow) into the page for a
  /// read-only preview. Mirrors what [copyGroupRecipe] writes, so the previewed
  /// content matches what gets saved.
  Future<void> _loadSharedPreview() async {
    final sourceRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(_sharedGroupId)
        .collection('recipes')
        .doc(widget.recipeId);
    final snap = await sourceRef.get();
    if (!snap.exists || !mounted) return;
    final s = snap.data()!;

    final data = <String, dynamic>{
      'name': s['name'] ?? '',
      'description': s['description'] ?? '',
      'tags': List<dynamic>.from(s['tags'] ?? const []),
      'dietary': List<dynamic>.from(s['dietary'] ?? const []),
      if (s['translations'] != null) 'translations': s['translations'],
      'steps': List<dynamic>.from(s['steps'] ?? const []),
      'images': List<String>.from(s['images'] ?? const []),
      'servings': s['servings'] ?? 2,
      'time': s['time'] ?? 0,
      'preparationTime': s['preparationTime'] ?? 0,
      if (s['attribution'] != null) 'attribution': s['attribution'],
    };

    final ingSnap = await sourceRef.collection('ingredients').get();
    final ings = <Map<String, dynamic>>[];
    for (final d in ingSnap.docs) {
      final dd = d.data();
      ings.add({
        'id': d.id,
        'ingredientId': (dd['ingredientId'] as String?) ?? kUnknownIngredient,
        'displayName': dd['displayName'] ?? '',
        'description': dd['description'] ?? '',
        'quantity': Map<String, dynamic>.from(dd['quantity'] ?? const {}),
      });
    }

    if (!mounted) return;
    setState(() {
      _applyData(data);
      ingredients = ings;
    });
  }

  Future<void> _loadDestGroupName() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .get();
      final name = (snap.data()?['name'] ?? '').toString();
      if (mounted && name.isNotEmpty) setState(() => _destGroupName = name);
    } catch (_) {}
  }

  /// Adopts/copies the previewed recipe into the group, then switches this same
  /// page over to the new local recipe without a route change: the copied image
  /// is warmed into the cache first so the storage-path swap paints from cache
  /// with no reload, and the scroll offset is preserved.
  Future<void> _saveToOwnRecipes() async {
    if (!_isPreview) return;
    setState(() => _saving = true);
    try {
      final String newId;
      if (_isSharedPreview) {
        newId = await copyGroupRecipe(
          groupId: widget.groupId,
          sourceGroupId: _sharedGroupId!,
          sourceRecipeId: widget.recipeId,
          uid: FirebaseAuth.instance.currentUser!.uid,
        );
      } else {
        final preload = await preloadPublicRecipe(_publicId!);
        final result = await adoptPublicRecipeFromPreload(
          groupId: widget.groupId,
          publicRecipeId: _publicId!,
          preload: preload,
          uid: FirebaseAuth.instance.currentUser!.uid,
          lang: lang,
        );
        newId = result.recipeId;
        await result.imageUpload; // wait for image before switching the page
      }
      final newRef = FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .collection('recipes')
          .doc(newId);
      final newSnap = await newRef.get();
      final newData = newSnap.data() ?? <String, dynamic>{};
      // Warm the cache for the copied image(s) so swapping to the local storage
      // path below finds them synchronously and does not flash a placeholder.
      for (final path in List<String>.from(newData['images'] ?? const [])) {
        try {
          await StorageImageCache.instance.getFile(path);
        } catch (_) {}
      }
      if (!mounted) return;
      _savedRecipeId = newId;
      _publicId = null;
      _sharedGroupId = null;
      _bindLocalRefs(newId);
      _startIngredientsSubscription();
      setState(() {
        _applyStreamData(newData);
        _saving = false;
      });
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      _snack('Could not save this recipe.');
    }
  }

  /// Live document updates while the recipe is being generated. Each snapshot
  /// fills in whatever parts have arrived and clears the matching shimmer.
  void _onDocSnap(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final data = snap.data();
    if (data == null) return;
    // Until the backend writes the `pending` field, keep the initial shimmers
    // (set in initState) — the client's own just-created doc has no `pending`
    // yet, and clearing it here would cancel the stream too early.
    final hasPending = data.containsKey('pending');
    setState(() {
      _applyStreamData(data);
      if (hasPending) {
        _pending = (data['pending'] as List?)
                ?.map((e) => e.toString())
                .toSet() ??
            <String>{};
      }
    });
    if (data['generationError'] == true) {
      _snack('Could not finish generating this recipe.');
    }
    if (hasPending && _pending.isEmpty) {
      _docSub?.cancel();
      _docSub = null;
    }
  }

  /// Like [_applyData] but always refreshes the editing controllers from the
  /// incoming data — used during generation, where fields stream in over time
  /// and the one-shot `??=` initialisation in [_applyData] would go stale.
  void _applyStreamData(Map<String, dynamic> data) {
    _applyData(data);
    // Read back through [recipeData] (set by [_applyData]) rather than the raw
    // [data] param, so these controllers pick up the localized name/tags/steps
    // too instead of the English base once translations land mid-generation.
    nameController?.text = recipeData?['name'] ?? '';
    descriptionController?.text = recipeData?['description'] ?? '';
    final newTags = List<String>.from(recipeData?['tags'] ?? []);
    tagsController?.text = newTags.map((e) => '#$e ').join('');
    final newSteps = List<String>.from(recipeData?['steps'] ?? []);
    if (newSteps.isNotEmpty) {
      for (final c in stepsControllers ?? const <TextEditingController>[]) {
        c.dispose();
      }
      stepsControllers =
          newSteps.map((s) => TextEditingController(text: s)).toList();
    }
  }

  void _startIngredientsSubscription() {
    _ingredientsSub = ingredientsRef.snapshots().listen((snap) async {
      if (!mounted) return;
      // Matched ingredients already have a curated name in every supported
      // language on their master /ingredients doc (see resolveOrCreateIngredient
      // in functions/src/ingredients.ts); prefer that over the recipe's own
      // (AI-translated) displayName, same as the add-to-shopping-list dialog.
      // Still-pending ingredients have no matching master doc, so this just
      // resolves to an empty snapshot for those — harmless.
      final masterDocs = await Future.wait(snap.docs.map((d) {
        final id = (d.data()['ingredientId'] ?? '').toString();
        return FirebaseFirestore.instance.collection('ingredients').doc(id).get();
      }));
      if (!mounted) return;
      final list = <Map<String, dynamic>>[
        for (int i = 0; i < snap.docs.length; i++)
          () {
            final localized = localizeIngredientData(snap.docs[i].data(), lang);
            final masterName =
                (masterDocs[i].data()?['name'] as Map?)?[lang]?.toString();
            return <String, dynamic>{
              ...localized,
              if (masterName != null && masterName.isNotEmpty)
                'displayName': masterName,
              'id': snap.docs[i].id,
            };
          }(),
      ];
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
          'groups/${widget.groupId}/recipes/$recipeId/${DateTime.now().millisecondsSinceEpoch}');
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
      'lang': lang,
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
        'recipeId': recipeId,
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
        'recipeId': recipeId,
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
        'recipeId': recipeId,
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
        'recipeId': recipeId,
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
    final update = docRef.update({
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
      await update;
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
      bottomNavigationBar: _isPreview
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveToOwnRecipes,
                    icon: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bookmark_add_outlined),
                    label: Text(
                      _isSharedPreview && _destGroupName != null
                          ? 'Save to recipes in $_destGroupName'
                          : 'Save in own recipes',
                    ),
                  ),
                ),
              ),
            )
          : null,
      appBar: AppBar(
        leading: edit
            ? IconButton(
                icon: const Icon(Icons.save),
                onPressed: _saveAndExit,
              )
            : null,
        actions: [
          if (_isPublicPreview && widget.canEditPublicRecipes)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  icon: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
                  title: const Text("Delete Public Recipe"),
                  content: const Text(
                      "Are you sure you want to delete this public recipe? This action cannot be undone."),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text("Cancel")),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(ctx).colorScheme.error),
                      onPressed: () async {
                        final publicId = _publicId!;
                        final db = FirebaseFirestore.instance;
                        final publicRef = db.doc('public_recipes/$publicId');
                        final ingsSnap = await publicRef.collection('ingredients').get();
                        final batch = db.batch();
                        for (final d in ingsSnap.docs) {
                          batch.delete(d.reference);
                        }
                        batch.delete(publicRef);
                        await batch.commit();
                        Navigator.of(ctx).pop();
                        Navigator.of(context).pop();
                      },
                      child: const Text("Delete"),
                    ),
                  ],
                ),
              ),
            ),
          if (!_isPreview)
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
                      final db = FirebaseFirestore.instance;
                      final plans = await db
                          .collection('groups')
                          .doc(widget.groupId)
                          .collection('cooking_plan')
                          .where('recipe', isEqualTo: recipeId)
                          .get();
                      final batch = db.batch();
                      for (final plan in plans.docs) {
                        batch.delete(plan.reference);
                      }
                      batch.delete(docRef);
                      await batch.commit();
                      Navigator.of(ctx).pop();
                      Navigator.of(context).pop();
                    },
                    child: const Text("Delete"),
                  ),
                ],
              ),
            ),
          ),
          if (!edit && !_isGenerating && !_isPreview)
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
            if (edit || images.isNotEmpty || _pending.contains('image'))
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.3,
                child: edit
                    ? _editImageCarousel()
                    : (images.isEmpty && _pending.contains('image'))
                        ? _generatingImagePlaceholder()
                        : _viewImageCarousel(),
              ),

            const SizedBox(height: 16),

            // ── Title ────────────────────────────────────────────────────
            edit
                ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: nameController,
                style: Theme.of(context).textTheme.headlineMedium,
                decoration: const InputDecoration(
                  hintText: 'Recipe name',
                  isDense: true,
                  contentPadding: EdgeInsets.only(bottom: 4),
                ),
              ),
            )
                : (_pending.contains('title') &&
                        (recipeData?['name'] ?? '').toString().isEmpty)
                    ? _titleShimmer()
                    : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                recipeData?['name'] ?? 'Unnamed Recipe',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),

            if (attribution != null && attribution!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(Icons.link, size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 4),
                    Expanded(child: _AttributionText(attribution!)),
                  ],
                ),
              ),

            // ── Tags + times ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  edit
                      ? TextField(
                          controller: tagsController,
                          style: Theme.of(context).textTheme.bodyMedium,
                          decoration: const InputDecoration(
                            hintText: '#tag1 #tag2…',
                            isDense: true,
                          ),
                        )
                      : Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            // Diet-recognized chips (icons) always lead, then
                            // the rest of the plain tags.
                            ...tags.where((t) => dietaryTagIcon(t) != null).map(_buildTagChip),
                            ..._dietaryChipsToShow.map(_buildTagChip),
                            ...tags.where((t) => dietaryTagIcon(t) == null).map(_buildTagChip),
                          ],
                        ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _timeTile(Icons.schedule, totalHour, totalMinute, 'time'),
                      _timeTile(Icons.blender, prepHour, prepMinute, 'preparationTime'),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Ingredients + servings (hidden in view mode when empty) ──
            if (edit || hasIngredients || _pending.contains('ingredients'))
              _ingredientsSection(),

            if (edit || hasIngredients || _pending.contains('ingredients'))
              const SizedBox(height: 20),

            // ── Steps (hidden in view mode when empty) ───────────────────
            if (edit || hasSteps || _pending.contains('steps')) _stepsSection(),

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
            crossAxisAlignment: CrossAxisAlignment.center,
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
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              if (edit && ingredients.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep),
                  tooltip: 'Clear all',
                  onPressed: _clearIngredients,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                if (_loadingIngredients || _pending.contains('ingredients'))
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
        if (_loadingSteps || _pending.contains('steps'))
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

  // Vegan implies vegetarian implies pescatarian, so only the tightest one
  // that applies is worth showing.
  static const _kPrimaryDietOrder = ['Vegan', 'Vegetarian', 'Pescatarian'];

  /// Picks which of [dietary]'s standard diet labels to show as chips: the
  /// ones the signed-in user has selected for themselves, plus the strongest
  /// of vegan/vegetarian/pescatarian the recipe satisfies (shown regardless
  /// of the user's own preferences). Keeps the recipe's own casing. Skips any
  /// diet already represented among the regular [tags] (matched by icon, not
  /// text, so e.g. a "Vegetarisch" tag also suppresses the "Vegetarian" chip)
  /// so the same diet never shows up twice.
  List<String> get _dietaryChipsToShow {
    if (dietary.isEmpty) return const [];
    final tagIcons = tags.map(dietaryTagIcon).whereType<IconData>().toSet();
    final chips = <String, String>{}; // lowercase -> original casing
    void addIfPresent(String label) {
      for (final d in dietary) {
        if (d.toLowerCase() == label.toLowerCase()) {
          if (tagIcons.contains(dietaryTagIcon(d))) return;
          chips[d.toLowerCase()] = d;
          return;
        }
      }
    }

    for (final pref in _userDietaryPrefs) {
      addIfPresent(pref);
    }
    for (final primary in _kPrimaryDietOrder) {
      if (dietary.any((d) => d.toLowerCase() == primary.toLowerCase())) {
        addIfPresent(primary);
        break;
      }
    }
    return chips.values.toList();
  }

  Widget _buildTagChip(String tag) {
    final cs = Theme.of(context).colorScheme;
    final onTap = widget.onTagTap == null ? null : () => widget.onTagTap!(tag);
    final icon = dietaryTagIcon(tag);
    if (icon != null) {
      return GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: tag,
          child: Container(
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: cs.onPrimaryContainer),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Chip(
        label: Text(tag,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.onPrimaryContainer)),
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        backgroundColor: cs.primaryContainer,
        side: BorderSide.none,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

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

  /// Full-width shimmer standing in for the title while it is generated.
  Widget _titleShimmer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: _Shimmer(
        child: Container(
          height: 28,
          width: MediaQuery.of(context).size.width * 0.6,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  /// Shimmer filling the image area while the recipe image is generated.
  Widget _generatingImagePlaceholder() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: _Shimmer(
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
    if (widget.editMode) {
      widget.onDescriptionSave(_descCtrl.text.trim());
    }
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
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      decoration: TextDecoration.underline,
      decorationColor: Theme.of(context).colorScheme.onSurfaceVariant,
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
// Loading placeholder
// =============================================================================

/// A static shimmering skeleton shaped like [RecipeDetailPage] in its
/// generating state. Pushed the instant a recipe link is shared, before the
/// active group / backing Firestore doc are even known, so something appears
/// on screen right away instead of a blank pause.
class RecipeDetailSkeleton extends StatelessWidget {
  const RecipeDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget shimmerBox({double? height, double? width, double radius = 8}) {
      return _Shimmer(
        child: Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: shimmerBox(radius: 28),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: shimmerBox(
                  height: 28, width: MediaQuery.of(context).size.width * 0.6),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: shimmerBox(
                  height: 16, width: MediaQuery.of(context).size.width * 0.4),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                child: shimmerBox(height: 48),
              ),
          ],
        ),
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