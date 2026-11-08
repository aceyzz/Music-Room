import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/form_page.dart';
import 'package:app/core/widgets/load_failed_view.dart';
import 'package:app/core/widgets/loading_button.dart';
import 'package:app/core/widgets/personal_details_fields.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/linked_accounts_store.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/auth/presentation/widgets/linked_accounts_section.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/profile_error_messages.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/features/user/presentation/stores/profile_store.dart';
import 'package:app/globals/app_router.dart';

/// The signed-in user's own profile: picture, details, and who may see each
/// detail (subject V.1). Display name and email are shown but not editable:
/// UserService has no RPC that changes them.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with BusyState<ProfilePage> {
  late final ProfileStore _store;
  late final LinkedAccountsStore _linked;
  late final String _email;

  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _birthDate = ValueNotifier<DateTime?>(null);
  final _city = TextEditingController();
  final _country = TextEditingController();
  final _phone = TextEditingController();
  final _bio = TextEditingController();
  final Map<ProfileField, ProfileVisibility> _visibility = {};

  /// The picked genres, by Deezer genre id. A genre already saved keeps its
  /// weight; a newly picked one gets the default.
  final Map<int, MusicPreference> _preferences = {};

  /// Which action [busy] is for, so the spinner shows on the avatar during
  /// an upload and on the button during a save.
  bool _avatarBusy = false;

  /// The provider a link or unlink is running for, same reason.
  OAuthProvider? _linkBusy;

  /// The form is filled from the first profile that arrives, then only after
  /// a save. Not on every state change: an avatar upload in the middle of an
  /// edit must not wipe what the user has typed.
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    final user = context.currentUser;
    _email = user.email;
    _store = ProfileStore(
      context.read<UserApi>(),
      user.publicId,
      onChanged: context.read<CurrentUserStore>().update,
    );
    _store.state.addListener(_fillOnFirstLoad);
    _store.start();
    _linked = LinkedAccountsStore(
      context.read<LinkedAccountsApi>(),
      context.read<OAuthBrowserFlow>(),
    )..start();
  }

  @override
  void dispose() {
    _store.state.removeListener(_fillOnFirstLoad);
    _store.stop();
    _linked.stop();
    for (final c in [_firstName, _lastName, _city, _country, _phone, _bio]) {
      c.dispose();
    }
    _birthDate.dispose();
    super.dispose();
  }

  void _fillOnFirstLoad() {
    final profile = _store.profile;
    if (!_filled && profile != null) {
      _fill(profile);
    }
  }

  void _fill(UserProfile p) {
    _filled = true;
    _firstName.text = p.firstName ?? '';
    _lastName.text = p.lastName ?? '';
    _birthDate.value = p.birthDate;
    _city.text = p.city ?? '';
    _country.text = p.countryCode ?? '';
    _phone.text = p.phoneNumber ?? '';
    _bio.text = p.bio ?? '';
    setState(() {
      for (final field in ProfileField.values) {
        _visibility[field] = p.visibilityOf(field);
      }
      _preferences
        ..clear()
        ..addAll({for (final pref in p.musicPreferences) pref.genreId: pref});
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final update = ProfileUpdate.fromForm(
      firstName: _firstName.text,
      lastName: _lastName.text,
      birthDate: _birthDate.value,
      city: _city.text,
      countryCode: _country.text,
      phoneNumber: _phone.text,
      bio: _bio.text,
      visibility: Map.of(_visibility),
      // The whole form is sent: a field left empty is cleared, not skipped.
      clearBlanks: true,
    );
    final preferences = _preferences.values.toList();
    final saved = await run(
      () async {
        await _store.save(update);
        // A separate RPC that replaces the whole set; skipped when nothing
        // changed, so saving the details alone stays one call.
        final stored = {for (final p in _store.profile!.musicPreferences) p.genreId: p};
        if (!mapEquals(stored, _preferences)) {
          await _store.savePreferences(preferences);
        }
      },
      message: (error) => profileErrorMessage(error, ProfileAction.save),
    );
    if (!saved || !mounted) {
      return;
    }
    _fill(_store.profile!);
    showInfo('Profile saved.');
  }

  Future<void> _runAvatar(Future<void> Function() action, ProfileAction kind) async {
    setState(() => _avatarBusy = true);
    await run(action, message: (error) => profileErrorMessage(error, kind));
    if (mounted) {
      setState(() => _avatarBusy = false);
    }
  }

  Future<bool> _runLinked(
    OAuthProvider provider,
    Future<void> Function() action,
    AuthAction kind,
  ) async {
    setState(() => _linkBusy = provider);
    final done = await run(
      action,
      // Closing the login window is a choice, not an error.
      message: (error) => error is OAuthCancelledError ? null : authErrorMessage(error, kind),
    );
    if (mounted) {
      setState(() => _linkBusy = null);
    }
    return done;
  }

  Future<void> _link(OAuthProvider provider) async {
    if (await _runLinked(provider, () => _linked.link(provider), AuthAction.linkAccount)) {
      showInfo('${provider.label} account linked.');
    }
  }

  Future<void> _unlink(OAuthProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Unlink ${provider.label}?'),
        content: Text('You will no longer be able to sign in with ${provider.label}. '
            'You can link it again at any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    if (await _runLinked(provider, () => _linked.unlink(provider), AuthAction.unlinkAccount)) {
      showInfo('${provider.label} account unlinked.');
    }
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final Uint8List bytes;
    try {
      // Downscaled on the device where the picker can (mobile, web); the
      // server keeps this as the original and makes its own 512px thumbnail.
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (file == null) {
        return; // cancelled
      }
      bytes = await file.readAsBytes();
    } on PlatformException catch (error) {
      debugPrint('Profile: image picker failed: $error');
      showError(source == ImageSource.camera
          ? 'The camera is not available. Check the app\'s permissions.'
          : 'Your photos are not available. Check the app\'s permissions.');
      return;
    }
    await _runAvatar(() => _store.changeAvatar(bytes), ProfileAction.changeAvatar);
  }

  Future<void> _openAvatarMenu(UserProfile profile) async {
    final picker = ImagePicker();
    final canUseCamera = picker.supportsImageSource(ImageSource.camera);
    final choice = await showModalBottomSheet<_AvatarChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a picture'),
              onTap: () => Navigator.pop(context, _AvatarChoice.gallery),
            ),
            if (canUseCamera)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, _AvatarChoice.camera),
              ),
            if (profile.avatarUrl != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                title: Text(
                  'Remove picture',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(context, _AvatarChoice.remove),
              ),
          ],
        ),
      ),
    );
    switch (choice) {
      case _AvatarChoice.gallery:
        await _pickAvatar(ImageSource.gallery);
      case _AvatarChoice.camera:
        await _pickAvatar(ImageSource.camera);
      case _AvatarChoice.remove:
        await _runAvatar(_store.removeAvatar, ProfileAction.removeAvatar);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ItemState<UserProfile>>(
      valueListenable: _store.state,
      builder: (context, state, _) {
        final profile = state.data;
        return FormPage(
          formKey: _formKey,
          maxWidth: 480,
          appBar: AppBar(
            title: const Text('Profile'),
            centerTitle: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Log out',
                // The router sends the user to /login once the session is gone.
                onPressed: () => context.read<SessionStore>().logout(),
              ),
            ],
          ),
          children: [
            if (profile != null)
              ..._form(profile)
            else if (state.error != null)
              LoadFailedView(
                message: profileErrorMessage(state.error!, ProfileAction.load),
                onRetry: _store.reload,
                retryLabel: 'Try again',
                buttonType: RetryButtonType.outlined,
              )
            else
              const Center(child: CircularProgressIndicator()),
          ],
        );
      },
    );
  }

  List<Widget> _form(UserProfile profile) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return [
      Center(
        child: _AvatarEditor(
          profile: profile,
          uploading: busy && _avatarBusy,
          onTap: busy ? null : () => _openAvatarMenu(profile),
        ),
      ),
      FormGap.field,
      Text(
        profile.displayName,
        textAlign: TextAlign.center,
        style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
      Text(
        _email,
        textAlign: TextAlign.center,
        style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
      Center(
        child: TextButton.icon(
          onPressed: busy ? null : () => context.push(changePasswordRoute),
          icon: const Icon(Icons.lock_reset),
          label: const Text('Change password'),
        ),
      ),
      FormGap.section,
      ValueListenableBuilder<ItemState<LinkedAccounts>>(
        valueListenable: _linked.state,
        builder: (context, state, _) => LinkedAccountsSection(
          state: state,
          linkable: _linked.linkableProviders,
          inFlight: _linkBusy,
          onLink: busy ? null : _link,
          onUnlink: busy ? null : _unlink,
          onRetry: _linked.reload,
        ),
      ),
      FormGap.large,
      Text('About you', style: textTheme.titleMedium),
      FormGap.small,
      PersonalDetailsFields(
        firstName: _firstName,
        lastName: _lastName,
        birthDate: _birthDate,
        city: _city,
        country: _country,
        phone: _phone,
        bio: _bio,
      ),
      FormGap.section,
      _GenrePreferencesSection(
        preferences: _preferences,
        busy: busy,
        onSelected: (genre, selected) => setState(() {
          if (selected) {
            _preferences[genre.genreId] = genre;
          } else {
            _preferences.remove(genre.genreId);
          }
        }),
      ),
      FormGap.section,
      _VisibilitySection(
        profile: profile,
        visibility: _visibility,
        busy: busy,
        onChanged: (field, v) => setState(() => _visibility[field] = v),
      ),
      FormGap.large,
      LoadingButton(
        label: 'Save changes',
        busy: busy && !_avatarBusy && _linkBusy == null,
        onPressed: busy ? null : _save,
      ),
    ];
  }
}

