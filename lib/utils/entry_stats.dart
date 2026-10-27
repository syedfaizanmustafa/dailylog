import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/location_prices.dart';
import 'sheet_cell_numeric.dart';

/// Read-only summary of one submitted `entries/{id}` document, computed the
/// same way the old Manage Log Sheets list did (data rows 0–14 only; paid =
/// columns 4, 9, 14, 19; SW = columns 0, 5, 10, 16).
class EntrySummary {
  final String id;
  final DateTime createdAt;
  final String dateKey;
  final String userId;
  final String email;
  final String? locationId;
  final String locationName;
  final String locationAddress;
  final String locationCertification;
  final bool approved;
  final int sheetCount;
  final int customers;
  final double paid;
  final double aluminiumSW;
  final double glassSW;
  final double peteSW;
  final double otherSW;
  final double aluminiumPaid;
  final double glassPaid;
  final double petePaid;
  final double otherPaid;

  /// Other commodities split by the row's CODE (column 15): SW pounds and
  /// dollars per code. Rows with no code are under '' ("No code").
  final Map<String, double> otherSWByCode;
  final Map<String, double> otherPaidByCode;
  final List<String> customerNames;

  const EntrySummary({
    required this.id,
    required this.createdAt,
    required this.dateKey,
    required this.userId,
    required this.email,
    required this.locationId,
    required this.locationName,
    required this.locationAddress,
    required this.locationCertification,
    required this.approved,
    required this.sheetCount,
    required this.customers,
    required this.paid,
    required this.aluminiumSW,
    required this.glassSW,
    required this.peteSW,
    required this.otherSW,
    this.aluminiumPaid = 0,
    this.glassPaid = 0,
    this.petePaid = 0,
    this.otherPaid = 0,
    this.otherSWByCode = const {},
    this.otherPaidByCode = const {},
    required this.customerNames,
  });

  String get reference => id.length > 8 ? id.substring(0, 8) : id;

  EntrySummary withApproved(bool value) => EntrySummary(
        id: id,
        createdAt: createdAt,
        dateKey: dateKey,
        userId: userId,
        email: email,
        locationId: locationId,
        locationName: locationName,
        locationAddress: locationAddress,
        locationCertification: locationCertification,
        approved: value,
        sheetCount: sheetCount,
        customers: customers,
        paid: paid,
        aluminiumSW: aluminiumSW,
        glassSW: glassSW,
        peteSW: peteSW,
        otherSW: otherSW,
        aluminiumPaid: aluminiumPaid,
        glassPaid: glassPaid,
        petePaid: petePaid,
        otherPaid: otherPaid,
        otherSWByCode: otherSWByCode,
        otherPaidByCode: otherPaidByCode,
        customerNames: customerNames,
      );

  String get locationLabel => locationName.isNotEmpty
      ? locationName
      : (locationAddress.isNotEmpty ? locationAddress : '—');

  /// Date the sheet is for (entryDateKey), falling back to createdAt.
  DateTime get sheetDate => DateTime.tryParse(dateKey) ?? createdAt;

  static EntrySummary fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      fromMap(doc.id, doc.data() ?? const {});

  static DateTime _parseDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v) ?? DateTime(2000);
    return DateTime(2000);
  }

  static EntrySummary fromMap(String id, Map<String, dynamic> data) {
    final createdAt = _parseDate(data['createdAt']);
    final sheets = data['sheets'] is Map
        ? Map<String, dynamic>.from(data['sheets'] as Map)
        : <String, dynamic>{};

    double paid = 0, al = 0, gl = 0, pe = 0, ot = 0;
    double alP = 0, glP = 0, peP = 0, otP = 0;
    int customers = 0;
    final names = <String>[];
    final otByCode = <String, double>{};
    final otPByCode = <String, double>{};

    final nameIndex = data['customerNamesIndex'] is Map
        ? Map<String, dynamic>.from(data['customerNamesIndex'] as Map)
        : const <String, dynamic>{};

    for (final sheetEntry in sheets.entries) {
      final sheet = sheetEntry.value;
      if (sheet is! Map) continue;
      // Names stored outside the grid: sheet.customerNames {"row-21": name}
      // and the admin backfill customerNamesIndex {"sheet": {"row": name}}.
      final extraNames = <int, String>{};
      if (sheet['customerNames'] is Map) {
        (sheet['customerNames'] as Map).forEach((k, v) {
          final r = int.tryParse(k.toString().split('-').first);
          if (r != null && v.toString().trim().isNotEmpty) extraNames[r] = v.toString().trim();
        });
      }
      final idx = nameIndex[sheetEntry.key];
      if (idx is Map) {
        idx.forEach((k, v) {
          final r = int.tryParse(k.toString());
          if (r != null && v.toString().trim().isNotEmpty) extraNames.putIfAbsent(r, () => v.toString().trim());
        });
      }
      final sheetData = sheet['data'];
      if (sheetData is! Map) continue;
      final values = sheetData['values'] as List<dynamic>? ?? const [];
      final cols = (sheetData['columns'] as num?)?.toInt() ?? 21;
      if (values.isEmpty || cols == 0) continue;
      final rowCount = (values.length / cols).floor();

      for (int row = 0; row < 15 && row < rowCount; row++) {
        String cell(int col) {
          final i = row * cols + col;
          return col < cols && i < values.length ? values[i].toString() : '';
        }

        double n(int col) => parseSheetCellNumericValue(cell(col));

        al += n(0);
        gl += n(5);
        pe += n(10);
        final o16 = n(16);
        ot += o16;
        final a4 = n(4), g9 = n(9), p14 = n(14), o19 = n(19);
        if (o16 > 0 || o19 > 0) {
          final code = normalizeOtherCode(cell(15));
          otByCode[code] = (otByCode[code] ?? 0) + o16;
          otPByCode[code] = (otPByCode[code] ?? 0) + o19;
        }
        alP += a4;
        glP += g9;
        peP += p14;
        otP += o19;
        final rowPaid = a4 + g9 + p14 + o19;
        paid += rowPaid;

        final sign = cell(21);
        String name = extraNames[row] ?? '';
        if (name.isEmpty && sign.contains('Signed')) {
          name = sign.split('/').first.trim();
        }
        if (name.isNotEmpty) names.add(name);
        if (name.isNotEmpty || rowPaid > 0) customers++;
      }
    }

    String? locationId;
    if (data['location'] is String && (data['location'] as String).isNotEmpty) {
      locationId = data['location'] as String;
    } else if (data['locationRef'] is DocumentReference) {
      locationId = (data['locationRef'] as DocumentReference).id;
    }

    final address = data['locationAddress'] as String? ?? '';
    return EntrySummary(
      id: id,
      createdAt: createdAt,
      dateKey: data['entryDateKey'] as String? ??
          '${createdAt.year.toString().padLeft(4, '0')}-'
              '${createdAt.month.toString().padLeft(2, '0')}-'
              '${createdAt.day.toString().padLeft(2, '0')}',
      userId: data['userId'] as String? ?? '',
      email: data['email'] as String? ?? '',
      locationId: locationId,
      locationName: data['locationName'] as String? ?? address,
      locationAddress: address,
      locationCertification: data['locationCertification'] as String? ?? '',
      approved: data['approved'] == true,
      sheetCount: sheets.length,
      customers: customers,
      paid: paid,
      aluminiumSW: al,
      glassSW: gl,
      peteSW: pe,
      otherSW: ot,
      aluminiumPaid: alP,
      glassPaid: glP,
      petePaid: peP,
      otherPaid: otP,
      otherSWByCode: otByCode,
      otherPaidByCode: otPByCode,
      customerNames: names,
    );
  }
}

