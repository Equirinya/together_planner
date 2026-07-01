String getRelativeDateString(DateTime date) {
  final now = DateTime.now();
  final difference = date.difference(now);

  if (difference.inDays > 6 || difference.inDays < -1) {
    return '${date.day}/${date.month}';
  } else if (difference.inHours > 0 && difference.inHours <= 24) {
    return 'Tomorrow';
  } else if (difference.inHours > -24 && difference.inHours <= 0) {
    return 'Today';
  } else if (difference.inHours > -48 && difference.inHours <= 24) {
    return 'Yesterday';
  } else {
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return weekdays[date.weekday - 1];
  }
}
