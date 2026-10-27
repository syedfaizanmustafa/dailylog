import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../utils/entry_stats.dart';
import '../widgets/admin_shell.dart';
import '../widgets/floating_confirmation_sheet.dart';
import '../widgets/shimmer.dart';
import '../services/data_sync.dart';

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

/// Date range for the overview. Defaults to the last 7 days.
class ChartDateRange {
  final DateTime start;
  final DateTime end;

  const ChartDateRange({required this.start, required this.end});

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static ChartDateRange lastDays(int days) =>
      ChartDateRange(start: _today.subtract(Duration(days: days - 1)), end: _today);

  static ChartDateRange get defaultRange => lastDays(7);

  int get length => end.difference(start).inDays + 1;
}

final chartDateRangeProvider =
    StateProvider<ChartDateRange>((ref) => ChartDateRange.defaultRange);

/// 'today' | '7' | '30' | 'custom'
final overviewPresetProvider = StateProvider<String>((ref) => '7');

/// Single location filter (null = all locations).
final overviewLocationProvider = StateProvider<String?>((ref) => null);

/// Chart metric: 'paid' or 'sheets'.
final overviewMetricProvider = StateProvider<String>((ref) => 'paid');

class OverviewDay {
  final DateTime date;
  final Map<String, double> paidByLocation;
  final Map<String, int> sheetsByLocation;

  /// Set when the bar is a week or month bucket instead of a single day.
  final String? axisLabel;
  final String? tooltipLabel;
  const OverviewDay(
    this.date,
    this.paidByLocation,
    this.sheetsByLocation, {
    this.axisLabel,
    this.tooltipLabel,
  });
}

/// Date of the first submitted sheet (for "All time").
final firstSheetDateProvider = FutureProvider<DateTime?>((ref) async {
  final snap = await FirebaseFirestore.instance
      .collection('entries')
      .orderBy('entryDateKey')
      .limit(1)
      .get();
  if (snap.docs.isEmpty) return null;
  final key = snap.docs.first.data()['entryDateKey']?.toString() ?? '';
  final d = DateTime.tryParse(key);
  return d == null ? null : DateTime(d.year, d.month, d.day);
});

class AdminOverview {
  final List<OverviewDay> days;
  final double paid;
  final double prevPaid;
  final int customers;
  final int sheets;
  final int activeLocations;
  final int receiptsIssued;
  final int receiptsTexted;
  final int failedTexts;
  final Set<String> failedLocationIds;
  final bool carrierBlocked;
  final int pendingCount;
  final DateTime? oldestPending;
  final Map<String, double> paidByLocation;
  final Map<String, int> sheetsByLocation;
  final Map<String, MaterialTotals> materialsByLocation;
  final MaterialTotals materialsTotal;

  const AdminOverview({
    required this.days,
    required this.paid,
    required this.prevPaid,
    required this.customers,
    required this.sheets,
    required this.activeLocations,
    required this.receiptsIssued,
    required this.receiptsTexted,
    required this.failedTexts,
    required this.failedLocationIds,
    required this.carrierBlocked,
    required this.pendingCount,
    required this.oldestPending,
    required this.paidByLocation,
    required this.sheetsByLocation,
    required this.materialsByLocation,
    required this.materialsTotal,
  });
}

