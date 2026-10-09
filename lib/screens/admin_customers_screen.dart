import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../utils/sheet_cell_numeric.dart';
import '../widgets/admin_shell.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data
//
// Customers are recognised by the name written on the log sheet (column 21,
// "Name/Signed"), normalised (case, spaces, punctuation). Phone numbers and
// ID #s come from issued receipts with the same name. One "visit" = one
// customer on one day (several rows the same day count once).
// ─────────────────────────────────────────────────────────────────────────────

const _kMaterialNames = ['Aluminum', 'Glass', 'PETE', 'Other'];
const _kMaterialColors = [AppColors.blue, AppColors.green, AppColors.amber, AppColors.purple];

String _normName(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String _dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

class CustomerVisit {
  final DateTime date;
  final String? locationId;
  final String locationName;
  double paid;
  final List<double> lb; // aluminum, glass, PETE, other
  final String entryId;
  final int sheet;
  final int row;

  CustomerVisit({
    required this.date,
    required this.locationId,
    required this.locationName,
    required this.paid,
    required this.lb,
    required this.entryId,
    required this.sheet,
    required this.row,
  });
}

class CustomerProfile {
  final String key;
  String name;
  String? phone;
  String? idNumber;

  /// One per customer per day, oldest first.
  final List<CustomerVisit> visits = [];

  CustomerProfile(this.key, this.name);

  DateTime get firstVisit => visits.first.date;
  DateTime get lastVisit => visits.last.date;
  double get totalPaid => visits.fold(0.0, (a, v) => a + v.paid);
  int get visitCount => visits.length;

  List<CustomerVisit> visitsIn(DateTime? from, Set<String>? locs) => [
        for (final v in visits)
          if ((from == null || !v.date.isBefore(from)) &&
              (locs == null || locs.isEmpty || locs.contains(v.locationId)))
            v,
      ];

  /// Lifecycle tag used in the list and detail sheet.
  (String, Color, Color) status(DateTime today) {
    final since = today.difference(lastVisit).inDays;
    if (today.difference(firstVisit).inDays <= 30) {
      return ('New', AppColors.blueTint, AppColors.blueText);
    }
    if (visitCount >= 3 && since <= 14) return ('Regular', AppColors.greenTint, AppColors.greenText);
    if (visitCount >= 3) return ('Lapsed', AppColors.amberTint, AppColors.amberText);
    return ('Occasional', AppColors.mist, AppColors.slate);
  }
}

class CustomerData {
  final Map<String, CustomerProfile> customers;

  /// Visits (rows with money or materials) that have no customer name.
  final List<DateTime> unnamedVisits;
  final DateTime loadedAt;
  const CustomerData(this.customers, this.unnamedVisits, this.loadedAt);
}

DateTime _parseDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v) ?? DateTime(2000);
  return DateTime(2000);
}

