part of 'view_entry_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Phone-only View Entry.
//
// • New view (default): Customers / Totals / Sheet tabs, a row details sheet
//   and a full-screen row editor.
// • Classic view: the original View Entry screen, unchanged. Admins switch it
//   from the ⋯ menu; the choice is saved on the phone (SharedPreferences).
// • iPad and the PDF are not touched by anything in this file.
// ─────────────────────────────────────────────────────────────────────────────

const String _kPhoneClassicPrefKey = 'viewEntry.phoneClassic';

bool _isPhoneLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide < 600;

/// One material block of the paper sheet.
class _Mat {
  final String name;
  final String short;
  final Color color;
  final Color tint;
  final Color text;
  final List<int> baseCols;
  final List<String> baseLabels;
  final int paidCol;

  /// $/lb used for SW → paid when the row has no rate of its own
  /// (same defaults as New Entry). 0 = paid is typed by hand.
  final double defaultRate;

  const _Mat(this.name, this.short, this.color, this.tint, this.text,
      this.baseCols, this.baseLabels, this.paidCol, this.defaultRate);

  bool get autoPaid => defaultRate > 0;
}

const List<_Mat> _kMats = [
  _Mat('Aluminum', 'Alum.', AppColors.blue, AppColors.blueTint, AppColors.blueText,
      [0, 1, 2, 3], ['SW', 'SC', 'C', 'SP'], 4, 1.80),
  _Mat('Glass', 'Glass', AppColors.green, AppColors.greenTint, AppColors.greenText,
      [5, 6, 7, 8], ['SW', 'SC', 'C', 'SP'], 9, 0.101),
  _Mat('PETE plastic', 'PETE', AppColors.amber, AppColors.amberTint, AppColors.amberText,
      [10, 11, 12, 13], ['SW', 'SC', 'C', 'SP'], 14, 1.46),
  _Mat('Other', 'Other', AppColors.purple, AppColors.purpleTint, AppColors.purpleText,
      [16, 17, 18], ['SW', 'SC', 'C'], 19, 0),
];

const int _kCodeCol = 15;
const int _kRowTotalCol = 20;
const int _kSignCol = 21;