class _GenrePreferencesSection extends StatelessWidget {
  final Map<int, MusicPreference> preferences;
  final bool busy;
  final void Function(MusicPreference genre, bool selected) onSelected;

  const _GenrePreferencesSection({
    required this.preferences,
    required this.busy,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Music preferences', style: Theme.of(context).textTheme.titleMedium),
        FormGap.small,
        Wrap(
          spacing: AppDimens.spacingXS,
          runSpacing: AppDimens.spacingXS,
          children: [
            for (final genre in musicGenres)
              FilterChip(
                label: Text(genre.genreName),
                selected: preferences.containsKey(genre.genreId),
                onSelected: busy ? null : (selected) => onSelected(genre, selected),
              ),
          ],
        ),
      ],
    );
  }
}

class _VisibilitySection extends StatelessWidget {
  final UserProfile profile;
  final Map<ProfileField, ProfileVisibility> visibility;
  final bool busy;
  final void Function(ProfileField field, ProfileVisibility value) onChanged;

  const _VisibilitySection({
    required this.profile,
    required this.visibility,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Who can see what', style: Theme.of(context).textTheme.titleMedium),
        FormGap.small,
        for (final field in ProfileField.values)
          _VisibilityRow(
            field: field,
            value: visibility[field] ?? profile.visibilityOf(field),
            onChanged: busy ? null : (v) => onChanged(field, v),
          ),
      ],
    );
  }
}

