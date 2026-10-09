import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../utils/entry_stats.dart';
import '../widgets/admin_shell.dart';
import '../widgets/floating_confirmation_sheet.dart';

/// Admin › Log sheets: table of submitted entries with status filters,
/// multi-select approve/delete, paging and CSV copy.
class LogSheetsScreen extends ConsumerStatefulWidget {
  /// 'all' | 'pending' | 'approved'
  final String initialFilter;
  const LogSheetsScreen({super.key, this.initialFilter = 'all'});

  @override
  ConsumerState<LogSheetsScreen> createState() => _LogSheetsScreenState();
}

class _ReceiptCounts {
  int sms = 0;
  int printed = 0;
  final List<int> numbers = [];
  final List<String> codes = [];
}

class _LogSheetsScreenState extends ConsumerState<LogSheetsScreen> {
  static const _pageSize = 50;

  final _searchController = TextEditingController();
  String _search = '';
  late String _filter = widget.initialFilter;
  /// Selected locations; empty = all locations.
  Set<String> _locationIds = {};

  /// null = all time (paged); otherwise number of days back from today.
  int? _rangeDays;

  List<EntrySummary> _rows = [];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  final Map<String, _ReceiptCounts> _receipts = {};
  int? _countAll;
  int? _countApproved;
  int? _countPending;

  final Set<String> _selected = {};
  final Set<String> _busy = {};
  final Set<String> _justApproved = {};

  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('entries');

  @override
  void initState() {
    super.initState();
    _load();
    _loadCounts();
  }

