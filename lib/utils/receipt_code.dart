import 'package:intl/intl.dart';

/// Receipt code: `LL-YYMMDD-SS-RR`
///   LL      location number (Locations screen), 2 digits
///   YYMMDD  date of the log sheet
///   SS      sheet number, 2 digits
///   RR      row on the sheet (1–15), 2 digits
/// e.g. `02-261008-03-07` = location 2, Oct 8 2026, sheet 3, row 7.
/// If two iPads at one location log the same sheet/row on the same day, the
/// second code gets a suffix: `02-261008-03-07-2`.
class ReceiptCode {
  final int location;
  final DateTime date;
  final int sheet;
  final int row; // 1-based, as printed on the paper sheet
  final int copy; // 1 = no suffix

  const ReceiptCode({
    required this.location,
    required this.date,
    required this.sheet,
    required this.row,
    this.copy = 1,
  });

  static String build({
    required int location,
    required DateTime date,
    required int sheet,
    required int row,
    int copy = 1,
  }) {
    String two(int v) => v.toString().padLeft(2, '0');
    final base = '${two(location)}-${DateFormat('yyMMdd').format(date)}-${two(sheet)}-${two(row)}';
    return copy > 1 ? '$base-$copy' : base;
  }

  /// Reads `02-261008-03-07`, `02-261008-03-07-2` or the 12 digits
  /// `022610080307`. Returns null for anything else (e.g. old numbers).
  static ReceiptCode? decode(String code) {
    final c = code.trim().replaceFirst('#', '');
    List<String> parts;
    if (c.contains('-')) {
      parts = c.split('-');
    } else if (RegExp(r'^\d{12}$').hasMatch(c)) {
      parts = [c.substring(0, 2), c.substring(2, 8), c.substring(8, 10), c.substring(10, 12)];
    } else {
      return null;
    }
    if (parts.length < 4 || parts.length > 5 || parts[1].length != 6) return null;
    final loc = int.tryParse(parts[0]);
    final yy = int.tryParse(parts[1].substring(0, 2));
    final mm = int.tryParse(parts[1].substring(2, 4));
    final dd = int.tryParse(parts[1].substring(4, 6));
    final sheet = int.tryParse(parts[2]);
    final row = int.tryParse(parts[3]);
    final copy = parts.length == 5 ? int.tryParse(parts[4]) : 1;
    if ([loc, yy, mm, dd, sheet, row, copy].contains(null)) return null;
    if (mm! < 1 || mm > 12 || dd! < 1 || dd > 31) return null;
    return ReceiptCode(
      location: loc!,
      date: DateTime(2000 + yy!, mm, dd),
      sheet: sheet!,
      row: row!,
      copy: copy!,
    );
  }

  /// "Location 02 · Oct 8, 2026 · Sheet 3 · Row 7"
  String describe() =>
      'Location ${location.toString().padLeft(2, '0')} · ${DateFormat('MMM d, yyyy').format(date)}'
      ' · Sheet $sheet · Row $row${copy > 1 ? ' (copy $copy)' : ''}';
}
