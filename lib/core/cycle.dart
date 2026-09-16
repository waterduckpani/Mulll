/// A budget cycle: one "month" that starts on the user's chosen reset day.
class Cycle {
  const Cycle(this.start, this.end);

  /// Inclusive start, exclusive end (both at local midnight).
  final DateTime start;
  final DateTime end;

  factory Cycle.of(DateTime now, int resetDay) {
    final day = resetDay.clamp(1, 28);
    var start = DateTime(now.year, now.month, day);
    if (now.isBefore(start)) start = DateTime(now.year, now.month - 1, day);
    return Cycle(start, DateTime(start.year, start.month + 1, day));
  }

  String get key => '${start.year}-${start.month.toString().padLeft(2, '0')}';

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  int daysLeft(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return (end.difference(today).inHours / 24).round();
  }

  /// The month most of this cycle falls in — "September".
  String get label => monthName(start.add(const Duration(days: 14)).month);
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String monthName(int month) => _months[month - 1];

String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';

String ordinal(int n) {
  if (n >= 11 && n <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

String daysAgo(DateTime then, DateTime now) {
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(then.year, then.month, then.day)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  return '$days days ago';
}
