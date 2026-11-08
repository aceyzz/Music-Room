import 'package:flutter/material.dart';

/// Shows a dialog prompting the user for a single line of text input.
///
/// Returns the entered string when confirmed, or `null` if cancelled.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? labelText = 'Name',
  String? hintText,
  String confirmLabel = 'Rename',
  String cancelLabel = 'Cancel',
  TextCapitalization textCapitalization = TextCapitalization.sentences,
  int? maxLength,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => TextInputDialog(
      title: title,
      initial: initial,
      labelText: labelText,
      hintText: hintText,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      textCapitalization: textCapitalization,
      maxLength: maxLength,
    ),
  );
}

/// A standard input dialog containing a single text field and cancel/confirm buttons.
class TextInputDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String? labelText;
  final String? hintText;
  final String confirmLabel;
  final String cancelLabel;
  final TextCapitalization textCapitalization;
  final int? maxLength;

  const TextInputDialog({
    super.key,
    required this.title,
    this.initial = '',
    this.labelText = 'Name',
    this.hintText,
    this.confirmLabel = 'Rename',
    this.cancelLabel = 'Cancel',
    this.textCapitalization = TextCapitalization.sentences,
    this.maxLength,
  });

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: widget.textCapitalization,
        maxLength: widget.maxLength,
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