const List<(String, String)> _kOtherCodes = [
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

String _cellAt(List<String> r, int c) => c < r.length ? r[c].trim() : '';
double _numAt(List<String> r, int c) => parseSheetCellNumericValue(_cellAt(r, c));

/// SW / SP cells may hold "a/b" split values.
bool _allowsSplit(int col) => const {0, 3, 5, 8, 10, 13, 16, 18}.contains(col);

/// Row total: column 20 (what New Entry writes and receipts use), else the
/// sum of the four paid columns.
double _rowTotalOf(List<String> r) {
  final total = _numAt(r, _kRowTotalCol);
  if (total > 0) return total;
  return _numAt(r, 4) + _numAt(r, 9) + _numAt(r, 14) + _numAt(r, 19);
}

double _matPaid(List<String> r, int i) {
  final m = _kMats[i];
  final v = _numAt(r, m.paidCol);
  if (v > 0 || i != 3) return v;
  // Older rows: "other" paid only lives in the row total.
  final known = _numAt(r, 4) + _numAt(r, 9) + _numAt(r, 14);
  return max(0.0, _numAt(r, _kRowTotalCol) - known);
}

/// Pounds = every weight basis (SC is a count, so it is left out).
double _matLb(List<String> r, int i) {
  final m = _kMats[i];
  double lb = 0;
  for (int k = 0; k < m.baseCols.length; k++) {
    if (m.baseLabels[k] == 'SC') continue;
    lb += _numAt(r, m.baseCols[k]);
  }
  return lb;
}

bool _matHasData(List<String> r, int i) {
  final m = _kMats[i];
  if (_matPaid(r, i) > 0) return true;
  for (final c in m.baseCols) {
    if (_cellAt(r, c).isNotEmpty) return true;
  }
  return i == 3 && _cellAt(r, _kCodeCol).isNotEmpty;
}

String _fmtLb(double v) {
  final s = NumberFormat('#,##0.##').format(v);
  return '$s lb';
}

final NumberFormat _money = NumberFormat.currency(symbol: '\$');
String _fmtMoney(double v) => _money.format(v);
String _fmtMoney0(double v) => NumberFormat.currency(symbol: '\$', decimalDigits: 0).format(v);

/// A row edit waiting to be saved.
class _RowEdit {
  final List<String> cells;
  final String name;
  final bool nameChanged;
  final List<SignaturePoint>? points;

  const _RowEdit({
    required this.cells,
    required this.name,
    required this.nameChanged,
    this.points,
  });
}

/// One customer line as the phone view shows it.
class _PRow {
  final int sheet;
  final int row;
  final List<String> cells;
  final String name;
  final List<SignaturePoint> points;
  final bool edited;

  _PRow({
    required this.sheet,
    required this.row,
    required this.cells,
    required this.name,
    required this.points,
    required this.edited,
  });

  String get key => '$sheet-$row';
  bool get signed => points.length > 1 || _cellAt(cells, _kSignCol).contains('Signed');
  double get total => _rowTotalOf(cells);

  bool get hasCustomer {
    if (signed || name.isNotEmpty || total > 0) return true;
    for (final m in _kMats) {
      for (final c in m.baseCols) {
        if (_cellAt(cells, c).isNotEmpty) return true;
      }
    }
    return _cellAt(cells, _kCodeCol).isNotEmpty;
  }

  String get displayName => name.isNotEmpty ? name : 'Customer';

  String get materialsLine {
    final parts = <String>[];
    for (int i = 0; i < _kMats.length; i++) {
      if (!_matHasData(cells, i)) continue;
      final lb = _matLb(cells, i);
      final label = i == 3 && _cellAt(cells, _kCodeCol).isNotEmpty
          ? 'Other ${_cellAt(cells, _kCodeCol)}'
          : _kMats[i].short;
      parts.add(lb > 0 ? '$label ${_fmtLb(lb)}' : label);
    }
    return parts.isEmpty ? 'No materials' : parts.join(' · ');
  }
}

/// (label, background, foreground) for a row's receipt.
(String, Color, Color) _receiptPill(ReceiptData? r) {
  if (r == null) return ('No receipt', AppColors.amberTint, AppColors.amberText);
  if (r.sms.requested) {
    switch (r.sms.status) {
      case 'delivered':
        return ('Texted', AppColors.greenTint, AppColors.greenText);
      case 'failed':
      case 'undelivered':
        return ('Text failed', AppColors.redTint, AppColors.redText);
      default:
        return ('Texting', AppColors.blueTint, AppColors.blueText);
    }
  }
  if (r.printed) return ('Printed', AppColors.mist, AppColors.navy);
  return ('#${r.receiptNumberLabel}', AppColors.mist, AppColors.navy);
}

// ─────────────────────────────────────────────────────────────────────────────
// ⋯ menu (both views)
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _showViewEntryMenu(
  BuildContext context,
  _ViewEntryScreenState host, {
  required bool classic,
  required bool isAdmin,
  required bool canSwitch,
  VoidCallback? onEdit,
  int? receiptsSheet,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    builder: (sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('Entry options',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy)),
              ),
              if (isAdmin)
                Material(
                  color: AppColors.mist,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: canSwitch
                        ? () {
                            Navigator.of(sheetContext).pop();
                            host._setPhoneClassic(!classic);
                          }
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.grid_on_rounded, color: AppColors.navy, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Classic view',
                                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.navy)),
                                const SizedBox(height: 2),
                                Text(
                                  canSwitch
                                      ? 'Open entries as the paper grid, like before. Remembered on this phone.'
                                      : 'Save or discard your changes first.',
                                  style: const TextStyle(fontSize: 12, color: AppColors.slate),
                                ),
                              ],
                            ),
                          ),
                          IgnorePointer(
                            child: Switch(
                              value: classic,
                              onChanged: canSwitch ? (_) {} : null,
                              activeColor: Colors.white,
                              activeTrackColor: AppColors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              if (onEdit != null)
                ListTile(
                  leading: const Icon(Icons.edit_outlined, color: AppColors.navy),
                  title: Text(classic ? 'Edit entry (classic)' : 'Edit entry',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onEdit();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined, color: AppColors.navy),
                title: const Text('Customer receipts', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: receiptsSheet == null ? null : Text('Sheet $receiptsSheet'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  if (receiptsSheet != null) {
                    host._showReceiptsForSheet(receiptsSheet);
                  } else {
                    host._showReceiptsSheet();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined, color: AppColors.navy),
                title: const Text('Download PDF', style: TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  host._generateAndSharePDF();
                },
              ),
              const SizedBox(height: 4),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: AppColors.navy,
                  side: const BorderSide(color: AppColors.field),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// New phone view
// ─────────────────────────────────────────────────────────────────────────────

class _PhoneEntryView extends StatefulWidget {
  final _ViewEntryScreenState host;
  final bool isAdmin;

  const _PhoneEntryView({required this.host, required this.isAdmin});

  @override
  State<_PhoneEntryView> createState() => _PhoneEntryViewState();
}

class _PhoneEntryViewState extends State<_PhoneEntryView> {
  int _tab = 0; // 0 customers · 1 totals · 2 sheet
  int _filter = 0; // 0 = all sheets
  int _sheet = 1;
  Map<String, ReceiptData> _receipts = {};
  bool _editing = false;
  bool _saving = false;
  final Map<String, _RowEdit> _edits = {};
  _PRow? _editorRow;

  _ViewEntryScreenState get h => widget.host;

  List<int> get _sheetNumbers => h._sheetsGridData.keys.toList()..sort();

  @override
  void initState() {
    super.initState();
    final nums = _sheetNumbers;
    if (nums.isNotEmpty) _sheet = nums.first;
    final wantedSheet = h._deepLinkHandled ? null : h.widget.initialSheet;
    h._deepLinkHandled = true;
    if (wantedSheet != null && nums.contains(wantedSheet)) {
      _sheet = wantedSheet;
      _filter = wantedSheet;
      final wantedRow = h.widget.initialRow;
      if (wantedRow != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final rows = _customers(wantedSheet);
          final i = rows.indexWhere((r) => r.row == wantedRow);
          if (i >= 0) _showRowDetails(rows, i);
        });
      }
    }
    _loadReceipts();
  }

  Future<void> _loadReceipts() async {
    try {
      final list = await ReceiptService.forEntry(h.widget.entryId);
      final map = <String, ReceiptData>{};
      for (final r in list) {
        map['${r.sheetNumber}-${r.row}'] = r; // newest wins (sorted by number)
      }
      if (mounted) setState(() => _receipts = map);
    } catch (e) {
      debugPrint('View entry (phone): receipts not loaded: $e');
    }
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  _PRow _rowAt(int sheet, int row) {
    final grid = h._sheetsGridData[sheet] ?? const <List<String>>[];
    final key = '$row-$_kSignCol';
    final edit = _edits['$sheet-$row'];
    final baseCells = row < grid.length ? grid[row] : const <String>[];
    var name = h._sheetsCustomerNames[sheet]?[key] ?? '';
    if (name.isEmpty) {
      final c21 = _cellAt(baseCells, _kSignCol);
      if (c21.isNotEmpty && c21 != 'Signed') name = c21.split('/').first.trim();
    }
    return _PRow(
      sheet: sheet,
      row: row,
      cells: edit?.cells ?? baseCells,
      name: edit?.name ?? name,
      points: edit?.points ?? h._sheetsSignaturePoints[sheet]?[key] ?? const <SignaturePoint>[],
      edited: edit != null,
    );
  }

  List<_PRow> _customers(int sheet) => [
        for (int r = 0; r < h.rowCount; r++)
          if (_rowAt(sheet, r).hasCustomer) _rowAt(sheet, r),
      ];

  List<_PRow> get _visibleRows {
    if (_filter != 0) return _customers(_filter);
    return [for (final s in _sheetNumbers) ..._customers(s)];
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _back() {
    if (_editing && _edits.isNotEmpty) {
      _discard();
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/submitted');
    }
  }

  void _openMenu() {
    _showViewEntryMenu(
      context,
      h,
      classic: false,
      isAdmin: widget.isAdmin,
      canSwitch: !_editing,
      onEdit: _editing ? null : () => setState(() => _editing = true),
      receiptsSheet: _tab == 2
          ? _sheet
          : (_filter != 0 ? _filter : (_sheetNumbers.isEmpty ? null : _sheetNumbers.first)),
    );
  }

  /// Opens the full-screen row editor in place (no extra route, so the
  /// customer signature screen can still be pushed from it).
  void _editRow(_PRow r) {
    if (_saving) return;
    setState(() {
      _editing = true;
      _editorRow = r;
    });
  }

  void _closeEditor(_RowEdit? result) {
    final r = _editorRow;
    setState(() {
      _editorRow = null;
      if (r != null && result != null) {
        final prev = _edits[r.key];
        _edits[r.key] = prev == null
            ? result
            : _RowEdit(
                cells: result.cells,
                name: result.name,
                nameChanged: prev.nameChanged || result.nameChanged,
                points: result.points ?? prev.points,
              );
      }
    });
  }

  void _addRow() {
    if (_sheetNumbers.isEmpty) return;
    final sheet = _filter != 0 ? _filter : (_tab == 2 ? _sheet : _sheetNumbers.last);
    for (int r = 0; r < h.rowCount; r++) {
      final row = _rowAt(sheet, r);
      if (!row.hasCustomer) {
        _editRow(row);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sheet $sheet is full (15 rows).')),
    );
  }

  Future<void> _discard() async {
    if (_edits.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Discard changes?'),
          content: Text('${_edits.length} edited row(s) will go back to how they were.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() {
      _edits.clear();
      _editing = false;
    });
  }

  Future<void> _save() async {
    if (_edits.isEmpty) {
      setState(() => _editing = false);
      return;
    }
    setState(() => _saving = true);
    final edits = Map<String, _RowEdit>.from(_edits);
    final ok = await h._applyPhoneEdits(edits);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _edits.clear();
        _editing = false;
      }
    });
    if (!ok) return;
    final reissue = edits.keys.where(_receipts.containsKey).toList()..sort();
    if (reissue.isEmpty) return;
    if (widget.isAdmin) {
      await _offerReissue(reissue);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Some edited rows already had receipts. Ask an admin to reissue them.'),
      ));
    }
  }

  Future<void> _offerReissue(List<String> keys) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Receipts already issued',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 4),
              const Text(
                'These rows changed after their receipt was issued. Reissue keeps the same receipt number and customer link, and replaces the PDF with the corrected one.',
                style: TextStyle(fontSize: 13, color: AppColors.slate),
              ),
              const SizedBox(height: 8),
              for (final k in keys)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Sheet ${k.split('-').first} · Row ${int.parse(k.split('-').last) + 1}'),
                  subtitle: Text('Receipt #${_receipts[k]?.receiptNumberLabel ?? ''}'),
                  trailing: FilledButton(
                    onPressed: () {
                      Navigator.of(c).pop();
                      _reissue(k, then: keys.where((x) => x != k).toList());
                    },
                    child: const Text('Reissue'),
                  ),
                ),
              TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Not now')),
            ],
          ),
        ),
      ),
    );
  }

  /// Reissues one receipt, then offers the remaining ones again.
  Future<void> _reissue(String key, {List<String> then = const []}) async {
    final existing = _receipts[key];
    if (existing == null) return;
    final sheet = int.parse(key.split('-').first);
    final row = int.parse(key.split('-').last);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await ReceiptService.reissue(existing, h._receiptDraftFor(sheet, row));
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Receipt #${updated.receiptNumberLabel} reissued')));
      if (updated.id != null) await openReceiptScreen(context, receiptId: updated.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not reissue the receipt: $e'),
        backgroundColor: AppColors.red,
      ));
    }
    if (!mounted) return;
    await _loadReceipts();
    if (mounted && then.isNotEmpty) await _offerReissue(then);
  }

  Future<void> _openReceipt(_PRow r) async {
    final existing = _receipts[r.key];
    if (existing?.id != null) {
      await openReceiptScreen(context, receiptId: existing!.id);
    } else {
      await h._openReceiptForSheetRow(r.sheet, r.row);
    }
    if (mounted) _loadReceipts();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  DateTime get _entryDate {
    final raw = h._entryData?['entryDate']?.toString();
    return (raw == null ? null : DateTime.tryParse(raw)) ?? h._createdAt ?? DateTime.now();
  }

  String get _locationLabel {
    final d = h._entryData ?? const {};
    for (final k in ['locationName', 'locationAddress', 'location']) {
      final v = d[k]?.toString() ?? '';
      if (v.isNotEmpty) return v;
    }
    return 'Unknown location';
  }

  /// Date shown on a customer row: when its receipt was issued if there is
  /// one, otherwise the log sheet's date. Only admins see the time.
  String _rowDate(_PRow r, {bool long = false}) {
    final issued = _receipts[r.key]?.createdAt?.toLocal();
    if (issued != null) {
      if (!widget.isAdmin) {
        return DateFormat(long ? 'MMM d, yyyy' : 'MMM d').format(issued);
      }
      return DateFormat(long ? 'MMM d, yyyy · h:mm a' : 'MMM d · h:mm a').format(issued);
    }
    return DateFormat('MMM d, yyyy').format(_entryDate);
  }

  String _subtitleDate() => '${DateFormat('MMM d').format(_entryDate)} · $_locationLabel';

  bool get _approved => h._entryData?['approved'] == true;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (h._entryData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('View Entry')),
        body: const Center(child: Text('This entry could not be loaded.')),
      );
    }
    final editing = _editorRow;
    if (editing != null) {
      return _PhoneRowEditorPage(
        key: ValueKey('editor-${editing.key}'),
        sheet: editing.sheet,
        row: editing.row,
        cells: editing.cells,
        name: editing.name,
        points: editing.points,
        receipt: _receipts[editing.key],
        subtitle: _subtitleDate(),
        sheetPrices: LocationPrices.fromMap(
          ((h._entryData?['sheets'] as Map?)?['${editing.sheet}'] as Map?)?['prices'],
        ),
        onDone: _closeEditor,
      );
    }
    final customers = _sheetNumbers.fold<int>(0, (a, s) => a + _customers(s).length);
    return PopScope(
      canPop: !_editing || _edits.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _discard();
      },
      child: Scaffold(
        backgroundColor: AppColors.mist,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _header(customers),
              if (_editing) _editBar(),
              _tabs(),
              Expanded(
                child: switch (_tab) {
                  0 => _customersTab(),
                  1 => _totalsTab(),
                  _ => _sheetTab(),
                },
              ),
            ],
          ),
        ),
        bottomNavigationBar: _footer(),
      ),
    );
  }

  Widget _header(int customers) {
    final n = _sheetNumbers.length;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: _back,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(color: AppColors.forest, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _subtitleDate(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.navy),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$n sheet${n == 1 ? '' : 's'} · $customers customer${customers == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.slate),
                ),
              ],
            ),
          ),
          _StatusPill(approved: _approved),
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz, color: AppColors.slate),
            onPressed: _openMenu,
          ),
        ],
      ),
    );
  }

  Widget _editBar() {
    final n = _edits.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: AppColors.amberTint,
        border: Border(bottom: BorderSide(color: AppColors.amberLine)),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_outlined, color: AppColors.amberText, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Editing',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.amberText)),
                Text(
                  n == 0 ? 'Tap a row to change it' : '$n row${n == 1 ? '' : 's'} changed · not saved yet',
                  style: const TextStyle(fontSize: 12, color: AppColors.amberText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabs() {
    const labels = ['Customers', 'Totals', 'Sheet'];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _tab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _tab == i ? AppColors.navy : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: _tab == i ? FontWeight.w600 : FontWeight.w500,
                      color: _tab == i ? Colors.white : AppColors.navy,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Customers tab ─────────────────────────────────────────────────────────

  Widget _customersTab() {
    final rows = _visibleRows;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        _summaryCard(rows),
        const SizedBox(height: 10),
        _chipsRow(
          [
            (0, 'All · ${_sheetNumbers.fold<int>(0, (a, s) => a + _customers(s).length)}'),
            for (final s in _sheetNumbers) (s, 'Sheet $s · ${_customers(s).length}'),
          ],
          _filter,
          (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('No customers on this sheet yet.', style: TextStyle(color: AppColors.slate)),
            ),
          ),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CustomerTile(
              row: r,
              showSheet: _filter == 0 && _sheetNumbers.length > 1,
              receipt: _receipts[r.key],
              date: _rowDate(r),
              editing: _editing,
              onTap: () => _editing ? _editRow(r) : _showRowDetails(rows, rows.indexOf(r)),
            ),
          ),
        if (_editing) _addRowButton(),
      ],
    );
  }

  Widget _addRowButton() {
    final sheet = _filter != 0 ? _filter : (_tab == 2 ? _sheet : (_sheetNumbers.isEmpty ? 1 : _sheetNumbers.last));
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: AppColors.slate,
          side: const BorderSide(color: AppColors.field, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _addRow,
        icon: const Icon(Icons.add),
        label: Text('Add customer row to Sheet $sheet', style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _chipsRow(List<(int, String)> items, int selected, ValueChanged<int> onPick) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (v, label) in items)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label),
                selected: v == selected,
                showCheckmark: false,
                onSelected: (_) => onPick(v),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: v == selected ? FontWeight.w600 : FontWeight.w500,
                  color: v == selected ? Colors.white : AppColors.navy,
                ),
                selectedColor: AppColors.navy,
                backgroundColor: Colors.white,
                side: BorderSide(color: v == selected ? AppColors.navy : AppColors.field),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryCard(List<_PRow> rows) {
    final lb = List<double>.filled(4, 0);
    final paid = List<double>.filled(4, 0);
    double total = 0;
    for (final r in rows) {
      for (int i = 0; i < 4; i++) {
        lb[i] += _matLb(r.cells, i);
        paid[i] += _matPaid(r.cells, i);
      }
      total += r.total;
    }
    final paidSum = paid.fold<double>(0, (a, b) => a + b);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Stack(
        children: [
          // Ruled log-sheet corner, the stripe motif from the logo.
          const Positioned(
            right: 0,
            top: 0,
            width: 150,
            height: 40,
            child: RuledLines(color: AppColors.mist, spacing: 8, thickness: 3),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  _filter == 0 ? 'Total paid · all sheets' : 'Total paid · sheet $_filter',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                ),
              ),
              Text(_fmtMoney(total),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.navy)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 4,
              child: paidSum <= 0
                  ? Container(color: AppColors.line)
                  : Row(
                      children: [
                        for (int i = 0; i < 4; i++)
                          if (paid[i] > 0)
                            Expanded(
                              flex: max(1, (paid[i] * 100).round()),
                              child: Container(color: _kMats[i].color),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (int i = 0; i < 4; i++)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('■ ${_kMats[i].short}',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kMats[i].text)),
                      Text(_fmtLb(lb[i]),
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.navy)),
                      Text(_fmtMoney0(paid[i]), style: const TextStyle(fontSize: 11.5, color: AppColors.slate)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
          ),
        ],
      ),
    );
  }

  // ── Row details sheet ─────────────────────────────────────────────────────

  Future<void> _showRowDetails(List<_PRow> rows, int start) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        int index = start;
        return StatefulBuilder(
          builder: (context, setSheet) {
            final r = rows[index];
            final receipt = _receipts[r.key];
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _RowNumber(number: r.row + 1, size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.navy)),
                              Text('Sheet ${r.sheet} · Row ${r.row + 1} · ${_rowDate(r, long: true)}',
                                  maxLines: 2,
                                  style: const TextStyle(fontSize: 12.5, color: AppColors.slate)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text('Total paid', style: TextStyle(fontSize: 11.5, color: AppColors.slate)),
                            Text(_fmtMoney(r.total),
                                style: const TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.navy)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 104,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFBFCFD),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.line),
                      ),
                      child: r.points.length > 1
                          ? CustomPaint(painter: SignaturePointsPainter(r.points), size: Size.infinite)
                          : const Center(
                              child: Text('Not signed', style: TextStyle(color: AppColors.slate)),
                            ),
                    ),
                    const SizedBox(height: 12),
                    _MaterialsTable(cells: r.cells),
                    const SizedBox(height: 12),
                    _ReceiptCard(
                      receipt: receipt,
                      total: r.total,
                      onOpen: () {
                        Navigator.of(sheetContext).pop();
                        _openReceipt(r);
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              foregroundColor: AppColors.navy,
                              side: const BorderSide(color: AppColors.field),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              _editRow(r);
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit row', style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              backgroundColor: AppColors.navy,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: index > 0 ? () => setSheet(() => index--) : null,
                          child: Text(index > 0 ? '‹ Row ${rows[index - 1].row + 1}' : ''),
                        ),
                        TextButton(
                          onPressed: index < rows.length - 1 ? () => setSheet(() => index++) : null,
                          child: Text(index < rows.length - 1 ? 'Row ${rows[index + 1].row + 1} ›' : ''),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Totals tab ────────────────────────────────────────────────────────────

  Widget _totalsTab() {
    final perSheet = <int, (List<double>, double)>{};
    // Other commodities by CODE per sheet: code -> (lb, paid). '' = no code.
    final codesPerSheet = <int, Map<String, (double, double)>>{};
    final allCodes = <String, (double, double)>{};
    void addCode(Map<String, (double, double)> m, String code, double lb, double paid) {
      final v = m[code] ?? (0.0, 0.0);
      m[code] = (v.$1 + lb, v.$2 + paid);
    }

    for (final s in _sheetNumbers) {
      final lb = List<double>.filled(4, 0);
      double paid = 0;
      final codes = <String, (double, double)>{};
      for (final r in _customers(s)) {
        for (int i = 0; i < 4; i++) {
          lb[i] += _matLb(r.cells, i);
        }
        paid += r.total;
        final oLb = _matLb(r.cells, 3), oPaid = _matPaid(r.cells, 3);
        if (oLb > 0 || oPaid > 0) {
          final code = normalizeOtherCode(_cellAt(r.cells, _kCodeCol));
          addCode(codes, code, oLb, oPaid);
          addCode(allCodes, code, oLb, oPaid);
        }
      }
      perSheet[s] = (lb, paid);
      codesPerSheet[s] = codes;
    }
    final allLb = List<double>.filled(4, 0);
    double allPaid = 0;
    for (final v in perSheet.values) {
      for (int i = 0; i < 4; i++) {
        allLb[i] += v.$1[i];
      }
      allPaid += v.$2;
    }

    // Heaviest first.
    List<MapEntry<String, (double, double)>> sorted(Map<String, (double, double)> m) =>
        m.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    String codeLine(Map<String, (double, double)> m) => sorted(m)
        .map((e) => '${otherCodeLabel(e.key)} ${NumberFormat('#,##0.##').format(e.value.$1)}')
        .join('  ·  ');

    // By basis across every material (SC is a count).
    final basis = <String, double>{'SW': 0, 'SC': 0, 'C': 0, 'SP': 0};
    for (final s in _sheetNumbers) {
      for (final r in _customers(s)) {
        for (final m in _kMats) {
          for (int k = 0; k < m.baseCols.length; k++) {
            basis[m.baseLabels[k]] = basis[m.baseLabels[k]]! + _numAt(r.cells, m.baseCols[k]);
          }
        }
      }
    }

    String lbCell(double v) => NumberFormat('#,##0.##').format(v);

    Widget line(String name, List<double> lb, double paid,
        {bool bold = false, VoidCallback? onTap, String codes = ''}) {
      final w = bold ? FontWeight.w700 : FontWeight.w500;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: bold ? AppColors.mist : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(width: 46, child: Text(name, style: TextStyle(fontSize: 13, fontWeight: w))),
                  for (int i = 0; i < 3; i++)
                    Expanded(child: Text(lbCell(lb[i]), style: TextStyle(fontSize: 12.5, fontWeight: w))),
                  SizedBox(
                    width: 76,
                    child: Text(_fmtMoney0(paid),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              if (codes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 46, top: 2),
                  child: Text(codes,
                      style: TextStyle(fontSize: 11, fontWeight: w, color: AppColors.purpleText)),
                ),
            ],
          ),
        ),
      );
    }

    final everyone = [for (final s in _sheetNumbers) ..._customers(s)];
    final otherAll = allCodes.values.fold<(double, double)>((0.0, 0.0), (a, v) => (a.$1 + v.$1, a.$2 + v.$2));

    Widget bigTile(int i) {
      final m = _kMats[i];
      return Expanded(
        child: Container(
          margin: EdgeInsets.only(left: i == 0 ? 0 : 6),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: m.tint,
            borderRadius: BorderRadius.circular(12),
            border: Border(top: BorderSide(color: m.color, width: 4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(i == 2 ? 'PETE Plastic' : m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: m.text)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(_fmtLb(allLb[i]),
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: m.text)),
              ),
              Text(_fmtMoney0(everyone.fold<double>(0, (a, r) => a + _matPaid(r.cells, i))),
                  style: TextStyle(fontSize: 11.5, color: m.text)),
            ],
          ),
        ),
      );
    }

    Widget codeTile(MapEntry<String, (double, double)> e) => Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(color: AppColors.purpleTint, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(otherCodeLabel(e.key),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.purpleText)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(otherCodeName(e.key),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5, color: AppColors.slate)),
                  ),
                ],
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(_fmtLb(e.value.$1),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
              ),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Expanded(
                    child: Text('Pounds · all sheets',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
                  ),
                  Text('lb · \$ paid', style: TextStyle(fontSize: 12, color: AppColors.slate)),
                ],
              ),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [bigTile(0), bigTile(1), bigTile(2)]),
              if (allCodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Other commodities by code',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.purpleText)),
                    ),
                    Text('${_fmtLb(otherAll.$1)} · ${_fmtMoney0(otherAll.$2)}',
                        style: const TextStyle(fontSize: 12, color: AppColors.slate)),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, c) {
                    final w = (c.maxWidth - 12) / 3;
                    return Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e in sorted(allCodes)) SizedBox(width: w, child: codeTile(e)),
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Expanded(
                    child: Text('Totals by sheet',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
                  ),
                  Text('lb · \$ paid', style: TextStyle(fontSize: 12, color: AppColors.slate)),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    const SizedBox(width: 46, child: Text('SHEET', style: _kHeadStyle)),
                    for (final m in _kMats.take(3))
                      Expanded(
                        child: Text(m.short.toUpperCase(),
                            style: _kHeadStyle.copyWith(color: m.text)),
                      ),
                    const SizedBox(width: 76, child: Text('PAID', textAlign: TextAlign.right, style: _kHeadStyle)),
                  ],
                ),
              ),
              for (final s in _sheetNumbers)
                line('$s', perSheet[s]!.$1, perSheet[s]!.$2,
                    codes: codeLine(codesPerSheet[s]!),
                    onTap: () => setState(() {
                          _sheet = s;
                          _tab = 2;
                        })),
              line('All', allLb, allPaid, bold: true, codes: codeLine(allCodes)),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text('Tap a sheet to open it in the Sheet tab',
                    style: TextStyle(fontSize: 11, color: AppColors.slate)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('By basis · all sheets',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final e in basis.entries)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: e.key == 'SW' || e.key == 'SP' ? AppColors.blueTint : AppColors.mist,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.key,
                                style: const TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.blueText)),
                            Text(e.key == 'SC' ? lbCell(e.value) : _fmtLb(e.value),
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _linkCard(
          icon: Icons.grid_on_rounded,
          iconBg: AppColors.mist,
          iconFg: AppColors.navy,
          title: 'Sheet view',
          subtitle: 'Every column of the paper sheet, row names pinned',
          trailing: Icons.chevron_right,
          onTap: () => setState(() => _tab = 2),
        ),
        const SizedBox(height: 10),
        _linkCard(
          icon: Icons.picture_as_pdf_outlined,
          iconBg: AppColors.redTint,
          iconFg: AppColors.redText,
          title: 'Download PDF',
          subtitle: 'Same landscape log sheet as before, one page per sheet',
          trailing: Icons.download_outlined,
          onTap: h._generateAndSharePDF,
        ),
      ],
    );
  }

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: child,
      );

  Widget _linkCard({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String title,
    required String subtitle,
    required IconData trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: iconFg, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.slate)),
                  ],
                ),
              ),
              Icon(trailing, color: AppColors.slate),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sheet tab ─────────────────────────────────────────────────────────────

  Widget _sheetTab() {
    final nums = _sheetNumbers;
    if (nums.isEmpty) {
      return const Center(child: Text('No sheets in this entry.'));
    }
    if (!nums.contains(_sheet)) _sheet = nums.first;
    final idx = nums.indexOf(_sheet);
    final rows = [for (int r = 0; r < h.rowCount; r++) _rowAt(_sheet, r)];
    final custCount = rows.where((r) => r.hasCustomer).length;
    final paid = rows.fold<double>(0, (a, r) => a + r.total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _SquareIconButton(
                icon: Icons.chevron_left,
                tooltip: 'Previous sheet',
                onTap: idx > 0 ? () => setState(() => _sheet = nums[idx - 1]) : null,
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final s in nums)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: _SheetNumberButton(
                            label: '$s',
                            selected: s == _sheet,
                            onTap: () => setState(() => _sheet = s),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              _SquareIconButton(
                icon: Icons.chevron_right,
                tooltip: 'Next sheet',
                onTap: idx < nums.length - 1 ? () => setState(() => _sheet = nums[idx + 1]) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Sheet $_sheet of ${nums.length} · $custCount customer${custCount == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.slate),
                ),
              ),
              Text(_fmtMoney(paid),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _PinnedSheetGrid(
              key: ValueKey('grid-$_sheet'),
              rows: rows,
              onTapRow: (r) {
                if (_editing) {
                  _editRow(r);
                } else if (r.hasCustomer) {
                  final list = rows.where((x) => x.hasCustomer).toList();
                  _showRowDetails(list, list.indexOf(r));
                }
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _editing ? 'Tap any row to edit it' : 'Swipe sideways for every column · tap a name to open that row',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: AppColors.slate),
          ),
        ],
      ),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────────

  Widget _footer() {
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    Widget body;
    if (_editing) {
      body = Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: AppColors.navy,
                side: const BorderSide(color: AppColors.field),
                shape: buttonShape,
              ),
              onPressed: _saving ? null : _discard,
              child: const Text('Discard', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: AppColors.green,
                shape: buttonShape,
              ),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check),
              label: Text(_edits.isEmpty ? 'Done' : 'Save changes (${_edits.length})',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );
    } else {
      body = Row(
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                foregroundColor: AppColors.navy,
                side: const BorderSide(color: AppColors.field),
                shape: buttonShape,
              ),
              onPressed: h._generateAndSharePDF,
              child: const Icon(Icons.download_outlined, semanticLabel: 'Download PDF'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _approved
                ? OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      foregroundColor: AppColors.greenText,
                      side: const BorderSide(color: AppColors.green),
                      shape: buttonShape,
                    ),
                    onPressed: null,
                    icon: const Icon(Icons.check_circle, color: AppColors.green),
                    label: const Text('Approved',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.greenText)),
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: AppColors.green,
                      shape: buttonShape,
                    ),
                    onPressed: h._approveEntry,
                    icon: const Icon(Icons.check),
                    label: const Text('Approve entry', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
          ),
        ],
      );
    }
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 10), child: body),
      ),
    );
  }
}

