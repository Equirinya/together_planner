import 'package:flutter/material.dart';

/// Optional tag on an expense. Purely cosmetic today (icon + label); kept as a
/// stable key so a later "spending by category" view needs no migration.
class MoneyCategory {
  const MoneyCategory(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

const List<MoneyCategory> kMoneyCategories = [
  MoneyCategory('groceries', 'Groceries', Icons.shopping_basket_outlined),
  MoneyCategory('eatingOut', 'Eating out', Icons.restaurant_outlined),
  MoneyCategory('home', 'Home', Icons.home_outlined),
  MoneyCategory('utilities', 'Bills', Icons.receipt_long_outlined),
  MoneyCategory('transport', 'Transport', Icons.directions_car_outlined),
  MoneyCategory('travel', 'Travel', Icons.flight_outlined),
  MoneyCategory('fun', 'Fun', Icons.celebration_outlined),
  MoneyCategory('health', 'Health', Icons.favorite_outline),
  MoneyCategory('gifts', 'Gifts', Icons.card_giftcard_outlined),
  MoneyCategory('other', 'Other', Icons.category_outlined),
];

MoneyCategory? moneyCategory(String? key) {
  if (key == null || key.isEmpty) return null;
  for (final c in kMoneyCategories) {
    if (c.key == key) return c;
  }
  return null;
}

IconData moneyCategoryIcon(String? key) =>
    moneyCategory(key)?.icon ?? Icons.receipt_outlined;

/// Words that suggest a category, in English and German.
///
/// Two rules keep this from misfiring, both enforced in [guessMoneyCategory]:
///
///   * a keyword of three letters or fewer only matches a whole word, so "bar"
///     does not fire on "Barbara" and "Eis" does not fire on "Reis";
///   * everything longer also matches inside a word, which is what makes
///     German compounds work: "Wocheneinkauf" finds "einkauf",
///     "Supermarkteinkauf" finds "supermarkt".
///
/// Where two keywords both hit, the longer one wins. That is what keeps
/// "Baumarkt" out of groceries (it contains "markt", but "baumarkt" is longer)
/// and "Buchung" out of fun (it contains "buch", but "buchung" is longer).
const Map<String, List<String>> kMoneyCategoryKeywords = {
  'groceries': [
    // English
    'groceries', 'grocery', 'supermarket', 'market', 'food shopping',
    'produce', 'bakery', 'butcher',
    // German
    'einkauf', 'einkaufen', 'lebensmittel', 'supermarkt', 'wocheneinkauf',
    'markt', 'obst', 'gemüse', 'brot', 'baguette', 'nudeln', 'pasta',
    'bäcker', 'bäckerei', 'metzger', 'fleischer', 'milch', 'käse', 'getränke',
    // Shops
    'aldi', 'lidl', 'rewe', 'edeka', 'penny', 'netto', 'kaufland', 'norma',
    'denns', 'alnatura', 'tegut', 'dm', 'rossmann', 'migros', 'billa',
    'hofer', 'tesco', 'sainsbury', 'walmart', 'costco', 'whole foods',
  ],
  'eatingOut': [
    // English
    'restaurant', 'dinner', 'lunch', 'breakfast', 'brunch', 'cafe', 'coffee',
    'bar', 'pub', 'drinks', 'takeaway', 'takeout', 'pizza', 'burger', 'sushi',
    'kebab', 'ice cream',
    // German
    'essen', 'mittagessen', 'abendessen', 'frühstück', 'gaststätte', 'imbiss',
    'döner', 'pommes', 'kaffee', 'kuchen', 'kneipe', 'bier', 'wein',
    'cocktail', 'eis', 'eisdiele', 'mensa', 'lieferung', 'trinkgeld',
    // Places
    'mcdonalds', 'burger king', 'subway', 'starbucks', 'kfc', 'dominos',
    'lieferando', 'wolt', 'uber eats',
  ],
  'home': [
    // English
    'rent', 'furniture', 'household', 'cleaning', 'repair', 'hardware',
    'garden', 'kitchen', 'decor',
    // German
    'miete', 'nebenkosten', 'möbel', 'haushalt', 'putzen', 'reinigung',
    'reparatur', 'baumarkt', 'garten', 'küche', 'deko', 'umzug', 'handwerker',
    'werkzeug',
    // Shops
    'ikea', 'obi', 'bauhaus', 'hornbach', 'toom',
  ],
  'utilities': [
    // English
    'bill', 'electricity', 'power', 'gas', 'water', 'heating', 'internet',
    'phone', 'mobile', 'insurance', 'subscription', 'fee', 'tax',
    // German
    'rechnung', 'strom', 'wasser', 'heizung', 'telefon', 'handy',
    'versicherung', 'abo', 'abonnement', 'gebühr', 'rundfunk', 'steuer',
    'beitrag',
    // Providers
    'telekom', 'vodafone', 'netflix', 'spotify', 'disney', 'prime',
  ],
  'transport': [
    // English
    'fuel', 'petrol', 'gas station', 'parking', 'taxi', 'bus', 'train',
    'ticket', 'car', 'bike', 'metro',
    // German
    'benzin', 'diesel', 'tanken', 'tankstelle', 'sprit', 'parken', 'parkhaus',
    'bahn', 'zug', 'fahrkarte', 'fahrschein', 'deutschlandticket', 'auto',
    'werkstatt', 'fahrrad', 'u-bahn', 's-bahn', 'straßenbahn', 'maut',
    // Providers
    'uber', 'bolt', 'flixbus', 'db', 'bvg', 'mvg', 'adac', 'shell', 'aral',
    'esso', 'easypark',
  ],
  'travel': [
    // English
    'flight', 'hotel', 'hostel', 'holiday', 'vacation', 'trip', 'luggage',
    'booking', 'airport', 'accommodation',
    // German
    'flug', 'urlaub', 'reise', 'ferien', 'unterkunft', 'gepäck', 'koffer',
    'flughafen', 'ausflug', 'camping', 'pension', 'buchung',
    // Providers
    'airbnb', 'ryanair', 'lufthansa', 'easyjet', 'eurowings', 'booking com',
  ],
  'fun': [
    // English
    'cinema', 'movie', 'concert', 'museum', 'theatre', 'theater', 'game',
    'sport', 'gym', 'club', 'party', 'festival', 'book', 'hobby',
    // German
    'kino', 'film', 'konzert', 'theater', 'spiel', 'fitness',
    'fitnessstudio', 'verein', 'schwimmbad', 'zoo', 'freizeit', 'eintritt',
    'buch', 'ausstellung', 'oper',
  ],
  'health': [
    // English
    'pharmacy', 'doctor', 'dentist', 'medicine', 'hospital', 'therapy',
    'glasses', 'prescription',
    // German
    'apotheke', 'arzt', 'ärztin', 'zahnarzt', 'medikament', 'krankenhaus',
    'therapie', 'brille', 'rezept', 'physio', 'praxis', 'optiker',
    'krankenkasse',
  ],
  'gifts': [
    // English
    'gift', 'present', 'birthday', 'christmas', 'wedding', 'flowers',
    'souvenir',
    // German
    'geschenk', 'geburtstag', 'weihnachten', 'hochzeit', 'blumen',
    'mitbringsel', 'ostern', 'jubiläum',
  ],
};

/// Words that name a *kind of document* rather than a subject, written folded
/// (no umlauts) to match the comparison form.
///
/// These only ever match as a whole word. Left to the compound rule they would
/// hijack anything they appear in: "Zahnarztrechnung" is a health expense, not
/// a utility bill, and "Kinoticket" is an evening out, not a train fare. On
/// their own they still mean what they say, so a bare "Rechnung" is a bill.
const Set<String> _wholeWordOnly = {
  'rechnung', 'bill', 'fee', 'gebuhr', 'beitrag', 'ticket', 'abo', 'tax',
};

/// Folds case and umlauts so "Bäckerei" and "backerei" are the same word.
String _fold(String value) => value
    .toLowerCase()
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('ß', 'ss');

/// The category [description] suggests, or null when nothing matches.
///
/// Longest keyword wins, so a more specific word beats a more general one that
/// happens to be inside it.
String? guessMoneyCategory(String description) {
  final text = _fold(description).trim();
  if (text.isEmpty) return null;
  final words = text
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return null;

  String? best;
  var bestLength = 0;
  kMoneyCategoryKeywords.forEach((category, keywords) {
    for (final raw in keywords) {
      final keyword = _fold(raw);
      if (keyword.length <= bestLength) continue;
      if (_matchesKeyword(text, words, keyword)) {
        best = category;
        bestLength = keyword.length;
      }
    }
  });
  return best;
}

bool _matchesKeyword(String text, List<String> words, String keyword) {
  // A keyword with a space or a hyphen in it is a phrase, matched against the
  // whole description rather than a single word.
  if (RegExp(r'[^a-z0-9]').hasMatch(keyword)) return text.contains(keyword);
  final exactOnly = keyword.length < 4 || _wholeWordOnly.contains(keyword);
  for (final word in words) {
    if (word == keyword) return true;
    if (!exactOnly && word.contains(keyword)) return true;
  }
  return false;
}
