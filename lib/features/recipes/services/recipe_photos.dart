import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img_lib;
import 'package:image_picker/image_picker.dart';

/// How many photos one "create a recipe from photos" run may use. They are all
/// treated as views/pages of a SINGLE recipe (e.g. both sides of a recipe card,
/// consecutive cookbook pages, the dish plus its ingredient list).
///
/// Kept in sync with `MAX_RECIPE_PHOTOS` in
/// firebase/functions/src/recipes/generateRecipeStaged.ts, which enforces the
/// same cap server-side.
const int maxRecipePhotos = 5;

/// The width every photo is downscaled to before it is sent. Large enough for
/// the model to read printed recipe text, small enough that [maxRecipePhotos]
/// photos still fit comfortably inside the callable's request-size limit.
const int _maxPhotoWidth = 1280;

/// One entry of the `images` argument of the `generateRecipeStaged` callable.
Map<String, String> recipePhotoPayload(List<int> bytes, String? mimeType) =>
    <String, String>{
      'base64': base64Encode(bytes),
      'mimeType': mimeType ?? 'image/jpeg',
    };

/// Reads and encodes picked photos into the `images` argument of
/// `generateRecipeStaged`, keeping the order they were picked in (the model is
/// told to read them as one recipe in that order) and never sending more than
/// [maxRecipePhotos] — the picker's own `limit` is only a hint on some
/// platforms. The picker already downscales, so the bytes are sent as-is.
Future<List<Map<String, String>>> encodeRecipePhotos(List<XFile> files) async {
  final capped = files.take(maxRecipePhotos);
  return Future.wait(capped.map((file) async =>
      recipePhotoPayload(await file.readAsBytes(), file.mimeType)));
}

/// Encodes a photo that came from another app's share sheet, where the bytes
/// are the untouched original and several full-resolution photos would
/// otherwise blow past the callable's request-size limit. Falls back to the
/// original bytes if the image can't be decoded.
Future<Map<String, String>> encodeSharedRecipePhoto(
  Uint8List bytes,
  String? mimeType,
) async {
  final resized = await compute(_downscaleToJpeg, bytes);
  return resized == null
      ? recipePhotoPayload(bytes, mimeType)
      : recipePhotoPayload(resized, 'image/jpeg');
}

/// Decodes [bytes], shrinks the image to at most [_maxPhotoWidth] wide and
/// re-encodes it as JPEG. Returns null when the bytes aren't a decodable image.
/// Runs in a background isolate via [compute].
Uint8List? _downscaleToJpeg(Uint8List bytes) {
  final decoded = img_lib.decodeImage(bytes);
  if (decoded == null) return null;
  final scaled = decoded.width > _maxPhotoWidth
      ? img_lib.copyResize(decoded, width: _maxPhotoWidth)
      : decoded;
  return img_lib.encodeJpg(scaled, quality: 70);
}
