import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/loading_button.dart';

/// What creates the playlist: LibraryStore.create, passed in so the sheet
/// does not depend on the store.
typedef CreatePlaylist = Future<LibraryPlaylist> Function({
  required String name,
  required PlaylistVisibility visibility,
  required EditLicense editLicense,
});

/// Opens the "new playlist" form from the bottom of the screen. Returns the
/// created playlist, or null when the user closed the form.
Future<LibraryPlaylist?> showCreatePlaylistSheet(BuildContext context, CreatePlaylist create) {
  return showModalBottomSheet<LibraryPlaylist>(
    context: context,
    // Grows above the keyboard instead of being hidden by it.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CreatePlaylistSheet(create: create),
  );
}

class CreatePlaylistSheet extends StatefulWidget {
  final CreatePlaylist create;

  /// The app's own limit: the server sets none, but a name has to fit a row.
  static const maxNameLength = 100;

  const CreatePlaylistSheet({super.key, required this.create});

  @override
  State<CreatePlaylistSheet> createState() => _CreatePlaylistSheetState();
}

class _CreatePlaylistSheetState extends State<CreatePlaylistSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();

  // The server's defaults.
  PlaylistVisibility _visibility = PlaylistVisibility.public;
  EditLicense _editLicense = EditLicense.everyone;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.create(
        name: _name.text.trim(),
        visibility: _visibility,
        editLicense: _editLicense,
      );
      if (mounted) {
        Navigator.of(context).pop(created);
      }
    } on AppError catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = switch (error) {
            NetworkError() => 'Cannot reach the server. Check your connection.',
            InvalidInputError(:final message) => message,
            _ => 'The playlist could not be created.',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final error = _error;
    return PopScope(
      canPop: !_busy, // no closing while the request runs
      child: Padding(
        // Keeps the form above the on-screen keyboard.
        padding: AppDimens.sheetPadding +
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New playlist', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppDimens.spacingM),
              TextFormField(
                controller: _name,
                enabled: !_busy,
                autofocus: true,
                maxLength: CreatePlaylistSheet.maxNameLength,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Give your playlist a name.' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppDimens.spacingXS),
              Text('Who can see it', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppDimens.spacingXS),
              SegmentedButton<PlaylistVisibility>(
                segments: [
                  for (final v in PlaylistVisibility.values)
                    ButtonSegment(value: v, label: Text(v.label)),
                ],
                selected: {_visibility},
                onSelectionChanged:
                    _busy ? null : (picked) => setState(() => _visibility = picked.single),
              ),
              const SizedBox(height: AppDimens.spacingXXS),
              Text(_visibility.description, style: hint),
              const SizedBox(height: AppDimens.spacingM),
              Text('Who can edit songs', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppDimens.spacingXS),
              SegmentedButton<EditLicense>(
                segments: [
                  for (final l in EditLicense.values) ButtonSegment(value: l, label: Text(l.label)),
                ],
                selected: {_editLicense},
                onSelectionChanged:
                    _busy ? null : (picked) => setState(() => _editLicense = picked.single),
              ),
              const SizedBox(height: AppDimens.spacingXXS),
              Text(_editLicense.description, style: hint),
              if (error != null) ...[
                const SizedBox(height: AppDimens.spacingM),
                Text(
                  error,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: AppDimens.spacingL),
              LoadingButton(
                label: 'Create',
                busy: _busy,
                onPressed: _submit,
                height: AppDimens.buttonHeightStandard,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