final adminOverviewProvider = FutureProvider<AdminOverview>((ref) async {
  final range = ref.watch(chartDateRangeProvider);
  final locFilter = ref.watch(overviewLocationProvider);
  final allTime = ref.watch(overviewPresetProvider) == 'all';
  final fmt = DateFormat('yyyy-MM-dd');

  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day);
  final len = end.difference(start).inDays + 1;
  // "All time" has no previous period to compare with.
  final prevStart = allTime ? start : start.subtract(Duration(days: len));
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final weekAgo = today.subtract(const Duration(days: 6));
  final rStart = start.isBefore(weekAgo) ? start : weekAgo;
  final rEnd = end.isAfter(today) ? end : today;

  final startKey = fmt.format(start);
  final endKey = fmt.format(end);
  final weekAgoKey = fmt.format(weekAgo);

  // From the on-device cache + only what changed since the last load
  // (services/data_sync.dart), filtered here instead of on the server.
  ref.watch(syncTickProvider);
  final synced = await Future.wait([
    SyncedCollection.entries.load(),
    SyncedCollection.receipts.load(),
  ]);
  bool inRange(Map<String, dynamic> d, String from, String to) {
    final k = d['entryDateKey']?.toString() ?? '';
    return k.isNotEmpty && k.compareTo(from) >= 0 && k.compareTo(to) <= 0;
  }

  final prevStartKey = fmt.format(prevStart);
  final rStartKey = fmt.format(rStart), rEndKey = fmt.format(rEnd);
  final entriesInRange =
      synced[0].where((d) => inRange(syncedData(d), prevStartKey, endKey)).toList();
  final receiptsInRange =
      synced[1].where((d) => inRange(syncedData(d), rStartKey, rEndKey)).toList();
  final pendingEntries = synced[0].where((d) => syncedData(d)['approved'] == false).toList();

  // Entries → paid / customers / sheets
  double paid = 0, prevPaid = 0;
  int customers = 0, sheets = 0;
  final activeLocs = <String>{};
  final paidByDay = <String, Map<String, double>>{};
  final sheetsByDay = <String, Map<String, int>>{};
  final paidByLoc = <String, double>{};
  final sheetsByLoc = <String, int>{};
  final matByLoc = <String, MaterialTotals>{};
  final matTotal = MaterialTotals();

  for (final doc in entriesInRange) {
    final s = EntrySummary.fromMap(doc.id, syncedData(doc));
    if (locFilter != null && s.locationId != locFilter) continue;
    final key = s.dateKey;
    if (key.compareTo(startKey) < 0) {
      prevPaid += s.paid;
      continue;
    }
    if (key.compareTo(endKey) > 0) continue;
    final loc = s.locationId ?? '';
    paid += s.paid;
    customers += s.customers;
    sheets += s.sheetCount;
    if (loc.isNotEmpty) activeLocs.add(loc);
    final pd = paidByDay.putIfAbsent(key, () => {});
    pd[loc] = (pd[loc] ?? 0) + s.paid;
    final sd = sheetsByDay.putIfAbsent(key, () => {});
    sd[loc] = (sd[loc] ?? 0) + s.sheetCount;
    paidByLoc[loc] = (paidByLoc[loc] ?? 0) + s.paid;
    sheetsByLoc[loc] = (sheetsByLoc[loc] ?? 0) + s.sheetCount;
    matByLoc.putIfAbsent(loc, MaterialTotals.new).add(s);
    matTotal.add(s);
  }

  final days = <OverviewDay>[];
  if (len <= 62) {
    for (int d = 0; d < len; d++) {
      final date = start.add(Duration(days: d));
      final key = fmt.format(date);
      days.add(OverviewDay(
        date,
        Map.of(paidByDay[key] ?? const {}),
        Map.of(sheetsByDay[key] ?? const {}),
      ));
    }
  } else {
    // Long ranges: one bar per week (≤ 1 year) or per month.
    final monthly = len > 366;
    DateTime bucketStart(DateTime d) => monthly
        ? DateTime(d.year, d.month, 1)
        : d.subtract(Duration(days: d.weekday - 1)); // Monday
    final order = <DateTime>[];
    final paidB = <DateTime, Map<String, double>>{};
    final sheetsB = <DateTime, Map<String, int>>{};
    for (int d = 0; d < len; d++) {
      final date = start.add(Duration(days: d));
      final b = bucketStart(date);
      if (!paidB.containsKey(b)) {
        order.add(b);
        paidB[b] = {};
        sheetsB[b] = {};
      }
      final key = fmt.format(date);
      (paidByDay[key] ?? const <String, double>{}).forEach((loc, v) {
        paidB[b]![loc] = (paidB[b]![loc] ?? 0) + v;
      });
      (sheetsByDay[key] ?? const <String, int>{}).forEach((loc, v) {
        sheetsB[b]![loc] = (sheetsB[b]![loc] ?? 0) + v;
      });
    }
    for (final b in order) {
      days.add(OverviewDay(
        b,
        paidB[b]!,
        sheetsB[b]!,
        axisLabel: monthly ? DateFormat('MMM yy').format(b) : DateFormat('M/d').format(b),
        tooltipLabel: monthly
            ? DateFormat('MMMM yyyy').format(b)
            : 'Week of ${DateFormat('MMM d').format(b)}',
      ));
    }
  }

  // Receipts → texted share, failures
  int issued = 0, texted = 0, failed = 0;
  bool carrierBlocked = false;
  final failedLocs = <String>{};
  for (final doc in receiptsInRange) {
    final d = syncedData(doc);
    final locId = d['locationId']?.toString();
    if (locFilter != null && locId != locFilter) continue;
    final key = d['entryDateKey']?.toString() ?? '';
    final sms = d['sms'] is Map ? Map<String, dynamic>.from(d['sms'] as Map) : const <String, dynamic>{};
    final requested = sms['requested'] == true;
    final status = sms['status']?.toString() ?? 'none';
    final error = sms['error']?.toString() ?? '';

    if (key.compareTo(startKey) >= 0 && key.compareTo(endKey) <= 0) {
      issued++;
      if (requested) texted++;
    }
    if (key.compareTo(weekAgoKey) >= 0) {
      if (status == 'failed' || status == 'undelivered') {
        failed++;
        if (locId != null) failedLocs.add(locId);
      }
      if (error.contains('30034') || error.contains('30032')) {
        carrierBlocked = true;
      }
    }
  }

  // Pending approvals
  int pending = 0;
  DateTime? oldest;
  for (final doc in pendingEntries) {
    final s = EntrySummary.fromMap(doc.id, syncedData(doc));
    if (locFilter != null && s.locationId != locFilter) continue;
    pending++;
    final dt = s.sheetDate;
    if (oldest == null || dt.isBefore(oldest)) oldest = dt;
  }

  return AdminOverview(
    days: days,
    paid: paid,
    prevPaid: prevPaid,
    customers: customers,
    sheets: sheets,
    activeLocations: activeLocs.length,
    receiptsIssued: issued,
    receiptsTexted: texted,
    failedTexts: failed,
    failedLocationIds: failedLocs,
    carrierBlocked: carrierBlocked,
    pendingCount: pending,
    oldestPending: oldest,
    paidByLocation: paidByLoc,
    sheetsByLocation: sheetsByLoc,
    materialsByLocation: matByLoc,
    materialsTotal: matTotal,
  );
});