/// Every submitted entry + every receipt, turned into customer profiles.
final customerDataProvider = FutureProvider.autoDispose<CustomerData>((ref) async {
  final db = FirebaseFirestore.instance;
  final results = await Future.wait([
    db.collection('entries').get(),
    db.collection('receipts').get(),
  ]);
  final entries = results[0];
  final receipts = results[1];

  // ── Customer names per entry: entryId -> sheet -> row -> name ──
  // The grid itself has no name column (it is saved with 21 columns), so
  // names come from, in order: the sheet's customerNames map, the admin
  // backfill index, the signature documents (fetched once, then indexed on
  // the entry so the next load is cheap), and finally issued receipts.
  final names = <String, Map<String, Map<int, String>>>{};
  final needFetch = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  for (final doc in entries.docs) {
    final data = doc.data();
    final perSheet = <String, Map<int, String>>{};
    final sheets = data['sheets'] is Map ? Map<String, dynamic>.from(data['sheets'] as Map) : const <String, dynamic>{};
    var hasSignatures = false;
    sheets.forEach((sheetKey, sheet) {
      if (sheet is! Map) return;
      if (sheet['hasSignatures'] == true || ((sheet['signatureCount'] as num?) ?? 0) > 0) hasSignatures = true;
      if (sheet['customerNames'] is Map) {
        (sheet['customerNames'] as Map).forEach((k, v) {
          final r = int.tryParse(k.toString().split('-').first);
          final n = v.toString().trim();
          if (r != null && n.isNotEmpty) perSheet.putIfAbsent(sheetKey, () => {})[r] = n;
        });
      }
    });
    if (data['customerNamesIndex'] is Map) {
      (data['customerNamesIndex'] as Map).forEach((sk, rows) {
        if (rows is! Map) return;
        rows.forEach((rk, v) {
          final r = int.tryParse(rk.toString());
          final n = v.toString().trim();
          if (r != null && n.isNotEmpty) perSheet.putIfAbsent(sk.toString(), () => {}).putIfAbsent(r, () => n);
        });
      });
    }
    names[doc.id] = perSheet;
    if (perSheet.isEmpty && hasSignatures && data['customerNamesIndex'] == null) needFetch.add(doc);
  }

  // Older entries: read names from their signature documents, 10 at a time,
  // and save a small index on the entry for next time.
  for (var i = 0; i < needFetch.length; i += 10) {
    await Future.wait(needFetch.sublist(i, min(i + 10, needFetch.length)).map((doc) async {
      try {
        final sigs = await doc.reference.collection('signatures').get();
        final perSheet = <String, Map<int, String>>{};
        for (final s in sigs.docs) {
          final cn = s.data()['customerNames'];
          if (cn is! Map) continue;
          cn.forEach((k, v) {
            final r = int.tryParse(k.toString().split('-').first);
            final n = v.toString().trim();
            if (r != null && n.isNotEmpty) perSheet.putIfAbsent(s.id, () => {})[r] = n;
          });
        }
        names[doc.id] = perSheet;
        await doc.reference.update({
          'customerNamesIndex': {
            for (final e in perSheet.entries)
              e.key: {for (final r in e.value.entries) '${r.key}': r.value},
          },
        });
      } catch (e) {
        debugPrint('Customers: names for entry ${doc.id} not read: $e');
      }
    }));
  }

  // Receipts fill any row still without a name.
  for (final r in receipts.docs) {
    final d = r.data();
    final entryId = d['entryId']?.toString();
    final n = d['customerName']?.toString().trim() ?? '';
    if (entryId == null || n.isEmpty || !names.containsKey(entryId)) continue;
    final sheet = '${(d['sheetNumber'] as num?)?.toInt() ?? 1}';
    final row = (d['row'] as num?)?.toInt();
    if (row == null) continue;
    names[entryId]!.putIfAbsent(sheet, () => {}).putIfAbsent(row, () => n);
  }

  final customers = <String, CustomerProfile>{};
  final unnamed = <DateTime>[];
  // key -> dayKey -> visit (merge several rows on the same day)
  final byDay = <String, Map<String, CustomerVisit>>{};
  // key -> date of the spelling kept in profile.name
  final nameDate = <String, DateTime>{};

  for (final doc in entries.docs) {
    final data = doc.data();
    final created = _parseDate(data['createdAt']);
    final date = DateTime.tryParse(data['entryDateKey']?.toString() ?? '') ??
        DateTime(created.year, created.month, created.day);
    String? locationId;
    if (data['location'] is String && (data['location'] as String).isNotEmpty) {
      locationId = data['location'] as String;
    } else if (data['locationRef'] is DocumentReference) {
      locationId = (data['locationRef'] as DocumentReference).id;
    }
    final locationName = (data['locationName'] ?? data['locationAddress'] ?? '').toString();
    final sheets = data['sheets'] is Map
        ? Map<String, dynamic>.from(data['sheets'] as Map)
        : const <String, dynamic>{};

    for (final entry in sheets.entries) {
      final sheet = entry.value;
      if (sheet is! Map) continue;
      final sd = sheet['data'];
      if (sd is! Map) continue;
      final values = sd['values'] as List<dynamic>? ?? const [];
      final cols = (sd['columns'] as num?)?.toInt() ?? 21;
      if (values.isEmpty || cols <= 0) continue;
      final rows = values.length ~/ cols;
      final sheetNo = int.tryParse(entry.key) ?? 1;

      for (int row = 0; row < 15 && row < rows; row++) {
        String cell(int col) {
          final i = row * cols + col;
          return col < cols && i < values.length ? values[i].toString().trim() : '';
        }

        double n(int col) => parseSheetCellNumericValue(cell(col));
        final paidSum = n(4) + n(9) + n(14) + n(19);
        final paid = paidSum > 0 ? paidSum : n(20);
        final lb = [
          n(0) + n(2) + n(3),
          n(5) + n(7) + n(8),
          n(10) + n(12) + n(13),
          n(16) + n(18),
        ];
        final hasGoods = paid > 0 || lb.any((x) => x > 0);

        var name = names[doc.id]?[entry.key]?[row] ?? '';
        if (name.isEmpty) {
          final sign = cell(21);
          if (sign.isNotEmpty && sign != 'Signed') name = sign.split('/').first.trim();
        }
        final key = _normName(name);
        if (key.isEmpty) {
          if (hasGoods) unnamed.add(date);
          continue;
        }

        final profile = customers.putIfAbsent(key, () => CustomerProfile(key, name));
        final days = byDay.putIfAbsent(key, () => {});
        final dk = _dayKey(date);
        final existing = days[dk];
        if (existing == null) {
          days[dk] = CustomerVisit(
            date: date,
            locationId: locationId,
            locationName: locationName,
            paid: paid,
            lb: lb,
            entryId: doc.id,
            sheet: sheetNo,
            row: row,
          );
        } else {
          existing.paid += paid;
          for (int i = 0; i < 4; i++) {
            existing.lb[i] += lb[i];
          }
        }
        // Keep the most recent spelling of the name.
        final seen = nameDate[key];
        if (seen == null || !date.isBefore(seen)) {
          profile.name = name;
          nameDate[key] = date;
        }
      }
    }
  }

  byDay.forEach((key, days) {
    final list = days.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    customers[key]!.visits
      ..clear()
      ..addAll(list);
  });
  customers.removeWhere((_, c) => c.visits.isEmpty);

  // Phone / ID # from receipts (newest wins).
  final recs = receipts.docs.map((d) => d.data()).toList()
    ..sort((a, b) => (a['receiptNumber'] as num? ?? 0).compareTo(b['receiptNumber'] as num? ?? 0));
  for (final r in recs) {
    final c = customers[_normName(r['customerName']?.toString() ?? '')];
    if (c == null) continue;
    final sms = r['sms'];
    final phone = sms is Map ? sms['to']?.toString() ?? '' : '';
    if (phone.isNotEmpty) c.phone = phone;
    final id = r['customerId']?.toString() ?? '';
    if (id.isNotEmpty) c.idNumber = id;
  }

  return CustomerData(customers, unnamed, DateTime.now());
});

