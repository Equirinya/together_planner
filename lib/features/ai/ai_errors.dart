import 'package:cloud_functions/cloud_functions.dart';

/// Maps a Cloud Functions error to a friendly, user-facing message for the two
/// AI-entitlement failures the backend raises: hitting the monthly generation
/// limit (`resource-exhausted`) and using a feature the plan doesn't include
/// (`permission-denied`). Returns null for anything else so callers can fall
/// back to their own message.
String? aiLimitMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    switch (error.code) {
      case 'resource-exhausted':
        return "You've used all your AI generations for this month. "
            'Your limit resets at the start of next month.';
      case 'permission-denied':
        return "That AI feature isn't part of your current plan.";
    }
  }
  return null;
}