String _money(double v, {bool cents = false}) =>
    NumberFormat.currency(symbol: '\$', decimalDigits: cents ? 2 : 0).format(v);

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  Future<void> _setPreset(WidgetRef ref, String preset) async {
    if (preset == 'all') {
      final today = ChartDateRange.lastDays(1).end;
      DateTime? first;
      try {
        first = await ref.read(firstSheetDateProvider.future);
      } catch (_) {}
      ref.read(chartDateRangeProvider.notifier).state = ChartDateRange(
        start: first == null || first.isAfter(today) ? today : first,
        end: today,
      );
      ref.read(overviewPresetProvider.notifier).state = 'all';
      return;
    }
    ref.read(overviewPresetProvider.notifier).state = preset;
    final range = switch (preset) {
      'today' => ChartDateRange.lastDays(1),
      '30' => ChartDateRange.lastDays(30),
      _ => ChartDateRange.lastDays(7),
    };
    ref.read(chartDateRangeProvider.notifier).state = range;
  }

  void _refresh(WidgetRef ref) {
    SyncedCollection.touchAll();
    ref.invalidate(adminOverviewProvider);
    ref.invalidate(pendingApprovalCountProvider);
    ref.invalidate(hasDraftProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Shown again from the tab bar: refresh quietly (the old numbers stay
    // on screen until the new ones are ready).
    ref.listen<(String, int)>(adminTabShownProvider, (_, next) async {
      if (Uri.parse(next.$1).path != '/admin') return;
      // Check for changes in the background; recompute only if any (the tab
      // switches instantly and keeps its numbers otherwise).
      if (await SyncedCollection.refreshChanged() && context.mounted) {
        ref.invalidate(adminOverviewProvider);
      }
    });
    final preset = ref.watch(overviewPresetProvider);
    final range = ref.watch(chartDateRangeProvider);
    final locId = ref.watch(overviewLocationProvider);
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const [];
    final colors = ref.watch(locationColorsProvider);
    final users = ref.watch(adminUsersProvider).valueOrNull ?? const [];
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final me = users.where((u) => u.id == uid).firstOrNull;
    final firstName = me == null
        ? null
        : me.displayName.split(RegExp(r'[\s@]')).first;

    final selectedLoc = locations.where((l) => l.id == locId).firstOrNull;
    final rangeLabel = preset == 'all'
        ? 'All time · since ${DateFormat('MMM d, yyyy').format(range.start)}'
        : range.length == 1
            ? DateFormat('EEEE, MMM d').format(range.end)
            : range.start.year != range.end.year
                ? '${DateFormat('MMM d, yyyy').format(range.start)} – ${DateFormat('MMM d, yyyy').format(range.end)}'
                : '${DateFormat('MMM d').format(range.start)} – ${DateFormat('MMM d').format(range.end)}';

    return AdminShell(
      floatingActionButton: const AdminNewEntryFab(),
      section: AdminSection.overview,
      title: 'Overview',
      subtitle: firstName == null || firstName.isEmpty
          ? rangeLabel
          : 'Welcome back, ${firstName[0].toUpperCase()}${firstName.substring(1)} · $rangeLabel',
      actions: [
        SegmentedPills<String>(
          options: const [
            ('today', 'Today'),
            ('7', '7 days'),
            ('30', '30 days'),
            ('all', 'All time'),
          ],
          value: preset == 'custom' ? null : preset,
          onChanged: (p) => _setPreset(ref, p),
        ),
        AdminFilterButton(
          label: preset == 'custom' ? rangeLabel : 'Dates',
          icon: Icons.calendar_month_rounded,
          active: preset == 'custom',
          onTap: () => _showDateFilterBottomSheet(context, ref, range),
        ),
        AdminFilterButton(
          label: selectedLoc?.name ?? 'All locations',
          active: selectedLoc != null,
          dot: selectedLoc == null ? null : colorForLocation(colors, selectedLoc.id),
          onTap: () => showLocationPickerSheet(
            context: context,
            locations: locations,
            colors: colors,
            selectedId: locId,
            onSelected: (id) =>
                ref.read(overviewLocationProvider.notifier).state = id,
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () => _refresh(ref),
          icon: const Icon(Icons.refresh_rounded, color: AppColors.navy),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () async {
          _refresh(ref);
          await ref.read(adminOverviewProvider.future);
        },
        child: const _OverviewBody(),
      ),
    );
  }

  void _showDateFilterBottomSheet(
    BuildContext context,
    WidgetRef ref,
    ChartDateRange currentRange,
  ) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _DateFilterBottomSheet(
            theme: theme,
            colorScheme: theme.colorScheme,
            initialStart: currentRange.start,
            initialEnd: currentRange.end,
            onApply: (start, end) {
              ref.read(overviewPresetProvider.notifier).state = 'custom';
              ref.read(chartDateRangeProvider.notifier).state =
                  ChartDateRange(start: start, end: end);
              Navigator.of(ctx).pop();
            },
          ),
        ),
      ),
    );
  }
}

