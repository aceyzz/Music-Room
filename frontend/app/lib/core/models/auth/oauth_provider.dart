/// The identity providers the server can exchange a code with
/// (backend/internal/auth/oauth). A provider whose credentials are missing
/// from the server's env is not registered there, and OAuthLogin answers
/// INVALID_ARGUMENT for it.
enum OAuthProvider {
  google(
    wireName: 'google',
    label: 'Google',
    badge: 'G',
    authorizeEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    // openid + email: the server reads https://openidconnect.googleapis.com/v1/userinfo.
    scope: 'openid email profile',
    extraParams: {'prompt': 'select_account'},
  ),
  facebook(
    wireName: 'facebook',
    label: 'Facebook',
    badge: 'f',
    // Same Graph API version as the server's token and /me calls.
    authorizeEndpoint: 'https://www.facebook.com/v21.0/dialog/oauth',
    scope: 'email', // public_profile (the name) is granted by default.
    // No Meta developer app could be registered, so there is no client ID
    // and the button could only ever be disabled. Hidden from the screens
    // rather than removed: the server provider, the DB enum value and
    // fromWireName still know it, should an app be registered one day.
    hidden: true,
  ),
  intra42(
    wireName: 'intra42',
    label: '42',
    badge: '42',
    authorizeEndpoint: 'https://api.intra.42.fr/oauth/authorize',
    // `public` is what /v2/me needs.
    scope: 'public',
  );

  /// The `provider` string OAuthLoginRequest expects: the server's
  /// `Provider.Name()`, which is also the oauth_provider enum value in the DB.
  final String wireName;
  final String label;

  /// What the button's badge shows, since there are no brand logos in the app.
  final String badge;

  /// Where the browser goes to log in (step 1 of the authorization-code flow).
  final String authorizeEndpoint;

  /// Must include whatever lets the server read the user's email: the server
  /// refuses an account without one.
  final String scope;

  /// Provider-specific query parameters added to the login URL.
  final Map<String, String> extraParams;

  /// Left off the sign-in buttons and the profile's linked accounts.
  final bool hidden;

  const OAuthProvider({
    required this.wireName,
    required this.label,
    required this.badge,
    required this.authorizeEndpoint,
    required this.scope,
    this.extraParams = const {},
    this.hidden = false,
  });

  /// The providers the screens show, in declaration order.
  static List<OAuthProvider> get visible => [
        for (final provider in values)
          if (!provider.hidden) provider,
      ];

  /// The provider the server calls [wireName], or null for one this build
  /// does not know (a provider added on the server before the app).
  static OAuthProvider? fromWireName(String wireName) {
    for (final provider in values) {
      if (provider.wireName == wireName) {
        return provider;
      }
    }
    return null;
  }
}
