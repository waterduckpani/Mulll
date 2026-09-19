/// Dates, the way Mull talks about them.
///
/// Everything here works in local midnight. A recurring expense that lands on
/// "the 1st" has to land on the 1st as the person experiences it, not as UTC
/// experiences it, and an expense dated today must never sort as yesterday.
library;

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

/// "December" — with the year once it is far enough out to be ambiguous.
String monthLabel(DateTime then, DateTime now) =>
    then.year == now.year ? monthName(then.month) : '${monthName(then.month)} ${then.year}';

String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';

/// "14 Sep" this year, "14 Sep 2025" once the year stops being obvious.
String shortDateWithYear(DateTime d, DateTime now) =>
    d.year == now.year ? shortDate(d) : '${shortDate(d)} ${d.year}';

String ordinal(int n) {
  if (n >= 11 && n <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

int daysBetween(DateTime from, DateTime to) => dayOf(to).difference(dayOf(from)).inDays;

String daysAgo(DateTime then, DateTime now) {
  final days = daysBetween(then, now);
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  return '$days days ago';
}

/// "today", "tomorrow", "in 4 days", "3 days ago" — how a due date reads when
/// the point is how soon it is rather than which date it is.
String relativeDay(DateTime then, DateTime now) {
  final days = daysBetween(now, then);
  return switch (days) {
    0 => 'today',
    1 => 'tomorrow',
    -1 => 'yesterday',
    < 0 => '${-days} days ago',
    < 14 => 'in $days days',
    _ => 'on ${shortDate(then)}',
  };
}

/// The last day of the month [year]-[month] is in, with December rolling over.
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Adds [count] months, keeping the day of the month where the month is long
/// enough to hold it.
///
/// Rent set on the 31st is still rent in February. Dart's own
/// `DateTime(y, m + 1, 31)` silently rolls into March, which would quietly move
/// a monthly expense a day later every short month until it drifted off the
/// calendar entirely — so the day is clamped instead.
DateTime addMonths(DateTime from, int count) {
  // Counting in months-since-year-zero keeps the wrap arithmetic to one line
  // and gets December → January right without a special case.
  final months = from.year * 12 + (from.month - 1) + count;
  final year = months ~/ 12;
  final month = months % 12 + 1;
  return DateTime(year, month, from.day.clamp(1, daysInMonth(year, month)));
}
