/// How strong a candidate password is, coarse enough to be honest.
///
/// Deliberately not a percentage: a precise-looking score implies a precision
/// this cannot have, and nudges people to game the meter rather than pick a
/// better password.
enum PasswordStrength { tooShort, weak, fair, strong }

extension PasswordStrengthDisplay on PasswordStrength {
  String get label => switch (this) {
        PasswordStrength.tooShort => 'Too short',
        PasswordStrength.weak => 'Weak',
        PasswordStrength.fair => 'Fair',
        PasswordStrength.strong => 'Strong',
      };

  /// Fraction of the meter to fill.
  double get fill => switch (this) {
        PasswordStrength.tooShort => 0.12,
        PasswordStrength.weak => 0.34,
        PasswordStrength.fair => 0.67,
        PasswordStrength.strong => 1.0,
      };

  bool get isAcceptable =>
      this == PasswordStrength.fair || this == PasswordStrength.strong;
}

/// The single source of truth for what counts as an acceptable password.
///
/// Shared by the signed-in change-password screen and the logged-out reset
/// flow so the two can never drift apart — and mirrored by the server, which
/// re-checks length independently because a client is never authoritative.
class PasswordPolicy {
  PasswordPolicy._();

  /// Matches the minimum enforced server-side in the reset plugin.
  static const int minLength = 10;

  /// Guards against pathological input being hashed.
  static const int maxLength = 128;

  /// Rejected outright regardless of length or character mix. Short list on
  /// purpose: it catches the passwords people actually reach for on a store
  /// account without pretending to be a breach corpus.
  static const Set<String> _commonPasswords = {
    'password',
    'password1',
    'password123',
    'qwerty',
    'qwerty123',
    '12345678',
    '123456789',
    '1234567890',
    'letmein',
    'welcome',
    'welcome1',
    'iloveyou',
    'admin123',
    'abc12345',
    'passw0rd',
    'qtoys',
    'qtoys123',
    'wholesale',
  };

  static PasswordStrength strengthOf(String password) {
    if (password.length < minLength) return PasswordStrength.tooShort;
    if (_commonPasswords.contains(password.toLowerCase())) {
      return PasswordStrength.weak;
    }
    if (_isRepeating(password) || _isSequential(password)) {
      return PasswordStrength.weak;
    }

    var classes = 0;
    if (RegExp(r'[a-z]').hasMatch(password)) classes++;
    if (RegExp(r'[A-Z]').hasMatch(password)) classes++;
    if (RegExp(r'[0-9]').hasMatch(password)) classes++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) classes++;

    // Length carries real entropy, so a long passphrase is not punished for
    // lacking a symbol.
    if (password.length >= 16 && classes >= 2) return PasswordStrength.strong;
    if (classes >= 3 && password.length >= 12) return PasswordStrength.strong;
    if (classes >= 2) return PasswordStrength.fair;
    return PasswordStrength.weak;
  }

  /// Validation message for the new-password field, or null when acceptable.
  static String? validate(String? password) {
    final value = password ?? '';
    if (value.isEmpty) return 'Enter a new password.';
    if (value.length < minLength) {
      return 'Use at least $minLength characters.';
    }
    if (value.length > maxLength) {
      return 'Use no more than $maxLength characters.';
    }
    if (value.trim() != value) {
      return 'Remove the space at the start or end.';
    }
    final strength = strengthOf(value);
    if (!strength.isAcceptable) {
      return 'Too easy to guess — mix in capitals, numbers or symbols.';
    }
    return null;
  }

  /// Validation message for the confirm field, or null when the pair matches.
  static String? validateConfirmation(String? confirmation, String password) {
    final value = confirmation ?? '';
    if (value.isEmpty) return 'Re-enter your new password.';
    if (value != password) return 'These passwords don\'t match.';
    return null;
  }

  /// True when the pair is complete, matching and strong enough to submit.
  static bool isSubmittable(String password, String confirmation) =>
      validate(password) == null &&
      validateConfirmation(confirmation, password) == null;

  /// e.g. `aaaaaaaaaa`, `abababab`.
  static bool _isRepeating(String value) {
    if (value.length < 4) return false;
    for (var unitLength = 1; unitLength <= 2; unitLength++) {
      final unit = value.substring(0, unitLength);
      if (unit * (value.length ~/ unitLength) +
              unit.substring(0, value.length % unitLength) ==
          value) {
        return true;
      }
    }
    return false;
  }

  /// e.g. `abcdefghij`, `1234567890`, and their reverses.
  static bool _isSequential(String value) {
    final lower = value.toLowerCase();
    var ascending = true;
    var descending = true;
    for (var i = 1; i < lower.length; i++) {
      final delta = lower.codeUnitAt(i) - lower.codeUnitAt(i - 1);
      if (delta != 1) ascending = false;
      if (delta != -1) descending = false;
      if (!ascending && !descending) return false;
    }
    return ascending || descending;
  }
}
