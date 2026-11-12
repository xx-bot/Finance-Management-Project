import 'package:intl/intl.dart';

enum LedgerCurrency {
  idr('IDR', 'Rp', 'id_ID'),
  myr('MYR', 'RM', 'en_MY'),
  usd('USD', r'$', 'en_US');

  const LedgerCurrency(this.code, this.symbol, this.locale);
  final String code;
  final String symbol;
  final String locale;

  String format(int minor, {bool compact = false}) {
    final value = minor / 100;
    if (compact && value.abs() >= 1000000) {
      return '$symbol ${NumberFormat('0.#', locale).format(value / 1000000)}m';
    }
    return NumberFormat.currency(
      locale: locale,
      symbol: '$symbol ',
      decimalDigits: this == idr && minor % 100 == 0 ? 0 : 2,
    ).format(value);
  }

  static LedgerCurrency fromCode(String code) => values.firstWhere(
        (currency) => currency.code == code,
        orElse: () => idr,
      );
}

enum NumberStyle {
  international('1,234.56', '.', ','),
  indonesian('1.234,56', ',', '.');

  const NumberStyle(this.example, this.decimal, this.grouping);
  final String example;
  final String decimal;
  final String grouping;
}

/// All calculations use integer hundredths. Never guess the printed convention.
int parseMinor(String input, NumberStyle style) {
  final text = input.trim();
  final group = RegExp.escape(style.grouping);
  final decimal = RegExp.escape(style.decimal);
  final pattern = RegExp(
    '^[+-]?(?:[0-9]+|[0-9]{1,3}(?:$group[0-9]{3})+)(?:$decimal[0-9]+)?\$',
  );
  if (!pattern.hasMatch(text)) {
    throw const FormatException('Check the amount and its number format.');
  }
  final normalized = text.replaceAll(style.grouping, '');
  final negative = normalized.startsWith('-');
  final unsigned = normalized.replaceFirst(RegExp(r'^[+-]'), '');
  final parts = unsigned.split(style.decimal);
  var fraction = parts.length == 2 ? parts[1] : '';
  while (fraction.length > 2 && fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  if (fraction.length > 2) {
    throw const FormatException('Amounts can have at most two decimal places.');
  }
  final result = BigInt.parse(parts[0]) * BigInt.from(100) +
      BigInt.parse(fraction.padRight(2, '0'));
  if (result > BigInt.from(9007199254740991)) {
    throw const FormatException('This amount is too large.');
  }
  return negative ? -result.toInt() : result.toInt();
}

String printedMinor(int minor, NumberStyle style) {
  final sign = minor < 0 ? '-' : '';
  final value = minor.abs();
  return '$sign${value ~/ 100}${style.decimal}${(value % 100).toString().padLeft(2, '0')}';
}