class _OverviewBody extends ConsumerWidget {
  const _OverviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminOverviewProvider);
    final width = MediaQuery.sizeOf(context).width;
    final hPad = width < 760 ? 16.0 : 28.0;

    return async.when(
      // Changing the period or location keeps the current figures on screen
      // until the new ones are ready (no shimmer flash).
      skipLoadingOnReload: true,
      loading: () => SkeletonDashboard(padding: EdgeInsets.all(hPad)),
      error: (e, _) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(hPad),
        children: [
          AdminCard(
            child: Row(
              children: [
                const Icon(Icons.cloud_off_rounded, color: AppColors.red),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Couldn't load the overview. ${friendlyError(e)}",
                    style: const TextStyle(color: AppColors.redText),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    SyncedCollection.touchAll();
                    ref.invalidate(adminOverviewProvider);
                  },
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ],
      ),
      data: (o) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 100),
        children: [
          _KpiRow(o: o),
          const SizedBox(height: 18),
          Entrance(
            delay: const Duration(milliseconds: 140),
            child: _MaterialsCard(o: o),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= 980) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Entrance(
                        delay: const Duration(milliseconds: 200),
                        child: _ChartCard(o: o),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      flex: 2,
                      child: Entrance(
                        delay: const Duration(milliseconds: 280),
                        child: _AttentionCard(o: o),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Entrance(
                    delay: const Duration(milliseconds: 200),
                    child: _AttentionCard(o: o),
                  ),
                  const SizedBox(height: 18),
                  Entrance(
                    delay: const Duration(milliseconds: 280),
                    child: _ChartCard(o: o),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Materials by location
// ─────────────────────────────────────────────────────────────────────────────

class _MaterialsCard extends ConsumerWidget {
  final AdminOverview o;
  const _MaterialsCard({required this.o});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const <AppLocation>[];
    final colors = ref.watch(locationColorsProvider);
    String nameOf(String id) => id.isEmpty
        ? 'No location'
        : (locations.where((l) => l.id == id).firstOrNull?.name ?? 'Unknown');

    // Locations with data, in the same (alphabetical) order as everywhere else.
    final ids = <String>[
      for (final l in locations)
        if (o.materialsByLocation.containsKey(l.id)) l.id,
      for (final id in o.materialsByLocation.keys)
        if (!locations.any((l) => l.id == id)) id,
    ];

    return AdminCard(
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 720;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Materials by location',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy),
              ),
              const SizedBox(height: 2),
              const Text(
                'CRV weight (SW, lb) and amount paid, for the dates and location selected above',
                style: TextStyle(fontSize: 12.5, color: AppColors.slate),
              ),
              const SizedBox(height: 14),
              // Totals per material
              _MaterialTotalsRow(t: o.materialsTotal, columns: wide ? 4 : 2, width: c.maxWidth),
              const SizedBox(height: 16),
              if (ids.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No sheets in this period.', style: TextStyle(color: AppColors.slate)),
                )
              else if (wide)
                _MaterialsTable(
                  ids: ids,
                  nameOf: nameOf,
                  colorOf: (id) => colorForLocation(colors, id.isEmpty ? null : id),
                  byLocation: o.materialsByLocation,
                  total: o.materialsTotal,
                )
              else
                for (final id in ids)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.mist.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            LocationDot(colorForLocation(colors, id.isEmpty ? null : id)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                nameOf(id),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
                              ),
                            ),
                            Text(
                              formatMoney(o.materialsByLocation[id]!.totalPaid),
                              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.only(left: 18, bottom: 8),
                          child: Text(
                            '${o.materialsByLocation[id]!.sheets} sheets · ${o.materialsByLocation[id]!.customers} customers',
                            style: const TextStyle(fontSize: 12, color: AppColors.slate),
                          ),
                        ),
                        MaterialShareBar(totals: o.materialsByLocation[id]!, height: 4),
                        const SizedBox(height: 8),
                        MaterialStrip(totals: o.materialsByLocation[id]!),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _MaterialTotalsRow extends StatelessWidget {
  final MaterialTotals t;
  final int columns;
  final double width;
  const _MaterialTotalsRow({required this.t, required this.columns, required this.width});

  @override
  Widget build(BuildContext context) {
    const gap = 10.0;
    final w = (width - gap * (columns - 1)) / columns;
    final reduce = MediaQuery.of(context).disableAnimations;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final (label, lb, paid) in t.rows)
          SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                color: kMaterialStyles[label]!.tint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(kMaterialStyles[label]!.icon, size: 16, color: kMaterialStyles[label]!.main),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: kMaterialStyles[label]!.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: lb),
                    duration: reduce ? Duration.zero : const Duration(milliseconds: 700),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => Text(
                      '${formatLb(v)} lb',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: kMaterialStyles[label]!.text,
                      ),
                    ),
                  ),
                  Text(
                    '${formatMoney(paid)} paid',
                    style: TextStyle(fontSize: 12.5, color: kMaterialStyles[label]!.text),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MaterialsTable extends StatelessWidget {
  final List<String> ids;
  final String Function(String) nameOf;
  final Color Function(String) colorOf;
  final Map<String, MaterialTotals> byLocation;
  final MaterialTotals total;
  const _MaterialsTable({
    required this.ids,
    required this.nameOf,
    required this.colorOf,
    required this.byLocation,
    required this.total,
  });

  static const _hdr = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: AppColors.slate,
  );

  Widget _cell(double lb, double paid, {bool bold = false, Color? color}) {
    return Expanded(
      flex: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            lb > 0 ? '${formatLb(lb)} lb' : '—',
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color ?? AppColors.navy,
            ),
          ),
          Text(
            paid > 0 ? formatMoney(paid) : '',
            style: const TextStyle(fontSize: 12, color: AppColors.slate),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, Widget lead, MaterialTotals t, {bool bold = false, Color? bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: lead),
          for (final (name, lb, paid) in t.rows)
            _cell(lb, paid, bold: bold, color: lb > 0 ? kMaterialStyles[name]!.text : null),
          Expanded(
            flex: 2,
            child: Text(
              formatMoney(t.totalPaid),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                color: AppColors.navy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Expanded(flex: 3, child: Text('LOCATION', style: _hdr)),
              for (final name in kMaterialStyles.keys)
                Expanded(
                  flex: 2,
                  child: Text(
                    name.toUpperCase(),
                    textAlign: TextAlign.right,
                    style: _hdr.copyWith(color: kMaterialStyles[name]!.text),
                  ),
                ),
              const Expanded(
                flex: 2,
                child: Text('TOTAL PAID', textAlign: TextAlign.right, style: _hdr),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < ids.length; i++)
          _row(
            nameOf(ids[i]),
            Row(
              children: [
                LocationDot(colorOf(ids[i])),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nameOf(ids[i]),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
                      ),
                      Text(
                        '${byLocation[ids[i]]!.sheets} sheets · ${byLocation[ids[i]]!.customers} cust.',
                        style: const TextStyle(fontSize: 12, color: AppColors.slate),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            byLocation[ids[i]]!,
            bg: i.isEven ? AppColors.mist.withValues(alpha: 0.55) : null,
          ),
        if (ids.length > 1) ...[
          const Divider(height: 16, color: AppColors.line),
          _row(
            'All locations',
            const Text(
              'All locations',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.navy),
            ),
            total,
            bold: true,
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KPIs
// ─────────────────────────────────────────────────────────────────────────────

class _KpiRow extends ConsumerWidget {
  final AdminOverview o;
  const _KpiRow({required this.o});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(chartDateRangeProvider);
    final prevLabel = range.length == 1 ? 'yesterday' : 'previous ${range.length} days';

    final allTime = ref.watch(overviewPresetProvider) == 'all';
    String paidFoot;
    if (allTime) {
      paidFoot = 'Since ${DateFormat('MMM d, yyyy').format(range.start)}';
    } else if (o.prevPaid <= 0) {
      paidFoot = o.paid > 0 ? 'Nothing paid the $prevLabel' : 'No sheets in this period';
    } else {
      final pct = ((o.paid - o.prevPaid) / o.prevPaid * 100).round();
      paidFoot = '${pct >= 0 ? '▲' : '▼'} ${pct.abs()}% vs $prevLabel';
    }

    final textedPct =
        o.receiptsIssued == 0 ? 0.0 : o.receiptsTexted / o.receiptsIssued * 100;

    final tiles = <Widget>[
      KpiTile(
        label: 'Paid out',
        value: o.paid,
        format: (v) => _money(v),
        footnote: paidFoot,
        accent: AppColors.green,
        valueColor: Colors.white,
        filled: true,
      ),
      KpiTile(
        label: 'Customers',
        value: o.customers.toDouble(),
        format: (v) => v.round().toString(),
        footnote: o.activeLocations == 0
            ? '${o.sheets} sheets'
            : '${o.sheets} sheets · ${o.activeLocations} location${o.activeLocations == 1 ? '' : 's'}',
        accent: AppColors.blue,
        valueColor: AppColors.blueText,
      ),
      KpiTile(
        label: 'Receipts texted',
        value: textedPct,
        format: (v) => o.receiptsIssued == 0 ? '—' : '${v.round()}%',
        footnote: o.receiptsIssued == 0
            ? 'No receipts issued yet'
            : '${o.receiptsTexted} of ${o.receiptsIssued} receipts',
        accent: AppColors.amber,
        valueColor: AppColors.amberText,
        onTap: () => showAdminTab(context, ref, '/admin/receipts'),
      ),
      KpiTile(
        label: 'Awaiting approval',
        value: o.pendingCount.toDouble(),
        format: (v) => v.round().toString(),
        footnote: o.oldestPending == null
            ? 'All sheets approved'
            : 'Oldest from ${DateFormat('MMM d').format(o.oldestPending!)}',
        accent: AppColors.purple,
        valueColor: AppColors.purpleText,
        onTap: () => showAdminTab(context, ref, '/admin/logs?filter=pending'),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 760 ? 4 : 2;
        const gap = 14.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < tiles.length; i++)
              SizedBox(
                width: w,
                child: Entrance(
                  delay: Duration(milliseconds: 60 * i),
                  child: tiles[i],
                ),
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Chart
// ─────────────────────────────────────────────────────────────────────────────

class _ChartCard extends ConsumerWidget {
  final AdminOverview o;
  const _ChartCard({required this.o});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metric = ref.watch(overviewMetricProvider);
    final isPaid = metric == 'paid';
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const [];
    final colors = ref.watch(locationColorsProvider);
    final locFilter = ref.watch(overviewLocationProvider);

    // Locations that appear in the data (plus "unknown" bucket if needed).
    final ids = <String>[
      for (final l in locations)
        if (locFilter == null || l.id == locFilter) l.id,
    ];
    final hasUnknown = (o.sheetsByLocation[''] ?? 0) > 0;
    if (hasUnknown) ids.add('');
    String nameOf(String id) => id.isEmpty
        ? 'No location'
        : (locations.where((l) => l.id == id).firstOrNull?.name ?? 'Unknown');

    double valueOf(OverviewDay d, String id) => isPaid
        ? (d.paidByLocation[id] ?? 0)
        : (d.sheetsByLocation[id] ?? 0).toDouble();

    final single = o.days.length == 1;
    double maxY = 0;
    if (single) {
      for (final id in ids) {
        final v = valueOf(o.days.first, id);
        if (v > maxY) maxY = v;
      }
    } else {
      for (final d in o.days) {
        double sum = 0;
        for (final id in ids) {
          sum += valueOf(d, id);
        }
        if (sum > maxY) maxY = sum;
      }
    }
    maxY = maxY <= 0 ? (isPaid ? 100 : 4) : (maxY * 1.18);
    final interval = maxY / 4;

    String axis(double v) {
      if (!isPaid) return v.round().toString();
      if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 1)}k';
      return '\$${v.round()}';
    }

    final total = isPaid ? _money(o.paid) : '${o.sheets} sheets';
    final firstTip = o.days.first.tooltipLabel;
    final unit = firstTip == null ? 'day' : (firstTip.startsWith('Week') ? 'week' : 'month');

    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaid
                          ? (single ? 'Paid out · per location' : 'Paid out by $unit · per location')
                          : (single ? 'Sheets · per location' : 'Sheets by $unit · per location'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Total $total',
                      style: const TextStyle(fontSize: 13, color: AppColors.slate),
                    ),
                  ],
                ),
              ),
              SegmentedPills<String>(
                options: const [('paid', '\$ Paid'), ('sheets', 'Sheets')],
                value: metric,
                background: AppColors.mist,
                onChanged: (m) =>
                    ref.read(overviewMetricProvider.notifier).state = m,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Legend with per-location totals
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final id in ids)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LocationDot(colorForLocation(colors, id.isEmpty ? null : id)),
                    const SizedBox(width: 6),
                    Text(
                      nameOf(id),
                      style: const TextStyle(fontSize: 13, color: AppColors.navy),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isPaid
                          ? _money(o.paidByLocation[id] ?? 0)
                          : '${o.sheetsByLocation[id] ?? 0}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 240,
            child: TweenAnimationBuilder<double>(
              key: ValueKey('$metric-${o.days.length}-${o.days.first.date}'),
              tween: Tween(begin: 0, end: 1),
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) {
                final groups = <BarChartGroupData>[];
                if (single) {
                  for (var i = 0; i < ids.length; i++) {
                    final v = valueOf(o.days.first, ids[i]) * t;
                    groups.add(BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: v,
                        width: 34,
                        color: colorForLocation(colors, ids[i].isEmpty ? null : ids[i]),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      ),
                    ]));
                  }
                } else {
                  final barWidth = o.days.length <= 7
                      ? 24.0
                      : o.days.length <= 14
                          ? 14.0
                          : o.days.length <= 31
                              ? 7.0
                              : 4.0;
                  for (var di = 0; di < o.days.length; di++) {
                    final d = o.days[di];
                    final stack = <BarChartRodStackItem>[];
                    double from = 0;
                    for (final id in ids) {
                      final v = valueOf(d, id) * t;
                      if (v <= 0) continue;
                      stack.add(BarChartRodStackItem(
                        from,
                        from + v,
                        colorForLocation(colors, id.isEmpty ? null : id),
                      ));
                      from += v;
                    }
                    groups.add(BarChartGroupData(x: di, barRods: [
                      BarChartRodData(
                        toY: from,
                        width: barWidth,
                        color: from == 0 ? AppColors.line : Colors.transparent,
                        rodStackItems: stack,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                      ),
                    ]));
                  }
                }

                return BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: maxY,
                    minY: 0,
                    barGroups: groups,
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => AppColors.navy,
                        fitInsideHorizontally: true,
                        fitInsideVertically: true,
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final style = const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          );
                          String fmt(double v) =>
                              isPaid ? _money(v, cents: true) : v.round().toString();
                          if (single) {
                            final id = ids[group.x];
                            return BarTooltipItem(
                              '${nameOf(id)}\n${fmt(valueOf(o.days.first, id))}',
                              style,
                            );
                          }
                          final d = o.days[group.x];
                          final lines = <String>[
                            d.tooltipLabel ?? DateFormat('EEE, MMM d').format(d.date),
                            for (final id in ids)
                              if (valueOf(d, id) > 0) '${nameOf(id)}  ${fmt(valueOf(d, id))}',
                          ];
                          if (lines.length == 1) lines.add('No sheets');
                          return BarTooltipItem(lines.join('\n'), style);
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: isPaid ? 48 : 30,
                          interval: interval,
                          getTitlesWidget: (v, meta) => Text(
                            axis(v),
                            style: const TextStyle(fontSize: 11, color: AppColors.slate),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: single ? 30 : 40,
                          interval: 1,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (single) {
                              if (i < 0 || i >= ids.length) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  nameOf(ids[i]),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: AppColors.navy),
                                ),
                              );
                            }
                            if (i < 0 || i >= o.days.length) return const SizedBox.shrink();
                            final step = o.days.length <= 10 ? 1 : (o.days.length / 6).ceil();
                            if (i % step != 0 && i != o.days.length - 1) {
                              return const SizedBox.shrink();
                            }
                            final day = o.days[i];
                            final d = day.date;
                            if (day.axisLabel != null) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  day.axisLabel!,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.navy,
                                  ),
                                ),
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (o.days.length <= 10)
                                    Text(
                                      DateFormat('EEE').format(d),
                                      style: const TextStyle(fontSize: 11, color: AppColors.slate),
                                    ),
                                  Text(
                                    DateFormat('M/d').format(d),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.navy,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: interval,
                      getDrawingHorizontalLine: (_) =>
                          FlLine(color: AppColors.line, strokeWidth: 1),
                    ),
                    borderData: FlBorderData(show: false),
                  ),
                  duration: Duration.zero,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Needs attention
// ─────────────────────────────────────────────────────────────────────────────

class _AttentionCard extends ConsumerWidget {
  final AdminOverview o;
  const _AttentionCard({required this.o});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasDraft = ref.watch(hasDraftProvider).valueOrNull ?? false;
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const [];
    final failedNames = o.failedLocationIds
        .map((id) => locations.where((l) => l.id == id).firstOrNull?.name)
        .whereType<String>()
        .join(', ');

    final items = <Widget>[
      if (o.failedTexts > 0)
        _AttentionItem(
          icon: Icons.sms_failed_rounded,
          bg: AppColors.redTint,
          fg: AppColors.red,
          title: '${o.failedTexts} text${o.failedTexts == 1 ? '' : 's'} failed',
          subtitle: '${failedNames.isEmpty ? 'Last 7 days' : failedNames} · tap to resend or print',
          pulse: true,
          onTap: () => showAdminTab(context, ref, '/admin/receipts?filter=failed'),
        ),
      if (o.pendingCount > 0)
        _AttentionItem(
          icon: Icons.fact_check_rounded,
          bg: AppColors.amberTint,
          fg: AppColors.amber,
          title: '${o.pendingCount} sheet${o.pendingCount == 1 ? '' : 's'} to approve',
          subtitle: o.oldestPending == null
              ? 'Tap to review'
              : 'Oldest from ${DateFormat('MMM d').format(o.oldestPending!)}',
          onTap: () => showAdminTab(context, ref, '/admin/logs?filter=pending'),
        ),
      if (hasDraft)
        _AttentionItem(
          icon: Icons.edit_note_rounded,
          bg: AppColors.blueTint,
          fg: AppColors.blue,
          title: 'Draft open on this iPad',
          subtitle: 'Continue it, or discard it to start fresh',
          onTap: () async {
            await context.push('/new-entry');
            ref.invalidate(hasDraftProvider);
          },
          trailing: IconButton(
            tooltip: 'Discard draft',
            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
            onPressed: () async {
              final ok = await showFloatingConfirmationBottomSheet(
                context: context,
                title: 'Discard draft?',
                message: 'This permanently deletes the sheet saved on this iPad.',
                confirmLabel: 'Discard',
                cancelLabel: 'Keep',
              );
              if (!ok) return;
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove(kDraftSheetKey);
              ref.invalidate(hasDraftProvider);
              if (context.mounted) showAppSnack(context, 'Draft discarded');
            },
          ),
        ),
      if (o.carrierBlocked)
        const _AttentionItem(
          icon: Icons.hourglass_top_rounded,
          bg: AppColors.purpleTint,
          fg: AppColors.purple,
          title: 'Texts waiting on carrier approval',
          subtitle: 'The SMS campaign is still in review — print receipts for now',
        ),
    ];

    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Needs attention',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const _AttentionItem(
              icon: Icons.check_circle_rounded,
              bg: AppColors.greenTint,
              fg: AppColors.green,
              title: 'All clear',
              subtitle: 'Nothing needs you right now.',
            )
          else
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Entrance(
                  delay: Duration(milliseconds: 320 + 70 * i),
                  child: items[i],
                ),
              ),
        ],
      ),
    );
  }
}

