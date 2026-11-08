import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/validation/validators.dart';

void main() {
  group('Validators', () {
    test('required rejects blank values', () {
      final v = Validators.required('needed');
      expect(v(null), 'needed');
      expect(v('   '), 'needed');
      expect(v('x'), isNull);
    });

    test('email accepts real-looking addresses and rejects the rest', () {
      final v = Validators.email('bad');
      expect(v('neo@example.test'), isNull);
      expect(v(' first.last+tag@sub.example.co '), isNull);
      expect(v('neo@example'), 'bad');
      expect(v('neo example.test'), 'bad');
      expect(v(''), 'bad');
    });

    test('minLength counts characters, spaces included', () {
      final v = Validators.minLength(8, 'short');
      expect(v('1234567'), 'short');
      expect(v('1234 678'), isNull);
    });

    test('matches compares against the other controller at validation time', () {
      final other = TextEditingController(text: 'a');
      final v = Validators.matches(other, 'differs');
      expect(v('a'), isNull);
      other.text = 'b';
      expect(v('a'), 'differs');
    });

    test('countryCode follows the DB check, case-insensitively', () {
      final v = Validators.countryCode('bad');
      expect(v('FR'), isNull);
      expect(v('fr'), isNull);
      expect(v('FRA'), 'bad');
      expect(v('F1'), 'bad');
    });

    test('phone allows common punctuation but not letters', () {
      final v = Validators.phone('bad');
      expect(v('+33 6 12 34 56 78'), isNull);
      expect(v('(555) 123-4567'), isNull);
      expect(v('call me'), 'bad');
      expect(v('12'), 'bad');
    });

    test('digits', () {
      final v = Validators.digits(6, 'bad');
      expect(v('123456'), isNull);
      expect(v('12345'), 'bad');
      expect(v('12345a'), 'bad');
    });

    test('optional lets blanks through and checks the rest', () {
      final v = Validators.optional(Validators.countryCode('bad'));
      expect(v(''), isNull);
      expect(v(null), isNull);
      expect(v('XYZ'), 'bad');
    });

    test('compose returns the first failure', () {
      final v = Validators.compose([Validators.required('empty'), Validators.email('bad')]);
      expect(v(''), 'empty');
      expect(v('x'), 'bad');
      expect(v('a@b.co'), isNull);
    });
  });

  group('ProfileUpdate.fromForm', () {
    test('trims, drops blanks and upper-cases the country', () {
      final p = ProfileUpdate.fromForm(firstName: ' Ada ', lastName: '  ', countryCode: 'fr');
      expect(p, const ProfileUpdate(firstName: 'Ada', countryCode: 'FR'));
      expect(p.isEmpty, isFalse);
      expect(ProfileUpdate.fromForm().isEmpty, isTrue);
    });
  });
}
