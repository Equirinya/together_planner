/// Money formatting and parsing for a single group currency.
///
/// Amounts are stored and passed around as **integer minor units** (cents)
/// everywhere in this feature — never as doubles. Floating point money is the
/// classic source of balances that fail to reach exactly zero, and the whole
/// settle-up algorithm depends on them reaching exactly zero.
///
/// Hand-rolled rather than pulled from `intl`: the app has no localisation
/// dependency today, and what is needed here is small and well defined.
class MoneyFormat {
  const MoneyFormat(this.currency);

  final String currency;

  /// Currencies with no minor unit, or with three of them. Everything else has
  /// the usual two.
  static const Map<String, int> _decimals = {
    'JPY': 0, 'KRW': 0, 'VND': 0, 'CLP': 0, 'ISK': 0, 'HUF': 0, 'TWD': 0,
    'BHD': 3, 'KWD': 3, 'OMR': 3, 'TND': 3, 'JOD': 3, 'IQD': 3, 'LYD': 3,
  };

  static const Map<String, String> _symbols = {
    'EUR': '€', 'USD': '\$', 'GBP': '£', 'JPY': '¥',
    'CHF': 'CHF', 'SEK': 'kr', 'NOK': 'kr', 'DKK': 'kr', 'PLN': 'zł',
    'CZK': 'Kč', 'HUF': 'Ft', 'RON': 'lei', 'BGN': 'лв',
    'TRY': '₺', 'RUB': '₽', 'UAH': '₴', 'INR': '₹',
    'CNY': '¥', 'KRW': '₩', 'BRL': 'R\$', 'MXN': '\$',
    'CAD': '\$', 'AUD': '\$', 'NZD': '\$', 'ZAR': 'R', 'ILS': '₪',
    'THB': '฿', 'VND': '₫', 'PHP': '₱', 'IDR': 'Rp',
  };

  /// Currencies conventionally written `1.234,56 X` rather than `X1,234.56`.
  static const Set<String> _suffixStyle = {
    'EUR', 'SEK', 'NOK', 'DKK', 'PLN', 'CZK', 'HUF', 'RON', 'BGN', 'TRY',
    'RUB', 'UAH', 'VND', 'CHF',
  };

  /// The short list offered in the currency picker. Anything else can still be
  /// stored; it just renders with its ISO code as the symbol.
  static const List<String> common = [
    'EUR', 'USD', 'GBP', 'CHF', 'SEK', 'NOK', 'DKK', 'PLN', 'CZK', 'HUF',
    'RON', 'BGN', 'TRY', 'CAD', 'AUD', 'NZD', 'JPY', 'CNY', 'INR', 'BRL',
    'MXN', 'ZAR', 'ILS', 'THB', 'PHP', 'IDR', 'KRW',
  ];

  int get decimals => _decimals[currency] ?? 2;

  String get symbol => _symbols[currency] ?? currency;

  bool get _suffix => _suffixStyle.contains(currency);

  /// The character between the whole part and the minor units, by the
  /// convention of this currency. Public because the input formatters need to
  /// agree with what [format] and [toInput] produce.
  String get decimalSeparator => _suffix ? ',' : '.';

  String get _groupSeparator => _suffix ? '.' : ',';

  /// Renders [minorUnits], e.g. `12.30 EUR` becomes `12,30 €`.
  ///
  /// With [signed], a positive amount gets a leading `+`. With [alwaysSign]
  /// off and a negative amount, the minus sign is kept.
  String format(int minorUnits, {bool signed = false}) {
    final negative = minorUnits < 0;
    final digits = _digits(minorUnits.abs());
    // A non-breaking space, so an amount never wraps away from its symbol.
    // Written as an escape on purpose: a literal one here is invisible in
    // the source and silently breaks anything comparing the output.
    final body = _suffix ? '$digits\u00A0$symbol' : '$symbol$digits';
    if (negative) return '-$body';
    if (signed) return '+$body';
    return body;
  }

  /// Renders the absolute value, for sentences that already carry the
  /// direction ("you owe …").
  String formatAbs(int minorUnits) => format(minorUnits.abs());

  String _digits(int value) {
    final d = decimals;
    if (d == 0) return _group(value.toString());
    final unit = _pow10(d);
    final whole = value ~/ unit;
    final fraction = (value % unit).toString().padLeft(d, '0');
    return '${_group(whole.toString())}$decimalSeparator$fraction';
  }

  String _group(String whole) {
    if (whole.length <= 3) return whole;
    final buffer = StringBuffer();
    final firstGroup = whole.length % 3 == 0 ? 3 : whole.length % 3;
    buffer.write(whole.substring(0, firstGroup));
    for (var i = firstGroup; i < whole.length; i += 3) {
      buffer
        ..write(_groupSeparator)
        ..write(whole.substring(i, i + 3));
    }
    return buffer.toString();
  }

  static int _pow10(int exponent) {
    var out = 1;
    for (var i = 0; i < exponent; i++) {
      out *= 10;
    }
    return out;
  }

  /// Parses user input into minor units, accepting both `12.30` and `12,30`
  /// and ignoring spaces, currency symbols and thousands separators.
  ///
  /// When both separators appear, the last one is taken as the decimal point
  /// (`1.234,56` and `1,234.56` both mean the same thing).
  int? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    final negative = text.startsWith('-');
    text = text.replaceAll(RegExp(r'[^0-9.,]'), '');
    if (text.isEmpty) return null;

    final lastDot = text.lastIndexOf('.');
    final lastComma = text.lastIndexOf(',');
    final hasBoth = lastDot != -1 && lastComma != -1;
    final separator = lastDot > lastComma ? lastDot : lastComma;

    String whole;
    String fraction;
    if (separator == -1) {
      whole = text;
      fraction = '';
    } else {
      whole = text.substring(0, separator);
      fraction = text.substring(separator + 1);
      // A lone separator followed by exactly three digits is a thousands
      // separator, not a decimal point: "1.000" and "1,000" both mean 1000.
      // With both separators present the last one is unambiguously decimal.
      if (!hasBoth && fraction.length == 3 && whole.isNotEmpty) {
        whole = '$whole$fraction';
        fraction = '';
      }
    }
    whole = whole.replaceAll(RegExp(r'[.,]'), '');
    fraction = fraction.replaceAll(RegExp(r'[.,]'), '');
    if (whole.isEmpty) whole = '0';

    final d = decimals;
    if (fraction.length > d) {
      fraction = fraction.substring(0, d);
    } else {
      fraction = fraction.padRight(d, '0');
    }

    final wholeValue = int.tryParse(whole);
    final fractionValue = fraction.isEmpty ? 0 : int.tryParse(fraction);
    if (wholeValue == null || fractionValue == null) return null;

    final value = wholeValue * _pow10(d) + fractionValue;
    return negative ? -value : value;
  }

  /// The plain editable text for [minorUnits], without symbol or grouping —
  /// what goes into a text field when an existing expense is edited.
  String toInput(int minorUnits) {
    final d = decimals;
    if (d == 0) return minorUnits.abs().toString();
    final unit = _pow10(d);
    final value = minorUnits.abs();
    return '${value ~/ unit}$decimalSeparator'
        '${(value % unit).toString().padLeft(d, '0')}';
  }
}