enum _AvatarChoice { gallery, camera, remove }

class _AvatarEditor extends StatelessWidget {
  final UserProfile profile;
  final bool uploading;
  final VoidCallback? onTap;

  const _AvatarEditor({required this.profile, required this.uploading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Change profile picture',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        // The initials and the badge would be read out after the label.
        child: ExcludeSemantics(
          child: Stack(
            alignment: Alignment.center,
            children: [
              UserAvatar(url: profile.avatarUrl, name: profile.displayName, radius: 56),
              if (uploading)
                const SizedBox(width: 112, height: 112, child: CircularProgressIndicator()),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: colorScheme.surface, width: 2),
                  ),
                  child: Icon(Icons.camera_alt_rounded, size: 18, color: colorScheme.onPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisibilityRow extends StatelessWidget {
  final ProfileField field;
  final ProfileVisibility value;
  final ValueChanged<ProfileVisibility>? onChanged;

  const _VisibilityRow({required this.field, required this.value, required this.onChanged});

  static IconData _icon(ProfileVisibility v) => switch (v) {
        ProfileVisibility.public => Icons.public,
        ProfileVisibility.friends => Icons.group_outlined,
        ProfileVisibility.private => Icons.lock_outline,
      };

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return Row(
      children: [
        Expanded(child: Text(field.label)),
        DropdownButton<ProfileVisibility>(
          value: value,
          underline: const SizedBox.shrink(),
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v != null) {
                    onChanged(v);
                  }
                },
          items: [
            for (final v in ProfileVisibility.values)
              DropdownMenuItem(
                value: v,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icon(v), size: 18),
                    const SizedBox(width: AppDimens.spacingXS),
                    Text(v.label),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