  @override
  void didUpdateWidget(covariant LogSheetsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilter != widget.initialFilter) {
      _setFilter(widget.initialFilter);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Data ────────────────────────────────────────────────────────────────

  Future<void> _loadCounts() async {
    try {
      final r = await Future.wait([
        _col.count().get(),
        _col.where('approved', isEqualTo: true).count().get(),
        _col.where('approved', isEqualTo: false).count().get(),
      ]);
      if (!mounted) return;
      setState(() {
        _countAll = r[0].count;
        _countApproved = r[1].count;
        _countPending = r[2].count;
      });
    } catch (_) {
      // Counts are decoration; the list still works without them.
    }
  }

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
        _selected.clear();
        _cursor = null;
      });
    }

    try {
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
      var hasMore = false;

      if (_rangeDays != null) {
        final fmt = DateFormat('yyyy-MM-dd');
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final start = today.subtract(Duration(days: _rangeDays! - 1));
        final snap = await _col
            .where('entryDateKey', isGreaterThanOrEqualTo: fmt.format(start))
            .where('entryDateKey', isLessThanOrEqualTo: fmt.format(today))
            .get();
        docs = snap.docs;
      } else if (_filter == 'pending') {
        final snap = await _col.where('approved', isEqualTo: false).get();
        docs = snap.docs;
      } else if (_locationIds.isNotEmpty) {
        // Chosen locations, all dates: whereIn in chunks of 30 (no composite
        // index needed), sorted below.
        final ids = _locationIds.toList();
        docs = [];
        for (var i = 0; i < ids.length; i += 30) {
          final part = await _col
              .where('location', whereIn: ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30))
              .get();
          docs.addAll(part.docs);
        }
      } else {
        Query<Map<String, dynamic>> q =
            _col.orderBy('createdAt', descending: true).limit(_pageSize);
        if (more && _cursor != null) q = q.startAfterDocument(_cursor!);
        final snap = await q.get();
        docs = snap.docs;
        hasMore = docs.length == _pageSize;
        if (docs.isNotEmpty) _cursor = docs.last;
      }

      final batch = docs.map(EntrySummary.fromDoc).toList();
      await _loadReceiptCounts(batch.map((e) => e.id).toList());

      if (!mounted) return;
      setState(() {
        final merged = more ? [..._rows, ...batch] : batch;
        merged.sort((a, b) {
          final byDay = b.dateKey.compareTo(a.dateKey);
          return byDay != 0 ? byDay : b.createdAt.compareTo(a.createdAt);
        });
        _rows = merged;
        _hasMore = hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadReceiptCounts(List<String> entryIds) async {
    final receipts = FirebaseFirestore.instance.collection('receipts');
    for (var i = 0; i < entryIds.length; i += 30) {
      final chunk = entryIds.sublist(
          i, i + 30 > entryIds.length ? entryIds.length : i + 30);
      try {
        final snap = await receipts.where('entryId', whereIn: chunk).get();
        for (final id in chunk) {
          _receipts[id] = _ReceiptCounts();
        }
        for (final doc in snap.docs) {
          final d = doc.data();
          final entryId = d['entryId']?.toString();
          if (entryId == null) continue;
          final c = _receipts.putIfAbsent(entryId, _ReceiptCounts.new);
          final sms = d['sms'];
          if (sms is Map && sms['requested'] == true) c.sms++;
          if (d['printed'] == true) c.printed++;
          final n = (d['receiptNumber'] as num?)?.toInt();
          if (n != null) c.numbers.add(n);
          final code = d['receiptCode']?.toString() ?? '';
          if (code.isNotEmpty) c.codes.add(code);
        }
      } catch (_) {
        // Receipt counts are optional — skip on error.
      }
    }
  }

  Future<void> _refreshOne(String id) async {
    try {
      final doc = await _col.doc(id).get();
      if (!mounted) return;
      setState(() {
        if (!doc.exists) {
          _rows.removeWhere((r) => r.id == id);
        } else {
          final updated = EntrySummary.fromDoc(doc);
          final i = _rows.indexWhere((r) => r.id == id);
          if (i >= 0) _rows[i] = updated;
        }
      });
      ref.invalidate(pendingApprovalCountProvider);
      _loadCounts();
    } catch (_) {}
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Future<void> _approve(List<String> ids) async {
    if (ids.isEmpty) return;
    setState(() => _busy.addAll(ids));
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final id in ids) {
        batch.update(_col.doc(id), {
          'approved': true,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      if (!mounted) return;
      HapticFeedback.lightImpact();
      setState(() {
        _rows = [
          for (final r in _rows) ids.contains(r.id) ? r.withApproved(true) : r,
        ];
        _selected.removeAll(ids);
        _justApproved.addAll(ids);
      });
      Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _justApproved.removeAll(ids));
      });
      showAppSnack(
        context,
        ids.length == 1 ? 'Sheet approved' : '${ids.length} sheets approved',
      );
      ref.invalidate(pendingApprovalCountProvider);
      _loadCounts();
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.removeAll(ids));
    }
  }

  Future<void> _delete(List<String> ids) async {
    if (ids.isEmpty) return;
    final ok = await showFloatingConfirmationBottomSheet(
      context: context,
      title: ids.length == 1 ? 'Delete this sheet?' : 'Delete ${ids.length} sheets?',
      message:
          'The entry and its sheets are removed for everyone. Receipts already issued stay on file.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!ok || !mounted) return;
    setState(() => _busy.addAll(ids));
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final id in ids) {
        batch.delete(_col.doc(id));
      }
      await batch.commit();
      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => ids.contains(r.id));
        _selected.removeAll(ids);
      });
      showAppSnack(
        context,
        ids.length == 1 ? 'Sheet deleted' : '${ids.length} sheets deleted',
      );
      ref.invalidate(pendingApprovalCountProvider);
      _loadCounts();
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.removeAll(ids));
    }
  }

  Future<void> _open(EntrySummary r) async {
    await context.push('/view-entry/${r.id}');
    await _refreshOne(r.id);
  }

  void _copyCsv(List<EntrySummary> rows, Map<String, AdminUser> users) {
    String esc(String v) =>
        v.contains(RegExp(r'[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
    final b = StringBuffer(
      'Date,Location,Certification,Staff,Email,Sheets,Customers,Paid,'
      'Aluminium SW (lb),Glass SW (lb),PETE SW (lb),Other SW (lb),'
      'Aluminium paid,Glass paid,PETE paid,Other paid,'
      'Receipts texted,Receipts printed,Status,Entry ID\n',
    );
    for (final r in rows) {
      final rc = _receipts[r.id];
      b.writeln([
        r.dateKey,
        r.locationLabel,
        r.locationCertification,
        _staffName(r, users),
        r.email,
        '${r.sheetCount}',
        '${r.customers}',
        r.paid.toStringAsFixed(2),
        r.aluminiumSW.toStringAsFixed(2),
        r.glassSW.toStringAsFixed(2),
        r.peteSW.toStringAsFixed(2),
        r.otherSW.toStringAsFixed(2),
        r.aluminiumPaid.toStringAsFixed(2),
        r.glassPaid.toStringAsFixed(2),
        r.petePaid.toStringAsFixed(2),
        r.otherPaid.toStringAsFixed(2),
        '${rc?.sms ?? 0}',
        '${rc?.printed ?? 0}',
        r.approved ? 'Approved' : 'Pending',
        r.id,
      ].map(esc).join(','));
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    showAppSnack(
      context,
      'Copied ${rows.length} row${rows.length == 1 ? '' : 's'} — paste into Numbers, Excel or an email',
    );
  }

  // ── Filters ─────────────────────────────────────────────────────────────

  void _setFilter(String f) {
    if (f == _filter) return;
    final needsReload =
        _rangeDays == null && (f == 'pending' || _filter == 'pending');
    setState(() {
      _filter = f;
      _selected.clear();
    });
    if (needsReload) _load();
  }

  void _setRange(int? days) {
    if (days == _rangeDays) return;
    setState(() => _rangeDays = days);
    _load();
  }

  String _staffName(EntrySummary r, Map<String, AdminUser> users) {
    final u = users[r.userId];
    if (u != null) return u.shortName;
    return r.email.split('@').first;
  }

  bool get _usingAggregateCounts =>
      _rangeDays == null && _locationIds.isEmpty && _search.isEmpty;

  bool _matchesNonStatus(EntrySummary r, Map<String, AdminUser> users) {
    if (_locationIds.isNotEmpty && !_locationIds.contains(r.locationId)) return false;
    if (_search.isNotEmpty) {
      final rc = _receipts[r.id];
      final hay = [
        r.email,
        r.reference,
        r.locationLabel,
        _staffName(r, users),
        ...r.customerNames,
        ...?rc?.numbers.map((n) => '$n'),
        ...?rc?.codes,
      ].join(' ').toLowerCase();
      if (!hay.contains(_search)) return false;
    }
    return true;
  }

  int? _countFor(String status, Map<String, AdminUser> users) {
    if (_usingAggregateCounts) {
      return switch (status) {
        'approved' => _countApproved,
        'pending' => _countPending,
        _ => _countAll,
      };
    }
    // Without a date range only pending sheets (or the loaded pages) are in
    // memory, so other counts would be misleading — hide them.
    if (_rangeDays == null && _filter == 'pending' && status != 'pending') {
      return null;
    }
    if (_rangeDays == null && _hasMore) return null;
    return _rows.where((r) {
      if (!_matchesNonStatus(r, users)) return false;
      if (status == 'approved') return r.approved;
      if (status == 'pending') return !r.approved;
      return true;
    }).length;
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final users = {
      for (final u in ref.watch(adminUsersProvider).valueOrNull ?? const <AdminUser>[])
        u.id: u,
    };
    final colors = ref.watch(locationColorsProvider);
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const <AppLocation>[];
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final phone = width < kAdminPhoneWidth;
    final hPad = narrow ? 16.0 : 28.0;

    final visible = _rows.where((r) {
      if (_filter == 'approved' && !r.approved) return false;
      if (_filter == 'pending' && r.approved) return false;
      return _matchesNonStatus(r, users);
    }).toList();

    final chosenLocs = locations.where((l) => _locationIds.contains(l.id)).toList();
    final selectedPending = _rows
        .where((r) => _selected.contains(r.id) && !r.approved)
        .map((r) => r.id)
        .toList();

    String rangeLabel() => switch (_rangeDays) {
          null => 'All dates',
          1 => 'Today',
          final d => 'Last $d days',
        };

    return AdminShell(
      section: AdminSection.sheets,
      title: 'Log sheets',
      subtitle: _countPending == null
          ? null
          : _countPending == 0
              ? 'Everything is approved'
              : '$_countPending waiting for approval',
      actions: [
        AdminSearchField(
          controller: _searchController,
          hint: 'Customer, staff or receipt #',
          width: phone ? 240 : (narrow ? 220 : 280),
          onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
        ),
        OutlinedButton.icon(
          onPressed: visible.isEmpty ? null : () => _copyCsv(visible, users),
          icon: const Icon(Icons.copy_all_rounded, size: 18),
          label: const Text('Copy CSV'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.navy,
            backgroundColor: Colors.white,
            side: const BorderSide(color: AppColors.field),
            minimumSize: const Size(0, 44),
          ),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: () {
            _load();
            _loadCounts();
            ref.invalidate(pendingApprovalCountProvider);
          },
          icon: const Icon(Icons.refresh_rounded, color: AppColors.navy),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Filters (wrap on tablet, sideways scroll on phone)
          Builder(builder: (context) {
            final filters = <Widget>[
                // Location filter first: opens the multi-select sheet.
                LocationFilterChip(
                  label: chosenLocs.isEmpty
                      ? 'All locations'
                      : (chosenLocs.length == 1 ? chosenLocs.first.name : '${chosenLocs.length} locations'),
                  dots: [for (final l in chosenLocs.take(3)) colorForLocation(colors, l.id)],
                  active: chosenLocs.isNotEmpty,
                  onTap: () async {
                    final result = await showLocationMultiPickerSheet(
                      context: context,
                      locations: locations,
                      colors: colors,
                      selected: _locationIds,
                      subtitle: 'Show log sheets from all locations, one, or several.',
                    );
                    if (result == null || !mounted) return;
                    if (result.length == _locationIds.length && result.containsAll(_locationIds)) return;
                    setState(() {
                      _locationIds = result;
                      _selected.clear();
                    });
                    // All dates are loaded per location from the server.
                    if (_rangeDays == null && _filter != 'pending') _load();
                  },
                ),
                const SizedBox(width: 4, height: 24, child: VerticalDivider(color: AppColors.field)),
                for (final (key, label) in const [
                  ('all', 'All'),
                  ('pending', 'Pending'),
                  ('approved', 'Approved'),
                ])
                  _StatusChip(
                    label: label,
                    count: _countFor(key, users),
                    selected: _filter == key,
                    dot: key == 'pending'
                        ? AppColors.amber
                        : key == 'approved'
                            ? AppColors.green
                            : null,
                    onTap: () => _setFilter(key),
                  ),
                if (!phone) const SizedBox(width: 8),
                AdminFilterButton(
                  label: rangeLabel(),
                  icon: Icons.calendar_month_rounded,
                  active: _rangeDays != null,
                  onTap: () => _showRangeSheet(context),
                ),
            ];
            if (phone) {
              return SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 10),
                  itemCount: filters.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Center(child: filters[i]),
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: filters,
              ),
            );
          }),
          // Selection actions sit at the top while sheets are selected.
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _selected.isEmpty
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 10),
                    child: _SelectionBar(
                      count: _selected.length,
                      pendingCount: selectedPending.length,
                      allSelected: visible.isNotEmpty &&
                          visible.every((r) => _selected.contains(r.id)),
                      busy: _busy.isNotEmpty,
                      onClear: () => setState(_selected.clear),
                      onSelectAll: () => setState(
                          () => _selected.addAll(visible.map((r) => r.id))),
                      onDelete: () => _delete(_selected.toList()),
                      onApprove: () => _approve(selectedPending),
                      phone: phone,
                    ),
                  ),
          ),
          Expanded(
            child: _buildList(
              visible: visible,
              users: users,
              colors: colors,
              narrow: narrow,
              hPad: hPad,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList({
    required List<EntrySummary> visible,
    required Map<String, AdminUser> users,
    required Map<String, Color> colors,
    required bool narrow,
    required double hPad,
  }) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.forest),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.red),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    final canLoadMore = _hasMore && _rangeDays == null && _filter != 'pending';
    final allVisibleSelected =
        visible.isNotEmpty && visible.every((r) => _selected.contains(r.id));
    final wideTable = !narrow;
    final showReceipts = MediaQuery.sizeOf(context).width >= 1100;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
      itemCount: visible.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          if (visible.isEmpty) {
            return Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  const Icon(Icons.inbox_rounded, size: 48, color: AppColors.field),
                  const SizedBox(height: 10),
                  Text(
                    _filter == 'pending'
                        ? 'No sheets waiting for approval'
                        : 'No sheets match these filters',
                    style: const TextStyle(fontSize: 15, color: AppColors.slate),
                  ),
                ],
              ),
            );
          }
          return wideTable
              ? _TableHeader(
                  allSelected: allVisibleSelected,
                  showReceipts: showReceipts,
                  onSelectAll: (v) => setState(() {
                    if (v) {
                      _selected.addAll(visible.map((r) => r.id));
                    } else {
                      _selected.removeAll(visible.map((r) => r.id));
                    }
                  }),
                )
              : const SizedBox(height: 4);
        }
        if (i == visible.length + 1) {
          if (!canLoadMore) {
            return visible.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Center(
                      child: Text(
                        '${visible.length} sheet${visible.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: AppColors.slate, fontSize: 13),
                      ),
                    ),
                  );
          }
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Center(
              child: OutlinedButton(
                onPressed: _loadingMore ? null : () => _load(more: true),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.navy,
                  side: const BorderSide(color: AppColors.field),
                  minimumSize: const Size(200, 46),
                ),
                child: _loadingMore
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Load 50 more'),
              ),
            ),
          );
        }

        final r = visible[i - 1];
        final row = _SheetRow(
          entry: r,
          staff: _staffName(r, users),
          color: colorForLocation(colors, r.locationId),
          receipts: _receipts[r.id],
          selected: _selected.contains(r.id),
          busy: _busy.contains(r.id),
          flash: _justApproved.contains(r.id),
          compact: narrow,
          showReceipts: showReceipts,
          selectionMode: _selected.isNotEmpty,
          onSelect: (v) => setState(() {
            if (v) {
              _selected.add(r.id);
            } else {
              _selected.remove(r.id);
            }
          }),
          onOpen: () => _open(r),
          onApprove: () => _approve([r.id]),
          onDelete: () => _delete([r.id]),
        );
        // Stagger only the first screenful.
        return i <= 12
            ? Entrance(delay: Duration(milliseconds: 25 * i), dy: 8, child: row)
            : row;
      },
    );
  }

  void _showRangeSheet(BuildContext context) {
    final options = <(int?, String)>[
      (null, 'All dates'),
      (1, 'Today'),
      (7, 'Last 7 days'),
      (30, 'Last 30 days'),
      (90, 'Last 90 days'),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (days, label) in options)
                ListTile(
                  title: Text(label),
                  trailing: _rangeDays == days
                      ? const Icon(Icons.check_rounded, color: AppColors.green)
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _setRange(days);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pieces
// ─────────────────────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final Color? dot;
  final VoidCallback onTap;
  const _StatusChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.navy : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.navy : AppColors.field),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[
              LocationDot(dot!, size: 8),
              const SizedBox(width: 6),
            ],
            Text(
              count == null ? label : '$label · $count',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.navy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _hdr = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.6,
  color: AppColors.slate,
);

class _TableHeader extends StatelessWidget {
  final bool allSelected;
  final bool showReceipts;
  final ValueChanged<bool> onSelectAll;
  const _TableHeader({
    required this.allSelected,
    required this.showReceipts,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Checkbox(
              value: allSelected,
              onChanged: (v) => onSelectAll(v ?? false),
              activeColor: AppColors.blue,
            ),
          ),
          const SizedBox(width: 92, child: Text('DATE', style: _hdr)),
          const Expanded(flex: 3, child: Text('LOCATION', style: _hdr)),
          const Expanded(flex: 2, child: Text('STAFF', style: _hdr)),
          const SizedBox(width: 60, child: Text('SHEETS', style: _hdr, textAlign: TextAlign.right)),
          const SizedBox(width: 60, child: Text('CUST.', style: _hdr, textAlign: TextAlign.right)),
          const SizedBox(width: 104, child: Text('PAID', style: _hdr, textAlign: TextAlign.right)),
          if (showReceipts)
            const SizedBox(
              width: 132,
              child: Padding(
                padding: EdgeInsets.only(left: 20),
                child: Text('RECEIPTS', style: _hdr),
              ),
            ),
          const SizedBox(width: 108, child: Text('STATUS', style: _hdr)),
          const SizedBox(width: 88),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final EntrySummary entry;
  final String staff;
  final Color color;
  final _ReceiptCounts? receipts;
  final bool selected;
  final bool busy;
  final bool flash;
  final bool compact;
  final bool showReceipts;
  /// True while any sheet is selected: phone cards show their checkbox and
  /// a tap toggles selection instead of opening the sheet.
  final bool selectionMode;
  final ValueChanged<bool> onSelect;
  final VoidCallback onOpen;
  final VoidCallback onApprove;
  final VoidCallback onDelete;

  const _SheetRow({
    required this.entry,
    required this.staff,
    required this.color,
    required this.receipts,
    required this.selected,
    required this.busy,
    required this.flash,
    required this.compact,
    required this.showReceipts,
    this.selectionMode = false,
    required this.onSelect,
    required this.onOpen,
    required this.onApprove,
    required this.onDelete,
  });

  MaterialTotals get _materials => MaterialTotals()..add(entry);

  void _showActions(BuildContext context, String money, String date) {
    Widget action({
      required IconData icon,
      required String title,
      String? subtitle,
      required Color fg,
      required Color bg,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              Navigator.of(context).pop();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: fg, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle,
                            style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                          ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: fg.withValues(alpha: 0.6)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.85,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Summary
                  Row(
                    children: [
                      LocationDot(color, size: 12),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$date · ${entry.locationLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy,
                          ),
                        ),
                      ),
                      entry.approved ? StatusPill.approved() : StatusPill.pending(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 20),
                    child: Text(
                      '$staff · ${entry.sheetCount} sheet${entry.sheetCount == 1 ? '' : 's'} · ${entry.customers} customers',
                      style: const TextStyle(fontSize: 13, color: AppColors.slate),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.mist,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Total paid',
                              style: TextStyle(fontSize: 13, color: AppColors.slate),
                            ),
                            const Spacer(),
                            Text(
                              money,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: AppColors.navy,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        MaterialShareBar(totals: _materials, height: 4),
                        const SizedBox(height: 8),
                        MaterialStrip(totals: _materials),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  action(
                    icon: Icons.open_in_new_rounded,
                    title: 'Open sheet',
                    subtitle: 'View the full log sheet and signatures',
                    fg: AppColors.blueText,
                    bg: AppColors.blueTint,
                    onTap: onOpen,
                  ),
                  if (!entry.approved)
                    action(
                      icon: Icons.check_circle_outline_rounded,
                      title: 'Approve',
                      subtitle: 'Mark this sheet as checked',
                      fg: AppColors.greenText,
                      bg: AppColors.greenTint,
                      onTap: onApprove,
                    ),
                  action(
                    icon: selected ? Icons.check_box_outline_blank_rounded : Icons.checklist_rounded,
                    title: selected ? 'Unselect' : 'Select',
                    subtitle: selected ? null : 'Pick several sheets to approve or delete together',
                    fg: AppColors.navy,
                    bg: AppColors.mist,
                    onTap: () => onSelect(!selected),
                  ),
                  action(
                    icon: Icons.delete_outline_rounded,
                    title: 'Delete',
                    subtitle: 'Remove this entry and its sheets',
                    fg: AppColors.redText,
                    bg: AppColors.redTint,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(entry.paid);
    final date = DateFormat('MMM d').format(entry.sheetDate);
    final bg = flash
        ? const Color(0xFFF2FAF5)
        : selected
            ? const Color(0xFFF3F7FE)
            : Colors.white;
    final pill = entry.approved ? StatusPill.approved() : StatusPill.pending();

    final menu = IconButton(
      tooltip: 'Actions',
      icon: const Icon(Icons.more_horiz_rounded, color: AppColors.slate),
      onPressed: () => _showActions(context, money, date),
    );

    final checkbox = SizedBox(
      width: 40,
      child: busy
          ? const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Checkbox(
              value: selected,
              onChanged: (v) => onSelect(v ?? false),
              activeColor: AppColors.blue,
            ),
    );

    Widget content;
    if (compact) {
      Widget meta(IconData icon, String text) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AppColors.slate),
              const SizedBox(width: 3),
              Text(text, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
            ],
          );
      final showCheck = selectionMode || busy;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1 · [checkbox] date · location ........ total ⋯
          Row(
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                child: showCheck
                    ? SizedBox(
                        width: 30,
                        height: 30,
                        child: busy
                            ? const Padding(
                                padding: EdgeInsets.all(6),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Checkbox(
                                value: selected,
                                onChanged: (v) => onSelect(v ?? false),
                                activeColor: AppColors.blue,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (showCheck) const SizedBox(width: 4),
              LocationDot(color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$date · ${entry.locationLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.navy,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                money,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.navy,
                ),
              ),
              SizedBox(width: 34, height: 32, child: menu),
            ],
          ),
          const SizedBox(height: 4),
          // 2 · details ........ status
          Padding(
            padding: EdgeInsets.only(left: showCheck ? 50 : 16, right: 34),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: [
                      meta(Icons.person_outline_rounded, staff),
                      meta(Icons.description_outlined, '${entry.sheetCount}'),
                      meta(Icons.groups_outlined, '${entry.customers}'),
                      if (receipts != null) ...[
                        meta(Icons.sms_outlined, '${receipts!.sms}'),
                        meta(Icons.print_outlined, '${receipts!.printed}'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                pill,
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 3 · share of paid + one-line material strip
          MaterialShareBar(totals: _materials, height: 4),
          const SizedBox(height: 8),
          MaterialStrip(totals: _materials),
        ],
      );
    } else {
      content = Row(
        children: [
          checkbox,
          SizedBox(
            width: 92,
            child: Text(
              date,
              style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    LocationDot(color),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        entry.locationLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.navy, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 18, top: 6),
                  child: MaterialChips(totals: _materials, showPaid: true, dense: true),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              staff,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.navy),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text('${entry.sheetCount}', textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 60,
            child: Text('${entry.customers}', textAlign: TextAlign.right),
          ),
          SizedBox(
            width: 104,
            child: Text(
              money,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
            ),
          ),
          if (showReceipts)
            SizedBox(
              width: 132,
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: receipts == null
                    ? const Text('—', style: TextStyle(color: AppColors.slate))
                    : Wrap(
                        spacing: 6,
                        children: [
                          _MiniCount(
                            label: 'SMS ${receipts!.sms}',
                            bg: AppColors.amberTint,
                            fg: AppColors.amberText,
                          ),
                          _MiniCount(
                            label: 'Print ${receipts!.printed}',
                            bg: AppColors.mist,
                            fg: AppColors.navy,
                          ),
                        ],
                      ),
              ),
            ),
          SizedBox(width: 108, child: Align(alignment: Alignment.centerLeft, child: pill)),
          SizedBox(
            width: 88,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Tooltip(
                  message: 'Open sheet',
                  child: IconButton(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new_rounded, size: 20, color: AppColors.blue),
                  ),
                ),
                SizedBox(width: 40, child: menu),
              ],
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: compact && selectionMode ? () => onSelect(!selected) : onOpen,
          onLongPress: () {
            HapticFeedback.selectionClick();
            onSelect(!selected);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: compact
                ? const EdgeInsets.fromLTRB(12, 10, 6, 12)
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? AppColors.blue.withValues(alpha: 0.4) : Colors.transparent,
              ),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _MiniCount extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _MiniCount({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  final int count;
  final int pendingCount;
  final bool allSelected;
  final bool busy;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;
  final VoidCallback onDelete;
  final VoidCallback onApprove;
  final bool phone;

  const _SelectionBar({
    required this.count,
    required this.pendingCount,
    required this.allSelected,
    required this.busy,
    required this.onClear,
    required this.onSelectAll,
    required this.onDelete,
    required this.onApprove,
    this.phone = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.navy,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Clear selection',
            onPressed: busy ? null : onClear,
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
          Expanded(
            child: Text(
              '$count selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          if (!allSelected)
            phone
                ? IconButton(
                    tooltip: 'Select all',
                    onPressed: busy ? null : onSelectAll,
                    icon: const Icon(Icons.select_all_rounded, color: Color(0xFFD5DAE2)),
                  )
                : TextButton(
                    onPressed: busy ? null : onSelectAll,
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFD5DAE2)),
                    child: const Text('Select all'),
                  ),
          phone
              ? IconButton(
                  tooltip: 'Delete',
                  onPressed: busy ? null : onDelete,
                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFFB4A9)),
                )
              : TextButton.icon(
                  onPressed: busy ? null : onDelete,
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFFFB4A9)),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: busy || pendingCount == 0 ? null : onApprove,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.green,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.12),
              disabledForegroundColor: Colors.white54,
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.check_rounded, size: 18),
            label: Text(
              pendingCount == 0
                  ? 'Approved'
                  : phone
                      ? 'Approve $pendingCount'
                      : (pendingCount == 1 ? 'Approve 1' : 'Approve all $pendingCount'),
            ),
          ),
        ],
      ),
    );
  }
}