/// Numbers for one period / location filter.
class _Insights {
  final List<(CustomerProfile, List<CustomerVisit>)> active;
  final int newCount;
  final int returningCount;
  final int repeatInPeriod;
  final int visits;
  final double paid;
  final List<int> frequency; // 1, 2–3, 4–9, 10+ visits in period
  final List<int> weekdays; // Mon..Sun
  final List<int> materialCustomers; // customers bringing each material
  final List<double> materialLb;
  final int withPhone;
  final int multiLocation;
  final int unnamed;
  final List<CustomerProfile> winBack;
  final double top10Share;

  _Insights({
    required this.active,
    required this.newCount,
    required this.returningCount,
    required this.repeatInPeriod,
    required this.visits,
    required this.paid,
    required this.frequency,
    required this.weekdays,
    required this.materialCustomers,
    required this.materialLb,
    required this.withPhone,
    required this.multiLocation,
    required this.unnamed,
    required this.winBack,
    required this.top10Share,
  });

  static _Insights compute(CustomerData d, DateTime? from, Set<String> locs, DateTime today) {
    final active = <(CustomerProfile, List<CustomerVisit>)>[];
    var newCount = 0, returning = 0, repeat = 0, visits = 0, withPhone = 0, multi = 0;
    double paid = 0;
    final freq = [0, 0, 0, 0];
    final weekdays = List<int>.filled(7, 0);
    final matCust = [0, 0, 0, 0];
    final matLb = [0.0, 0.0, 0.0, 0.0];

    for (final c in d.customers.values) {
      final vs = c.visitsIn(from, locs);
      if (vs.isEmpty) continue;
      active.add((c, vs));
      visits += vs.length;
      final p = vs.fold<double>(0, (a, v) => a + v.paid);
      paid += p;
      if (from == null || !c.firstVisit.isBefore(from)) {
        newCount++;
      } else {
        returning++;
      }
      if (vs.length >= 2) repeat++;
      final n = vs.length;
      freq[n == 1 ? 0 : (n <= 3 ? 1 : (n <= 9 ? 2 : 3))]++;
      for (final v in vs) {
        weekdays[v.date.weekday - 1]++;
        for (int i = 0; i < 4; i++) {
          matLb[i] += v.lb[i];
        }
      }
      for (int i = 0; i < 4; i++) {
        if (vs.any((v) => v.lb[i] > 0)) matCust[i]++;
      }
      if ((c.phone ?? '').isNotEmpty) withPhone++;
      if (vs.map((v) => v.locationId).toSet().length > 1) multi++;
    }

    active.sort((a, b) =>
        b.$2.fold<double>(0, (s, v) => s + v.paid).compareTo(a.$2.fold<double>(0, (s, v) => s + v.paid)));
    final top10 = active.take(10).fold<double>(0, (s, e) => s + e.$2.fold<double>(0, (t, v) => t + v.paid));

    // Regulars (3+ visits ever) who have not come in 14–120 days.
    final winBack = d.customers.values.where((c) {
      if (c.visitCount < 3) return false;
      if (locs.isNotEmpty && !c.visits.any((v) => locs.contains(v.locationId))) return false;
      final since = today.difference(c.lastVisit).inDays;
      return since > 14 && since <= 120;
    }).toList()
      ..sort((a, b) => b.totalPaid.compareTo(a.totalPaid));

    final unnamed = d.unnamedVisits.where((t) => from == null || !t.isBefore(from)).length;

    return _Insights(
      active: active,
      newCount: newCount,
      returningCount: returning,
      repeatInPeriod: repeat,
      visits: visits,
      paid: paid,
      frequency: freq,
      weekdays: weekdays,
      materialCustomers: matCust,
      materialLb: matLb,
      withPhone: withPhone,
      multiLocation: multi,
      unnamed: unnamed,
      winBack: winBack,
      top10Share: paid > 0 ? top10 / paid : 0,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class AdminCustomersScreen extends ConsumerStatefulWidget {
  const AdminCustomersScreen({super.key});

  @override
  ConsumerState<AdminCustomersScreen> createState() => _AdminCustomersScreenState();
}

class _AdminCustomersScreenState extends ConsumerState<AdminCustomersScreen> {
  int _days = 90; // 0 = all time
  String? _locationId;
  final _search = TextEditingController();
  String _query = '';
  String _sort = 'recent'; // recent | paid | visits
  int _shown = 30;

  static final _money = NumberFormat.currency(symbol: '\$');
  static final _money0 = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime? get _from => _days == 0 ? null : _today.subtract(Duration(days: _days - 1));

  String get _periodLabel => switch (_days) {
        0 => 'all time',
        365 => 'the last year',
        _ => 'the last $_days days',
      };

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customerDataProvider);
    final colors = ref.watch(locationColorsProvider);
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const <AppLocation>[];
    final selectedLoc = locations.where((l) => l.id == _locationId).firstOrNull;
    final phone = isAdminPhone(context);
    final data = async.valueOrNull;
    final ins = data == null
        ? null
        : _Insights.compute(data, _from, {if (_locationId != null) _locationId!}, _today);

    return AdminShell(
      section: AdminSection.customers,
      title: 'Customers',
      subtitle: ins == null ? null : '${ins.active.length} customers · $_periodLabel',
      actions: [
        AdminFilterButton(
          label: selectedLoc?.name ?? 'All locations',
          active: selectedLoc != null,
          dot: selectedLoc == null ? null : colorForLocation(colors, selectedLoc.id),
          onTap: () => showLocationPickerSheet(
            context: context,
            locations: locations,
            colors: colors,
            selectedId: _locationId,
            onSelected: (id) => setState(() => _locationId = id),
          ),
        ),
        SegmentedPills<int>(
          options: const [(30, '30 days'), (90, '90 days'), (365, '1 year'), (0, 'All')],
          value: _days,
          onChanged: (d) => setState(() {
            _days = d;
            _shown = 30;
          }),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => ref.invalidate(customerDataProvider),
          icon: const Icon(Icons.refresh_rounded, color: AppColors.navy),
        ),
      ],
      child: async.when(
        loading: () => const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.forest),
          ),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.red),
              const SizedBox(height: 8),
              Text(friendlyError(e)),
              TextButton(onPressed: () => ref.invalidate(customerDataProvider), child: const Text('Try again')),
            ],
          ),
        ),
        data: (d) => _body(d, ins!, phone),
      ),
    );
  }

  Widget _body(CustomerData d, _Insights ins, bool phone) {
    final hPad = phone ? 16.0 : 28.0;
    if (d.customers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No named customers yet. Names come from the customer signature screen on submitted log sheets.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.slate),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(customerDataProvider),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 40),
        children: [
          _kpis(ins, phone),
          const SizedBox(height: 16),
          _twoUp(phone, _frequencyCard(ins), _weekdayCard(ins)),
          const SizedBox(height: 16),
          _winBackCard(ins),
          const SizedBox(height: 16),
          _twoUp(phone, _topCard(ins), _reachCard(ins)),
          const SizedBox(height: 16),
          _materialsCard(ins),
          const SizedBox(height: 16),
          _directoryCard(ins),
        ],
      ),
    );
  }

  Widget _twoUp(bool phone, Widget a, Widget b) {
    if (phone) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 16), b]);
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: a), const SizedBox(width: 16), Expanded(child: b)],
      ),
    );
  }

  // ── KPIs ────────────────────────────────────────────────────────────────

  Widget _kpis(_Insights ins, bool phone) {
    final active = ins.active.length;
    final repeatPct = active == 0 ? 0.0 : ins.repeatInPeriod * 100 / active;
    final avgVisit = ins.visits == 0 ? 0.0 : ins.paid / ins.visits;
    final tiles = [
      KpiTile(
        label: 'Customers',
        value: active.toDouble(),
        format: (v) => v.round().toString(),
        footnote: '${ins.visits} visits',
        accent: AppColors.forest,
        valueColor: AppColors.navy,
      ),
      KpiTile(
        label: _days == 0 ? 'First-time (30 days)' : 'New customers',
        value: (_days == 0 ? _newInLast30() : ins.newCount).toDouble(),
        format: (v) => v.round().toString(),
        footnote: _days == 0 ? 'first visit in the last 30 days' : '${ins.returningCount} returning',
        accent: AppColors.blue,
        valueColor: AppColors.navy,
      ),
      KpiTile(
        label: 'Came back',
        value: repeatPct,
        format: (v) => '${v.round()}%',
        footnote: '${ins.repeatInPeriod} visited 2+ days',
        accent: AppColors.green,
        valueColor: AppColors.navy,
      ),
      KpiTile(
        label: 'Avg paid per visit',
        value: avgVisit,
        format: (v) => _money.format(v),
        footnote: '${_money0.format(ins.paid)} total',
        accent: AppColors.amber,
        valueColor: AppColors.navy,
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = phone ? 2 : 4;
      final w = (c.maxWidth - 12 * (cols - 1)) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }

  int _newInLast30() {
    final d = ref.read(customerDataProvider).valueOrNull;
    if (d == null) return 0;
    final from = _today.subtract(const Duration(days: 29));
    return d.customers.values
        .where((c) => !c.firstVisit.isBefore(from))
        .where((c) => _locationId == null || c.visits.any((v) => v.locationId == _locationId))
        .length;
  }

  // ── Cards ───────────────────────────────────────────────────────────────

  Widget _cardTitle(String title, String? hint) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy)),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint, style: const TextStyle(fontSize: 12.5, color: AppColors.slate)),
            ],
          ],
        ),
      );

  Widget _insightLine(IconData icon, String text, {Color color = AppColors.forest}) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppColors.cream, borderRadius: BorderRadius.circular(12)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35, color: AppColors.navy))),
          ],
        ),
      );

  Widget _bar(String label, int value, int max, Color color, {String? trailing}) {
    final f = max == 0 ? 0.0 : value / max;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 74, child: Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.slate))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  Container(height: 18, color: AppColors.mist),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: f.clamp(0.0, 1.0).toDouble(),
                    child: Container(height: 18, color: color),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(trailing ?? '$value',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.navy)),
          ),
        ],
      ),
    );
  }

  Widget _frequencyCard(_Insights ins) {
    const labels = ['Once', '2–3 days', '4–9 days', '10+ days'];
    const colors = [AppColors.field, AppColors.sage, AppColors.olive, AppColors.forest];
    final total = ins.active.length;
    final mx = ins.frequency.fold<int>(0, max);
    final oncePct = total == 0 ? 0 : (ins.frequency[0] * 100 / total).round();
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('How often they come', 'Days each customer visited in $_periodLabel'),
          for (int i = 0; i < 4; i++)
            _bar(labels[i], ins.frequency[i], mx, colors[i],
                trailing: '${ins.frequency[i]} · ${total == 0 ? 0 : (ins.frequency[i] * 100 / total).round()}%'),
          _insightLine(
            Icons.lightbulb_outline_rounded,
            '$oncePct% came only once. A small thank-you on the receipt text, or a better rate on the '
            'second visit, is the cheapest way to turn them into regulars.',
          ),
        ],
      ),
    );
  }

  Widget _weekdayCard(_Insights ins) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final mx = ins.weekdays.fold<int>(0, max);
    final total = ins.weekdays.fold<int>(0, (a, b) => a + b);
    var best = 0, worst = 0;
    for (int i = 1; i < 7; i++) {
      if (ins.weekdays[i] > ins.weekdays[best]) best = i;
      if (ins.weekdays[i] < ins.weekdays[worst]) worst = i;
    }
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Busiest days', 'Customer visits by weekday'),
          for (int i = 0; i < 7; i++)
            _bar(names[i], ins.weekdays[i], mx, i == best ? AppColors.forest : AppColors.sage),
          if (total > 0)
            _insightLine(
              Icons.calendar_month_rounded,
              '${names[best]} is the busiest day (${(ins.weekdays[best] * 100 / total).round()}% of visits) and '
              '${names[worst]} the quietest. Staff up on ${names[best]}; try a ${names[worst]} bonus to spread the load.',
            ),
        ],
      ),
    );
  }

  Widget _winBackCard(_Insights ins) {
    final list = ins.winBack;
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle(
            'Win back these regulars (${list.length})',
            'Came 3 or more times, but not in the last 2 weeks. Sorted by what they have been paid.',
          ),
          if (list.isEmpty)
            const Text('No regulars have dropped off.', style: TextStyle(color: AppColors.slate))
          else
            for (final c in list.take(8)) _customerTile(c, null, showSince: true),
          if (list.length > 8)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _sort = 'lapsed';
                  _shown = 60;
                }),
                child: Text('Show all ${list.length} in the list below'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topCard(_Insights ins) {
    final top = ins.active.take(8).toList();
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Top customers', 'By amount paid in $_periodLabel'),
          for (int i = 0; i < top.length; i++)
            _customerTile(top[i].$1, top[i].$2, rank: i + 1),
          if (ins.active.length >= 10)
            _insightLine(
              Icons.star_outline_rounded,
              'Your top 10 customers are ${(ins.top10Share * 100).round()}% of all payouts. '
              'Know them by name and keep them coming.',
            ),
        ],
      ),
    );
  }

  Widget _reachCard(_Insights ins) {
    final active = ins.active.length;
    final phonePct = active == 0 ? 0 : (ins.withPhone * 100 / active).round();
    Widget stat(String value, String label, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.mist, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
                Text(label, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
              ],
            ),
          ),
        );
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('Reach & data', null),
          Row(
            children: [
              stat('$phonePct%', 'have a phone on file', AppColors.blueText),
              const SizedBox(width: 10),
              stat('${ins.multiLocation}', 'use 2+ locations', AppColors.purpleText),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              stat('${ins.unnamed}', 'visits with no name', ins.unnamed > 0 ? AppColors.amberText : AppColors.greenText),
              const SizedBox(width: 10),
              stat('${ins.returningCount}', 'returning customers', AppColors.greenText),
            ],
          ),
          if (phonePct < 50)
            _insightLine(
              Icons.sms_outlined,
              'Only $phonePct% of customers can be reached. Offering the texted receipt at every signature '
              'builds a list you can use for opening-hour changes or price updates.',
              color: AppColors.blue,
            ),
          if (ins.unnamed > 0)
            _insightLine(
              Icons.edit_note_rounded,
              '${ins.unnamed} visits have money but no customer name, so they can\'t be counted as repeat visits. '
              'Ask staff to always fill the name on the signature screen.',
              color: AppColors.amber,
            ),
        ],
      ),
    );
  }

  Widget _materialsCard(_Insights ins) {
    final active = ins.active.length;
    final perVisit = [for (final lb in ins.materialLb) ins.visits == 0 ? 0.0 : lb / ins.visits];
    var top = 0;
    for (int i = 1; i < 4; i++) {
      if (ins.materialCustomers[i] > ins.materialCustomers[top]) top = i;
    }
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('What customers bring', 'Share of customers bringing each material · average lb per visit'),
          for (int i = 0; i < 4; i++)
            _bar(
              _kMaterialNames[i],
              ins.materialCustomers[i],
              active,
              _kMaterialColors[i],
              trailing: '${active == 0 ? 0 : (ins.materialCustomers[i] * 100 / active).round()}% · '
                  '${perVisit[i].toStringAsFixed(1)} lb',
            ),
          if (active > 0)
            _insightLine(
              Icons.recycling_rounded,
              '${_kMaterialNames[top]} is what most customers bring. Customers bringing only one material are '
              'the easiest to grow: a sign about the other materials you take can raise each visit.',
            ),
        ],
      ),
    );
  }

  // ── Directory ───────────────────────────────────────────────────────────

  Widget _directoryCard(_Insights ins) {
    final d = ref.read(customerDataProvider).valueOrNull!;
    var list = <(CustomerProfile, List<CustomerVisit>)>[];
    if (_sort == 'lapsed') {
      list = [for (final c in ins.winBack) (c, c.visits)];
    } else {
      list = List.of(ins.active);
      switch (_sort) {
        case 'paid':
          break; // already by paid
        case 'visits':
          list.sort((a, b) => b.$2.length.compareTo(a.$2.length));
        default:
          list.sort((a, b) => b.$1.lastVisit.compareTo(a.$1.lastVisit));
      }
    }
    if (_query.isNotEmpty) {
      final q = _normName(_query);
      final digits = _query.replaceAll(RegExp(r'\D'), '');
      list = [
        for (final c in d.customers.values)
          if (c.key.contains(q) ||
              (digits.length >= 3 && (c.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(digits)) ||
              (c.idNumber ?? '').toLowerCase().contains(_query.toLowerCase()))
            (c, c.visitsIn(_from, {if (_locationId != null) _locationId!})),
      ]..sort((a, b) => b.$1.lastVisit.compareTo(a.$1.lastVisit));
    }
    final shown = list.take(_shown).toList();

    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardTitle('All customers', 'Tap a customer for their visits, totals and phone'),
          TextField(
            controller: _search,
            onChanged: (v) => setState(() {
              _query = v.trim();
              _shown = 30;
            }),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Name, phone or ID #',
              filled: true,
              fillColor: AppColors.mist,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (key, label) in const [
                  ('recent', 'Recent'),
                  ('paid', 'Top paid'),
                  ('visits', 'Most visits'),
                  ('lapsed', 'Win back'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _sort == key,
                      showCheckmark: false,
                      selectedColor: AppColors.navy,
                      backgroundColor: Colors.white,
                      side: BorderSide(color: _sort == key ? AppColors.navy : AppColors.field),
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _sort == key ? Colors.white : AppColors.navy,
                      ),
                      onSelected: (_) => setState(() {
                        _sort = key;
                        _shown = 30;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No customers match.', style: TextStyle(color: AppColors.slate))),
            ),
          for (final (c, vs) in shown) _customerTile(c, vs, showSince: _sort == 'lapsed'),
          if (list.length > shown.length)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _shown += 50),
                child: Text('Show more (${list.length - shown.length} left)'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _customerTile(CustomerProfile c, List<CustomerVisit>? periodVisits, {int? rank, bool showSince = false}) {
    final vs = periodVisits ?? c.visits;
    final paid = vs.fold<double>(0, (a, v) => a + v.paid);
    final (tag, tagBg, tagFg) = c.status(_today);
    final since = _today.difference(c.lastVisit).inDays;
    final sub = showSince
        ? '${c.visitCount} visits · last ${since == 0 ? 'today' : '$since days ago'}'
        : '${vs.length} visit${vs.length == 1 ? '' : 's'} · last ${DateFormat('MMM d').format(c.lastVisit)}';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showCustomer(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            if (rank != null)
              SizedBox(
                width: 26,
                child: Text('$rank',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.slate)),
              ),
            CircleAvatar(
              radius: 18,
              backgroundColor: tagBg,
              child: Text(
                c.name.isEmpty ? '?' : c.name.trim()[0].toUpperCase(),
                style: TextStyle(fontWeight: FontWeight.w700, color: tagFg),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy)),
                      ),
                      if ((c.phone ?? '').isNotEmpty) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.sms_outlined, size: 14, color: AppColors.blue),
                      ],
                    ],
                  ),
                  Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_money0.format(showSince ? c.totalPaid : paid),
                    style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy)),
                const SizedBox(height: 2),
                StatusPill(label: tag, bg: tagBg, fg: tagFg),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Customer detail ─────────────────────────────────────────────────────

  void _showCustomer(CustomerProfile c) {
    final (tag, tagBg, tagFg) = c.status(_today);
    final lb = [0.0, 0.0, 0.0, 0.0];
    for (final v in c.visits) {
      for (int i = 0; i < 4; i++) {
        lb[i] += v.lb[i];
      }
    }
    final locs = <String, int>{};
    for (final v in c.visits) {
      final name = v.locationName.isEmpty ? '—' : v.locationName;
      locs[name] = (locs[name] ?? 0) + 1;
    }
    final gaps = <int>[
      for (int i = 1; i < c.visits.length; i++) c.visits[i].date.difference(c.visits[i - 1].date).inDays,
    ];
    final avgGap = gaps.isEmpty ? null : gaps.reduce((a, b) => a + b) / gaps.length;
    final recent = c.visits.reversed.take(12).toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: tagBg,
                    child: Text(c.name.isEmpty ? '?' : c.name.trim()[0].toUpperCase(),
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: tagFg)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name,
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.navy)),
                        Text(
                          'Customer since ${DateFormat('MMM d, yyyy').format(c.firstVisit)}',
                          style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(label: tag, bg: tagBg, fg: tagFg),
                ],
              ),
              const SizedBox(height: 14),
              if ((c.phone ?? '').isNotEmpty || (c.idNumber ?? '').isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.mist, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      if ((c.phone ?? '').isNotEmpty)
                        Row(
                          children: [
                            const Icon(Icons.phone_iphone_rounded, size: 18, color: AppColors.slate),
                            const SizedBox(width: 8),
                            Expanded(child: Text(c.phone!, style: const TextStyle(fontWeight: FontWeight.w600))),
                            TextButton(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: c.phone!));
                                showAppSnack(context, 'Phone number copied');
                              },
                              child: const Text('Copy'),
                            ),
                          ],
                        ),
                      if ((c.idNumber ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.badge_outlined, size: 18, color: AppColors.slate),
                              const SizedBox(width: 8),
                              Text('ID # ${c.idNumber}', style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _miniStat('${c.visitCount}', 'visits'),
                  _miniStat(_money0.format(c.totalPaid), 'paid in total'),
                  _miniStat(_money.format(c.visitCount == 0 ? 0 : c.totalPaid / c.visitCount), 'per visit'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _miniStat(DateFormat('MMM d').format(c.lastVisit), 'last visit'),
                  _miniStat(avgGap == null ? '—' : '${avgGap.round()} days', 'between visits'),
                  _miniStat('${locs.length}', locs.length == 1 ? 'location' : 'locations'),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Materials (all visits)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (int i = 0; i < 4; i++)
                    if (lb[i] > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _kMaterialColors[i].withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('${_kMaterialNames[i]} · ${lb[i].toStringAsFixed(1)} lb',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                ],
              ),
              if (locs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('Locations',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.navy)),
                const SizedBox(height: 6),
                Text(
                  (locs.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                      .map((e) => '${e.key} (${e.value})')
                      .join(' · '),
                  style: const TextStyle(fontSize: 13, color: AppColors.slate),
                ),
              ],
              const SizedBox(height: 16),
              const Text('Recent visits',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 4),
              for (final v in recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(DateFormat('EEE, MMM d, yyyy').format(v.date),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${v.locationName.isEmpty ? '—' : v.locationName} · sheet ${v.sheet}, row ${v.row + 1}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_money.format(v.paid), style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
                    ],
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.push('/view-entry/${v.entryId}?sheet=${v.sheet}&row=${v.row}');
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(String value, String label) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: AppColors.mist, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.navy)),
              Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.slate)),
            ],
          ),
        ),
      );
}