class _AttentionItem extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color fg;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool pulse;

  const _AttentionItem({
    required this.icon,
    required this.bg,
    required this.fg,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.pulse = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _PulseIcon(icon: icon, bg: bg, fg: fg, pulse: pulse),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
          if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
        ],
      ),
    );
    if (onTap == null) return row;
    return PressScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: row,
    );
  }
}

/// Icon bubble; optionally pulses (failed texts) unless Reduce Motion is on.
class _PulseIcon extends StatefulWidget {
  final IconData icon;
  final Color bg;
  final Color fg;
  final bool pulse;
  const _PulseIcon({
    required this.icon,
    required this.bg,
    required this.fg,
    required this.pulse,
  });

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.pulse && !MediaQuery.of(context).disableAnimations) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = widget.pulse ? _c.value : 0.0;
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: widget.bg,
            borderRadius: BorderRadius.circular(12),
            boxShadow: widget.pulse
                ? [
                    BoxShadow(
                      color: widget.fg.withValues(alpha: 0.35 * (1 - t)),
                      blurRadius: 0,
                      spreadRadius: 7 * t,
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      child: Icon(widget.icon, color: widget.fg, size: 22),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom date range sheet (unchanged behaviour from the previous dashboard)
// ─────────────────────────────────────────────────────────────────────────────

class _CupertinoDatePickerSheet extends StatefulWidget {
  const _CupertinoDatePickerSheet({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_CupertinoDatePickerSheet> createState() =>
      _CupertinoDatePickerSheetState();
}

class _CupertinoDatePickerSheetState extends State<_CupertinoDatePickerSheet> {
  late DateTime _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialDate;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 48),
              Text(
                'Select date',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.navy,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_picked),
                child: const Text('Done'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: theme.brightness,
                primaryColor: colorScheme.primary,
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _picked,
                minimumDate: widget.firstDate,
                maximumDate: widget.lastDate,
                onDateTimeChanged: (DateTime value) {
                  setState(() => _picked = value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateFilterBottomSheet extends StatefulWidget {
  const _DateFilterBottomSheet({
    required this.theme,
    required this.colorScheme,
    required this.initialStart,
    required this.initialEnd,
    required this.onApply,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final DateTime initialStart;
  final DateTime initialEnd;
  final void Function(DateTime start, DateTime end) onApply;

  @override
  State<_DateFilterBottomSheet> createState() => _DateFilterBottomSheetState();
}

class _DateFilterBottomSheetState extends State<_DateFilterBottomSheet> {
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    _start = DateTime(
        widget.initialStart.year, widget.initialStart.month, widget.initialStart.day);
    _end = DateTime(
        widget.initialEnd.year, widget.initialEnd.month, widget.initialEnd.day);
  }

  static Future<DateTime?> _pick({
    required BuildContext context,
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: _CupertinoDatePickerSheet(
          initialDate: initialDate,
          firstDate: firstDate,
          lastDate: lastDate,
        ),
      ),
    );
  }

  Widget _dateBox(String label, DateTime value, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.field),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
              const SizedBox(height: 2),
              Text(
                DateFormat('MMM d, yyyy').format(value),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.navy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Date range',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _dateBox('From', _start, () async {
                final picked = await _pick(
                  context: context,
                  initialDate: _start,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null && mounted) {
                  setState(() {
                    _start = picked;
                    if (_end.isBefore(_start)) _end = _start;
                  });
                }
              }),
              const SizedBox(width: 12),
              _dateBox('To', _end, () async {
                final picked = await _pick(
                  context: context,
                  initialDate: _end,
                  firstDate: _start,
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null && mounted) {
                  setState(() => _end = picked);
                }
              }),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.navy,
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: () => widget.onApply(_start, _end),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
