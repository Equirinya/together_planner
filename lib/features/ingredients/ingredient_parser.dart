import 'package:couple_planner/features/ingredients/models/ingredients.dart';
import 'package:couple_planner/features/ingredients/services/units_cache.dart';

// =============================================================================
// Input parser
// =============================================================================

num? _tryNum(String s) => num.tryParse(s.replaceAll(',', '.'));

/// Splits glued tokens ("300g"), extracts a leading/trailing number as the
/// quantity, then a unit word adjacent to it (only when it matches the cache).
ParsedInput parseInput(String input) {
  final tokens = input
      .trim()
      .split(RegExp(r'[\s,]+')) // commas act as separators
      .where((t) => t.isNotEmpty)
      .expand<String>((t) {
    final glued =
        RegExp(r'^(\d+[.,]?\d*)([a-zA-ZäöüÄÖÜß]+)$').firstMatch(t) ??
            RegExp(r'^([a-zA-ZäöüÄÖÜß]+)(\d+[.,]?\d*)$').firstMatch(t);
    return glued != null ? [glued.group(1)!, glued.group(2)!] : [t];
  })
      .toList();

  num? qty;
  if (tokens.isNotEmpty && _tryNum(tokens.first) != null) {
    qty = _tryNum(tokens.removeAt(0));
  } else if (tokens.isNotEmpty && _tryNum(tokens.last) != null) {
    qty = _tryNum(tokens.removeLast());
  }

  String? unitId;
  if (tokens.isNotEmpty) {
    if (UnitsCache.instance.matchWord(tokens.first) case final u?) {
      unitId = u.id;
      tokens.removeAt(0);
    } else if (tokens.length > 1) {
      if (UnitsCache.instance.matchWord(tokens.last) case final u?) {
        unitId = u.id;
        tokens.removeLast();
      }
    }
  }

  return ParsedInput(qty, unitId, tokens);
}

/// Enumerates (name, description) candidates where description is a leading or
/// trailing word run. Full-name-no-description comes first.
List<({String name, String description})> nameDescCandidates(List<String> tokens) {
  final n = tokens.length;
  if (n == 0) return const [];

  final out = <({String name, String description})>[
    (name: tokens.join(' '), description: ''),
  ];
  for (var i = 1; i < n; i++) {
    out.add((name: tokens.sublist(i).join(' '), description: tokens.sublist(0, i).join(' ')));
    out.add((name: tokens.sublist(0, n - i).join(' '), description: tokens.sublist(n - i).join(' ')));
  }

  final seen = <String>{};
  return out.where((c) => c.name.isNotEmpty && seen.add('${c.name}|${c.description}')).toList();
}

/// Progressively shorter substrings to try when resolving a pending item.
List<String> subsetCandidates(String displayName) {
  final tokens =
  displayName.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final n = tokens.length;

  final out = [
    tokens.join(' '),
    for (var i = 1; i < n; i++) tokens.sublist(i).join(' '),
    for (var j = 1; j < n; j++) tokens.sublist(0, n - j).join(' '),
    ...tokens,
  ];

  final seen = <String>{};
  return out.where((s) => seen.add(s.toLowerCase())).toList();
}
