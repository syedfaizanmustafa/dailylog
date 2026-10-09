import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../models/receipt.dart';
import '../services/receipt_service.dart';
import '../widgets/admin_shell.dart';

/// Admin › Receipts: every issued customer receipt (all time by default,
/// newest first, 100 at a time) with its text-message status, filtered by
/// status and location. Tap a row to open it; each row can also open its log
/// sheet or be downloaded as a PDF.
class AdminReceiptsScreen extends ConsumerStatefulWidget {
  /// 'all' | 'texted' | 'failed' | 'not_texted' | 'printed'
  final String initialFilter;
  const AdminReceiptsScreen({super.key, this.initialFilter = 'all'});

  @override
  ConsumerState<AdminReceiptsScreen> createState() => _AdminReceiptsScreenState();
}

class _AdminReceiptsScreenState extends ConsumerState<AdminReceiptsScreen> {
  final _searchController = TextEditingController();
  String _search = '';
  late String _filter = widget.initialFilter;
  /// Selected locations; empty = all locations.
  Set<String> _locationIds = {};

  /// 0 = all time.
  int _days = 0;

  static const int _pageSize = 100;
  List<ReceiptData> _rows = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  String? _error;

  /// Bumped on every fresh load so a slow "load more" from an older query
  /// cannot mix its rows into the new list.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AdminReceiptsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilter != widget.initialFilter) {
      setState(() => _filter = widget.initialFilter);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    setState(() {
      _loadingMore = false;
      _loading = true;
      _error = null;
    });
    try {
      final col = FirebaseFirestore.instance.collection('receipts');
      QuerySnapshot<Map<String, dynamic>> snap;
      var paged = false;
      if (_days == 0 && _locationIds.isNotEmpty) {
        // Chosen locations, all time: whereIn in chunks of 30 (no composite
        // index needed); merged and sorted below.
        final ids = _locationIds.toList();
        final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        for (var i = 0; i < ids.length; i += 30) {
          final part = await col
              .where('locationId', whereIn: ids.sublist(i, min(i + 30, ids.length)))
              .get();
          docs.addAll(part.docs);
        }
        final rows = docs.map(ReceiptData.fromFirestore).toList()..sort(_newestFirst);
        if (!mounted || gen != _loadGen) return;
        setState(() {
          _rows = rows;
          _lastDoc = null;
          _hasMore = false;
          _loading = false;
        });
        return;
      } else if (_days == 0) {
        snap = await col.orderBy('receiptNumber', descending: true).limit(_pageSize).get();
        paged = true;
      } else {
        final fmt = DateFormat('yyyy-MM-dd');
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final start = today.subtract(Duration(days: _days - 1));
        snap = await col
            .where('entryDateKey', isGreaterThanOrEqualTo: fmt.format(start))
            .where('entryDateKey', isLessThanOrEqualTo: fmt.format(today))
            .get();
      }
      final rows = snap.docs.map(ReceiptData.fromFirestore).toList()..sort(_newestFirst);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _rows = rows;
        _lastDoc = snap.docs.isEmpty ? null : snap.docs.last;
        _hasMore = paged && snap.docs.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  static int _newestFirst(ReceiptData a, ReceiptData b) {
    final an = a.receiptNumber ?? 0, bn = b.receiptNumber ?? 0;
    if (an != bn) return bn.compareTo(an);
    return (b.createdAt ?? b.date).compareTo(a.createdAt ?? a.date);
  }

  Future<void> _loadMore() async {
    final last = _lastDoc;
    if (last == null || _loadingMore) return;
    final gen = _loadGen;
    setState(() => _loadingMore = true);
    try {
      final snap = await FirebaseFirestore.instance
          .collection('receipts')
          .orderBy('receiptNumber', descending: true)
          .startAfterDocument(last)
          .limit(_pageSize)
          .get();
      if (!mounted || gen != _loadGen) return;
      setState(() {
        final seen = _rows.map((r) => r.id).toSet();
        _rows = [
          ..._rows,
          ...snap.docs.map(ReceiptData.fromFirestore).where((r) => !seen.contains(r.id)),
        ]..sort(_newestFirst);
        if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
        _hasMore = snap.docs.length == _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _loadingMore = false);
      showAppSnack(context, friendlyError(e), error: true);
    }
  }

  // ── Row actions ─────────────────────────────────────────────────────────

  Future<void> _open(ReceiptData r) async {
    await context.push('/receipt', extra: {'receiptId': r.id});
    _load();
  }

  void _viewSheet(ReceiptData r) {
    final entryId = r.entryId;
    if (entryId == null || entryId.isEmpty) {
      showAppSnack(context, 'This receipt is not linked to a submitted log sheet.', error: true);
      return;
    }
    context.push('/view-entry/$entryId?sheet=${r.sheetNumber}&row=${r.row}');
  }

  Future<void> _download(ReceiptData r) async {
    showAppSnack(context, 'Preparing receipt #${r.receiptNumberLabel}…');
    try {
      final bytes = await ReceiptService.render(r);
      await Printing.sharePdf(bytes: bytes, filename: 'Receipt_${r.receiptNumberLabel}.pdf');
    } catch (e) {
      if (mounted) showAppSnack(context, 'Could not make the PDF: ${friendlyError(e)}', error: true);
    }
  }

  void _showActions(ReceiptData r) {
    final linked = (r.entryId ?? '').isNotEmpty;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Receipt #${r.receiptNumberLabel} · ${r.customerName.isEmpty ? 'Customer' : r.customerName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_rounded, color: AppColors.navy),
              title: const Text('Open receipt', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Print, text again or copy the link'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _open(r);
              },
            ),
            ListTile(
              enabled: linked,
              leading: const Icon(Icons.grid_on_rounded, color: AppColors.navy),
              title: const Text('View log sheet', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(linked
                  ? 'Sheet ${r.sheetNumber} · row ${r.row + 1}'
                  : 'Not linked to a submitted log sheet'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _viewSheet(r);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded, color: AppColors.navy),
              title: const Text('Download PDF', style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _download(r);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static bool _failed(ReceiptData r) =>
      r.sms.requested && (r.sms.status == 'failed' || r.sms.status == 'undelivered');

  void _applyLocations(Set<String> ids) {
    if (ids.length == _locationIds.length && ids.containsAll(_locationIds)) return;
    setState(() => _locationIds = ids);
    // All time is loaded per location from the server; date ranges filter here.
    if (_days == 0) _load();
  }

  Future<void> _openLocationSheet(List<AppLocation> locations, Map<String, Color> colors) async {
    final result = await showLocationMultiPickerSheet(
      context: context,
      locations: locations,
      colors: colors,
      selected: _locationIds,
      subtitle: 'Show receipts from all locations, one, or several.',
    );
    if (result != null && mounted) _applyLocations(result);
  }

  bool _matches(ReceiptData r, String filter) {
    if (_locationIds.isNotEmpty && !_locationIds.contains(r.locationId)) return false;
    if (_search.isNotEmpty) {
      final code = r.receiptCode ?? '';
      final hay = '${r.receiptNumber ?? ''} $code ${code.replaceAll('-', '')} ${r.customerName} ${r.customerId} ${r.sms.to}'
          .toLowerCase();
      if (!hay.contains(_search)) return false;
    }
    switch (filter) {
      case 'texted':
        return r.sms.requested;
      case 'failed':
        return _failed(r);
      case 'not_texted':
        return !r.sms.requested;
      case 'printed':
        return r.printed;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(locationColorsProvider);
    final locations = ref.watch(adminLocationsProvider).valueOrNull ?? const <AppLocation>[];
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final phone = width < kAdminPhoneWidth;
    final hPad = narrow ? 16.0 : 28.0;

    final visible = _rows.where((r) => _matches(r, _filter)).toList();
    int count(String f) => _rows.where((r) => _matches(r, f)).length;
    final total = visible.fold<double>(0, (s, r) => s + r.grandTotal);

    return AdminShell(
      section: AdminSection.receipts,
      title: 'Receipts',
      subtitle: _loading
          ? null
          : '${visible.length}${_hasMore ? '+' : ''} receipt${visible.length == 1 ? '' : 's'} · '
              '${NumberFormat.currency(symbol: '\$').format(total)}',
      actions: [
        AdminSearchField(
          controller: _searchController,
          hint: 'Customer, phone or receipt #',
          width: phone ? 240 : (narrow ? 220 : 280),
          onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
        ),
        SegmentedPills<int>(
          options: const [(0, 'All'), (1, 'Today'), (7, '7 days'), (30, '30 days')],
          value: _days,
          onChanged: (d) {
            setState(() => _days = d);
            _load();
          },
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, color: AppColors.navy),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(builder: (context) {
            final chosen = locations.where((l) => _locationIds.contains(l.id)).toList();
            final chips = <Widget>[
                // Location filter first: opens the multi-select sheet.
                LocationFilterChip(
                  label: chosen.isEmpty
                      ? 'All locations'
                      : (chosen.length == 1 ? chosen.first.name : '${chosen.length} locations'),
                  dots: [for (final l in chosen.take(3)) colorForLocation(colors, l.id)],
                  active: chosen.isNotEmpty,
                  onTap: () => _openLocationSheet(locations, colors),
                ),
                const SizedBox(width: 4, height: 24, child: VerticalDivider(color: AppColors.field)),
                for (final (key, label, dot) in const [
                  ('all', 'All', null),
                  ('texted', 'Texted', AppColors.blue),
                  ('failed', 'Failed', AppColors.red),
                  ('not_texted', 'Not texted', AppColors.slate),
                  ('printed', 'Printed', AppColors.navy),
                ])
                  _FilterChip(
                    label: label,
                    count: _loading ? null : count(key),
                    dot: dot,
                    selected: _filter == key,
                    onTap: () => setState(() => _filter = key),
                  ),
            ];
            if (phone) {
              return SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 10),
                  itemCount: chips.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Center(child: chips[i]),
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 12),
              child: Wrap(spacing: 8, runSpacing: 8, children: chips),
            );
          }),
          Expanded(child: _buildList(visible, colors, locations, narrow, hPad)),
        ],
      ),
    );
  }

  Widget _buildList(
    List<ReceiptData> visible,
    Map<String, Color> colors,
    List<AppLocation> locations,
    bool narrow,
    double hPad,
  ) {
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.red),
            const SizedBox(height: 8),
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.receipt_long_rounded, size: 48, color: AppColors.field),
          const SizedBox(height: 10),
          Center(
            child: Text(
              _filter == 'failed'
                  ? 'No failed texts${_days == 0 ? '' : ' in this period'}'
                  : (_days == 0 ? 'No receipts yet' : 'No receipts in this period'),
              style: const TextStyle(fontSize: 15, color: AppColors.slate),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
        itemCount: visible.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == visible.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _loadingMore ? null : _loadMore,
                  icon: _loadingMore
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.expand_more_rounded),
                  label: Text(_loadingMore ? 'Loading…' : 'Load $_pageSize more'),
                ),
              ),
            );
          }
          final r = visible[i];
          final locName = locations.where((l) => l.id == r.locationId).firstOrNull?.name ??
              (r.recyclerName.isNotEmpty ? r.recyclerName : '—');
          final row = _ReceiptRow(
            receipt: r,
            locationName: locName,
            color: colorForLocation(colors, r.locationId),
            compact: narrow,
            onTap: () => _open(r),
            onViewSheet: (r.entryId ?? '').isEmpty ? null : () => _viewSheet(r),
            onDownload: () => _download(r),
            onMore: () => _showActions(r),
          );
          return i < 12
              ? Entrance(delay: Duration(milliseconds: 25 * i), dy: 8, child: row)
              : row;
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int? count;
  final Color? dot;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.count,
    required this.dot,
    required this.selected,
    required this.onTap,
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

