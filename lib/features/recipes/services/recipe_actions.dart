import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/features/ingredients/models/ingredients.dart' show kPendingIngredient;
import 'package:couple_planner/features/ingredients/services/ingredient_index.dart' show resolvePendingItem;
import 'package:couple_planner/features/recipes/pages/recipe_page.dart';
import 'package:couple_planner/features/recipes/pages/recipe_detail.dart';
import 'package:couple_planner/features/recipes/services/adopt_public_recipe.dart';
import 'package:couple_planner/features/recipes/services/recipe_suggestions.dart';
import 'package:couple_planner/features/recipes/widgets/create_recipe_sheet.dart';
import 'package:couple_planner/features/recipes/widgets/generating_dialog.dart';
import 'package:couple_planner/features/recipes/widgets/recipe_suggestion.dart';
import 'package:couple_planner/features/ai/ai_errors.dart';

/// Acting on suggestions (tap / drag to save / drag onto a day) and creating
/// recipes (blank / text / photo / link) for the recipe page. Mixed into
/// [RecipePage]'s state alongside [RecipeSuggestionsMixin] (from which it uses
/// [functions], [extractUrl], [searchQuery] and [recipes]).
mixin RecipeActionsMixin on State<RecipePage>, RecipeSuggestionsMixin {
  // ── provided by RecipePage's state ──────────────────────────────────────
  DocumentReference<Map<String, dynamic>> get groupDoc;

  /// Tapping a tag chip in the recipe detail page: close it and run a tag
  /// search for that tag in the grid below.
  void onDetailTagTap(String tag);

  /// Places (or moves) a recipe/plan onto [day] at [index] within [plans];
  /// lives in the state because it also drives the calendar's drop preview.
  Future<void> handleDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    DocumentSnapshot<Map<String, dynamic>> data,
  );

  // Search-grid suggestions currently being adopted into the group, keyed by
  // [suggestionKey]. Presence means the dragged tile shows in-place loading
  // (not draggable); the stored value is the resulting private recipe's
  // snapshot once written, at which point the tile transforms into that recipe
  // (which can then be dragged onto a day). The snapshot is fetched directly
  // (see [_resolveAdoptedTile]) rather than waited for from the recipes stream,
  // which — while searching — may not surface a recipe that doesn't match the
  // query text. Cleared when the search is cleared.
  final Map<String, DocumentSnapshot<Map<String, dynamic>>?> adoptingSuggestions = {};

  // Public recipe data preloaded when a suggestion drag starts, keyed by public
  // recipe id. Awaited on drop so the recipe doc can be written immediately.
  final Map<String, Future<PublicRecipePreload>> publicPreload = {};

  // Recipe ids whose image is still landing — after an instant public adopt
  // (image upload) or after an idea was planned and its AI image is still being
  // generated (see [_trackImageGeneration]). Plan tiles for these show a loading
  // overlay until the image is ready.
  final Set<String> uploadingRecipeIds = {};

  // Live document listeners watching a just-generated planned recipe until its
  // image lands, so the plan tile's loading overlay can be cleared. Cancelled
  // on dispose.
  final Set<StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>> imageTrackSubs = {};

  /// Stable identity for a suggestion, so a drag that starts an adoption can be
  /// matched back to its tile across rebuilds (the suggestion list is rebuilt
  /// as results stream in).
  String suggestionKey(RecipeSuggestion s) =>
      s.publicId ?? s.url ?? 'name:${s.title}';

  // ── recipe document seed ────────────────────────────────────────────────

  /// The document data a brand-new group recipe starts from (before AI
  /// generation streams the real content in). Shared by the blank/generated/
  /// link/photo flows so they can't drift apart.
  Map<String, dynamic> _recipeSeedDoc({
    required String name,
    String? attribution,
    String? searchHint,
  }) => {
        'name': name,
        'description': '',
        'creator': FirebaseAuth.instance.currentUser!.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'lastUsedAt': null,
        'preparationTime': 0,
        'time': 0,
        'servings': 2,
        'tags': <String>[],
        'images': <String>[],
        'steps': <String>[],
        if (attribution != null) 'attribution': attribution,
        if (searchHint != null && searchHint.isNotEmpty) 'searchHint': searchHint,
      };

  /// Creates a bare recipe document and returns its reference.
  Future<DocumentReference<Map<String, dynamic>>> _createRecipeDoc({
    required String name,
    String? attribution,
    String? searchHint,
  }) {
    return groupDoc.collection('recipes').add(
        _recipeSeedDoc(name: name, attribution: attribution, searchHint: searchHint));
  }

  /// Returns the id of an already-existing recipe whose [attribution] matches
  /// [url], or null if no such recipe is loaded yet.
  String? _findRecipeIdByUrl(String url) {
    for (final r in recipes) {
      if ((r.data()['attribution'] ?? '') == url) return r.id;
    }
    return null;
  }

  // The lighter, image/title-only map handed to the detail page as
  // [initialData] so it can paint immediately during the open transition.
  Map<String, dynamic> _seedData(String name, {String? attribution}) => {
        'name': name,
        'description': '',
        'images': <String>[],
        'steps': <String>[],
        'tags': <String>[],
        'servings': 2,
        'time': 0,
        'preparationTime': 0,
        if (attribution != null) 'attribution': attribution,
      };

  Future<void> _callStaged(String recipeId, RecipeSuggestion s) async {
    final data = <String, dynamic>{'groupId': widget.groupId, 'recipeId': recipeId, 'lang': LanguageService.instance.code.value};
    if (s.kind == SuggestionKind.url) {
      data['source'] = 'url';
      data['url'] = s.url;
    } else {
      data['source'] = 'name';
      data['prompt'] = s.title;
    }
    try {
      await functions.httpsCallable('recipes-generateRecipeStaged').call(data);
    } catch (e) {
      // Surface a hit monthly limit / plan restriction; other failures already
      // show up as the recipe's generationError state on the detail page.
      final msg = aiLimitMessage(e);
      if (msg != null && mounted) _snack(msg);
    }
  }

  // ── acting on a suggestion (tap / drag) ────────────────────────────────────

  /// Tapping a suggestion: public recipes open a read-only preview that saves
  /// itself into the group in place; name/link ideas open the detail page
  /// immediately and generate in the background (shimmering the parts that
  /// haven't arrived yet).
  Future<void> openSuggestion(RecipeSuggestion s) async {
    if (s.kind == SuggestionKind.public) {
      _pushDetail(
        '',
        publicRecipeId: s.publicId,
        initialData: _seedData(s.title)
          ..['images'] = (s.publicImage?.isNotEmpty ?? false)
              ? [s.publicImage!]
              : <String>[],
      );
      return;
    }

    if (s.kind == SuggestionKind.url && s.url != null) {
      final existing = _findRecipeIdByUrl(s.url!);
      if (existing != null) {
        _pushDetail(existing);
        return;
      }
    }

    // Idea tiles are only offered while there's quota (see
    // recipe_suggestions.dart's `_canOfferAiIdeas`), but a tile tapped right
    // as the last unit was spent elsewhere would otherwise still create an
    // empty recipe doc that the server then refuses to fill in.
    if (!widget.access.hasGenerationQuota) {
      _snack("You've used all your AI generations for this month.");
      return;
    }

    final name = s.kind == SuggestionKind.name ? s.title : '';
    final attribution = s.kind == SuggestionKind.url ? s.url : null;
    final ref = groupDoc.collection('recipes').doc();
    ref.set(_recipeSeedDoc(name: name, attribution: attribution));
    _pushDetail(
      ref.id,
      generating: true,
      initialData: _seedData(name, attribution: attribution),
    );
    // Fire and forget; the detail page streams progress from the document.
    _callStaged(ref.id, s).ignore();
  }

  void _pushDetail(String recipeId,
      {bool generating = false,
      Map<String, dynamic>? initialData,
      String? publicRecipeId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecipeDetailPage(
          groupId: widget.groupId,
          recipeId: recipeId,
          access: widget.access,
          generating: generating,
          initialData: initialData,
          publicRecipeId: publicRecipeId,
          canEditPublicRecipes: widget.canEditPublicRecipes,
          onTagTap: onDetailTagTap,
        ),
      ),
    );
  }

  // Fetches the just-created private recipe [recipeId] and stores its snapshot
  // against the adopting suggestion [key], transforming that tile in place from
  // loading into the (draggable) recipe. Fetched directly rather than read from
  // the recipes stream so it resolves even while searching, when the stream may
  // not surface a recipe that doesn't match the query text.
  Future<void> _resolveAdoptedTile(String key, String recipeId) async {
    try {
      final snap = await groupDoc.collection('recipes').doc(recipeId).get();
      if (!mounted || !adoptingSuggestions.containsKey(key)) return;
      setState(() => adoptingSuggestions[key] = snap);
    } catch (_) {}
  }

  /// Resolves any still-pending (unmatched) ingredients of a freshly generated
  /// or adopted recipe in place, so the shopping-list dialog shows clean names.
  Future<void> _resolvePendingIngredients(String recipeId) async {
    final lang = LanguageService.instance.code.value;
    final ingRef =
        groupDoc.collection('recipes').doc(recipeId).collection('ingredients');
    final snap = await ingRef.get();
    await Future.wait(snap.docs
        .where((d) => (d.data()['ingredientId'] ?? '').toString() == kPendingIngredient)
        .map((d) => resolvePendingItem(
              ingRef.doc(d.id),
              (d.data()['displayName'] ?? '').toString(),
              lang,
            )));
  }

  /// Waits only until the recipe's `ingredients` stage has cleared from the
  /// doc's `pending` array (steps 1–3 of generateRecipeStaged), rather than the
  /// whole call — the image (stage 4) keeps generating in the background via
  /// [generation]. Also surfaces a failure if [generation] itself rejects
  /// before ever writing `pending`, or if the function flags generationError.
  Future<void> _awaitIngredientsStage(
      String recipeId, Future<void> generation) async {
    final ref = groupDoc.collection('recipes').doc(recipeId);
    final ready = Completer<void>();
    late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
    sub = ref.snapshots().listen((snap) {
      final data = snap.data();
      if (data == null || ready.isCompleted) return;
      if (data['generationError'] == true) {
        ready.completeError(Exception('Recipe generation failed'));
        return;
      }
      if (!data.containsKey('pending')) return;
      final pending = List<String>.from(data['pending'] ?? const []);
      if (!pending.contains('ingredients')) ready.complete();
    });
    generation.catchError((Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });
    try {
      await ready.future;
    } finally {
      sub.cancel();
    }
  }

  /// Dragging a suggestion onto the save zone: generate/adopt the recipe and
  /// set lastUsedAt to now, without planning it. Public recipes are adopted
  /// instantly from preloaded data. The dragged tile shows in-place loading and
  /// transforms into the adopted recipe (see [adoptingSuggestions]).
  Future<void> handleSuggestionSave(RecipeSuggestion s) async {
    if (s.kind != SuggestionKind.public && !widget.access.hasGenerationQuota) {
      _snack("You've used all your AI generations for this month.");
      return;
    }
    final key = suggestionKey(s);
    setState(() => adoptingSuggestions[key] = null);
    if (s.kind == SuggestionKind.public) {
      try {
        final preloadFuture =
            publicPreload.remove(s.publicId!) ?? preloadPublicRecipe(s.publicId!);
        final preload = await preloadFuture;
        final result = await adoptPublicRecipeFromPreload(
          groupId: widget.groupId,
          publicRecipeId: s.publicId!,
          preload: preload,
          uid: FirebaseAuth.instance.currentUser!.uid,
          lang: LanguageService.instance.code.value,
        );
        _resolveAdoptedTile(key, result.recipeId);
        result.imageUpload.ignore();
      } catch (_) {
        if (mounted) setState(() => adoptingSuggestions.remove(key));
        _snack('Could not save this recipe.');
      }
      return;
    }
    // The current search text, if any, is stamped onto the new recipe as
    // `searchHint` so it stays findable under the term that surfaced this
    // suggestion, even once AI generation replaces its name/description/tags
    // with something that doesn't literally contain those words.
    final searchHint = searchQuery.trim();
    String? recipeId;
    try {
      if (s.kind == SuggestionKind.url && s.url != null) {
        final existing = _findRecipeIdByUrl(s.url!);
        if (existing != null) {
          recipeId = existing;
        } else {
          final ref = await _createRecipeDoc(
              name: '', attribution: s.url, searchHint: searchHint);
          recipeId = ref.id;
          // Fire and forget; the doc is edited in place as generation streams in.
          _callStaged(recipeId, s).ignore();
        }
      } else {
        final ref = await _createRecipeDoc(
            name: s.kind == SuggestionKind.name ? s.title : '',
            searchHint: searchHint);
        recipeId = ref.id;
        _callStaged(recipeId, s).ignore();
      }
      if (recipeId != null) {
        groupDoc
            .collection('recipes')
            .doc(recipeId)
            .update({'lastUsedAt': FieldValue.serverTimestamp()});
      }
    } catch (_) {
      if (mounted) setState(() => adoptingSuggestions.remove(key));
      _snack('Could not save this recipe.');
      return;
    }
    if (recipeId != null) _resolveAdoptedTile(key, recipeId);
  }

  /// Dragging a suggestion onto a day: generate/adopt the recipe, then plan it
  /// and open the add-to-shopping-list dialog. Public recipes are adopted
  /// instantly from preloaded data. The dragged tile shows in-place loading and
  /// transforms into the adopted recipe (see [adoptingSuggestions]).
  Future<void> handleSuggestionDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    RecipeSuggestion s,
  ) async {
    if (s.kind == SuggestionKind.public) {
      await _handlePublicRecipeDrop(day, plans, index, s);
      return;
    }
    if (!widget.access.hasGenerationQuota) {
      _snack("You've used all your AI generations for this month.");
      return;
    }
    final key = suggestionKey(s);
    setState(() => adoptingSuggestions[key] = null);
    // Block on a "generating" dialog until the ingredients stage is done; only
    // then is the recipe planned (so its plan tile appears) with the image
    // still generating in the background (see [_trackImageGeneration]).
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const GeneratingDialog(),
    );
    String? recipeId;
    // Whether the recipe was freshly generated (so its image may still be in
    // flight), as opposed to an already-existing link recipe.
    var generated = true;
    try {
      if (s.kind == SuggestionKind.url && s.url != null) {
        final existing = _findRecipeIdByUrl(s.url!);
        if (existing != null) {
          recipeId = existing;
          generated = false;
          _resolveAdoptedTile(key, recipeId);
        } else {
          final ref = await _createRecipeDoc(
              name: '',
              attribution: s.url);
          recipeId = ref.id;
          _resolveAdoptedTile(key, recipeId);
          await _awaitIngredientsStage(recipeId, _callStaged(recipeId, s));
        }
      } else {
        final ref = await _createRecipeDoc(
            name: s.kind == SuggestionKind.name ? s.title : '',
            attribution: null);
        recipeId = ref.id;
        _resolveAdoptedTile(key, recipeId);
        await _awaitIngredientsStage(recipeId, _callStaged(recipeId, s));
      }
      if (recipeId != null) await _resolvePendingIngredients(recipeId);
    } catch (_) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => adoptingSuggestions.remove(key));
      }
      _snack('Could not generate this recipe.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close generating dialog
    if (recipeId == null) return;
    final snap = await groupDoc.collection('recipes').doc(recipeId).get();
    if (!mounted) return;
    handleDrop(day, plans, index, snap);
    if (generated) _trackImageGeneration(recipeId);
  }

  /// Adopts [s] using preloaded data: writes recipe + cooking plan instantly,
  /// then uploads the image in the background with a loading overlay on the tile.
  Future<void> _handlePublicRecipeDrop(
    DateTime day,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> plans,
    int index,
    RecipeSuggestion s,
  ) async {
    final key = suggestionKey(s);
    setState(() => adoptingSuggestions[key] = null);
    String? recipeId;
    try {
      final preloadFuture =
          publicPreload.remove(s.publicId!) ?? preloadPublicRecipe(s.publicId!);
      final preload = await preloadFuture;
      final result = await adoptPublicRecipeFromPreload(
        groupId: widget.groupId,
        publicRecipeId: s.publicId!,
        preload: preload,
        uid: FirebaseAuth.instance.currentUser!.uid,
        lang: LanguageService.instance.code.value,
      );
      recipeId = result.recipeId;
      _resolveAdoptedTile(key, recipeId);
      if (mounted) setState(() => uploadingRecipeIds.add(recipeId!));
      result.imageUpload.whenComplete(() {
        if (mounted) setState(() => uploadingRecipeIds.remove(recipeId));
      });
    } catch (_) {
      if (mounted) setState(() => adoptingSuggestions.remove(key));
      _snack('Could not adopt this recipe.');
      return;
    }
    if (!mounted || recipeId == null) return;
    final snap = await groupDoc.collection('recipes').doc(recipeId).get();
    if (mounted) handleDrop(day, plans, index, snap);
  }

  /// Keeps a freshly-generated planned recipe's plan tile in the loading state
  /// (via [uploadingRecipeIds]) until its AI image (generation stage 4) lands —
  /// signalled by the doc's `pending` no longer listing `image`, an image being
  /// written, or a generation error — then clears it.
  void _trackImageGeneration(String recipeId) {
    if (!mounted) return;
    setState(() => uploadingRecipeIds.add(recipeId));
    late final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> sub;
    sub = groupDoc.collection('recipes').doc(recipeId).snapshots().listen((snap) {
      final data = snap.data();
      if (data == null) return;
      final pending = List<String>.from(data['pending'] ?? const []);
      final hasImage = (data['images'] as List?)?.isNotEmpty ?? false;
      final done = data['generationError'] == true ||
          hasImage ||
          (data.containsKey('pending') && !pending.contains('image'));
      if (!done) return;
      sub.cancel();
      imageTrackSubs.remove(sub);
      if (mounted) setState(() => uploadingRecipeIds.remove(recipeId));
    });
    imageTrackSubs.add(sub);
  }

  // ── create menu (plus button) ──────────────────────────────────────────────

  void addNewRecipe({String? name}) async {
    final newRecipeRef = await _createRecipeDoc(name: name ?? searchQuery);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RecipeDetailPage(
            groupId: widget.groupId,
            recipeId: newRecipeRef.id,
            editMode: true,
            access: widget.access,
          ),
        ),
      );
    }
  }

  Future<void> openCreateMenu() async {
    final result = await showModalBottomSheet<CreateRecipeResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CreateRecipeSheet(access: widget.access),
    );
    if (result == null || !mounted) return;
    switch (result.type) {
      case CreateRecipeType.blank:
        addNewRecipe(name: result.text ?? '');
        break;
      case CreateRecipeType.photo:
        _createFromPhoto();
        break;
      case CreateRecipeType.text:
        _createFromText(result.text ?? '');
        break;
    }
  }

  Future<void> _createFromText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final url = extractUrl(t);
    if (url != null) {
      final existing = _findRecipeIdByUrl(url);
      if (existing != null) {
        if (mounted) _pushDetail(existing);
        return;
      }
    }
    if (!widget.access.hasGenerationQuota) {
      _snack("You've used all your AI generations for this month.");
      return;
    }
    final name = url != null ? '' : t;
    final ref = groupDoc.collection('recipes').doc();
    ref.set(_recipeSeedDoc(name: name, attribution: url));
    _pushDetail(ref.id,
        generating: true, initialData: _seedData(name, attribution: url));
    _callStaged(
      ref.id,
      url != null
          ? RecipeSuggestion(kind: SuggestionKind.url, title: t, url: url)
          : RecipeSuggestion(kind: SuggestionKind.name, title: t),
    ).ignore();
  }

  Future<void> _createFromPhoto() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      imageQuality: 70,
    );
    if (image == null || !mounted) return;
    if (!widget.access.hasGenerationQuota) {
      _snack("You've used all your AI generations for this month.");
      return;
    }
    final bytes = await image.readAsBytes();
    final ref = await _createRecipeDoc(name: '');
    if (!mounted) return;
    _pushDetail(ref.id, generating: true, initialData: _seedData(''));
    try {
      await functions.httpsCallable('recipes-generateRecipeStaged').call(<String, dynamic>{
        'groupId': widget.groupId,
        'recipeId': ref.id,
        'source': 'photo',
        'imageBase64': base64Encode(bytes),
        'imageMimeType': image.mimeType ?? 'image/jpeg',
        'lang': LanguageService.instance.code.value,
      });
    } catch (e) {
      final msg = aiLimitMessage(e);
      if (msg != null && mounted) _snack(msg);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}