const TextStyle _kHeadStyle = TextStyle(
  fontSize: 10.5,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.4,
  color: AppColors.slate,
);

// ─────────────────────────────────────────────────────────────────────────────
// Small widgets
// ─────────────────────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final bool approved;
  const _StatusPill({required this.approved});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: approved ? AppColors.greenTint : AppColors.amberTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        approved ? 'Approved' : 'Pending',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: approved ? AppColors.greenText : AppColors.amberText,
        ),
      ),
    );
  }
}

class _RowNumber extends StatelessWidget {
  final int number;
  final double size;
  final bool highlight;
  const _RowNumber({required this.number, this.size = 30, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlight ? AppColors.amberTint : AppColors.mist,
        borderRadius: BorderRadius.circular(size * 0.27),
      ),
      child: Text(
        '$number',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: highlight ? AppColors.amberText : AppColors.slate,
        ),
      ),
    );
  }
}

class _SquareIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const _SquareIconButton({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
          foregroundColor: AppColors.navy,
          side: const BorderSide(color: AppColors.field),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Icon(icon, semanticLabel: tooltip),
      ),
    );
  }
}

class _SheetNumberButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SheetNumberButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(52, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: selected ? AppColors.navy : Colors.white,
          foregroundColor: selected ? Colors.white : AppColors.navy,
          side: BorderSide(color: selected ? AppColors.navy : AppColors.field),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onTap,
        child: Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}

