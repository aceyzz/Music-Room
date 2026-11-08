import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:app/core/validation/validators.dart';

/// A [TextFormField] with the options pages actually use. Borders, fill and
/// padding come from `AppTheme.inputDecorationTheme`, so a field here looks
/// like every other field in the app without restating any of it.
class AppTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String label;
  final String? hint;
  final IconData? icon;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool obscureText;
  final bool readOnly;
  final bool enabled;
  final int maxLines;
  final int? maxLength;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;

  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.icon,
    this.suffix,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.validator,
    this.onSubmitted,
    this.onTap,
    this.obscureText = false,
    this.readOnly = false,
    this.enabled = true,
    this.maxLines = 1,
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      validator: validator,
      onFieldSubmitted: onSubmitted,
      onTap: onTap,
      obscureText: obscureText,
      readOnly: readOnly,
      enabled: enabled,
      maxLines: obscureText ? 1 : maxLines,
      maxLength: maxLength,
      textCapitalization: textCapitalization,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
        suffixIcon: suffix,
        counterText: maxLength == null ? null : '',
        alignLabelWithHint: maxLines > 1,
      ),
    );
  }
}

/// Email field with the matching keyboard, autofill hint and validation.
class EmailField extends StatelessWidget {
  final TextEditingController controller;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  const EmailField({
    super.key,
    required this.controller,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: controller,
      label: 'Email',
      hint: 'name@example.com',
      icon: Icons.email_outlined,
      keyboardType: TextInputType.emailAddress,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      autofillHints: const [AutofillHints.email],
      validator: Validators.compose([
        Validators.required('Enter your email'),
        Validators.email(),
      ]),
    );
  }
}

/// Password field that owns its show/hide toggle, so pages don't each keep
/// an `_obscure` flag per field.
///
/// The default validator only requires a value. Pass [validator] for sign-up
/// style rules (minimum length, matching a first field).
class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;

  /// [AutofillHints.newPassword] on sign-up, so password managers offer to
  /// generate and save one.
  final bool isNew;

  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.textInputAction = TextInputAction.done,
    this.onSubmitted,
    this.validator,
    this.isNew = false,
  });

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: widget.controller,
      label: widget.label,
      icon: Icons.lock_outline_rounded,
      obscureText: _obscure,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
      validator: widget.validator ?? Validators.required('Enter your password'),
      suffix: IconButton(
        tooltip: _obscure ? 'Show password' : 'Hide password',
        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    );
  }
}

/// A read-only field that opens the platform date picker. Holds its value in
/// a [ValueNotifier] so the page reads it like a controller.
class DateField extends StatefulWidget {
  final ValueNotifier<DateTime?> value;
  final String label;
  final IconData icon;
  final DateTime? firstDate;
  final DateTime? lastDate;

  const DateField({
    super.key,
    required this.value,
    required this.label,
    this.icon = Icons.cake_outlined,
    this.firstDate,
    this.lastDate,
  });

  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.value.addListener(_sync);
  }

  @override
  void dispose() {
    widget.value.removeListener(_sync);
    _text.dispose();
    super.dispose();
  }

  void _sync() {
    _text.text = switch (widget.value.value) {
      final date? => MaterialLocalizations.of(context).formatMediumDate(date),
      null => '',
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(); // MaterialLocalizations is only safe to read from here on.
  }

  Future<void> _pick() async {
    final last = widget.lastDate ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value.value ?? DateTime(last.year - 20, last.month, last.day),
      firstDate: widget.firstDate ?? DateTime(1900),
      lastDate: last,
    );
    if (picked != null) {
      widget.value.value = picked;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime?>(
      valueListenable: widget.value,
      builder: (context, date, _) => AppTextField(
        controller: _text,
        label: widget.label,
        icon: widget.icon,
        readOnly: true,
        onTap: _pick,
        suffix: date == null
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => widget.value.value = null,
              ),
      ),
    );
  }
}

/// Upper-cases as the user types. Country codes are stored upper case (the DB
/// CHECK is `^[A-Z]{2}$`).
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
