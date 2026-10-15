import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../utils/sheet_cell_numeric.dart';

/// A single stroke point of the customer's signature, decoupled from the
/// `signature` package so receipts can be built from either the live
/// signature pad (`Point`) or the stored Firestore points.
class ReceiptSignaturePoint {
  final double dx;
  final double dy;

  /// 0 = pen down / move, 1 = draw (matches how the app stores points).
  final int type;

  const ReceiptSignaturePoint(this.dx, this.dy, this.type);

  Map<String, dynamic> toMap() => {'dx': dx, 'dy': dy, 'type': type};

  static ReceiptSignaturePoint fromMap(Map<String, dynamic> m) =>
      ReceiptSignaturePoint(
        (m['dx'] as num?)?.toDouble() ?? 0,
        (m['dy'] as num?)?.toDouble() ?? 0,
        (m['type'] as num?)?.toInt() ?? 1,
      );
}

/// Material rows printed on the receipt, in the order of the paper form.
enum ReceiptMaterial {
  aluminum('ALUMINUM'),
  glass('GLASS'),
  bimetal('BIMETAL'),
  pete('#1 (PETE)'),
  hdpe('#2 (HDPE)'),
  pvc('#3 (PVC)'),
  ldpe('#4 (LDPE)'),
  pp('#5 (PP)'),
  ps('#6 (PS)'),
  other('#7 (OTHER)**'),

  /// Non-CRV scrap. Only printed on receipts that have scrap, and may be
  /// paid $0.00.
  scrap('SCRAP');

  final String label;
  const ReceiptMaterial(this.label);

  /// Maps the sheet's "CODE" cell (BI, P#2 … CC) onto a receipt row.
  static ReceiptMaterial fromCode(String code) {
    switch (code.trim().toUpperCase()) {
      case 'BI':
        return ReceiptMaterial.bimetal;
      case 'P#2':
        return ReceiptMaterial.hdpe;
      case 'P#3':
        return ReceiptMaterial.pvc;
      case 'P#4':
        return ReceiptMaterial.ldpe;
      case 'P#5':
        return ReceiptMaterial.pp;
      case 'P#6':
        return ReceiptMaterial.ps;
      case 'SCRAP':
        return ReceiptMaterial.scrap;
      default:
        // P#7, WDS, MLP, BIB, CC and anything unknown → "#7 (OTHER)"
        return ReceiptMaterial.other;
    }
  }
}

/// One filled row of the receipt table.
class ReceiptLine {
  final ReceiptMaterial material;

  /// Basis codes that had values, e.g. `SW` or `SW, SP`.
  final String basis;

  /// Human-readable weight/count, e.g. `12.5` or `SW 12.5 / SP 3`.
  final String weightOrCount;

  /// Total pounds across weight-based bases (SW, C, SP). Excludes SC counts.
  final double pounds;

  final double? pricePerPound;
  final double totalPaid;

  /// Free-text note for the "rejected / out of sale containers" column.
  final String note;

  const ReceiptLine({
    required this.material,
    required this.basis,
    required this.weightOrCount,
    required this.pounds,
    required this.pricePerPound,
    required this.totalPaid,
    this.note = '',
  });

  Map<String, dynamic> toMap() => {
        'material': material.name,
        'materialLabel': material.label,
        'basis': basis,
        'weightOrCount': weightOrCount,
        'pounds': pounds,
        'pricePerPound': pricePerPound,
        'totalPaid': totalPaid,
        'note': note,
      };

  static ReceiptLine fromMap(Map<String, dynamic> m) => ReceiptLine(
        material: ReceiptMaterial.values.firstWhere(
          (v) => v.name == m['material'],
          orElse: () => ReceiptMaterial.other,
        ),
        basis: m['basis']?.toString() ?? '',
        weightOrCount: m['weightOrCount']?.toString() ?? '',
        pounds: (m['pounds'] as num?)?.toDouble() ?? 0,
        pricePerPound: (m['pricePerPound'] as num?)?.toDouble(),
        totalPaid: (m['totalPaid'] as num?)?.toDouble() ?? 0,
        note: m['note']?.toString() ?? '',
      );
}

