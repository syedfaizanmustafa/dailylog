import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

/// Other-commodity codes that can have a per-location price, in the order of
/// the paper sheet's CODE legend.
const List<(String, String)> kOtherCommodityCodes = [
  ('BI', 'Bimetal'),
  ('P#2', 'HDPE'),
  ('P#3', 'PVC (Vinyl)'),
  ('P#4', 'LDPE'),
  ('P#5', 'PP'),
  ('P#6', 'PS'),
  ('P#7', 'Other resins'),
  ('WDS', 'WDS'),
  ('MLP', 'Multi layer pouch'),
  ('BIB', 'Bag-in-box'),
  ('CC', 'Cardboard carton'),
  ('SCRAP', 'Scrap'),
];

/// $/lb prices one location pays. New Entry multiplies the SW weight by
/// these to fill Total Paid; staff can still lower a row's Total Paid by
/// hand (discounts). Rows already on a sheet are never recalculated when
/// prices change.
///
/// Stored on `locations/{id}`:
///   prices:       {aluminum, glass, pete, other: {code: price},
///                  updatedAt, updatedByUid, updatedByName}
///   priceHistory: [{at, byUid, byName, aluminum, glass, pete, other,
///                   previous}]  (newest first, max 30)
class LocationPrices {
  final double aluminum;
  final double glass;
  final double pete;

  /// Other commodities by CODE (e.g. `P#2`, `SCRAP`). A code that is missing
  /// is priced by hand on the sheet, as before.
  final Map<String, double> other;

  final DateTime? updatedAt;
  final String updatedByName;

  const LocationPrices({
    required this.aluminum,
    required this.glass,
    required this.pete,
    this.other = const {},
    this.updatedAt,
    this.updatedByName = '',
  });

  /// The prices New Entry used before per-location prices existed.
  static const standard = LocationPrices(aluminum: 1.80, glass: 0.101, pete: 1.46);

  static const mainKeys = ['aluminum', 'glass', 'pete'];

  static const Map<String, String> labels = {
    'aluminum': 'Aluminum',
    'glass': 'Glass',
    'pete': 'PETE plastic',
  };

  double operator [](String key) => switch (key) {
        'aluminum' => aluminum,
        'glass' => glass,
        _ => pete,
      };

  /// Price for an other-commodity code, or null when it is priced by hand.
  double? otherFor(String code) => other[code.trim().toUpperCase()];

  static double? _num(dynamic v) {
    final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    if (d == null || d.isNaN || d.isInfinite || d < 0) return null;
    return d;
  }

  /// Prices from Firestore, or null if missing or incomplete (never
  /// half-apply a price set).
  static LocationPrices? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final a = _num(raw['aluminum']), g = _num(raw['glass']), p = _num(raw['pete']);
    if (a == null || g == null || p == null) return null;
    final other = <String, double>{};
    final rawOther = raw['other'];
    if (rawOther is Map) {
      rawOther.forEach((k, v) {
        final d = _num(v);
        final code = '$k'.trim().toUpperCase();
        if (d != null && code.isNotEmpty) other[code] = d;
      });
    }
    final at = raw['updatedAt'];
    return LocationPrices(
      aluminum: a,
      glass: g,
      pete: p,
      other: other,
      updatedAt: at is Timestamp ? at.toDate() : DateTime.tryParse('${at ?? ''}'),
      updatedByName: raw['updatedByName']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toPlainMap() => {
        'aluminum': aluminum,
        'glass': glass,
        'pete': pete,
        'other': Map<String, double>.from(other),
      };

  bool sameAs(LocationPrices o) {
    bool eq(double x, double y) => (x - y).abs() < 1e-9;
    if (!eq(aluminum, o.aluminum) || !eq(glass, o.glass) || !eq(pete, o.pete)) return false;
    if (other.length != o.other.length) return false;
    for (final e in other.entries) {
      final v = o.other[e.key];
      if (v == null || !eq(v, e.value)) return false;
    }
    return true;
  }

  /// "$1.80", "$0.101", "$1.825"
  static String fmt(double v) => '\$${NumberFormat('0.00##').format(v)}';

  /// Text for an editor field ("1.8" → "1.80").
  static String edit(double v) => NumberFormat('0.00##').format(v);

  /// Parses what an admin typed ("1.8", "$1.80", ".101", "0"). Returns the
  /// value or an error message. An empty field gives (null, null) when
  /// [optional], else an error.
  static (double?, String?) parse(String text, {bool optional = false}) {
    final t = text.trim().replaceAll('\$', '').replaceAll(' ', '');
    if (t.isEmpty) return (null, optional ? null : 'Enter a price');
    if (!RegExp(r'^\d*\.?\d+$|^\d+\.$').hasMatch(t)) return (null, 'Numbers only, e.g. 1.80');
    final dot = t.indexOf('.');
    if (dot >= 0 && t.length - dot - 1 > 4) return (null, 'At most 4 decimals');
    final v = double.tryParse(t);
    if (v == null) return (null, 'Numbers only, e.g. 1.80');
    return (v, null);
  }

  /// Saves new prices and adds them to the history in one transaction, so
  /// the price and its history always match.
  static Future<void> save({
    required String locationId,
    required LocationPrices prices,
    required String byUid,
    required String byName,
  }) async {
    final ref = FirebaseFirestore.instance.collection('locations').doc(locationId);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data() ?? const <String, dynamic>{};
      final old = fromMap(data['prices']);
      final history = <Map<String, dynamic>>[
        for (final h in (data['priceHistory'] as List?) ?? const [])
          if (h is Map) Map<String, dynamic>.from(h),
      ];
      final now = DateTime.now().toIso8601String();
      history.insert(0, {
        'at': now,
        'byUid': byUid,
        'byName': byName,
        ...prices.toPlainMap(),
        if (old != null) 'previous': old.toPlainMap(),
      });
      tx.update(ref, {
        'prices': {
          ...prices.toPlainMap(),
          'updatedAt': now,
          'updatedByUid': byUid,
          'updatedByName': byName,
        },
        'priceHistory': history.take(30).toList(),
      });
    });
  }
}

/// One entry of a location's price history.
class PriceChange {
  final DateTime at;
  final String byName;
  final LocationPrices prices;
  final LocationPrices? previous;
  const PriceChange(this.at, this.byName, this.prices, this.previous);

  static List<PriceChange> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    final out = <PriceChange>[];
    for (final h in raw) {
      if (h is! Map) continue;
      final p = LocationPrices.fromMap(h);
      final at = DateTime.tryParse('${h['at'] ?? ''}');
      if (p == null || at == null) continue;
      out.add(PriceChange(at, h['byName']?.toString() ?? '', p, LocationPrices.fromMap(h['previous'])));
    }
    return out;
  }
}

/// Live prices of one location (null = not set yet → standard prices).
final locationPricesProvider = StreamProvider.family<LocationPrices?, String>((ref, locationId) {
  return FirebaseFirestore.instance
      .collection('locations')
      .doc(locationId)
      .snapshots()
      .map((d) => LocationPrices.fromMap(d.data()?['prices']));
});

/// Prices + history of every location (admin Locations screen).
final allLocationPricesProvider =
    StreamProvider<Map<String, (LocationPrices?, List<PriceChange>)>>((ref) {
  return FirebaseFirestore.instance.collection('locations').snapshots().map((snap) => {
        for (final d in snap.docs)
          d.id: (LocationPrices.fromMap(d.data()['prices']), PriceChange.listFrom(d.data()['priceHistory'])),
      });
});