class _CustomerTile extends StatelessWidget {
  final _PRow row;
  final bool showSheet;
  final ReceiptData? receipt;
  final String date;
  final bool editing;
  final VoidCallback onTap;

  const _CustomerTile({
    required this.row,
    required this.showSheet,
    required this.receipt,
    required this.date,
    required this.editing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = _receiptPill(receipt);
    final edited = row.edited;
    final sub = edited
        ? 'Edited · ${row.materialsLine}'
        : '${showSheet ? 'Sheet ${row.sheet} · ' : ''}${row.materialsLine}';
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: edited ? const BorderSide(color: AppColors.amberLine, width: 2) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _RowNumber(number: row.row + 1, highlight: edited),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.navy),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          date,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.slate),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: edited ? AppColors.amberText : AppColors.slate),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_fmtMoney(row.total),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.navy)),
                  const SizedBox(height: 3),
                  if (editing)
                    const Icon(Icons.edit_outlined, size: 16, color: AppColors.slate)
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: fg)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaterialsTable extends StatelessWidget {
  final List<String> cells;
  const _MaterialsTable({required this.cells});

  @override
  Widget build(BuildContext context) {
    String v(int c) => _cellAt(cells, c).isEmpty ? '—' : _cellAt(cells, c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              SizedBox(width: 86, child: Text('MATERIAL', style: _kHeadStyle)),
              Expanded(child: Text('SW', textAlign: TextAlign.center, style: _kHeadStyle)),
              Expanded(child: Text('SC', textAlign: TextAlign.center, style: _kHeadStyle)),
              Expanded(child: Text('C', textAlign: TextAlign.center, style: _kHeadStyle)),
              Expanded(child: Text('SP', textAlign: TextAlign.center, style: _kHeadStyle)),
              SizedBox(width: 64, child: Text('PAID', textAlign: TextAlign.right, style: _kHeadStyle)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        for (int i = 0; i < _kMats.length; i++)
          Opacity(
            opacity: _matHasData(cells, i) ? 1 : 0.5,
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
              decoration: BoxDecoration(color: _kMats[i].tint, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  SizedBox(
                    width: 86,
                    child: Text(
                      i == 3 && _cellAt(cells, _kCodeCol).isNotEmpty
                          ? 'Other ${_cellAt(cells, _kCodeCol)}'
                          : _kMats[i].name.split(' ').first,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kMats[i].text),
                    ),
                  ),
                  for (final label in const ['SW', 'SC', 'C', 'SP'])
                    Expanded(
                      child: Text(
                        _kMats[i].baseLabels.contains(label)
                            ? v(_kMats[i].baseCols[_kMats[i].baseLabels.indexOf(label)])
                            : '—',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13.5, fontWeight: label == 'SW' ? FontWeight.w600 : FontWeight.w400),
                      ),
                    ),
                  SizedBox(
                    width: 64,
                    child: Text(_fmtMoney(_matPaid(cells, i)),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text('SW by weight · SC by count · C commingled · SP scrap only',
              style: TextStyle(fontSize: 11, color: AppColors.slate)),
        ),
      ],
    );
  }
}

class _ReceiptCard extends StatelessWidget {
  final ReceiptData? receipt;
  final double total;
  final VoidCallback onOpen;
  const _ReceiptCard({required this.receipt, required this.total, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    final has = r != null;
    final (label, _, _) = _receiptPill(r);
    final canIssue = !has && total > 0;
    final bg = has ? AppColors.greenTint : AppColors.amberSoft;
    final fg = has ? AppColors.greenText : AppColors.amberText;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: has ? null : Border.all(color: AppColors.amberLine),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long_outlined, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(has ? 'Receipt #${r?.receiptNumberLabel ?? ''}' : 'No receipt yet',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
                Text(
                  has
                      ? label
                      : (total > 0 ? 'Issue one for this customer' : 'Nothing paid on this row'),
                  style: TextStyle(fontSize: 12, color: fg),
                ),
              ],
            ),
          ),
          if (has || canIssue)
            TextButton(
              onPressed: onOpen,
              child: Text(has ? 'Open' : 'Issue', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet grid with pinned header, pinned names and a pinned total row
// ─────────────────────────────────────────────────────────────────────────────

class _GridCol {
  final String label;
  final double width;
  final int group; // 0..3 material, 4 = row total, 5 = signed
  final int? col;
  final bool paid;
  const _GridCol(this.label, this.width, this.group, {this.col, this.paid = false});
}

List<_GridCol> _gridColumns() {
  final cols = <_GridCol>[];
  for (int i = 0; i < _kMats.length; i++) {
    final m = _kMats[i];
    if (i == 3) cols.add(const _GridCol('Code', 50, 3, col: _kCodeCol));
    for (int k = 0; k < m.baseCols.length; k++) {
      cols.add(_GridCol(m.baseLabels[k], 46, i, col: m.baseCols[k]));
    }
    cols.add(_GridCol('\$', 62, i, col: m.paidCol, paid: true));
  }
  cols.add(const _GridCol('Total', 70, 4, col: _kRowTotalCol, paid: true));
  cols.add(const _GridCol('Signed', 80, 5));
  return cols;
}

class _PinnedSheetGrid extends StatefulWidget {
  final List<_PRow> rows;
  final ValueChanged<_PRow> onTapRow;
  const _PinnedSheetGrid({super.key, required this.rows, required this.onTapRow});

  @override
  State<_PinnedSheetGrid> createState() => _PinnedSheetGridState();
}

class _PinnedSheetGridState extends State<_PinnedSheetGrid> {
  static const double _nameW = 116;
  static const double _rowH = 40;
  static const double _groupH = 26;
  static const double _subH = 26;
  static const double _footH = 36;

  final _hBody = ScrollController();
  final _hHead = ScrollController();
  final _hFoot = ScrollController();
  final _vBody = ScrollController();
  final _vNames = ScrollController();
  final List<_GridCol> _cols = _gridColumns();

  @override
  void initState() {
    super.initState();
    _hBody.addListener(_syncH);
    _vBody.addListener(_syncV);
  }

  void _syncH() {
    for (final c in [_hHead, _hFoot]) {
      if (c.hasClients && c.offset != _hBody.offset) c.jumpTo(_hBody.offset);
    }
  }

  void _syncV() {
    if (_vNames.hasClients && _vNames.offset != _vBody.offset) _vNames.jumpTo(_vBody.offset);
  }

  @override
  void dispose() {
    _hBody.removeListener(_syncH);
    _vBody.removeListener(_syncV);
    for (final c in [_hBody, _hHead, _hFoot, _vBody, _vNames]) {
      c.dispose();
    }
    super.dispose();
  }

  Color _groupColor(int g) => g < 4 ? _kMats[g].color : AppColors.navy;
  Color _groupTint(int g) => g < 4 ? _kMats[g].tint : AppColors.mist;
  Color _groupText(int g) => g < 4 ? _kMats[g].text : AppColors.slate;
  String _groupLabel(int g) => switch (g) {
        0 => 'ALUMINUM',
        1 => 'GLASS',
        2 => 'PETE PLASTIC',
        3 => 'OTHER',
        4 => 'ROW',
        _ => 'CUSTOMER',
      };

  bool _endsGroup(int i) => i == _cols.length - 1 || _cols[i + 1].group != _cols[i].group;

  String _value(_PRow r, _GridCol c) {
    if (c.col == null) return '';
    if (c.col == _kRowTotalCol) return r.total > 0 ? r.total.toStringAsFixed(2) : '';
    if (c.paid && c.group == 3) {
      final p = _matPaid(r.cells, 3);
      return p > 0 ? p.toStringAsFixed(2) : '';
    }
    final v = _cellAt(r.cells, c.col!);
    if (c.paid && parseSheetCellNumericValue(v) == 0) return '';
    return v;
  }

  String _footValue(_GridCol c) {
    if (c.col == null) {
      final n = widget.rows.where((r) => r.signed).length;
      return '$n / ${widget.rows.length}';
    }
    if (c.col == _kCodeCol) {
      final n = widget.rows.where((r) => _cellAt(r.cells, _kCodeCol).isNotEmpty).length;
      return n > 0 ? '$n' : '';
    }
    double sum = 0;
    for (final r in widget.rows) {
      if (c.col == _kRowTotalCol) {
        sum += r.total;
      } else if (c.paid && c.group == 3) {
        sum += _matPaid(r.cells, 3);
      } else {
        sum += _numAt(r.cells, c.col!);
      }
    }
    if (sum == 0) return '';
    return c.paid ? sum.toStringAsFixed(2) : NumberFormat('#,##0.##').format(sum);
  }

  Border _cellBorder(int i, {bool top = false}) => Border(
        right: BorderSide(color: _endsGroup(i) ? AppColors.field : AppColors.mist),
        bottom: const BorderSide(color: AppColors.mist),
        top: top ? const BorderSide(color: AppColors.field) : BorderSide.none,
      );

  @override
  Widget build(BuildContext context) {
    // Group header spans.
    final groups = <(int, double)>[];
    for (final c in _cols) {
      if (groups.isNotEmpty && groups.last.$1 == c.group) {
        groups[groups.length - 1] = (c.group, groups.last.$2 + c.width);
      } else {
        groups.add((c.group, c.width));
      }
    }

    final header = Column(
      children: [
        Row(
          children: [
            for (final (g, w) in groups)
              Container(
                width: w,
                height: _groupH,
                alignment: Alignment.center,
                color: _groupColor(g),
                child: Text(_groupLabel(g),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Colors.white)),
              ),
          ],
        ),
        Row(
          children: [
            for (int i = 0; i < _cols.length; i++)
              Container(
                width: _cols[i].width,
                height: _subH,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _groupTint(_cols[i].group),
                  border: Border(
                    right: BorderSide(color: _endsGroup(i) ? AppColors.field : Colors.transparent),
                    bottom: const BorderSide(color: AppColors.field),
                  ),
                ),
                child: Text(_cols[i].label,
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _groupText(_cols[i].group))),
              ),
          ],
        ),
      ],
    );

    final body = Column(
      children: [
        for (final r in widget.rows)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onTapRow(r),
            child: Row(
              children: [
                for (int i = 0; i < _cols.length; i++)
                  Container(
                    width: _cols[i].width,
                    height: _rowH,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: r.edited
                          ? AppColors.amberSoft
                          : (_cols[i].paid ? _groupTint(_cols[i].group) : Colors.white),
                      border: _cellBorder(i),
                    ),
                    child: _cols[i].group == 5
                        ? (r.signed
                            ? const Icon(Icons.check_circle, size: 18, color: AppColors.green,
                                semanticLabel: 'Signed')
                            : const SizedBox.shrink())
                        : Text(
                            _value(r, _cols[i]),
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: _cols[i].paid ? FontWeight.w700 : FontWeight.w500,
                              color: AppColors.navy,
                            ),
                          ),
                  ),
              ],
            ),
          ),
      ],
    );

    final foot = Row(
      children: [
        for (int i = 0; i < _cols.length; i++)
          Container(
            width: _cols[i].width,
            height: _footH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE4E9EE),
              border: Border(
                top: const BorderSide(color: AppColors.field),
                right: BorderSide(color: _endsGroup(i) ? AppColors.field : Colors.transparent),
              ),
            ),
            child: Text(_footValue(_cols[i]),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.navy)),
          ),
      ],
    );

    final names = Column(
      children: [
        for (final r in widget.rows)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onTapRow(r),
            child: Container(
              width: _nameW,
              height: _rowH,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: r.edited ? AppColors.amberSoft : Colors.white,
                border: const Border(
                  right: BorderSide(color: AppColors.field),
                  bottom: BorderSide(color: AppColors.mist),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Text('${r.row + 1}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF8D99AE))),
                  ),
                  Expanded(
                    child: Text(
                      r.hasCustomer ? r.displayName : '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: r.hasCustomer ? AppColors.navy : AppColors.field,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            // Pinned header
            Row(
              children: [
                Container(
                  width: _nameW,
                  height: _groupH + _subH,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: AppColors.navy,
                  child: const Text('#   Customer',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hHead,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: header,
                  ),
                ),
              ],
            ),
            // Body
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: _nameW,
                    child: SingleChildScrollView(
                      controller: _vNames,
                      physics: const NeverScrollableScrollPhysics(),
                      child: names,
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _vBody,
                      child: SingleChildScrollView(
                        controller: _hBody,
                        scrollDirection: Axis.horizontal,
                        child: body,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Pinned totals
            Row(
              children: [
                Container(
                  width: _nameW,
                  height: _footH,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: AppColors.navy,
                  child: const Text('Sheet total',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _hFoot,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: foot,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Row editor (new view)
// ─────────────────────────────────────────────────────────────────────────────

class _PhoneRowEditorPage extends StatefulWidget {
  final int sheet;
  final int row;
  final List<String> cells;
  final String name;
  final List<SignaturePoint> points;
  final ReceiptData? receipt;
  final String subtitle;
  final ValueChanged<_RowEdit?> onDone;

  /// Prices saved with the sheet when it was submitted (null on older
  /// sheets). Used for SW → paid when the row has no rate of its own, so
  /// editing an old sheet never picks up today's prices.
  final LocationPrices? sheetPrices;

  const _PhoneRowEditorPage({
    super.key,
    required this.onDone,
    this.sheetPrices,
    required this.sheet,
    required this.row,
    required this.cells,
    required this.name,
    required this.points,
    required this.receipt,
    required this.subtitle,
  });

  @override
  State<_PhoneRowEditorPage> createState() => _PhoneRowEditorPageState();
}

class _PhoneRowEditorPageState extends State<_PhoneRowEditorPage> {
  late List<String> _cells;
  late final TextEditingController _name;
  final FocusNode _nameFocus = FocusNode();
  late final List<double> _rates;
  final Set<int> _manualPaid = {};
  List<SignaturePoint>? _newPoints;
  int _open = 0;
  int? _active;

  /// Keypad order for Prev / Next (code is picked from a list instead).
  static const List<int> _order = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19];

  @override
  void initState() {
    super.initState();
    _cells = List<String>.from(widget.cells);
    while (_cells.length < 22) {
      _cells.add('');
    }
    // Older rows keep the "other" amount only inside the row total; move it
    // into column 19 so recalculating the total does not lose it.
    if (_cellAt(_cells, 19).isEmpty) {
      final hidden = _matPaid(_cells, 3);
      if (hidden > 0) _cells[19] = hidden.toStringAsFixed(2);
    }
    _name = TextEditingController(text: widget.name);
    _rates = [
      for (final m in _kMats) _rateFor(m),
    ];
    for (int i = 0; i < _kMats.length; i++) {
      if (_matHasData(_cells, i)) {
        _open = i;
        break;
      }
    }
    _active = _kMats[_open].baseCols.first;
    _nameFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  double _rateFor(_Mat m) {
    if (!m.autoPaid) return 0.0;
    final sw = _numAt(_cells, m.baseCols.first);
    final paid = _numAt(_cells, m.paidCol);
    if (sw > 0 && paid > 0) return paid / sw;
    final saved = widget.sheetPrices;
    final i = _kMats.indexOf(m);
    if (saved != null && i >= 0 && i < LocationPrices.mainKeys.length) {
      return saved[LocationPrices.mainKeys[i]];
    }
    return m.defaultRate;
  }

  bool get _changed {
    final orig = List<String>.from(widget.cells);
    while (orig.length < 22) {
      orig.add('');
    }
    for (int c = 0; c < 22; c++) {
      if (c == _kSignCol) continue;
      if (orig[c].trim() != _cells[c].trim()) return true;
    }
    return _name.text.trim() != widget.name.trim() || _newPoints != null;
  }

  int _matOf(int col) {
    if (col == _kCodeCol) return 3;
    for (int i = 0; i < _kMats.length; i++) {
      if (_kMats[i].baseCols.contains(col) || _kMats[i].paidCol == col) return i;
    }
    return 0;
  }

  void _activate(int col) {
    _nameFocus.unfocus();
    setState(() {
      _active = col;
      _open = _matOf(col);
    });
  }

  void _recalc(int col) {
    final i = _matOf(col);
    final m = _kMats[i];
    if (m.autoPaid && col == m.baseCols.first && !_manualPaid.contains(m.paidCol)) {
      final sw = parseSheetCellNumericValue(_cells[col]);
      _cells[m.paidCol] = sw > 0 ? (sw * _rates[i]).toStringAsFixed(2) : '';
    }
    final total = _numAt(_cells, 4) + _numAt(_cells, 9) + _numAt(_cells, 14) + _numAt(_cells, 19);
    _cells[_kRowTotalCol] = total > 0 ? total.toStringAsFixed(2) : '';
  }

  void _key(String k) {
    final col = _active;
    if (col == null) return;
    HapticFeedback.selectionClick();
    if (k == 'Prev' || k == 'Next') {
      final i = _order.indexOf(col);
      final next = k == 'Next' ? i + 1 : i - 1;
      if (next >= 0 && next < _order.length) _activate(_order[next]);
      return;
    }
    var v = _cells[col];
    switch (k) {
      case '⌫':
        if (v.isNotEmpty) v = v.substring(0, v.length - 1);
      case 'Clear':
        v = '';
      case 'a/b':
        if (!_allowsSplit(col) || v.isEmpty || v.contains('/')) return;
        v = '$v/';
      case '.':
        final seg = v.split('/').last;
        if (seg.contains('.')) return;
        v = '$v${seg.isEmpty ? '0' : ''}.';
      default:
        if (v.split('/').last.length >= 8) return;
        v = '$v$k';
    }
    setState(() {
      _cells[col] = v;
      if (col == _kMats[_matOf(col)].paidCol) _manualPaid.add(col);
      _recalc(col);
    });
  }

  Future<void> _pickCode() async {
    _nameFocus.unfocus();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Other commodity code', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              for (final (code, label) in _kOtherCodes)
                ListTile(
                  title: Text(code, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(label),
                  trailing: _cells[_kCodeCol] == code ? const Icon(Icons.check, color: AppColors.green) : null,
                  onTap: () => Navigator.pop(c, code),
                ),
              ListTile(
                title: const Text('No code'),
                onTap: () => Navigator.pop(c, ''),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _cells[_kCodeCol] = picked;
        _open = 3;
      });
    }
  }

  Future<void> _resign() async {
    _nameFocus.unfocus();
    await context.push(
      '/customer',
      extra: <String, dynamic>{
        'existingName': _name.text.trim(),
        'onSignatureComplete': (Uint8List bytes, String customerName) {},
        'onSignaturePointsComplete': (List<Point> pts, String customerName) {
          if (!mounted) return;
          setState(() {
            _newPoints = pts.map((p) => SignaturePoint(p.offset.dx, p.offset.dy, p.type.index)).toList();
            if (customerName.trim().isNotEmpty) _name.text = customerName.trim();
          });
        },
      },
    );
  }

  Future<void> _cancel() async {
    if (!_changed) {
      widget.onDone(null);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes to this row?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (discard == true && mounted) widget.onDone(null);
  }

  void _save() {
    if (!_changed) {
      widget.onDone(null);
      return;
    }
    final name = _name.text.trim();
    widget.onDone(_RowEdit(
      cells: List<String>.from(_cells),
      name: name,
      nameChanged: name != widget.name.trim(),
      points: _newPoints,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final showPad = _active != null && !_nameFocus.hasFocus;
    final points = _newPoints ?? widget.points;
    final total = _rowTotalOf(_cells);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: AppColors.mist,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          automaticallyImplyLeading: false,
          leadingWidth: 88,
          leading: TextButton(
            onPressed: _cancel,
            child: const Text('Cancel', style: TextStyle(fontSize: 15, color: AppColors.slate)),
          ),
          centerTitle: true,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Edit row ${widget.row + 1}',
                  maxLines: 1,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy)),
              Text('Sheet ${widget.sheet} · ${widget.subtitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.slate)),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _save,
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                children: [
                  if (widget.receipt != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.amberSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.amberLine),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Receipt #${widget.receipt!.receiptNumberLabel} was already issued for this row. '
                              'It will not change by itself: after saving you can reissue it.',
                              style: const TextStyle(fontSize: 12, height: 1.4, color: AppColors.amberText),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _name,
                            focusNode: _nameFocus,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            decoration: const InputDecoration(
                              labelText: 'Customer',
                              border: InputBorder.none,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        if (points.length > 1)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.greenTint,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(_newPoints != null ? 'New signature' : 'Signed',
                                style: const TextStyle(
                                    fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.greenText)),
                          ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.navy,
                            side: const BorderSide(color: AppColors.field),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _resign,
                          child: Text(points.length > 1 ? 'Re-sign' : 'Sign'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < _kMats.length; i++) ...[
                    i == _open ? _openCard(i) : _closedCard(i),
                    const SizedBox(height: 8),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Row total', style: TextStyle(fontSize: 12.5, color: AppColors.slate)),
                        ),
                        Text(_fmtMoney(total),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.navy)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (showPad) _keypad(),
          ],
        ),
      ),
    );
  }

  Widget _valueBox(String label, int col, Color color, Color tint, Color text, {VoidCallback? onTap}) {
    final active = _active == col && !_nameFocus.hasFocus;
    final v = _cells[col].trim();
    return GestureDetector(
      onTap: onTap ?? () => _activate(col),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: active ? tint : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : AppColors.field, width: active ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: active ? text : AppColors.slate)),
            Text(
              v.isEmpty ? '—' : v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: v.isEmpty ? FontWeight.w400 : FontWeight.w700,
                color: v.isEmpty ? const Color(0xFF8D99AE) : AppColors.navy,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _openCard(int i) {
    final m = _kMats[i];
    final auto = m.autoPaid && !_manualPaid.contains(m.paidCol);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: m.color, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: m.text)),
              ),
              if (m.autoPaid)
                Text('× \$${_rates[i].toStringAsFixed(_rates[i] < 1 ? 3 : 2)}/lb',
                    style: const TextStyle(fontSize: 12, color: AppColors.slate)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (i == 3) ...[
                Expanded(
                  child: _valueBox('Code', _kCodeCol, m.color, m.tint, m.text, onTap: _pickCode),
                ),
                const SizedBox(width: 6),
              ],
              for (int k = 0; k < m.baseCols.length; k++) ...[
                if (k > 0) const SizedBox(width: 6),
                Expanded(child: _valueBox(m.baseLabels[k], m.baseCols[k], m.color, m.tint, m.text)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  auto ? 'Paid (from SW × rate) · tap to type it' : 'Paid',
                  style: const TextStyle(fontSize: 12, color: AppColors.slate),
                ),
              ),
              SizedBox(width: 120, child: _valueBox('\$ paid', m.paidCol, m.color, m.tint, m.text)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _closedCard(int i) {
    final m = _kMats[i];
    final parts = <String>[
      if (i == 3 && _cellAt(_cells, _kCodeCol).isNotEmpty) 'Code ${_cellAt(_cells, _kCodeCol)}',
      for (int k = 0; k < m.baseCols.length; k++)
        if (_cellAt(_cells, m.baseCols[k]).isNotEmpty) '${m.baseLabels[k]} ${_cellAt(_cells, m.baseCols[k])}',
    ];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _activate(m.baseCols.first),
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 74,
                  child: Text(m.short, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: m.text)),
                ),
                Expanded(
                  child: Text(parts.isEmpty ? 'empty' : parts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.slate)),
                ),
                Text(_fmtMoney(_matPaid(_cells, i)),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.navy)),
                const Icon(Icons.expand_more, color: AppColors.slate),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _keypad() {
    const keys = ['1', '2', '3', '⌫', '4', '5', '6', 'a/b', '7', '8', '9', 'Clear', '.', '0', 'Prev', 'Next'];
    return Container(
      color: AppColors.line,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 2.0,
            children: [
              for (final k in keys)
                Material(
                  color: k == 'Next'
                      ? AppColors.blue
                      : (k.length > 1 || k == '⌫' ? AppColors.field : Colors.white),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: (k == 'a/b' && !(_active != null && _allowsSplit(_active!))) ? null : () => _key(k),
                    child: Center(
                      child: k == '⌫'
                          ? const Icon(Icons.backspace_outlined, size: 20, color: AppColors.navy, semanticLabel: 'Delete')
                          : Text(
                              k == 'Next' ? 'Next ›' : k,
                              style: TextStyle(
                                fontSize: k.length > 1 ? 14 : 20,
                                fontWeight: FontWeight.w600,
                                color: k == 'Next'
                                    ? Colors.white
                                    : (k == 'a/b' && !(_active != null && _allowsSplit(_active!))
                                        ? const Color(0xFF8D99AE)
                                        : AppColors.navy),
                              ),
                            ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
