import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reduces any locale tag to a bare 2-letter language code, defaulting to 'en'.
String sanitizeLang(String code) =>
    RegExp(r'^[a-z]{2}').firstMatch(code.toLowerCase())?.group(0) ?? 'en';

/// A selectable language: its 2-letter ISO 639-1 [code], the [name] as written
/// in that language, and its [english] name (both searchable in the picker).
typedef LanguageOption = ({String code, String name, String english});

/// Every ISO 639-1 language, sorted by English name.
const List<LanguageOption> kLanguages = [
  (code: 'ab', name: 'Аԥсшәа', english: 'Abkhazian'),
  (code: 'aa', name: 'Afar', english: 'Afar'),
  (code: 'af', name: 'Afrikaans', english: 'Afrikaans'),
  (code: 'ak', name: 'Akan', english: 'Akan'),
  (code: 'sq', name: 'shqip', english: 'Albanian'),
  (code: 'am', name: 'አማርኛ', english: 'Amharic'),
  (code: 'ar', name: 'العربية', english: 'Arabic'),
  (code: 'an', name: 'aragonés', english: 'Aragonese'),
  (code: 'hy', name: 'հայերեն', english: 'Armenian'),
  (code: 'as', name: 'অসমীয়া', english: 'Assamese'),
  (code: 'av', name: 'Avaric', english: 'Avaric'),
  (code: 'ae', name: 'Avestan', english: 'Avestan'),
  (code: 'ay', name: 'Aymara', english: 'Aymara'),
  (code: 'az', name: 'azərbaycan', english: 'Azerbaijani'),
  (code: 'bm', name: 'bamanakan', english: 'Bambara'),
  (code: 'ba', name: 'башҡорт теле', english: 'Bashkir'),
  (code: 'eu', name: 'euskara', english: 'Basque'),
  (code: 'be', name: 'беларуская', english: 'Belarusian'),
  (code: 'bn', name: 'বাংলা', english: 'Bengali'),
  (code: 'bi', name: 'Bislama', english: 'Bislama'),
  (code: 'bs', name: 'bosanski', english: 'Bosnian'),
  (code: 'br', name: 'brezhoneg', english: 'Breton'),
  (code: 'bg', name: 'български', english: 'Bulgarian'),
  (code: 'my', name: 'မြန်မာ', english: 'Burmese'),
  (code: 'ca', name: 'català', english: 'Catalan'),
  (code: 'ch', name: 'Chamorro', english: 'Chamorro'),
  (code: 'ce', name: 'нохчийн', english: 'Chechen'),
  (code: 'ny', name: 'Nyanja', english: 'Chichewa'),
  (code: 'zh', name: '中文', english: 'Chinese'),
  (code: 'cu', name: 'Church Slavic', english: 'Church Slavic'),
  (code: 'cv', name: 'чӑваш', english: 'Chuvash'),
  (code: 'kw', name: 'kernewek', english: 'Cornish'),
  (code: 'co', name: 'corsu', english: 'Corsican'),
  (code: 'cr', name: 'Cree', english: 'Cree'),
  (code: 'hr', name: 'hrvatski', english: 'Croatian'),
  (code: 'cs', name: 'čeština', english: 'Czech'),
  (code: 'da', name: 'dansk', english: 'Danish'),
  (code: 'dv', name: 'Divehi', english: 'Divehi'),
  (code: 'nl', name: 'Nederlands', english: 'Dutch'),
  (code: 'dz', name: 'རྫོང་ཁ', english: 'Dzongkha'),
  (code: 'en', name: 'English', english: 'English'),
  (code: 'eo', name: 'Esperanto', english: 'Esperanto'),
  (code: 'et', name: 'eesti', english: 'Estonian'),
  (code: 'ee', name: 'eʋegbe', english: 'Ewe'),
  (code: 'fo', name: 'føroyskt', english: 'Faroese'),
  (code: 'fj', name: 'Fijian', english: 'Fijian'),
  (code: 'fi', name: 'suomi', english: 'Finnish'),
  (code: 'fr', name: 'français', english: 'French'),
  (code: 'ff', name: 'Pulaar', english: 'Fulah'),
  (code: 'gl', name: 'galego', english: 'Galician'),
  (code: 'lg', name: 'Luganda', english: 'Ganda'),
  (code: 'ka', name: 'ქართული', english: 'Georgian'),
  (code: 'de', name: 'Deutsch', english: 'German'),
  (code: 'gn', name: 'avañe’ẽ', english: 'Guarani'),
  (code: 'gu', name: 'ગુજરાતી', english: 'Gujarati'),
  (code: 'ht', name: 'Kreyòl Ayisyen', english: 'Haitian'),
  (code: 'ha', name: 'Hausa', english: 'Hausa'),
  (code: 'he', name: 'עברית', english: 'Hebrew'),
  (code: 'hz', name: 'Herero', english: 'Herero'),
  (code: 'hi', name: 'हिन्दी', english: 'Hindi'),
  (code: 'ho', name: 'Hiri Motu', english: 'Hiri Motu'),
  (code: 'hu', name: 'magyar', english: 'Hungarian'),
  (code: 'is', name: 'íslenska', english: 'Icelandic'),
  (code: 'io', name: 'Ido', english: 'Ido'),
  (code: 'ig', name: 'Igbo', english: 'Igbo'),
  (code: 'id', name: 'bahasa Indonesia', english: 'Indonesian'),
  (code: 'ia', name: 'interlingua', english: 'Interlingua (International Auxiliary Language Association)'),
  (code: 'ie', name: 'Interlingue', english: 'Interlingue'),
  (code: 'iu', name: 'Inuktitut', english: 'Inuktitut'),
  (code: 'ik', name: 'Inupiaq', english: 'Inupiaq'),
  (code: 'ga', name: 'Gaeilge', english: 'Irish'),
  (code: 'it', name: 'italiano', english: 'Italian'),
  (code: 'ja', name: '日本語', english: 'Japanese'),
  (code: 'jv', name: 'Jawa', english: 'Javanese'),
  (code: 'kl', name: 'kalaallisut', english: 'Kalaallisut'),
  (code: 'kn', name: 'ಕನ್ನಡ', english: 'Kannada'),
  (code: 'kr', name: 'Kanuri', english: 'Kanuri'),
  (code: 'ks', name: 'کٲشُر', english: 'Kashmiri'),
  (code: 'kk', name: 'қазақ тілі', english: 'Kazakh'),
  (code: 'km', name: 'ខ្មែរ', english: 'Khmer'),
  (code: 'ki', name: 'Gikuyu', english: 'Kikuyu'),
  (code: 'rw', name: 'Ikinyarwanda', english: 'Kinyarwanda'),
  (code: 'ky', name: 'кыргызча', english: 'Kirghiz'),
  (code: 'kv', name: 'Komi', english: 'Komi'),
  (code: 'kg', name: 'Kongo', english: 'Kongo'),
  (code: 'ko', name: '한국어', english: 'Korean'),
  (code: 'kj', name: 'Kuanyama', english: 'Kuanyama'),
  (code: 'ku', name: 'kurdî (kurmancî)', english: 'Kurdish'),
  (code: 'lo', name: 'ລາວ', english: 'Lao'),
  (code: 'la', name: 'Lingua latina', english: 'Latin'),
  (code: 'lv', name: 'latviešu', english: 'Latvian'),
  (code: 'li', name: 'Limburgish', english: 'Limburgan'),
  (code: 'ln', name: 'lingála', english: 'Lingala'),
  (code: 'lt', name: 'lietuvių', english: 'Lithuanian'),
  (code: 'lu', name: 'Tshiluba', english: 'Luba-Katanga'),
  (code: 'lb', name: 'Lëtzebuergesch', english: 'Luxembourgish'),
  (code: 'mk', name: 'македонски', english: 'Macedonian'),
  (code: 'mg', name: 'Malagasy', english: 'Malagasy'),
  (code: 'ms', name: 'bahasa Malaysia', english: 'Malay (macrolanguage)'),
  (code: 'ml', name: 'മലയാളം', english: 'Malayalam'),
  (code: 'mt', name: 'Malti', english: 'Maltese'),
  (code: 'gv', name: 'Gaelg', english: 'Manx'),
  (code: 'mi', name: 'Māori', english: 'Maori'),
  (code: 'mr', name: 'मराठी', english: 'Marathi'),
  (code: 'mh', name: 'Marshallese', english: 'Marshallese'),
  (code: 'el', name: 'Ελληνικά', english: 'Modern Greek (1453-)'),
  (code: 'mn', name: 'монгол', english: 'Mongolian'),
  (code: 'na', name: 'Nauru', english: 'Nauru'),
  (code: 'nv', name: 'Diné Bizaad', english: 'Navajo'),
  (code: 'ng', name: 'Ndonga', english: 'Ndonga'),
  (code: 'ne', name: 'नेपाली', english: 'Nepali (macrolanguage)'),
  (code: 'nd', name: 'isiNdebele', english: 'North Ndebele'),
  (code: 'se', name: 'davvisámegiella', english: 'Northern Sami'),
  (code: 'no', name: 'norsk', english: 'Norwegian'),
  (code: 'nb', name: 'norsk bokmål', english: 'Norwegian Bokmål'),
  (code: 'nn', name: 'norsk nynorsk', english: 'Norwegian Nynorsk'),
  (code: 'oc', name: 'occitan', english: 'Occitan (post 1500)'),
  (code: 'oj', name: 'Ojibwa', english: 'Ojibwa'),
  (code: 'or', name: 'ଓଡ଼ିଆ', english: 'Oriya (macrolanguage)'),
  (code: 'om', name: 'Oromoo', english: 'Oromo'),
  (code: 'os', name: 'ирон', english: 'Ossetian'),
  (code: 'pi', name: 'Pali', english: 'Pali'),
  (code: 'pa', name: 'ਪੰਜਾਬੀ', english: 'Panjabi'),
  (code: 'fa', name: 'فارسی', english: 'Persian'),
  (code: 'pl', name: 'polski', english: 'Polish'),
  (code: 'pt', name: 'português', english: 'Portuguese'),
  (code: 'ps', name: 'پښتو', english: 'Pushto'),
  (code: 'qu', name: 'Runasimi', english: 'Quechua'),
  (code: 'ro', name: 'română', english: 'Romanian'),
  (code: 'rm', name: 'rumantsch', english: 'Romansh'),
  (code: 'rn', name: 'Ikirundi', english: 'Rundi'),
  (code: 'ru', name: 'русский', english: 'Russian'),
  (code: 'sm', name: 'Samoan', english: 'Samoan'),
  (code: 'sg', name: 'Sängö', english: 'Sango'),
  (code: 'sa', name: 'संस्कृत भाषा', english: 'Sanskrit'),
  (code: 'sc', name: 'sardu', english: 'Sardinian'),
  (code: 'gd', name: 'Gàidhlig', english: 'Scottish Gaelic'),
  (code: 'sr', name: 'српски', english: 'Serbian'),
  (code: 'sh', name: 'srpski (latinica)', english: 'Serbo-Croatian'),
  (code: 'sn', name: 'chiShona', english: 'Shona'),
  (code: 'ii', name: 'ꆈꌠꉙ', english: 'Sichuan Yi'),
  (code: 'sd', name: 'سنڌي', english: 'Sindhi'),
  (code: 'si', name: 'සිංහල', english: 'Sinhala'),
  (code: 'sk', name: 'slovenčina', english: 'Slovak'),
  (code: 'sl', name: 'slovenščina', english: 'Slovenian'),
  (code: 'so', name: 'Soomaali', english: 'Somali'),
  (code: 'nr', name: 'South Ndebele', english: 'South Ndebele'),
  (code: 'st', name: 'Sesotho', english: 'Southern Sotho'),
  (code: 'es', name: 'español', english: 'Spanish'),
  (code: 'su', name: 'Basa Sunda', english: 'Sundanese'),
  (code: 'sw', name: 'Kiswahili', english: 'Swahili (macrolanguage)'),
  (code: 'ss', name: 'siSwati', english: 'Swati'),
  (code: 'sv', name: 'svenska', english: 'Swedish'),
  (code: 'tl', name: 'Filipino', english: 'Tagalog'),
  (code: 'ty', name: 'Tahitian', english: 'Tahitian'),
  (code: 'tg', name: 'тоҷикӣ', english: 'Tajik'),
  (code: 'ta', name: 'தமிழ்', english: 'Tamil'),
  (code: 'tt', name: 'татар', english: 'Tatar'),
  (code: 'te', name: 'తెలుగు', english: 'Telugu'),
  (code: 'th', name: 'ไทย', english: 'Thai'),
  (code: 'bo', name: 'བོད་སྐད་', english: 'Tibetan'),
  (code: 'ti', name: 'ትግርኛ', english: 'Tigrinya'),
  (code: 'to', name: 'lea fakatonga', english: 'Tonga (Tonga Islands)'),
  (code: 'ts', name: 'Tsonga', english: 'Tsonga'),
  (code: 'tn', name: 'Setswana', english: 'Tswana'),
  (code: 'tr', name: 'Türkçe', english: 'Turkish'),
  (code: 'tk', name: 'türkmen dili', english: 'Turkmen'),
  (code: 'tw', name: 'Twi', english: 'Twi'),
  (code: 'ug', name: 'ئۇيغۇرچە', english: 'Uighur'),
  (code: 'uk', name: 'українська', english: 'Ukrainian'),
  (code: 'ur', name: 'اردو', english: 'Urdu'),
  (code: 'uz', name: 'o‘zbek', english: 'Uzbek'),
  (code: 've', name: 'tshiVenḓa', english: 'Venda'),
  (code: 'vi', name: 'Tiếng Việt', english: 'Vietnamese'),
  (code: 'vo', name: 'Volapük', english: 'Volapük'),
  (code: 'wa', name: 'walon', english: 'Walloon'),
  (code: 'cy', name: 'Cymraeg', english: 'Welsh'),
  (code: 'fy', name: 'Frysk', english: 'Western Frisian'),
  (code: 'wo', name: 'Wolof', english: 'Wolof'),
  (code: 'xh', name: 'IsiXhosa', english: 'Xhosa'),
  (code: 'yi', name: 'ייִדיש', english: 'Yiddish'),
  (code: 'yo', name: 'Èdè Yorùbá', english: 'Yoruba'),
  (code: 'za', name: 'Vahcuengh', english: 'Zhuang'),
  (code: 'zu', name: 'isiZulu', english: 'Zulu'),
];