/// Delivery state for one channel (sms / email).
class ReceiptDelivery {
  final bool requested;
  final String to;

  /// pending → queued → sent → delivered | undelivered | failed
  final String status;
  final String? error;
  final DateTime? updatedAt;

  const ReceiptDelivery({
    this.requested = false,
    this.to = '',
    this.status = 'none',
    this.error,
    this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'requested': requested,
        'to': to,
        'status': status,
        'error': error,
        'updatedAt': updatedAt?.toIso8601String(),
      };

  static ReceiptDelivery fromMap(Map<String, dynamic>? m) {
    if (m == null) return const ReceiptDelivery();
    return ReceiptDelivery(
      requested: m['requested'] == true,
      to: m['to']?.toString() ?? '',
      status: m['status']?.toString() ?? 'none',
      error: m['error']?.toString(),
      updatedAt: m['updatedAt'] is String
          ? DateTime.tryParse(m['updatedAt'] as String)
          : null,
    );
  }
}

/// Everything needed to render, store and send one customer receipt.
class ReceiptData {
  // Identity (null until the receipt has been issued)
  final String? id;
  /// Internal running number (ordering, uniqueness). Not shown on new
  /// receipts once [receiptCode] is set.
  final int? receiptNumber;

  /// Printed receipt number: `LL-YYMMDD-SS-RR` (see utils/receipt_code.dart).
  final String? receiptCode;
  final String? token;

  // Recycler
  final String certification;
  final String recyclerName;
  final String recyclerAddress;
  final String? locationId;

  // Transaction
  final DateTime date;
  final String customerName;
  final String customerId;
  final List<ReceiptLine> lines;
  final double grandTotal;
  final List<ReceiptSignaturePoint> signature;

  // Link back to the log sheet
  final String? entryId;
  final int sheetNumber;
  final int row;

  // Storage / delivery
  final String? pdfPath;
  final ReceiptDelivery sms;
  final ReceiptDelivery email;
  final bool printed;
  final DateTime? createdAt;
  final String? createdBy;

  const ReceiptData({
    this.id,
    this.receiptNumber,
    this.receiptCode,
    this.token,
    required this.certification,
    required this.recyclerName,
    required this.recyclerAddress,
    this.locationId,
    required this.date,
    required this.customerName,
    this.customerId = '',
    required this.lines,
    required this.grandTotal,
    required this.signature,
    this.entryId,
    required this.sheetNumber,
    required this.row,
    this.pdfPath,
    this.sms = const ReceiptDelivery(),
    this.email = const ReceiptDelivery(),
    this.printed = false,
    this.createdAt,
    this.createdBy,
  });

  bool get isIssued => id != null && receiptNumber != null;

  String get entryDateKey => DateFormat('yyyy-MM-dd').format(date);

  String get formattedDate => DateFormat('MM/dd/yyyy').format(date);

  /// What is printed and shown as the receipt number: the location/date/
  /// sheet/row code for new receipts, the running number for older ones.
  String get receiptNumberLabel => (receiptCode ?? '').isNotEmpty
      ? receiptCode!
      : (receiptNumber == null ? 'DRAFT' : receiptNumber.toString());

