/// Rupee formatting and forgiving amount parsing.
library;

/// Formats with Indian digit grouping: 1,24,600.
String inr(int amount, {bool symbol = true}) {
  final negative = amount < 0;
  final digits = amount.abs().toString();
  String grouped;
  if (digits.length <= 3) {
    grouped = digits;
  } else {
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  return '${negative ? '−' : ''}${symbol ? '₹' : ''}$grouped';
}

final _noise = RegExp(r'(₹|rs\.?|inr|,|\s|/-)', caseSensitive: false);
final _amount = RegExp(r'^(\d+(?:\.\d+)?)(k|thousand|lakhs|lakh|lacs|lac|l|crores|crore|cr|m)?$');

/// Postel's law: 28000, 28k, 28,000, ₹28k, 1.2L, 2 lakh and Rs. 499/- all work.
int? parseAmount(String input) {
  final s = input.toLowerCase().replaceAll(_noise, '');
  if (s.isEmpty) return null;
  final m = _amount.firstMatch(s);
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!);
  if (n == null) return null;
  final multiplier = switch (m.group(2)) {
    'k' || 'thousand' => 1000,
    'l' || 'lac' || 'lacs' || 'lakh' || 'lakhs' => 100000,
    'cr' || 'crore' || 'crores' => 10000000,
    'm' => 1000000,
    _ => 1,
  };
  final value = (n * multiplier).round();
  return value > 0 && value < 100000000000 ? value : null;
}