/// Running per-material totals (pounds by SW weight + dollars paid).
class MaterialTotals {
  double aluminiumLb = 0, glassLb = 0, peteLb = 0, otherLb = 0;
  double aluminiumPaid = 0, glassPaid = 0, petePaid = 0, otherPaid = 0;

  /// Other commodities by CODE ('' = no code picked).
  final Map<String, double> otherLbByCode = {};
  final Map<String, double> otherPaidByCode = {};
  int sheets = 0;
  int customers = 0;

  double get totalLb => aluminiumLb + glassLb + peteLb + otherLb;
  double get totalPaid => aluminiumPaid + glassPaid + petePaid + otherPaid;

  void add(EntrySummary e) {
    aluminiumLb += e.aluminiumSW;
    glassLb += e.glassSW;
    peteLb += e.peteSW;
    otherLb += e.otherSW;
    aluminiumPaid += e.aluminiumPaid;
    glassPaid += e.glassPaid;
    petePaid += e.petePaid;
    otherPaid += e.otherPaid;
    _merge(otherLbByCode, e.otherSWByCode);
    _merge(otherPaidByCode, e.otherPaidByCode);
    sheets += e.sheetCount;
    customers += e.customers;
  }

  void addAll(MaterialTotals o) {
    aluminiumLb += o.aluminiumLb;
    glassLb += o.glassLb;
    peteLb += o.peteLb;
    otherLb += o.otherLb;
    aluminiumPaid += o.aluminiumPaid;
    glassPaid += o.glassPaid;
    petePaid += o.petePaid;
    otherPaid += o.otherPaid;
    _merge(otherLbByCode, o.otherLbByCode);
    _merge(otherPaidByCode, o.otherPaidByCode);
    sheets += o.sheets;
    customers += o.customers;
  }

  /// (label, pounds, dollars) in sheet order.
  List<(String, double, double)> get rows => [
        ('Aluminum', aluminiumLb, aluminiumPaid),
        ('Glass', glassLb, glassPaid),
        ('PETE plastic', peteLb, petePaid),
        ('Other', otherLb, otherPaid),
      ];

  /// Aluminum, Glass, PETE plastic: always first, always in this order.
  List<(String, double, double)> get mainRows => rows.sublist(0, 3);

  /// Other commodities by code, heaviest first (then by dollars). Only codes
  /// that were used.
  List<(String, double, double)> get otherCodeRows {
    final codes = {...otherLbByCode.keys, ...otherPaidByCode.keys};
    final list = [
      for (final c in codes)
        (c, otherLbByCode[c] ?? 0.0, otherPaidByCode[c] ?? 0.0),
    ].where((r) => r.$2 > 0 || r.$3 > 0).toList()
      ..sort((a, b) {
        final byLb = b.$2.compareTo(a.$2);
        return byLb != 0 ? byLb : b.$3.compareTo(a.$3);
      });
    return list;
  }

  static void _merge(Map<String, double> into, Map<String, double> from) {
    from.forEach((k, v) => into[k] = (into[k] ?? 0.0) + v);
  }
}

/// Sheet CODE cell → the code used for grouping ('P#2', 'CC', …; '' = none).
String normalizeOtherCode(String raw) => raw.trim().toUpperCase();

/// Short label for a code, as staff say it: P#2 → #2, CC → CC, '' → No code.
String otherCodeLabel(String code) {
  if (code.isEmpty) return 'No code';
  if (code.startsWith('P#')) return code.substring(1);
  return code;
}

/// Plain name for a code from the sheet legend (P#2 → HDPE), or ''.
String otherCodeName(String code) {
  for (final (c, name) in kOtherCommodityCodes) {
    if (c == code) return name;
  }
  return '';
}