  ReceiptData copyWith({
    String? id,
    int? receiptNumber,
    String? receiptCode,
    String? token,
    String? customerName,
    String? customerId,
    String? entryId,
    int? sheetNumber,
    String? pdfPath,
    ReceiptDelivery? sms,
    ReceiptDelivery? email,
    bool? printed,
    DateTime? createdAt,
    String? createdBy,
  }) {
    return ReceiptData(
      id: id ?? this.id,
      receiptNumber: receiptNumber ?? this.receiptNumber,
      receiptCode: receiptCode ?? this.receiptCode,
      token: token ?? this.token,
      certification: certification,
      recyclerName: recyclerName,
      recyclerAddress: recyclerAddress,
      locationId: locationId,
      date: date,
      customerName: customerName ?? this.customerName,
      customerId: customerId ?? this.customerId,
      lines: lines,
      grandTotal: grandTotal,
      signature: signature,
      entryId: entryId ?? this.entryId,
      sheetNumber: sheetNumber ?? this.sheetNumber,
      row: row,
      pdfPath: pdfPath ?? this.pdfPath,
      sms: sms ?? this.sms,
      email: email ?? this.email,
      printed: printed ?? this.printed,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  // ── Grid → receipt ────────────────────────────────────────────────────

  /// Column layout of one log-sheet row (22 cells):
  /// 0–3 aluminum SW/SC/C/SP, 4 aluminum paid;
  /// 5–8 glass, 9 glass paid; 10–13 PETE, 14 PETE paid;
  /// 15 commodity CODE; 16–18 other SW/SC/C, 19 other paid;
  /// 20 row total paid; 21 customer name + signature marker.
  static const int totalPaidColumn = 20;

  /// Builds a receipt draft from one row of the log-sheet grid.
  ///
  /// [priceHints] are the $/lb multipliers used while entering data
  /// (aluminum, glass, plastic). They are only used when the price cannot be
  /// derived from paid ÷ weight.
  static ReceiptData fromGridRow({
    required List<String> cells,
    required int row,
    required int sheetNumber,
    required DateTime date,
    required String customerName,
    required List<ReceiptSignaturePoint> signature,
    required String certification,
    required String recyclerName,
    required String recyclerAddress,
    String? locationId,
    String? entryId,
    Map<ReceiptMaterial, double> priceHints = const {},
  }) {
    final c = List<String>.from(cells);
    while (c.length < 22) {
      c.add('');
    }

    final lines = <ReceiptLine>[];

    ReceiptLine? section(
      ReceiptMaterial material,
      int sw,
      int sc,
      int cm,
      int? sp,
      int paidCol, {
      String note = '',
    }) {
      final bases = <String, String>{
        'SW': c[sw].trim(),
        'SC': c[sc].trim(),
        'C': c[cm].trim(),
        if (sp != null) 'SP': c[sp].trim(),
      }..removeWhere((_, v) => v.isEmpty);
      final paid = parseSheetCellNumericValue(c[paidCol]);
      if (bases.isEmpty && paid == 0) return null;

      double pounds = 0;
      bases.forEach((k, v) {
        if (k != 'SC') pounds += parseSheetCellNumericValue(v);
      });

      final weightText = bases.length == 1
          ? _prettyNumber(bases.values.first)
          : bases.entries
              .map((e) => '${e.key} ${_prettyNumber(e.value)}')
              .join(' / ');

      double? price;
      if (pounds > 0 && paid > 0) {
        price = paid / pounds;
      } else {
        price = priceHints[material];
      }

      return ReceiptLine(
        material: material,
        basis: bases.keys.join(', '),
        weightOrCount: weightText,
        pounds: pounds,
        pricePerPound: price,
        totalPaid: paid,
        note: note,
      );
    }

    final alum = section(ReceiptMaterial.aluminum, 0, 1, 2, 3, 4);
    final glass = section(ReceiptMaterial.glass, 5, 6, 7, 8, 9);
    final pete = section(ReceiptMaterial.pete, 10, 11, 12, 13, 14);

    // Other commodities: the sheet stores the paid amount in column 19 and
    // the row total in column 20. Derive "other paid" from the row total so
    // the receipt always reconciles with what the customer was handed.
    final rowTotal = parseSheetCellNumericValue(c[totalPaidColumn]);
    final knownPaid =
        (alum?.totalPaid ?? 0) + (glass?.totalPaid ?? 0) + (pete?.totalPaid ?? 0);
    final otherPaid = max(0.0, rowTotal - knownPaid);
    final code = c[15].trim();
    final otherBases = <String, String>{
      'SW': c[16].trim(),
      'SC': c[17].trim(),
      'C': c[18].trim(),
    }..removeWhere((_, v) => v.isEmpty);

    ReceiptLine? other;
    if (otherBases.isNotEmpty || otherPaid > 0 || code.isNotEmpty) {
      double pounds = 0;
      otherBases.forEach((k, v) {
        if (k != 'SC') pounds += parseSheetCellNumericValue(v);
      });
      final weightText = otherBases.length == 1
          ? _prettyNumber(otherBases.values.first)
          : otherBases.entries
              .map((e) => '${e.key} ${_prettyNumber(e.value)}')
              .join(' / ');
      final material = ReceiptMaterial.fromCode(code);
      other = ReceiptLine(
        material: material,
        basis: otherBases.keys.join(', '),
        weightOrCount: weightText,
        pounds: pounds,
        pricePerPound: pounds > 0 && otherPaid > 0 ? otherPaid / pounds : null,
        totalPaid: otherPaid,
        note: material == ReceiptMaterial.other && code.isNotEmpty
            ? 'Code: $code'
            : '',
      );
    }

    for (final l in [alum, glass, pete, other]) {
      if (l != null) lines.add(l);
    }

    final grand = rowTotal > 0
        ? rowTotal
        : lines.fold<double>(0, (s, l) => s + l.totalPaid);

    return ReceiptData(
      certification: certification,
      recyclerName: recyclerName,
      recyclerAddress: recyclerAddress,
      locationId: locationId,
      date: date,
      customerName: customerName,
      lines: lines,
      grandTotal: grand,
      signature: signature,
      entryId: entryId,
      sheetNumber: sheetNumber,
      row: row,
    );
  }

  static String _prettyNumber(String raw) {
    final t = raw.trim();
    // Keep "a/b" pairs as entered, but tidy plain numbers.
    if (t.contains('/') || t.contains(',')) return t.replaceAll(',', ' + ');
    final v = double.tryParse(t);
    if (v == null) return t;
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
  }

  // ── Firestore ─────────────────────────────────────────────────────────

  Map<String, dynamic> toFirestore() => {
        'receiptNumber': receiptNumber,
        'receiptCode': receiptCode,
        'token': token,
        'certification': certification,
        'recyclerName': recyclerName,
        'recyclerAddress': recyclerAddress,
        'locationId': locationId,
        'date': date.toIso8601String(),
        'entryDateKey': entryDateKey,
        'customerName': customerName,
        'customerId': customerId,
        'lines': lines.map((l) => l.toMap()).toList(),
        'grandTotal': grandTotal,
        // Stroke points are kept so the PDF can be regenerated if needed.
        'signature': signature.map((p) => p.toMap()).toList(),
        'entryId': entryId,
        'sheetNumber': sheetNumber,
        'row': row,
        'pdfPath': pdfPath,
        'sms': sms.toMap(),
        'email': email.toMap(),
        'printed': printed,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        'createdBy': createdBy,
      };

  static ReceiptData fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    final sigRaw = d['signature'] as List<dynamic>? ?? const [];
    return ReceiptData(
      id: doc.id,
      receiptNumber: (d['receiptNumber'] as num?)?.toInt(),
      receiptCode: d['receiptCode']?.toString(),
      token: d['token']?.toString(),
      certification: d['certification']?.toString() ?? '',
      recyclerName: d['recyclerName']?.toString() ?? '',
      recyclerAddress: d['recyclerAddress']?.toString() ?? '',
      locationId: d['locationId']?.toString(),
      date: DateTime.tryParse(d['date']?.toString() ?? '') ?? DateTime.now(),
      customerName: d['customerName']?.toString() ?? '',
      customerId: d['customerId']?.toString() ?? '',
      lines: (d['lines'] as List<dynamic>? ?? const [])
          .map((e) => ReceiptLine.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      grandTotal: (d['grandTotal'] as num?)?.toDouble() ?? 0,
      signature: sigRaw
          .map((e) =>
              ReceiptSignaturePoint.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      entryId: d['entryId']?.toString(),
      sheetNumber: (d['sheetNumber'] as num?)?.toInt() ?? 1,
      row: (d['row'] as num?)?.toInt() ?? 0,
      pdfPath: d['pdfPath']?.toString(),
      sms: ReceiptDelivery.fromMap(
          d['sms'] is Map ? Map<String, dynamic>.from(d['sms'] as Map) : null),
      email: ReceiptDelivery.fromMap(d['email'] is Map
          ? Map<String, dynamic>.from(d['email'] as Map)
          : null),
      printed: d['printed'] == true,
      createdAt: DateTime.tryParse(d['createdAt']?.toString() ?? ''),
      createdBy: d['createdBy']?.toString(),
    );
  }
}
