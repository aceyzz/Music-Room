// How event and playlist pages say lengths of time and counts.

/// How long until something, at the grain that matters: "2 d 4 h",
/// "3 h 20 min", "35 min", "less than a minute".
String formatCountdown(Duration left) {
  if (left.inDays > 0) {
    final hours = left.inHours % 24;
    return hours == 0 ? '${left.inDays} d' : '${left.inDays} d $hours h';
  }
  if (left.inHours > 0) {
    final minutes = left.inMinutes % 60;
    return minutes == 0 ? '${left.inHours} h' : '${left.inHours} h $minutes min';
  }
  if (left.inMinutes > 0) {
    return '${left.inMinutes} min';
  }
  return 'less than a minute';
}

/// A length of listening: "45 s", "12 min", "1 h 05 min".
String formatListeningTime(Duration time) {
  if (time.inHours > 0) {
    return '${time.inHours} h ${(time.inMinutes % 60).toString().padLeft(2, '0')} min';
  }
  if (time.inMinutes > 0) {
    return '${time.inMinutes} min';
  }
  return '${time.inSeconds} s';
}

/// "1 song" / "2 songs".
String plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : many ?? '${one}s'}';
