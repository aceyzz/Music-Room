import 'dart:typed_data';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// In-memory [AuthApi]: records calls, and throws whatever a test queues.
class FakeAuthApi implements AuthApi {
  final List<String> calls = [];
  final Map<String, AppError> failures = {};
  bool emailVerified = false;

  /// The arguments of the last [oauthLogin] call.
  ({OAuthProvider provider, String code, String redirectUri})? lastOAuth;

  void _call(String name) {
    calls.add(name);
    final failure = failures[name];
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async =>
      _call('register');

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    _call('login');
    return _session(email);
  }

  AuthSession _session(String email) => AuthSession(
      token: 'token-$email',
      expiresAt: DateTime.now().add(const Duration(days: 30)),
      user: AuthUser(
        publicId: 'u-1',
        displayName: 'neo',
        email: email,
        emailVerified: emailVerified,
      ),
    );

  @override
  Future<void> logout() async => _call('logout');

  @override
  Future<void> requestEmailVerification() async => _call('requestEmailVerification');

  @override
  Future<void> verifyEmail(String code) async => _call('verifyEmail');

  @override
  Future<AuthSession> oauthLogin({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    _call('oauthLogin');
    lastOAuth = (provider: provider, code: code, redirectUri: redirectUri);
    return _session('${provider.wireName}@example.test');
  }

  @override
  Future<void> requestPasswordReset(String email) async => _call('requestPasswordReset');

  /// The arguments of the last [resetPassword] call.
  ({String email, String code, String newPassword})? lastReset;

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    _call('resetPassword');
    lastReset = (email: email, code: code, newPassword: newPassword);
  }
}

/// In-memory [UserApi]. [calls] is shared with a [FakeAuthApi] when a test
/// cares about the order across both.
/// In-memory [UserApi]. Holds one profile and applies writes to it the way
/// the server does: absent fields and scopes are left unchanged, and with
/// [ProfileUpdate.clearsBlanks] a null field is cleared.
class FakeUserApi implements UserApi {
  final List<String> calls;
  AppError? failure;
  final List<(String, ProfileUpdate)> updates = [];
  final List<(Uint8List, String)> avatars = [];

  List<FriendSummary> friends = const [];

  UserProfile profile = const UserProfile(
    publicId: 'u-1',
    displayName: 'neo',
    visibility: {},
  );

  FakeUserApi([List<String>? calls]) : calls = calls ?? [];

  void _call(String name) {
    calls.add(name);
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<UserProfile> getProfile(String userPublicId) async {
    _call('getProfile');
    return profile;
  }

  @override
  Future<UserProfile> updateProfile(String userPublicId, ProfileUpdate update) async {
    _call('updateProfile');
    updates.add((userPublicId, update));
    final p = profile;
    T? apply<T>(T? sent, T? current) => sent ?? (update.clearsBlanks ? null : current);
    return profile = UserProfile(
      publicId: p.publicId,
      displayName: p.displayName,
      avatarUrl: p.avatarUrl,
      firstName: apply(update.firstName, p.firstName),
      lastName: apply(update.lastName, p.lastName),
      bio: apply(update.bio, p.bio),
      birthDate: apply(update.birthDate, p.birthDate),
      city: apply(update.city, p.city),
      countryCode: apply(update.countryCode, p.countryCode),
      phoneNumber: apply(update.phoneNumber, p.phoneNumber),
      musicPreferences: p.musicPreferences,
      visibility: {...p.visibility, ...update.visibility},
    );
  }

  @override
  Future<List<MusicPreference>> setMusicPreferences(
    String userPublicId,
    List<MusicPreference> preferences,
  ) async {
    _call('setMusicPreferences');
    profile = profile.withMusicPreferences(preferences);
    return preferences;
  }

  @override
  Future<UserProfile> uploadAvatar(String userPublicId, Uint8List image, String contentType) async {
    _call('uploadAvatar');
    avatars.add((image, contentType));
    return profile = _withAvatar('http://media.test/avatars/${avatars.length}.png');
  }

  @override
  Future<UserProfile> deleteAvatar(String userPublicId) async {
    _call('deleteAvatar');
    return profile = _withAvatar(null);
  }

  @override
  Future<List<FriendSummary>> getFriends(String userPublicId) async {
    _call('getFriends');
    return friends;
  }

    UserProfile _withAvatar(String? url) => UserProfile(
        publicId: profile.publicId,
        displayName: profile.displayName,
        avatarUrl: url,
        firstName: profile.firstName,
        lastName: profile.lastName,
        bio: profile.bio,
        birthDate: profile.birthDate,
        city: profile.city,
        countryCode: profile.countryCode,
        phoneNumber: profile.phoneNumber,
        musicPreferences: profile.musicPreferences,
        visibility: profile.visibility,
      );
}