/// Label + colours for a receipt's text-message state.
(String, Color, Color) smsStatusStyle(ReceiptDelivery sms) {
  if (!sms.requested) return ('Not texted', AppColors.mist, AppColors.slate);
  switch (sms.status) {
    case 'delivered':
      return ('Delivered', AppColors.greenTint, AppColors.greenText);
    case 'failed':
    case 'undelivered':
      return ('Failed', AppColors.redTint, AppColors.redText);
    case 'sent':
      return ('Sent', AppColors.blueTint, AppColors.blueText);
    case 'queued':
    case 'accepted':
    case 'sending':
      return ('Sending', AppColors.blueTint, AppColors.blueText);
    default:
      return ('Queued', AppColors.amberTint, AppColors.amberText);
  }
}

class _ReceiptRow extends StatelessWidget {
  final ReceiptData receipt;
  final String locationName;
  final Color color;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback? onViewSheet;
  final VoidCallback onDownload;
  final VoidCallback onMore;

  const _ReceiptRow({
    required this.receipt,
    required this.locationName,
    required this.color,
    required this.compact,
    required this.onTap,
    required this.onViewSheet,
    required this.onDownload,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final (smsLabel, smsBg, smsFg) = smsStatusStyle(r.sms);
    final money = NumberFormat.currency(symbol: '\$').format(r.grandTotal);
    final date = DateFormat('MMM d').format(r.date);
    final time = r.createdAt == null ? '' : DateFormat('h:mm a').format(r.createdAt!);

    final number = Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.cream,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        '#${r.receiptNumberLabel}',
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppColors.forest,
          fontSize: 13,
        ),
      ),
    );

    final smsPill = StatusPill(
      label: smsLabel,
      bg: smsBg,
      fg: smsFg,
      icon: r.sms.requested ? Icons.sms_outlined : null,
    );
    final printedIcon = Tooltip(
      message: r.printed ? 'Printed' : 'Not printed',
      child: Icon(
        Icons.print_rounded,
        size: 20,
        color: r.printed ? AppColors.navy : AppColors.field,
      ),
    );

    final Widget content;
    if (compact) {
      content = Row(
        children: [
          number,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.customerName.isEmpty ? 'Customer' : r.customerName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    LocationDot(color, size: 8),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '$date · $locationName',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(money, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 4),
              smsPill,
            ],
          ),
          IconButton(
            tooltip: 'More',
            visualDensity: VisualDensity.compact,
            onPressed: onMore,
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.slate),
          ),
        ],
      );
    } else {
      content = Row(
        children: [
          number,
          const SizedBox(width: 16),
          SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(date, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy)),
                if (time.isNotEmpty)
                  Text(time, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.customerName.isEmpty ? 'Customer' : r.customerName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
                ),
                if (r.sms.to.isNotEmpty)
                  Text(
                    r.sms.to,
                    style: const TextStyle(fontSize: 12, color: AppColors.slate),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Row(
              children: [
                LocationDot(color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    locationName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.navy),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 104,
            child: Text(
              money,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
            ),
          ),
          const SizedBox(width: 24),
          SizedBox(width: 122, child: Align(alignment: Alignment.centerLeft, child: smsPill)),
          SizedBox(width: 32, child: printedIcon),
          IconButton(
            tooltip: onViewSheet == null ? 'Not linked to a log sheet' : 'View log sheet',
            onPressed: onViewSheet,
            icon: Icon(Icons.grid_on_rounded,
                color: onViewSheet == null ? AppColors.field : AppColors.navy),
          ),
          IconButton(
            tooltip: 'Download PDF',
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded, color: AppColors.navy),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PressScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: r.sms.requested &&
                      (r.sms.status == 'failed' || r.sms.status == 'undelivered')
                  ? AppColors.red.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}
