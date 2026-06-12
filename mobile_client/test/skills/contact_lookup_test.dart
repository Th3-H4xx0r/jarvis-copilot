import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/skills/contact_lookup.dart';

({String name, List<String> phones}) c(String name, List<String> phones) =>
    (name: name, phones: phones);

void main() {
  group('cleanNumber', () {
    test('keeps a single leading + and digits only', () {
      expect(cleanNumber('+1 (510) 378-0762'), '+15103780762');
      expect(cleanNumber('510-378-0762'), '5103780762');
    });
    test('non-numeric text is returned trimmed', () {
      expect(cleanNumber('  hi '), 'hi');
    });
  });

  group('bestContactNumber', () {
    final contacts = [
      c('Chahel Singh', ['+1 510-378-0762']),
      c('Chad', ['+1 415 000 1111']),
      c('Mom', ['(212) 555-0100']),
      c('No Number', const []),
    ];

    test('exact name beats prefix/contains', () {
      expect(bestContactNumber([
        c('Chahel', ['111']),
        c('Chahel Singh', ['222']),
      ], 'Chahel'), '111');
    });

    test('prefix match when no exact', () {
      expect(bestContactNumber(contacts, 'chahel'), '+15103780762');
    });

    test('case-insensitive contains match', () {
      expect(bestContactNumber(contacts, 'mom'), '2125550100');
    });

    test('skips contacts with no phone', () {
      expect(bestContactNumber(contacts, 'no number'), isNull);
    });

    test('no match → null', () {
      expect(bestContactNumber(contacts, 'zzz'), isNull);
      expect(bestContactNumber(contacts, ''), isNull);
    });
  });
}
