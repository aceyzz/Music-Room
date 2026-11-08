import 'package:flutter/widgets.dart';

/// Reusable `TextFormField` validators. Each returns the message to show, or
/// null when the value is fine.
///
/// Build a field's rule by composing them:
/// `Validators.compose([Validators.required('Enter your email'), Validators.email()])`.
/// Optional fields wrap their rule in [optional] so an empty value passes.
///
/// These only catch typos early. The server re-validates everything, so the
/// rules mirror its constraints instead of inventing stricter ones.
abstract final class Validators {
  /// Runs [validators] in order and returns the first failure.
  static FormFieldValidator<String> compose(List<FormFieldValidator<String>> validators) {
    return (value) {
      for (final validator in validators) {
        final error = validator(value);
        if (error != null) {
          return error;
        }
      }
      return null;
    };
  }

  /// Lets an empty value through; otherwise applies [validator].
  static FormFieldValidator<String> optional(FormFieldValidator<String> validator) {
    return (value) => (value == null || value.trim().isEmpty) ? null : validator(value);
  }

  static FormFieldValidator<String> required([String message = 'This field is required']) {
    return (value) => (value == null || value.trim().isEmpty) ? message : null;
  }

  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Deliberately loose: one `@`, a dot in the domain, no spaces. Anything
  /// stricter rejects real addresses, and the verification email is the real check.
  static FormFieldValidator<String> email([String message = 'Enter a valid email address']) {
    return (value) => _email.hasMatch(value?.trim() ?? '') ? null : message;
  }

  /// Mirrors the server's floor (register.DefaultMinPasswordLen) when n = 8.
  static FormFieldValidator<String> minLength(int n, [String? message]) {
    return (value) =>
        (value ?? '').length < n ? (message ?? 'Must be at least $n characters') : null;
  }

  /// For "confirm password": the value must equal what [other] holds when
  /// the form is validated.
  static FormFieldValidator<String> matches(
    TextEditingController other, [
    String message = 'Does not match',
  ]) {
    return (value) => value == other.text ? null : message;
  }

  static FormFieldValidator<String> digits(int n, [String? message]) {
    final pattern = RegExp('^\\d{$n}\$');
    return (value) =>
        pattern.hasMatch(value?.trim() ?? '') ? null : (message ?? 'Must be $n digits');
  }

  static final RegExp _countryCode = RegExp(r'^[A-Z]{2}$');

  /// ISO 3166-1 alpha-2, same rule as the user_profiles_country_code_check
  /// constraint. Upper-cased before checking: the field upper-cases too.
  static FormFieldValidator<String> countryCode([
    String message = 'Use a 2-letter country code (e.g. FR)',
  ]) {
    return (value) => _countryCode.hasMatch(value?.trim().toUpperCase() ?? '') ? null : message;
  }

  static final RegExp _phone = RegExp(r'^\+?[0-9 ().-]{6,20}$');

  /// The server stores phone numbers as free text; this only rules out
  /// letters and obvious truncation.
  static FormFieldValidator<String> phone([String message = 'Enter a valid phone number']) {
    return (value) => _phone.hasMatch(value?.trim() ?? '') ? null : message;
  }
}
