import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/auth/domain/password_policy.dart';

void main() {
  group('strength', () {
    test('anything under the minimum length is tooShort', () {
      expect(PasswordPolicy.strengthOf(''), PasswordStrength.tooShort);
      expect(PasswordPolicy.strengthOf('Ab1!'), PasswordStrength.tooShort);
      expect(
        PasswordPolicy.strengthOf('A' * (PasswordPolicy.minLength - 1)),
        PasswordStrength.tooShort,
      );
    });

    test('common passwords are never acceptable', () {
      // Shorter entries fail on length first; what matters is that none of
      // them can be submitted, not which rule catches them.
      for (final p in ['password123', 'qwerty123', '1234567890', 'qtoys123']) {
        expect(PasswordPolicy.strengthOf(p).isAcceptable, isFalse, reason: p);
      }
      expect(PasswordPolicy.strengthOf('password123'), PasswordStrength.weak);
    });

    test('repeated and sequential strings are weak', () {
      expect(PasswordPolicy.strengthOf('aaaaaaaaaaaa'), PasswordStrength.weak);
      expect(PasswordPolicy.strengthOf('ababababababab'), PasswordStrength.weak);
      expect(PasswordPolicy.strengthOf('abcdefghijkl'), PasswordStrength.weak);
      expect(PasswordPolicy.strengthOf('9876543210'), PasswordStrength.weak);
    });

    test('a single character class is weak', () {
      expect(PasswordPolicy.strengthOf('trumpetwalrus'), PasswordStrength.weak);
    });

    test('two classes at moderate length is fair', () {
      expect(PasswordPolicy.strengthOf('trumpet9walrus'.substring(0, 11)),
          PasswordStrength.fair);
    });

    test('three classes at length is strong', () {
      expect(PasswordPolicy.strengthOf('Trumpet9Walrus'), PasswordStrength.strong);
    });

    test('a long two-class passphrase is strong without a symbol', () {
      expect(
        PasswordPolicy.strengthOf('correcthorsebattery9'),
        PasswordStrength.strong,
        reason: 'length carries real entropy; do not punish passphrases',
      );
    });
  });

  group('validate', () {
    test('accepts a strong password', () {
      expect(PasswordPolicy.validate('Trumpet9Walrus'), isNull);
    });

    test('rejects empty, short and over-long', () {
      expect(PasswordPolicy.validate(''), isNotNull);
      expect(PasswordPolicy.validate(null), isNotNull);
      expect(PasswordPolicy.validate('Ab1!'), contains('at least'));
      expect(
        PasswordPolicy.validate('A1b!' * 40),
        contains('no more than'),
      );
    });

    test('rejects leading or trailing whitespace', () {
      expect(PasswordPolicy.validate(' Trumpet9Walrus'), contains('space'));
      expect(PasswordPolicy.validate('Trumpet9Walrus '), contains('space'));
    });

    test('rejects a guessable password that is long enough', () {
      expect(PasswordPolicy.validate('password123'), contains('guess'));
    });
  });

  group('confirmation', () {
    test('must be present and identical', () {
      expect(PasswordPolicy.validateConfirmation('', 'Trumpet9Walrus'),
          isNotNull);
      expect(
        PasswordPolicy.validateConfirmation('Trumpet9Walru', 'Trumpet9Walrus'),
        contains('match'),
      );
      expect(
        PasswordPolicy.validateConfirmation('Trumpet9Walrus', 'Trumpet9Walrus'),
        isNull,
      );
    });

    test('comparison is case sensitive', () {
      expect(
        PasswordPolicy.validateConfirmation('trumpet9walrus', 'Trumpet9Walrus'),
        contains('match'),
      );
    });
  });

  group('isSubmittable', () {
    test('true only when both fields pass', () {
      expect(
        PasswordPolicy.isSubmittable('Trumpet9Walrus', 'Trumpet9Walrus'),
        isTrue,
      );
      expect(PasswordPolicy.isSubmittable('Trumpet9Walrus', 'nope'), isFalse);
      expect(PasswordPolicy.isSubmittable('password123', 'password123'), isFalse,
          reason: 'a matching pair of weak passwords is still not submittable');
      expect(PasswordPolicy.isSubmittable('', ''), isFalse);
    });
  });
}
