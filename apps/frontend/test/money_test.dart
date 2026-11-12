import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/core/money.dart';

void main() {
  test('number conventions must be explicit and preserve different meanings', () {
    expect(parseMinor('20.000', NumberStyle.indonesian), 2000000);
    expect(parseMinor('20.000', NumberStyle.international), 2000);
    expect(parseMinor('1,234.56', NumberStyle.international), 123456);
    expect(parseMinor('1.234,56', NumberStyle.indonesian), 123456);
    expect(parseMinor('-0,01', NumberStyle.indonesian), -1);
  });

  test('reject malformed OCR amounts instead of silently repairing them', () {
    for (final text in ['3,26000.00', '12,34.00', '436.2O', 'Rp 100', '1.234', '', 'NaN']) {
      expect(() => parseMinor(text, NumberStyle.international), throwsFormatException, reason: text);
    }
    expect(() => parseMinor('1.23,00', NumberStyle.indonesian), throwsFormatException);
    expect(() => parseMinor('999999999999999999999999', NumberStyle.international), throwsFormatException);
  });

  test('minor units round-trip without binary floating point calculations', () {
    for (final value in [-123456, -1, 0, 1, 43620, 2600000]) {
      for (final style in NumberStyle.values) {
        expect(parseMinor(printedMinor(value, style), style), value);
      }
    }
    expect(parseMinor('0.10', NumberStyle.international) + parseMinor('0.20', NumberStyle.international), 30);
  });
}
