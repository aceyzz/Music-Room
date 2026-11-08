/// Who can find and open a playlist (`playlists.visibility`).
enum PlaylistVisibility {
  public('public', 'Public', 'Anyone can find and open it.'),
  private('private', 'Private', 'Only people you invite can open it.');

  final String wire;
  final String label;
  final String description;

  const PlaylistVisibility(this.wire, this.label, this.description);

  /// Unknown or empty values read as [public], the server's default.
  static PlaylistVisibility fromWire(String value) =>
      values.firstWhere((v) => v.wire == value, orElse: () => public);
}

/// Who can add and remove songs (`playlists.edit_license`). Independent of
/// [PlaylistVisibility]: on a private playlist "everyone" still means only
/// the people who can see it, that is its members.
enum EditLicense {
  everyone(
    'everyone',
    'Anyone who can see it',
    'Anyone who can open it can add, move and remove songs.',
  ),
  invitedOnly(
    'invited_only',
    'Only invited people',
    'Only the people invited to it can add, move and remove songs. Everyone else can listen.',
  );

  final String wire;
  final String label;

  /// What the choice means, in a sentence, under the picker.
  final String description;

  const EditLicense(this.wire, this.label, this.description);

  /// Unknown or empty values read as [everyone], the server's default.
  static EditLicense fromWire(String value) =>
      values.firstWhere((v) => v.wire == value, orElse: () => everyone);
}
