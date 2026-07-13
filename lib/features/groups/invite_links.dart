import 'package:cloud_functions/cloud_functions.dart';

/// Cloud Functions are deployed in this region (see functions/src/index.ts).
const String kFunctionsRegion = 'europe-west1';

/// HTTPS landing page (GitHub Pages, see docs/join.html) that bounces into the
/// app via the coupleplanner://join scheme (registered in the native manifests).
const String kInviteLinkBase = 'https://equirinya.github.io/together_planner/join.html';

String buildInviteLink(String groupId, String inviteId) => '$kInviteLinkBase?g=$groupId&i=$inviteId';

/// Extracts the group/invite ids from an incoming link, accepting both the
/// https landing URL and the coupleplanner://join scheme. Returns null if the
/// URI is not a (well-formed) invite link.
({String groupId, String inviteId})? parseInviteUri(Uri uri) {
  final g = uri.queryParameters['g'];
  final i = uri.queryParameters['i'];
  final looksLikeJoin = uri.host == 'join' || uri.pathSegments.contains('join') || uri.path.contains('join');
  if (looksLikeJoin && g != null && g.isNotEmpty && i != null && i.isNotEmpty) {
    return (groupId: g, inviteId: i);
  }
  return null;
}

/// HTTPS landing page (GitHub Pages, see docs/recipe.html) that bounces into the
/// app via the coupleplanner://recipe scheme, letting someone from another group
/// preview a single shared recipe and save it into their own recipes.
const String kRecipeLinkBase = 'https://equirinya.github.io/together_planner/recipe.html';

String buildRecipeShareLink(String groupId, String recipeId) => '$kRecipeLinkBase?g=$groupId&r=$recipeId';

/// Extracts the group/recipe ids from a single-recipe share link, accepting both
/// the https landing URL and the coupleplanner://recipe scheme. Returns null if
/// the URI is not a (well-formed) recipe share link.
({String groupId, String recipeId})? parseRecipeShareUri(Uri uri) {
  final g = uri.queryParameters['g'];
  final r = uri.queryParameters['r'];
  final looksLikeRecipe = uri.host == 'recipe' || uri.pathSegments.contains('recipe') || uri.path.contains('recipe');
  if (looksLikeRecipe && g != null && g.isNotEmpty && r != null && r.isNotEmpty) {
    return (groupId: g, recipeId: r);
  }
  return null;
}

FirebaseFunctions get _functions => FirebaseFunctions.instanceFor(region: kFunctionsRegion);

/// Returns {name, enabledFeatures, members:[{username, role}], alreadyMember}.
Future<Map<String, dynamic>> previewInvite(String groupId, String inviteId) async {
  final res = await _functions
      .httpsCallable('userManagement-previewInvite')
      .call(<String, dynamic>{'groupId': groupId, 'inviteId': inviteId});
  return Map<String, dynamic>.from(res.data as Map);
}

Future<void> joinGroupViaInvite(String groupId, String inviteId) async {
  await _functions
      .httpsCallable('userManagement-joinGroup')
      .call(<String, dynamic>{'groupId': groupId, 'inviteId': inviteId});
}

Future<void> deleteGroup(String groupId) async {
  await _functions.httpsCallable('userManagement-deleteGroup').call(<String, dynamic>{'groupId': groupId});
}

/// Permanently deletes the signed-in user's account. When [deleteOwnedRecipes]
/// is true, recipes they created in groups that still have other members are
/// deleted too; otherwise those recipes are kept for the remaining members.
Future<void> deleteAccount({required bool deleteOwnedRecipes}) async {
  await _functions
      .httpsCallable('userManagement-deleteAccount')
      .call(<String, dynamic>{'deleteOwnedRecipes': deleteOwnedRecipes});
}
