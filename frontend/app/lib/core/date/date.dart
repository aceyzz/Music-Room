import 'package:intl/intl.dart';

// Format from a DateTime object
String formatDate(DateTime date) {
  return DateFormat('MMM dd', 'en_US').format(date).toUpperCase();
}

// Format directly from a String input
String formatDateString(String dateStr) {
  final dateTime = DateTime.tryParse(dateStr);
  if (dateTime == null) return '';
  return DateFormat('MMM dd', 'en_US').format(dateTime).toUpperCase();
}

DateTime parseDateString(String dateStr) {
  final trimmed = dateStr.trim();
  final titleCased = trimmed[0].toUpperCase() + trimmed.substring(1).toLowerCase();
  return DateFormat('MMM dd', 'en_US').parse(titleCased);
}