/// The language option for [code], or null when it isn't in [kLanguages].
LanguageOption? languageOptionFor(String code) {
  for (final l in kLanguages) {
    if (l.code == code) return l;
  }
  return null;
}

/// App language, split into the device language and an optional user override.
///
/// App strings are English for now; [code] is the language passed alongside
/// backend operations (ingredient/recipe localization). A null override means
/// "follow the device". The effective, sanitized code is exposed via [code] so
/// widgets can rebuild when it changes.
class LanguageService {
  LanguageService._();
  static final LanguageService instance = LanguageService._();

  static const _prefsKey = 'language_override';

  /// The effective language code (override, else device), always sanitized.
  final ValueNotifier<String> code = ValueNotifier(_deviceCode());

  String? _override;

  static String _deviceCode() => sanitizeLang(
      WidgetsBinding.instance.platformDispatcher.locale.languageCode);

  /// The device's current language, sanitized to a bare 2-letter code.
  String get deviceCode => _deviceCode();

  /// The user's chosen override, or null when following the device.
  String? get override => _override;

  /// Whether the effective language follows the device.
  bool get isFollowingDevice => _override == null;

  /// Load the stored override and publish the effective code. Call before
  /// runApp so the first frame already has the right language.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _override = prefs.getString(_prefsKey);
    code.value = _override ?? deviceCode;
  }

  /// Set (or clear, with null) the override, persist it, and publish the new
  /// effective code.
  Future<void> setOverride(String? lang) async {
    _override = lang;
    final prefs = await SharedPreferences.getInstance();
    if (lang == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, lang);
    }
    code.value = lang ?? deviceCode;
  }
}
