import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../controllers/auth_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:signature/signature.dart';
import '../utils/log_sheet_cell_label.dart';
import '../utils/sheet_cell_numeric.dart';
import '../widgets/dual_numeric_cell_editor.dart';
import '../widgets/floating_confirmation_sheet.dart';
import '../widgets/logout_confirmation_sheet.dart';
import '../widgets/single_numeric_cell_editor.dart';
import '../models/location_prices.dart';
import '../models/receipt.dart';
import '../widgets/location_price_editor.dart';
import '../services/receipt_service.dart';
import '../services/data_sync.dart';
import '../services/sheet_outbox.dart';
import 'receipt_screen.dart';

class _TwoDimensionalScrollBehavior extends MaterialScrollBehavior {
  const _TwoDimensionalScrollBehavior();

  @override
  Set<ui.PointerDeviceKind> get dragDevices => {
        ui.PointerDeviceKind.touch,
        ui.PointerDeviceKind.mouse,
        ui.PointerDeviceKind.trackpad,
        ui.PointerDeviceKind.stylus,
        ui.PointerDeviceKind.invertedStylus,
      };
}

class NewEntryScreen extends ConsumerStatefulWidget {
  const NewEntryScreen({super.key});

  @override
  ConsumerState<NewEntryScreen> createState() => _NewEntryScreenState();
}

class _NewEntryScreenState extends ConsumerState<NewEntryScreen>
    with WidgetsBindingObserver {
  final int rowCount = 15;
  static const double colWidth = 80;
  static const double paidColWidth = 80;
  static const double signColWidth = 300;
  int _currentSheetNumber = 1;
  final List<String> sectionHeaders = [
    'ALUMINIUM',
    'GLASS',
    '#1 PETE PLASTIC',
    'OTHER COMMODITIES',
    'CUSTOMER SIGN AND NAME OR I.D.',
  ];
  final List<int> sectionSpans = [4, 4, 4, 4, 1];
  final List<List<String>> subHeaders = [
    ['CRV WEIGHT', 'NON-CRV WEIGHT', 'TOTAL PAID', ''],
    ['CRV WEIGHT', 'NON-CRV WEIGHT', 'TOTAL PAID', ''],
    ['CRV WEIGHT', 'NON-CRV WEIGHT', 'TOTAL PAID', ''],
    ['CRV WEIGHT', 'NON-CRV WEIGHT', 'TOTAL PAID', ''],
    [''],
  ];
  final List<double> columnWidths = [
    // ALUMINIUM
    colWidth, colWidth, colWidth, colWidth, paidColWidth,
    // GLASS
    colWidth, colWidth, colWidth, colWidth, paidColWidth,
    // #1 PETE PLASTIC
    colWidth, colWidth, colWidth, colWidth, paidColWidth,
    // OTHER COMMODITIES
    colWidth, colWidth, colWidth, colWidth, paidColWidth,
    // CUSTOMER SIGN
    signColWidth,
  ];
  double get _totalGridWidth => _sheetGridWidth + receiptColWidth + 32.0; // + receipt column + padding allowance

  /// The paper sheet itself (columns + header Total Paid column).
  double get _sheetGridWidth {
    try {
      return columnWidths.fold(0.0, (sum, w) => sum + w) + colWidth;
    } catch (_) {
      return 1168.0;
    }
  }
  late List<List<String>> gridData;
  final ScrollController _horizontalController = ScrollController();

  Map<String, Uint8List> _signatureImages = {};

  // Map to store grid data for each sheet
  final Map<int, List<List<String>>> _sheetsGridData = {};

  // Map to store signatures for each sheet
  final Map<int, Map<String, Uint8List>> _sheetsSignatures = {};

  // Loading state for submission
  bool _isSubmitting = false;

  /// Set once the entry is saved in the outbox: from then on the draft must
  /// not be saved again (it would come back and be submitted twice).
  bool _submitted = false;
  // Note: refreshed in the later initState after sheet init

  // Selected date for the entry
  DateTime _selectedDate = DateTime.now();

  // Map to cache loaded signature images
  final Map<String, Uint8List> _loadedSignatures = {};

  // Map to store signature points for each sheet
  final Map<int, Map<String, List<Point>>> _sheetsSignaturePoints = {};

  // Price per pound for auto-calculating Total Paid from SW (weight). These
  // follow the location's prices (Locations › Prices) live; until they load,
  // the standard prices (or the ones saved with the draft) are used. A price
  // change only affects rows entered afterwards: amounts already on the
  // sheet are never recalculated.
  double _aluminumMultiplier = LocationPrices.standard.aluminum;
  double _glassMultiplier = LocationPrices.standard.glass;
  double _plasticMultiplier = LocationPrices.standard.pete;

  /// Other commodities by CODE (col 15). A code without a price is paid by
  /// hand, as before.
  Map<String, double> _otherPrices = const {};

  /// Prices last applied from Firestore, and for which location.
  LocationPrices? _appliedPrices;
  String? _pricesLocationId;

  /// 'location' when the location has its own prices, else 'standard'.
  String _priceSource = 'standard';

  /// Once the entry has rows, its prices are fixed: a price update by an
  /// admin only applies to entries started after it. Kept with the draft.
  bool _pricesLocked = false;

  /// Admin-selected location override. When non-null, used instead of nearestLocation for display and submission.
  AppLocation? _locationOverride;

  /// Receipts issued while this sheet was being filled: "sheet-row" -> receipt id.
  /// Linked to the entry document once the sheet is submitted.
  final Map<String, String> _receiptIdsByCell = {};

  // Helper method to compress signature data
  Map<String, String> _compressSignatures(Map<String, Uint8List>? signatures) {
    final Map<String, String> compressedSignatures = {};

    if (signatures == null || signatures.isEmpty) {
      return compressedSignatures;
    }

    signatures.forEach((key, value) {
      try {
        // Skip empty signatures
        if (value.isEmpty) return;

        // Check if signature is too large before compression
        if (value.length > 500000) {
          // 500KB limit per signature
          print(
            'Warning: Signature $key is too large (${value.length} bytes), skipping',
          );
          return;
        }

        // Convert Uint8List to base64 string for storage
        final base64String = base64Encode(value);

        // Additional size check after encoding
        if (base64String.length > 1000000) {
          // 1MB limit per field
          print('Warning: Compressed signature $key is too large, skipping');
          return;
        }

        compressedSignatures[key] = base64String;
      } catch (e) {
        print('Error compressing signature for key $key: $e');
        // If compression fails, skip this signature
      }
    });

    return compressedSignatures;
  }

  // Helper method to validate data before submission
  bool _validateData() {
    // Check if there's any data to submit
    bool hasData = false;
    _sheetsGridData.forEach((sheetNumber, gridData) {
      for (int row = 0; row < gridData.length; row++) {
        for (int col = 0; col < gridData[row].length; col++) {
          if (gridData[row][col].isNotEmpty) {
            hasData = true;
            break;
          }
        }
        if (hasData) break;
      }
    });

    if (!hasData) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter some data before submitting'),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    return true;
  }

  // Helper method to check data size
  bool _checkDataSize() {
    try {
      int totalSize = 0;
      int signatureCount = 0;

      _sheetsSignatures.forEach((sheetNumber, signatures) {
        signatures.forEach((key, value) {
          totalSize += value.length;
          signatureCount++;
        });
      });

      // If total signature size is more than 10MB, warn the user
      if (totalSize > 10 * 1024 * 1024) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Warning: Large signature data detected (${(totalSize / 1024 / 1024).toStringAsFixed(1)}MB). This may take longer to upload.',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 3),
          ),
        );
      }

      return true;
    } catch (e) {
      print('Error checking data size: $e');
      return true; // Continue anyway
    }
  }

  // Helper method to log submission progress
  void _logSubmissionProgress(String message) {
    print('Submission Progress: $message');
    // In a production app, you might want to send this to a logging service
  }

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle so we can snapshot a draft if the app is
    // backgrounded or killed mid-edit (not just on back-button exit).
    WidgetsBinding.instance.addObserver(this);
    // Initialize the first sheet, then overwrite with draft if one exists
    _initializeSheet(1);
    _loadDraftIfExists();
    // Calculate initial totals
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateAndUpdateTotals();
      // After first layout, refresh nearest location so UI picks it up
      final container = ProviderScope.containerOf(context, listen: false);
      container.read(appControllerProvider.notifier).refreshNearest();
    });
  }

  // ── Draft persistence ───────────────────────────────────────────────────

  /// Serialize the current sheet state to SharedPreferences.
  Future<void> _saveDraft() async {
    if (_submitted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final sheetsMap = <String, dynamic>{};
      _sheetsGridData.forEach((sheetNum, rows) {
        sheetsMap[sheetNum.toString()] = rows;
      });
      // Serialize signature strokes so a signed cell survives an app kill.
      // Includes pressure so the restored Point is a faithful copy.
      final signaturePointsMap = <String, dynamic>{};
      _sheetsSignaturePoints.forEach((sheetNum, cellMap) {
        if (cellMap.isEmpty) return;
        final cells = <String, dynamic>{};
        cellMap.forEach((cellKey, points) {
          cells[cellKey] = points
              .map((point) => {
                    'dx': point.offset.dx,
                    'dy': point.offset.dy,
                    'type': point.type.index,
                    'pressure': point.pressure,
                  })
              .toList();
        });
        signaturePointsMap[sheetNum.toString()] = cells;
      });
      final draft = <String, dynamic>{
        'sheetsGridData': sheetsMap,
        'signaturePoints': signaturePointsMap,
        'selectedDate': _selectedDate.toIso8601String(),
        'currentSheetNumber': _currentSheetNumber,
        'aluminumMultiplier': _aluminumMultiplier,
        'glassMultiplier': _glassMultiplier,
        'plasticMultiplier': _plasticMultiplier,
        'otherPrices': _otherPrices,
        'priceSource': _priceSource,
        'pricesLocationId': _pricesLocationId,
        'pricesLocked': _pricesLocked,
        'receiptIds': _receiptIdsByCell,
      };
      if (_locationOverride != null) {
        draft['locationOverride'] = {
          'id': _locationOverride!.id,
          'name': _locationOverride!.name,
          'address': _locationOverride!.address,
          'certification': _locationOverride!.certification,
          'latitude': _locationOverride!.latitude,
          'longitude': _locationOverride!.longitude,
        };
      }
      await prefs.setString(kDraftSheetKey, jsonEncode(draft));
      ref.invalidate(hasDraftProvider);
    } catch (e) {
      print('Error saving draft: $e');
    }
  }

  /// Load a previously saved draft from SharedPreferences, if any.
  Future<void> _loadDraftIfExists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(kDraftSheetKey);
      if (jsonStr == null) return;
      final draft = jsonDecode(jsonStr) as Map<String, dynamic>;

      final sheetsMapRaw = draft['sheetsGridData'] as Map<String, dynamic>?;
      if (sheetsMapRaw != null) {
        sheetsMapRaw.forEach((key, value) {
          final sheetNum = int.tryParse(key);
          if (sheetNum != null) {
            final rows = (value as List)
                .map((row) =>
                    (row as List).map((cell) => cell.toString()).toList())
                .toList();
            _sheetsGridData[sheetNum] = rows;
            _sheetsSignatures[sheetNum] = {};
            _sheetsSignaturePoints[sheetNum] = {};
          }
        });
      }

      // Restore signature strokes so signed cells re-render (and re-submit)
      // instead of showing "Signed" with no signature behind it.
      final receiptIdsRaw = draft['receiptIds'] as Map<String, dynamic>?;
      if (receiptIdsRaw != null) {
        receiptIdsRaw.forEach((k, v) => _receiptIdsByCell[k] = v.toString());
      }

      final signaturePointsRaw =
          draft['signaturePoints'] as Map<String, dynamic>?;
      if (signaturePointsRaw != null) {
        signaturePointsRaw.forEach((sheetKey, cellsRaw) {
          final sheetNum = int.tryParse(sheetKey);
          if (sheetNum == null || cellsRaw is! Map<String, dynamic>) return;
          final cellMap = <String, List<Point>>{};
          cellsRaw.forEach((cellKey, pointsRaw) {
            if (pointsRaw is! List) return;
            cellMap[cellKey] = pointsRaw.map<Point>((p) {
              final m = p as Map<String, dynamic>;
              final typeIndex = (m['type'] as num?)?.toInt() ?? 0;
              final safeType = (typeIndex >= 0 &&
                      typeIndex < PointType.values.length)
                  ? typeIndex
                  : 0;
              return Point(
                Offset(
                  (m['dx'] as num).toDouble(),
                  (m['dy'] as num).toDouble(),
                ),
                PointType.values[safeType],
                (m['pressure'] as num?)?.toDouble() ?? 1.0,
              );
            }).toList();
          });
          _sheetsSignaturePoints[sheetNum] = cellMap;
        });
      }

      if (draft['selectedDate'] != null) {
        _selectedDate = DateTime.parse(draft['selectedDate'] as String);
      }
      if (draft['currentSheetNumber'] != null) {
        _currentSheetNumber = draft['currentSheetNumber'] as int;
      }
      if (draft['aluminumMultiplier'] != null) {
        _aluminumMultiplier =
            (draft['aluminumMultiplier'] as num).toDouble();
      }
      if (draft['glassMultiplier'] != null) {
        _glassMultiplier = (draft['glassMultiplier'] as num).toDouble();
      }
      if (draft['plasticMultiplier'] != null) {
        _plasticMultiplier =
            (draft['plasticMultiplier'] as num).toDouble();
      }
      final draftOther = draft['otherPrices'];
      if (draftOther is Map) {
        _otherPrices = {
          for (final e in draftOther.entries)
            if (e.value is num) '${e.key}': (e.value as num).toDouble(),
        };
      }
      if (draft['locationOverride'] != null) {
        final loc = draft['locationOverride'] as Map<String, dynamic>;
        _locationOverride = AppLocation(
          id: loc['id'] as String,
          name: loc['name'] as String,
          address: loc['address'] as String,
          certification: (loc['certification'] as String?) ?? '',
          latitude: (loc['latitude'] as num).toDouble(),
          longitude: (loc['longitude'] as num).toDouble(),
        );
      }
      // A draft with rows keeps the prices it was started with (also drafts
      // saved before prices were locked). An empty draft takes the
      // location's current prices on the next build.
      if (_hasAnyData()) {
        _pricesLocked = true;
        _priceSource = draft['priceSource']?.toString() ?? _priceSource;
        _pricesLocationId = draft['pricesLocationId']?.toString();
        _appliedPrices = LocationPrices(
          aluminum: _aluminumMultiplier,
          glass: _glassMultiplier,
          pete: _plasticMultiplier,
          other: _otherPrices,
        );
      } else {
        _pricesLocked = false;
        _appliedPrices = null;
        _pricesLocationId = null;
      }

      if (mounted) {
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback(
          (_) { if (mounted) _calculateAndUpdateTotals(); },
        );
      }
    } catch (e) {
      print('Error loading draft: $e');
    }
  }

  /// Remove the saved draft from SharedPreferences.
  Future<void> _clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kDraftSheetKey);
      ref.invalidate(hasDraftProvider);
    } catch (e) {
      print('Error clearing draft: $e');
    }
  }

  /// Returns true if at least one user-entered cell is non-empty across all
  /// sheets. Col 20 is the auto-calculated row "Total Paid" — it is always
  /// written as "0.00" by [_calculateAndUpdateTotals] even on a blank sheet,
  /// so it must be excluded from this check.
  bool _hasAnyData() {
    for (final gridData in _sheetsGridData.values) {
      for (int row = 0; row < rowCount; row++) {
        if (row >= gridData.length) continue;
        for (int col = 0; col < gridData[row].length; col++) {
          if (col == 20) continue; // auto-calculated, not user data
          if (gridData[row][col].isNotEmpty) return true;
        }
      }
    }
    return false;
  }

  /// Show a confirmation sheet before leaving, save draft on confirm.
  /// If all sheets are blank, just pops without any confirmation or save.
  Future<void> _handleBackPress() async {
    if (_submitted || _isSubmitting) return; // finishing a submit
    if (!_hasAnyData()) {
      if (mounted) context.pop();
      return;
    }
    final confirmed = await showFloatingConfirmationBottomSheet(
      context: context,
      title: 'Leave entry?',
      message:
          'Your progress will be saved as a draft so you can continue later.',
      confirmLabel: 'Save & exit',
      cancelLabel: 'Keep editing',
    );
    if (!confirmed || !mounted) return;
    await _saveDraft();
    if (mounted) context.pop();
  }

  void _initializeSheet(int sheetNumber) {
    if (!_sheetsGridData.containsKey(sheetNumber)) {
      _sheetsGridData[sheetNumber] = List.generate(
        rowCount + 1, // +1 for the totals row
        (_) => List.generate(22, (_) => ''),
      );
      _sheetsSignatures[sheetNumber] = {};
      _sheetsSignaturePoints[sheetNumber] = {};
    } else {
      // Ensure the totals row exists
      if (_sheetsGridData[sheetNumber]!.length <= rowCount) {
        _sheetsGridData[sheetNumber]!.add(List.generate(22, (_) => ''));
      }
    }
  }

  List<List<String>> get _currentGridData =>
      _sheetsGridData[_currentSheetNumber]!;

  Map<String, Uint8List> get _currentSignatures =>
      _sheetsSignatures[_currentSheetNumber]!;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When the app is about to be backgrounded/suspended, the OS may kill the
    // process without ever calling dispose(). Snapshot the in-progress sheet
    // as a draft so nothing is lost. Mirrors the "Save & exit" behaviour and
    // is safely restored by _loadDraftIfExists() on the next launch.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_hasAnyData()) {
        _saveDraft();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _horizontalController.dispose();
    super.dispose();
  }

  // Helper method to check if a column is SP or SW
  bool _isSpOrSwColumn(int col) {
    // SW columns: 0, 5, 10, 16 (first column of each section)
    // SP columns: 3, 8, 13, 18 (fourth column of each section)
    // CODE column: 15 (standalone column after TP-PL)
    return col == 0 ||
        col == 3 ||
        col == 5 ||
        col == 8 ||
        col == 10 ||
        col == 13 ||
        col == 15 ||
        col == 16 ||
        col == 18;
  }

  // Helper method to parse a cell value and return its numeric value
  double _parseCellValue(String value) => parseSheetCellNumericValue(value);

  /// When an SW (weight) cell is updated, auto-fill the corresponding Total Paid
  /// for that material: Aluminum (col 0→4), Glass (col 5→9), Plastic (col 10→14),
  /// Other commodities (col 16→19) when the row's CODE has a location price.
  /// Total Paid can still be changed by hand afterwards (discounts).
  void _updatePaidFromSw(int row, int col, String swValue) {
    if (row >= _currentGridData.length) return;
    // Just switched location and its prices haven't loaded yet: don't fill
    // Paid with the previous location's prices (it can be typed by hand).
    final loc =
        _locationOverride ?? ref.read(appControllerProvider).nearestLocation;
    if (!_pricesLocked &&
        loc != null &&
        _pricesLocationId != null &&
        _pricesLocationId != loc.id) {
      return;
    }
    while (_currentGridData[row].length < 22) {
      _currentGridData[row].add('');
    }
    final double weight = _parseCellValue(swValue);
    if (col == 0) {
      _currentGridData[row][4] = (weight * _aluminumMultiplier).toStringAsFixed(2);
    } else if (col == 5) {
      _currentGridData[row][9] = (weight * _glassMultiplier).toStringAsFixed(2);
    } else if (col == 10) {
      _currentGridData[row][14] = (weight * _plasticMultiplier).toStringAsFixed(2);
    } else if (col == 16) {
      final price = _otherPrices[_currentGridData[row][15].trim().toUpperCase()];
      // No price for this code (or no code yet): stays paid by hand.
      if (price != null && swValue.trim().isNotEmpty) {
        _currentGridData[row][19] = (weight * price).toStringAsFixed(2);
      }
    }
  }

  /// Applies the location's live prices (called from build) while the entry
  /// is still empty, then locks them once it has rows: a price update only
  /// applies to entries started after it. Keeps the current prices while
  /// they load or if they can't be read.
  void _syncLocationPrices() {
    if (_pricesLocked) return;
    final loc =
        _locationOverride ?? ref.watch(appControllerProvider).nearestLocation;
    if (loc != null) {
      final async = ref.watch(locationPricesProvider(loc.id));
      if (async.hasValue) {
        final p = async.value ?? LocationPrices.standard;
        final source = async.value == null ? 'standard' : 'location';
        final same = _pricesLocationId == loc.id &&
            _appliedPrices != null &&
            _appliedPrices!.sameAs(p) &&
            _priceSource == source;
        if (!same) {
          _aluminumMultiplier = p.aluminum;
          _glassMultiplier = p.glass;
          _plasticMultiplier = p.pete;
          _otherPrices = Map<String, double>.from(p.other);
          _appliedPrices = p;
          _pricesLocationId = loc.id;
          _priceSource = source;
        }
      }
    }
    // Lock once rows exist and this location's prices are in use.
    if (_appliedPrices != null &&
        (loc == null || _pricesLocationId == loc.id) &&
        _hasAnyData()) {
      _pricesLocked = true;
    }
  }

  /// Prices are set by an admin in Locations › Prices. Tapping a section's
  /// SW header shows them; nobody edits prices on the sheet. Staff can still
  /// change a row's Total Paid (e.g. for a discount).
  Future<void> _showPricesInfo() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final loc =
        _locationOverride ?? container.read(appControllerProvider).nearestLocation;
    final isAdmin =
        container.read(currentUserRoleProvider).valueOrNull == 'admin';
    final priced = [
      for (final (code, label) in kOtherCommodityCodes)
        if (_otherPrices[code] != null) (code, label, _otherPrices[code]!),
    ];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                loc == null ? 'Prices' : 'Prices · ${loc.name}',
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.navy),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  _priceSource == 'location'
                      ? 'Set by an admin for this location.'
                      : 'Standard prices (no prices set for this location yet).',
                  if (_pricesLocked)
                    'This entry keeps the prices it started with; price updates apply to new entries.',
                ].join(' '),
                style: const TextStyle(fontSize: 13, color: AppColors.slate),
              ),
              const SizedBox(height: 12),
              for (final (label, v) in [
                ('Aluminum', _aluminumMultiplier),
                ('Glass', _glassMultiplier),
                ('PETE plastic', _plasticMultiplier),
                for (final (c, l, pv) in priced) ('$c · $l', pv),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
                      Text('${LocationPrices.fmt(v)} / lb',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              if (priced.length < kOtherCommodityCodes.length)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Other codes without a price are paid by hand.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.slate)),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.cream,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Prices can\'t be changed on the sheet. For a discount, tap the row\'s '
                  'Total Paid cell and enter the amount paid.',
                  style: TextStyle(fontSize: 13.5, height: 1.4, color: AppColors.navy),
                ),
              ),
              if (isAdmin && loc != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('Edit prices for this location'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openLocationPriceEditor(loc);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Admin shortcut to Locations › Prices for the sheet's location.
  Future<void> _openLocationPriceEditor(AppLocation loc) async {
    final container = ProviderScope.containerOf(context, listen: false);
    Map<String, (LocationPrices?, List<PriceChange>)> all;
    try {
      all = await container.read(allLocationPricesProvider.future);
    } catch (_) {
      all = const {};
    }
    if (!mounted) return;
    final locations = container.read(appControllerProvider).locations;
    await showLocationPriceEditor(
      context: context,
      location: loc,
      current: all[loc.id]?.$1,
      history: all[loc.id]?.$2 ?? const [],
      otherLocations: {
        for (final l in locations)
          if (l.id != loc.id && all[l.id]?.$1 != null) l.id: (l.name, all[l.id]!.$1!),
      },
    );
  }

  // Method to calculate totals for each column and update the last row
  void _calculateAndUpdateTotals() {
    // Ensure all existing rows have 22 columns
    for (int i = 0; i < _currentGridData.length; i++) {
      if (_currentGridData[i].length < 22) {
        // Pad with empty strings to reach 22 columns
        while (_currentGridData[i].length < 22) {
          _currentGridData[i].add('');
        }
      } else if (_currentGridData[i].length > 22) {
        // Truncate to 22 columns if somehow longer
        _currentGridData[i] = _currentGridData[i].sublist(0, 22);
      }
    }

    if (_currentGridData.length <= rowCount) {
      _currentGridData.add(List.generate(22, (_) => ''));
    }

    // Calculate totals for each column (0 to 21)
    for (int col = 0; col < 22; col++) {
      if (col == 15) {
        // CODE column - show count of entries instead of sum
        int count = 0;
        for (int row = 0; row < rowCount; row++) {
          if (row < _currentGridData.length &&
              col < _currentGridData[row].length &&
              _currentGridData[row][col].isNotEmpty) {
            count++;
          }
        }
        // Update the total row (rowCount) for CODE column
        if (col < _currentGridData[rowCount].length) {
          _currentGridData[rowCount][col] = count > 0 ? 'Count: $count' : '';
        }
      } else {
        double total = 0.0;

        // Sum all values in this column from rows 0 to rowCount-1
        for (int row = 0; row < rowCount; row++) {
          if (row < _currentGridData.length &&
              col < _currentGridData[row].length) {
            total += _parseCellValue(_currentGridData[row][col]);
          }
        }

        // Update the total row (rowCount)
        if (col < _currentGridData[rowCount].length) {
          _currentGridData[rowCount][col] = total.toStringAsFixed(2);
        }
      }
    }

    // Auto-calculate Total Paid column (column 20) for each row based on sum of columns 4, 9, 14, 19
    final totalPaidSourceColumns = [4, 9, 14, 19];
    for (int row = 0; row < rowCount; row++) {
      if (row < _currentGridData.length) {
        double rowTotal = 0.0;
        for (int col in totalPaidSourceColumns) {
          if (col < _currentGridData[row].length) {
            rowTotal += _parseCellValue(_currentGridData[row][col]);
          }
        }
        // Update column 20 (Total Paid) for this row
        if (_currentGridData[row].length > 20) {
          _currentGridData[row][20] = rowTotal.toStringAsFixed(2);
        }
      }
    }

    // Calculate grand total of the "Total Paid" column (column 20) right before signature
    // Sum all values in column 20 from rows 0 to rowCount-1
    double grandTotal = 0.0;
    for (int row = 0; row < rowCount; row++) {
      if (row < _currentGridData.length &&
          20 < _currentGridData[row].length) {
        grandTotal += _parseCellValue(_currentGridData[row][20]);
      }
    }

    // Update the last cell (column 21) with the grand total
    if (_currentGridData[rowCount].length > 21) {
      _currentGridData[rowCount][21] = grandTotal.toStringAsFixed(2);
    }

    // Trigger UI update
    setState(() {});
  }

  void _editCell(int row, int col, {bool isLongPress = false}) async {
    String value = _currentGridData[row][col];

    // Handle SP and SW columns with long press for dual input
    if (_isSpOrSwColumn(col) && isLongPress) {
      await _showDualInputBottomSheet(row, col, value);
      return;
    }

    if (col == 21) {
      // Pass any existing name + signature so the customer screen opens
      // pre-filled instead of blank when editing an already-signed cell.
      String existingName = '';
      if (value.contains('/') && value.contains('Signed')) {
        existingName = value.split('/')[0];
      }
      final existingPoints =
          _sheetsSignaturePoints[_currentSheetNumber]?['$row-$col'];
      bool signedNow = false;
      await context.push(
        '/customer',
        extra: {
          'existingName': existingName,
          'existingPoints': existingPoints,
          'onSignatureComplete': (
            Uint8List signatureBytes,
            String customerName,
          ) {
            setState(() {
              _currentSignatures['$row-$col'] = signatureBytes;
              _currentGridData[row][col] = '$customerName/Signed';
            });
            // Calculate totals after updating the cell
            _calculateAndUpdateTotals();
          },
          'onSignaturePointsComplete': (
            List<Point> signaturePoints,
            String customerName,
          ) {
            setState(() {
              _sheetsSignaturePoints[_currentSheetNumber] ??= {};
              _sheetsSignaturePoints[_currentSheetNumber]!['$row-$col'] =
                  signaturePoints;
              _currentGridData[row][col] = '$customerName/Signed';
              signedNow = true;
              print(
                'Saved ${signaturePoints.length} signature points for cell $row-$col',
              );
            });
          },
        },
      );
      // Customer just signed: hand them their receipt right away.
      if (signedNow && mounted) {
        await _openReceiptForRow(row);
      }
    } else if (col == 15) {
      // CODE column (standalone column after TP-PL)
      final String? result = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Select Commodity'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildCommodityOption(context, 'BI', 'Bimetal'),
                  _buildCommodityOption(
                    context,
                    'P#2',
                    'HDPE (High Density Polyethylene)',
                  ),
                  _buildCommodityOption(context, 'P#3', 'PVC (Vinyl)'),
                  _buildCommodityOption(
                    context,
                    'P#4',
                    'LDPE (Low Density Polyethylene)',
                  ),
                  _buildCommodityOption(context, 'P#5', 'PP (Polypropylene)'),
                  _buildCommodityOption(context, 'P#6', 'PS (Polystyrene)'),
                  _buildCommodityOption(
                    context,
                    'P#7',
                    'Other (Includes multilayer and unspecified resins)',
                  ),
                  _buildCommodityOption(context, 'WDS', 'WDS'),
                  _buildCommodityOption(context, 'MLP', 'Multi layer pouch'),
                  _buildCommodityOption(context, 'BIB', 'Bag-in-box'),
                  _buildCommodityOption(context, 'CC', 'Cardboard Carton'),
                  _buildCommodityOption(
                    context,
                    'SCRAP',
                    'Scrap (non-CRV, can be paid \$0.00)',
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (result != null) {
        setState(() {
          final cells = _currentGridData[row];
          while (cells.length < 22) {
            cells.add('');
          }
          final oldCode = cells[15].trim().toUpperCase();
          final oldPrice = _otherPrices[oldCode];
          cells[col] = result;
          // A different code re-prices the row's other-commodity SW, but
          // only if Paid is empty or still the old code's automatic amount:
          // a typed amount (discount) is never overwritten. A code without
          // a price clears the old automatic amount so it's typed by hand.
          final sw = cells[16];
          final newCode = result.trim().toUpperCase();
          if (sw.trim().isNotEmpty && newCode != oldCode) {
            final paid = cells[19].trim();
            final wasAuto = paid.isEmpty ||
                (oldPrice != null &&
                    paid == (_parseCellValue(sw) * oldPrice).toStringAsFixed(2));
            if (wasAuto) {
              if (_otherPrices[newCode] != null) {
                _updatePaidFromSw(row, 16, sw);
              } else {
                cells[19] = '';
              }
            }
          }
        });
        // Calculate totals after updating the cell
        _calculateAndUpdateTotals();
      }
    } else {
      String? result = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          final mq = MediaQuery.of(context);
          final hPad = (mq.size.width * 0.04).clamp(12.0, 22.0);
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: mq.viewInsets.bottom,
                left: hPad,
                right: hPad,
                top: 12,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SingleNumericCellEditor(
                      cellLabel: logSheetCellTitle(row, col),
                      initialValue: value,
                      showActions: true,
                      onCancel: () => Navigator.pop(context),
                      onSave: (v) => Navigator.pop(context, v),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          );
        },
      );
      if (result != null) {
        setState(() {
          _currentGridData[row][col] = result;
          if (col == 0 || col == 5 || col == 10 || col == 16) {
            _updatePaidFromSw(row, col, result);
          }
        });
        // Calculate totals after updating the cell
        _calculateAndUpdateTotals();
      }
    }
  }

  // Method to show dual input bottom sheet for SP and SW columns
  Future<void> _showDualInputBottomSheet(
    int row,
    int col,
    String currentValue,
  ) async {
    final dualKey = GlobalKey<DualNumericCellEditorState>();

    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final mq = MediaQuery.of(context);
        final hPad = (mq.size.width * 0.04).clamp(12.0, 22.0);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: mq.viewInsets.bottom,
              left: hPad,
              right: hPad,
              top: 12,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DualNumericCellEditor(
                    key: dualKey,
                    cellLabel: logSheetCellTitle(row, col),
                    initialValue: currentValue,
                    pairDelimiter: '/',
                    longPressPairMode: true,
                    secondFieldOptional: false,
                    showActions: false,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 12,
                            ),
                            textStyle: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: () => Navigator.pop(context, null),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 12,
                            ),
                            textStyle: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: () {
                            final st = dualKey.currentState;
                            if (st == null) return;
                            if (!st.validate()) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Enter the first number before the second.'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                              return;
                            }
                            final valueA = st.valueA;
                            final valueB = st.valueB;
                            if (valueA.isNotEmpty && valueB.isNotEmpty) {
                              if (double.tryParse(valueA) == null ||
                                  double.tryParse(valueB) == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Enter valid numbers.'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              Navigator.pop(context, {'a': valueA, 'b': valueB});
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Please enter both values'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                          child: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (result != null) {
      setState(() {
        _currentGridData[row][col] = '${result['a']}/${result['b']}';
        if (col == 0 || col == 5 || col == 10 || col == 16) {
          _updatePaidFromSw(row, col, '${result['a']}/${result['b']}');
        }
      });
      // Calculate totals after updating the cell
      _calculateAndUpdateTotals();
    }
  }

  Widget _buildCommodityOption(
    BuildContext context,
    String code,
    String description,
  ) {
    final price = _otherPrices[code];
    return ListTile(
      title: Text(code),
      subtitle: Text(description),
      trailing: price == null
          ? const Text('by hand', style: TextStyle(fontSize: 12.5, color: AppColors.slate))
          : Text('${LocationPrices.fmt(price)}/lb',
              style: const TextStyle(fontWeight: FontWeight.w700)),
      onTap: () => Navigator.pop(context, code),
    );
  }

  /// Show bottom sheet for admin to pick a location (address). Updates _locationOverride on selection.
  Future<void> _showLocationPickerBottomSheet() async {
    final locations = ref.read(appControllerProvider).locations;
    if (locations.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No locations available')),
        );
      }
      return;
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = await showModalBottomSheet<AppLocation>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.6,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: colorScheme.outline.withOpacity(0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outline.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Select location',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: locations.length,
                itemBuilder: (context, index) {
                  final loc = locations[index];
                  return ListTile(
                    title: Text(
                      loc.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      loc.address,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    onTap: () => Navigator.pop(ctx, loc),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _locationOverride = selected);
    }
  }

  // Method to show Cupertino date picker
  Future<void> _showDatePicker() async {
    final DateTime? picked = await showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (BuildContext context) {
        return Container(
          height: 400,
          color: Colors.white,
          child: Column(
            children: [
              Container(
                height: 60,
                color: Colors.grey[200],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      child: Text('Cancel'),
                      onPressed: () => Navigator.pop(context),
                    ),
                    CupertinoButton(
                      child: Text('Done'),
                      onPressed: () => Navigator.pop(context, _selectedDate),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: _selectedDate,
                  onDateTimeChanged: (DateTime newDate) {
                    setState(() {
                      _selectedDate = newDate;
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  // ── Customer receipts ────────────────────────────────────────────────

  /// True when anything was entered in [cells] (a weight, count or code),
  /// even if it paid $0.00 (e.g. scrap).
  bool _rowHasGoods(List<String> cells) {
    const cols = [0, 1, 2, 3, 5, 6, 7, 8, 10, 11, 12, 13, 15, 16, 17, 18];
    for (final c in cols) {
      if (c < cells.length && cells[c].trim().isNotEmpty) return true;
    }
    return false;
  }

  /// Opens the receipt for [row] of the current sheet (issuing one if the
  /// customer has signed but no receipt exists yet).
  Future<void> _openReceiptForRow(int row) async {
    if (row >= rowCount || row >= _currentGridData.length) return;
    final cellKey = '$_currentSheetNumber-$row';
    final existingId = _receiptIdsByCell[cellKey];
    if (existingId != null) {
      await openReceiptScreen(context, receiptId: existingId);
      return;
    }

    final signCell = _currentGridData[row].length > 21
        ? _currentGridData[row][21]
        : '';
    final points = _sheetsSignaturePoints[_currentSheetNumber]?['$row-21'];
    if (!signCell.contains('Signed') || points == null || points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The customer needs to sign before a receipt can be issued.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final rowTotal = _currentGridData[row].length > 20
        ? _parseCellValue(_currentGridData[row][20])
        : 0.0;
    if (rowTotal <= 0 && !_rowHasGoods(_currentGridData[row])) {
      // Don't burn a receipt number on an empty row. $0.00 is fine when
      // something was brought in (scrap).
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter the amounts for this row, then long-press the signature cell to issue the receipt.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final customerName = signCell.split('/').first.trim();
    final container = ProviderScope.containerOf(context, listen: false);
    final location =
        _locationOverride ?? container.read(appControllerProvider).nearestLocation;

    final draft = ReceiptData.fromGridRow(
      cells: _currentGridData[row],
      row: row,
      sheetNumber: _currentSheetNumber,
      date: _selectedDate,
      customerName: customerName,
      signature: points
          .map((p) => ReceiptSignaturePoint(p.offset.dx, p.offset.dy, p.type.index))
          .toList(),
      certification: location?.certification ?? '',
      recyclerName: location?.name ?? '',
      recyclerAddress: location?.address ?? '',
      locationId: location?.id,
      priceHints: {
        ReceiptMaterial.aluminum: _aluminumMultiplier,
        ReceiptMaterial.glass: _glassMultiplier,
        ReceiptMaterial.pete: _plasticMultiplier,
      },
    );

    await openReceiptScreen(
      context,
      draft: draft,
      onIssued: (issued) {
        if (issued.id != null) {
          _receiptIdsByCell[cellKey] = issued.id!;
          _saveDraft();
        }
      },
    );
  }

  Widget _buildSignatureCell(int row, int col) {
    final signatureKey = '$row-$col';
    // Ensure the row has enough columns
    if (_currentGridData[row].length <= col) {
      // Pad the row with empty strings if needed
      while (_currentGridData[row].length <= col) {
        _currentGridData[row].add('');
      }
    }
    final cellData = _currentGridData[row][col];

    // Check if we have local signature points (for current session)
    final signaturePoints =
        _sheetsSignaturePoints[_currentSheetNumber]?[signatureKey];

    // Check if cell contains name/signature data
    if (cellData.contains('/') && cellData.contains('Signed')) {
      final parts = cellData.split('/');
      final customerName = parts[0];

      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Customer name
          Expanded(
            flex: 2,
            child: Text(
              customerName,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.blue[700],
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          // Signature indicator
          Expanded(
            flex: 3,
            child:
                signaturePoints != null && signaturePoints.isNotEmpty
                    ? CustomPaint(
                      size: Size.infinite,
                      painter: SignaturePointsPainter(signaturePoints),
                    )
                    : Text(
                      'Signed',
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.green[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
          ),
        ],
      );
    }

    // Fallback to text for empty cells
    return Text(cellData, overflow: TextOverflow.ellipsis);
  }

  // Future method to build signature cell with URL support
  Future<Widget> _buildSignatureCellWithUrl(
    String signatureKey,
    String? signatureUrl,
  ) async {
    // Check if we have local signature data (for current session)
    if (_currentSignatures.containsKey(signatureKey)) {
      return Image.memory(
        _currentSignatures[signatureKey]!,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Text(
            'Error loading signature',
            style: TextStyle(color: Colors.red),
          );
        },
      );
    }

    // Check if we have a URL (for loaded data from Firestore)
    if (signatureUrl != null) {
      try {
        final signatureData = await _loadSignatureFromUrl(signatureUrl);
        if (signatureData != null) {
          return Image.memory(
            signatureData,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Text(
                'Error loading signature',
                style: TextStyle(color: Colors.red),
              );
            },
          );
        }
      } catch (e) {
        print('Error loading signature from URL: $e');
      }
    }

    // Fallback to text
    return Text('No signature', style: TextStyle(color: Colors.grey));
  }

  Widget _buildStaticDetails() {
    final double gridWidth = 4 * (colWidth * 4 + paidColWidth) + signColWidth;
    final String formattedDate = DateFormat('MM/dd/yyyy').format(_selectedDate);
    return SizedBox(
      width: gridWidth,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LOG SHEET DETAILS (far left)
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LOG SHEET',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'CERTIFICATION #',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'RECYCLER NAME',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'ADDRESS',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Consumer(
                          builder: (context, ref, _) {
                            final appState = ref.watch(appControllerProvider);
                            final roleAsync = ref.watch(currentUserRoleProvider);
                            final effectiveLocation = _locationOverride ?? appState.nearestLocation;
                            final certification = effectiveLocation?.certification ?? '';
                            final recyclerName = effectiveLocation?.name ?? '';
                            final address = effectiveLocation?.address ?? '';
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  certification.isNotEmpty ? certification : '—',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  recyclerName.isNotEmpty ? recyclerName : '—',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                  ),
                                ),
                                Builder(
                                  builder: (context) {
                                    Widget content;
                                    if (address.isEmpty) {
                                      content = const Text(
                                        'Detecting location...',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 14,
                                        ),
                                      );
                                    } else {
                                      content = Text(
                                        address.replaceAll('\n', ' '),
                                        softWrap: true,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 14,
                                        ),
                                      );
                                    }
                                    final isAdmin = roleAsync.valueOrNull == 'admin';
                                    if (isAdmin) {
                                      final clickableContent = address.isEmpty
                                          ? content
                                          : Text(
                                              address.replaceAll('\n', ' '),
                                              softWrap: true,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                                decoration: TextDecoration.underline,
                                              ),
                                            );
                                      return Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          onTap: _showLocationPickerBottomSheet,
                                          borderRadius: BorderRadius.circular(4),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 2),
                                            child: clickableContent,
                                          ),
                                        ),
                                      );
                                    }
                                    return content;
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // BASIC LEGEND (left-aligned)
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    alignment: Alignment.centerLeft,
                    color: Colors.grey[300],
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'BASIC LEGEND',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'SW   SEGREGATED BY WEIGHT',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'SC   SEGREGATE BY COUNT',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'C    COMMINGLED 9MIXOF CRV AND NONCRV CONTAINERS',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'SP   SCRAP ONLY (NON-CRV MATERIALS)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ],
              ),
            ),
            // OTHER COMMODITIES LEGEND (left-aligned) + DATE (top right)
            Expanded(
              flex: 6, // wider
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Container(
                          alignment: Alignment.centerLeft,
                          color: Colors.grey[300],
                          padding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            'OTHER COMMODITIES LEGEND',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 24), // more space before date
                      Text(
                        'DATE:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(width: 4),
                      Expanded(
                        flex: 2,
                        child: GestureDetector(
                          onTap: _showDatePicker,
                          child: Text(
                            formattedDate,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'B1   BIMETAL',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#2  HDPE (High Density Polyethylene)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#3  PVC (Vinyl)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#4  LDPE (Low Density Polyethylene)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#5  PP (Polypropylene)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#6  PS (Polystyrene)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'P#7  Other (Includes multilayer and unspecified resins)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  Text(
                    'SCRAP  Scrap (non-CRV, can be paid \$0.00)',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet grid followed by the receipt column.
  Widget _buildGrid() {
    return SizedBox(
      width: _totalGridWidth,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSheetGrid(),
          _buildReceiptColumn(),
        ],
      ),
    );
  }

  // ── Receipt column (classic grid only; the PDF is unchanged) ──────────

  static const double receiptColWidth = 130;

  /// Header (same height as the grid's three header rows) + one cell per row.
  Widget _buildReceiptColumn() {
    return SizedBox(
      width: receiptColWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 132,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              border: Border.all(color: Colors.black, width: 1),
            ),
            child: const Text(
              'RECEIPT',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 1.2),
            ),
          ),
          for (int row = 0; row < rowCount; row++) _buildReceiptCell(row),
        ],
      ),
    );
  }

  Widget _receiptCellBox({required Widget child, VoidCallback? onTap, Color color = Colors.white}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: receiptColWidth,
        height: 48,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Colors.black, width: 1),
        ),
        child: child,
      ),
    );
  }

  /// Receipt number + delivery status, or "Issue" for a signed, paid row.
  Widget _receiptCellContent(ReceiptData? r, {required bool canIssue}) {
    if (r != null) {
      final status = r.sms.requested
          ? (r.sms.status == 'delivered'
              ? 'Texted'
              : (r.sms.status == 'failed' || r.sms.status == 'undelivered' ? 'Text failed' : 'Texting'))
          : (r.printed ? 'Printed' : 'Issued');
      final failed = status == 'Text failed';
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '#${r.receiptNumberLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: AppColors.forest),
          ),
          Text(
            status,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: failed ? AppColors.redText : AppColors.slate,
            ),
          ),
        ],
      );
    }
    if (canIssue) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.amberTint,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.amberLine),
        ),
        child: const Text('Issue',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.amberText)),
      );
    }
    return const SizedBox.shrink();
  }

  /// Issued receipts by id (for the receipt column).
  final Map<String, ReceiptData> _receiptCache = {};

  /// Ids already asked for, so a build never starts the same fetch twice.
  final Set<String> _receiptRequested = {};

  Future<void> _refreshReceiptCache() async {
    final missing = _receiptIdsByCell.values
        .where((id) => !_receiptCache.containsKey(id) && !_receiptRequested.contains(id))
        .toSet();
    if (missing.isEmpty) return;
    _receiptRequested.addAll(missing);
    try {
      final fetched = await Future.wait(missing.map(ReceiptService.getById));
      if (!mounted) return;
      setState(() {
        for (final r in fetched) {
          if (r?.id != null) _receiptCache[r!.id!] = r;
        }
      });
    } catch (e) {
      print('New entry: receipts not loaded: $e');
    }
  }

  Widget _buildReceiptCell(int row) {
    final id = _receiptIdsByCell['$_currentSheetNumber-$row'];
    final r = id == null ? null : _receiptCache[id];
    if (id != null && r == null) _refreshReceiptCache();
    final cells = row < _currentGridData.length ? _currentGridData[row] : const <String>[];
    final signed = cells.length > 21 && cells[21].contains('Signed');
    final total = cells.length > 20 ? _parseCellValue(cells[20]) : 0.0;
    final canIssue = id == null && signed && total > 0;
    return _receiptCellBox(
      color: id != null ? const Color(0xFFF1F8EC) : Colors.white,
      onTap: id == null && !canIssue
          ? null
          : () async {
              await _openReceiptForRow(row);
              final newId = _receiptIdsByCell['$_currentSheetNumber-$row'];
              if (newId != null) {
                _receiptCache.remove(newId);
                _receiptRequested.remove(newId);
              }
              if (mounted) _refreshReceiptCache();
            },
      child: id != null && r == null
          ? const Text('Issued', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))
          : _receiptCellContent(r, canIssue: canIssue),
    );
  }

  Widget _buildSheetGrid() {
    return SizedBox(
      width: _sheetGridWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Section headers (top row)
          Row(
            children: [
              for (int i = 0; i < 4; i++)
                Container(
                  width:
                      i ==
                              3 // If Other Commodities
                          ? (colWidth * 3 + colWidth + paidColWidth)
                          : (colWidth * 3 + colWidth + paidColWidth),
                  // 3 CRV + 1 NON-CRV + 1 PAID
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  child: Text(
                    sectionHeaders[i],
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              //Total Paid
              Container(
                width: colWidth,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  border: Border(
                    top: BorderSide(color: Colors.black, width: 2),
                    // top border
                    right: BorderSide(color: Colors.black, width: 2),
                    // right border
                    bottom: BorderSide.none,
                    // bottom border
                    left: BorderSide(
                      color: Colors.black,
                      width: 2,
                    ), // no left border
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      "",
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        letterSpacing: 1.2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              // Customer sign
              Container(
                width: signColWidth,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  sectionHeaders[4],
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    letterSpacing: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          // Sub-header row (second row)
          Row(
            children: [
              for (int i = 0; i < 4; i++) ...[
                // CRV WEIGHT (spans 3 columns)
                Container(
                  width: i == 3 ? colWidth * 3 : colWidth * 3,
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  child: Text(
                    'CRV WEIGHT',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ),
                // NON-CRV WEIGHT (spans 1 column)
                Container(
                  width: colWidth,
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                  child: Text(
                    'NON-CRV\nWEIGHT',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                  ),
                ),

                if (i == 3)
                  Container(
                    width: colWidth,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      border: Border(
                        left: BorderSide(color: Colors.black, width: 1),
                        right: BorderSide(color: Colors.black, width: 1),
                      ),
                    ),
                    child: Text(
                      'Total \nPaid',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                    ),
                  ),

                // TOTAL PAID (spans 1 column, paidColWidth)
                Container(
                  width: paidColWidth,
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    border: Border(
                      top: BorderSide.none,
                      right: BorderSide(color: Colors.black, width: 2),
                      // right border
                      bottom: BorderSide(color: Colors.black, width: 0),
                      // right border
                      left: BorderSide(
                        color: Colors.black,
                        width: 2,
                      ), // no left border
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "Total Paid",
                        maxLines: 2,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          letterSpacing: 1.2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
              // Customer sign
              Container(
                width: signColWidth,
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'CUSTOMER SIGN AND NAME OR I.D.',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          // Column headers (third row)
          Row(
            children: [
              // ALUMINIUM section headers (columns 0-4) — tap SW to edit $/lb
              Material(
                color: Colors.blue[50],
                child: InkWell(
                  onTap: _showPricesInfo,
                  child: Container(
                    width: colWidth,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 1),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'SW',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '${LocationPrices.fmt(_aluminumMultiplier)}/lb',
                          style: TextStyle(fontSize: 7, color: Colors.blue[700]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SP',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'ALUMINIUM',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
              // GLASS section headers (columns 5-9) — tap SW to edit $/lb
              Material(
                color: Colors.blue[50],
                child: InkWell(
                  onTap: _showPricesInfo,
                  child: Container(
                    width: colWidth,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 1),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'SW',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '${LocationPrices.fmt(_glassMultiplier)}/lb',
                          style: TextStyle(fontSize: 7, color: Colors.blue[700]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SP',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'GLASS',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
              // #1 PETE PLASTIC section headers (columns 10-14) — tap SW to edit $/lb
              Material(
                color: Colors.blue[50],
                child: InkWell(
                  onTap: _showPricesInfo,
                  child: Container(
                    width: colWidth,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 1),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'SW',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '${LocationPrices.fmt(_plasticMultiplier)}/lb',
                          style: TextStyle(fontSize: 7, color: Colors.blue[700]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SP',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'PETE',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
              // CODE column header (column 15)
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Code',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              // OTHER COMMODITIES section headers (columns 16-19)
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SW',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SP',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'Long press',
                      style: TextStyle(fontSize: 7, color: Colors.blue[600]),
                    ),
                  ],
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  border: Border(
                    top: BorderSide.none,
                    right: BorderSide(color: Colors.black, width: 2),
                    // right border
                    bottom: BorderSide(color: Colors.black, width: 2),
                    // right border
                    left: BorderSide(
                      color: Colors.black,
                      width: 2,
                    ), // no left border
                  ),
                ),
                child: Text(
                  '',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
              // Customer sign
              Container(
                width: signColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SIGN/ID',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
          // Grid rows (no inner scroll - lets parent scroll view receive drags)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(rowCount, (row) {
                return Row(
                  children: [
                    // ALUMINIUM section (columns 0-4)
                    for (int col = 0; col < 4; col++)
                      GestureDetector(
                        onTap: () => _editCell(row, col),
                        onLongPress:
                            _isSpOrSwColumn(col)
                                ? () => _editCell(row, col, isLongPress: true)
                                : null,
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // ALUMINIUM paid column (column 4)
                    GestureDetector(
                      onTap: () => _editCell(row, 4),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][4],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // GLASS section (columns 5-9)
                    for (int col = 5; col < 9; col++)
                      GestureDetector(
                        onTap: () => _editCell(row, col),
                        onLongPress:
                            _isSpOrSwColumn(col)
                                ? () => _editCell(row, col, isLongPress: true)
                                : null,
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // GLASS paid column (column 9)
                    GestureDetector(
                      onTap: () => _editCell(row, 9),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][9],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // #1 PETE PLASTIC section (columns 10-14)
                    for (int col = 10; col < 14; col++)
                      GestureDetector(
                        onTap: () => _editCell(row, col),
                        onLongPress:
                            _isSpOrSwColumn(col)
                                ? () => _editCell(row, col, isLongPress: true)
                                : null,
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // #1 PETE PLASTIC paid column (column 14)
                    GestureDetector(
                      onTap: () => _editCell(row, 14),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][14],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // CODE column (column 15)
                    GestureDetector(
                      onTap: () => _editCell(row, 15),
                      child: Container(
                        width: colWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][15],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // OTHER COMMODITIES section (columns 16-20)
                    for (int col = 16; col < 20; col++)
                      GestureDetector(
                        onTap: () => _editCell(row, col),
                        onLongPress:
                            _isSpOrSwColumn(col)
                                ? () => _editCell(row, col, isLongPress: true)
                                : null,
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // OTHER COMMODITIES paid column (column 20) - Auto-calculated, not editable
                    Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][20],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // Customer sign (column 21) — long press re-opens the receipt
                    GestureDetector(
                      onTap: () => _editCell(row, 21),
                      onLongPress: () => _openReceiptForRow(row),
                      child: Container(
                        width: signColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: _buildSignatureCell(row, 21),
                      ),
                    ),
                  ],
                );
              }),
            ),
          SizedBox(height: 16),
          Row(
            children: [
              // ALUMINIUM
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SW',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SP',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'TP-AL',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // GLASS
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SW',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SP',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'TP-GL',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // #1 PETE PLASTIC
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SW',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SP',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'TP-PL',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // CODE column
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'CODE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // OTHER COMMODITIES
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SW',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SC',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'C',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SP',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // Grand Total (merged TP and GRAND TOTAL)
              Container(
                width: paidColWidth + signColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.orange[100],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'GRAND TOTAL',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          // Add an empty editable row below:
          Builder(
            builder: (context) {
              // Ensure all existing rows have 22 columns
              for (int i = 0; i < _currentGridData.length; i++) {
                if (_currentGridData[i].length < 22) {
                  // Pad with empty strings to reach 22 columns
                  while (_currentGridData[i].length < 22) {
                    _currentGridData[i].add('');
                  }
                } else if (_currentGridData[i].length > 22) {
                  // Truncate to 22 columns if somehow longer
                  _currentGridData[i] = _currentGridData[i].sublist(0, 22);
                }
              }

              // Ensure gridData has an extra row for this editable row
              if (_currentGridData.length <= rowCount) {
                _currentGridData.add(List.generate(22, (_) => ''));
              }
              return Row(
                children: [
                  for (int col = 0; col < 20; col++)
                    Container(
                      width: colWidthsForEditableRow(col),
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black, width: 1),
                        color: Colors.blue[50], // Different color to indicate it's the totals row
                      ),
                      child: Text(
                        _currentGridData[rowCount][col],
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  // Grand Total (merged cell showing the grand total value)
                  Container(
                    width: paidColWidth + signColWidth,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 1),
                      color: Colors.orange[50], // Special color for grand total cell
                    ),
                    child: Text(
                      _currentGridData[rowCount][21], // Show the grand total value
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange[800],
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  double colWidthsForEditableRow(int col) {
    // Handle paid columns: 4, 9, 14, 20 (paid columns of each section)
    if (col == 4 || col == 9 || col == 14 || col == 20) return paidColWidth;
    return colWidth;
  }

  // Helper method to sanitize data for Firestore
  List<List<String>> _sanitizeGridData(List<List<String>> gridData) {
    return gridData.map((row) {
      return row.map((cell) {
        // Ensure all values are strings and handle null/undefined values
        if (cell == null) return '';
        return cell.toString().trim();
      }).toList();
    }).toList();
  }

  // Helper method to convert grid data to Firestore-safe format
  Map<String, dynamic> _convertGridDataToSafeFormat(
    List<List<String>> gridData,
  ) {
    final List<String> flattenedData = [];
    final int rows = gridData.length;
    final int cols = gridData.isNotEmpty ? gridData[0].length : 0;

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final value =
            row < gridData.length && col < gridData[row].length
                ? gridData[row][col]
                : '';
        flattenedData.add(value);
      }
    }

    return {'rows': rows, 'columns': cols, 'values': flattenedData};
  }

  // Helper method to validate and sanitize entry data
  Future<Map<String, dynamic>> _prepareEntryData(
    String userId,
    String email,
  ) async {
    final Map<String, dynamic> entryData = {
      'userId': userId,
      // Firestore reference to the user document
      'userRef': FirebaseFirestore.instance.collection('users').doc(userId),
      'email': email,
      'createdAt': DateTime.now().toIso8601String(),
      'entryDate': _selectedDate.toIso8601String(),
      // Normalized date key (YYYY-MM-DD) for easier querying/merging
      'entryDateKey': DateFormat('yyyy-MM-dd').format(_selectedDate),
      // New moderation/location fields
      'approved': false, // default sheet approval status
      'accepted': false, // legacy fields retained if used elsewhere
      'rejected': false,
      // Prefer storing locationRef; keep legacy 'location' for compatibility
      'location': null, // location id string (legacy)
      'locationRef': null, // DocumentReference to locations/{id}
      'sheets': {},
    };

    try {
      // Use admin-selected location override if set, otherwise nearest location from app controller
      final container = ProviderScope.containerOf(context, listen: false);
      final appState = container.read(appControllerProvider);
      final effective = _locationOverride ?? appState.nearestLocation;
      if (effective != null) {
        entryData['location'] = effective.id;
        entryData['locationRef'] = FirebaseFirestore.instance
            .collection('locations')
            .doc(effective.id);
        entryData['locationAddress'] = effective.address;
        entryData['locationName'] = effective.name;
        entryData['locationCertification'] = effective.certification;
      }
    } catch (_) {}

    // Process each sheet with validation
    for (final entry in _sheetsGridData.entries) {
      final sheetNumber = entry.key;
      final gridData = entry.value;

      try {
        print('Processing sheet $sheetNumber');
        print('Grid data type: ${gridData.runtimeType}');
        print('Grid data length: ${gridData.length}');

        // Sanitize the grid data
        final sanitizedGridData = _sanitizeGridData(gridData);
        print('Sanitized grid data length: ${sanitizedGridData.length}');

        // Validate that the data structure is correct
        if (sanitizedGridData.isEmpty) {
          print('Warning: Empty grid data for sheet $sheetNumber, skipping');
          continue; // Skip this sheet
        }

        // Ensure each row has the correct number of columns
        for (int i = 0; i < sanitizedGridData.length; i++) {
          if (sanitizedGridData[i].length != 21) {
            print(
              'Warning: Row $i has ${sanitizedGridData[i].length} columns, expected 21. Fixing...',
            );
            // Pad or truncate to 21 columns
            while (sanitizedGridData[i].length < 21) {
              sanitizedGridData[i].add('');
            }
            if (sanitizedGridData[i].length > 21) {
              sanitizedGridData[i] = sanitizedGridData[i].sublist(0, 21);
            }
          }
        }

        // Get signature points for this sheet
        final signaturePoints = _sheetsSignaturePoints[sheetNumber] ?? {};
        print(
          'Found ${signaturePoints.length} signature points for sheet $sheetNumber',
        );

        // Extract customer names from the grid as entered (the signature
        // column 21 is cut off by the 21-column sanitising above).
        final customerNames = <String, String>{};
        String originalCell(int r, int c) {
          try {
            final rowData = gridData[r];
            if (rowData is List && c < rowData.length) return rowData[c].toString();
          } catch (_) {}
          return '';
        }
        signaturePoints.forEach((key, points) {
          final rowCol = key.split('-');
          if (rowCol.length == 2) {
            final row = int.tryParse(rowCol[0]);
            final col = int.tryParse(rowCol[1]);
            if (row != null && col != null) {
              final cellData = originalCell(row, col);
              if (cellData.contains('/') && cellData.contains('Signed')) {
                final parts = cellData.split('/');
                customerNames[key] = parts[0]; // Store the customer name
              }
            }
          }
        });

        // Convert to safe format
        final safeGridData = _convertGridDataToSafeFormat(sanitizedGridData);

        entryData['sheets'][sheetNumber.toString()] = {
          'data': safeGridData,
          'hasSignatures': signaturePoints.isNotEmpty,
          'signatureCount': signaturePoints.length,
          'customerNames': customerNames, // Add customer names to sheet data
          // Prices in effect when the sheet was submitted (audit trail).
          'prices': {
            'aluminum': _aluminumMultiplier,
            'glass': _glassMultiplier,
            'pete': _plasticMultiplier,
            'other': Map<String, double>.from(_otherPrices),
            'source': _priceSource,
            if (_pricesLocationId != null) 'locationId': _pricesLocationId,
          },
        };

        _logSubmissionProgress('Processed sheet $sheetNumber');
      } catch (e) {
        print('Error processing sheet $sheetNumber: $e');
        _logSubmissionProgress('Error processing sheet $sheetNumber: $e');
        // Continue with other sheets even if one fails
      }
    }

    print('Final entry data keys: ${entryData.keys}');
    print('Sheets count: ${(entryData['sheets'] as Map).length}');

    // If a location id has been selected earlier and placed into entryData['location'],
    // also set a proper DocumentReference for stronger consistency.
    try {
      final dynamic maybeLocationId = entryData['location'];
      if (maybeLocationId is String && maybeLocationId.isNotEmpty) {
        entryData['locationRef'] = FirebaseFirestore.instance
            .collection('locations')
            .doc(maybeLocationId);
      }
    } catch (_) {}

    return entryData;
  }

  // Helper method to validate total data size
  bool _validateDataSize(Map<String, dynamic> entryData) {
    try {
      // Convert to JSON string to check size
      final jsonString = entryData.toString();
      final sizeInBytes = jsonString.length;
      final sizeInKB = sizeInBytes / 1024;

      print('Total data size: ${sizeInKB.toStringAsFixed(2)} KB');
      _logSubmissionProgress(
        'Total data size: ${sizeInKB.toStringAsFixed(2)} KB',
      );

      // With Firebase Storage, documents should be much smaller
      // URLs are typically ~200-300 characters each
      if (sizeInKB > 500) {
        // 500KB limit (much more conservative now)
        print(
          'Warning: Data size (${sizeInKB.toStringAsFixed(2)} KB) is approaching limit',
        );
        _logSubmissionProgress('Warning: Data size is approaching limit');

        // Show warning to user
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Warning: Data size (${sizeInKB.toStringAsFixed(2)} KB) is large.',
              ),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            ),
          );
        }

        return false;
      }

      return true;
    } catch (e) {
      print('Error validating data size: $e');
      return false;
    }
  }

  // Helper method to upload signature to Firebase Storage
  Future<String?> _uploadSignatureToStorage(
    Uint8List signatureBytes,
    String signatureKey,
  ) async {
    try {
      print('Uploading signature $signatureKey to Firebase Storage...');

      // Create a unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = 'signatures/$signatureKey-$timestamp.png';

      // Upload to Firebase Storage
      final storageRef = FirebaseStorage.instance.ref().child(filename);
      final uploadTask = storageRef.putData(signatureBytes);

      // Wait for upload to complete
      final snapshot = await uploadTask;

      // Get download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();

      print('Signature uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      print('Error uploading signature $signatureKey: $e');
      return null;
    }
  }

  // Helper method to upload all signatures and get URLs
  Future<Map<String, String>> _uploadSignaturesAndGetUrls(
    Map<String, Uint8List>? signatures,
  ) async {
    final Map<String, String> signatureUrls = {};

    if (signatures == null || signatures.isEmpty) {
      return signatureUrls;
    }

    print('Uploading ${signatures.length} signatures to Firebase Storage...');

    // Show progress to user
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Uploading ${signatures.length} signatures...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    // Upload signatures in parallel for better performance
    final futures = signatures.entries.map((entry) async {
      final url = await _uploadSignatureToStorage(entry.value, entry.key);
      if (url != null) {
        signatureUrls[entry.key] = url;
      }
    });

    await Future.wait(futures);

    print('Successfully uploaded ${signatureUrls.length} signatures');

    // Show completion message
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Successfully uploaded ${signatureUrls.length} signatures',
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }

    return signatureUrls;
  }

  // Helper method to load signature from URL
  Future<Uint8List?> _loadSignatureFromUrl(String url) async {
    try {
      print('Loading signature from URL: $url');

      // Check if already cached
      if (_loadedSignatures.containsKey(url)) {
        print('Signature already cached');
        return _loadedSignatures[url];
      }

      // Download from Firebase Storage
      final response = await FirebaseStorage.instance.refFromURL(url).getData();

      if (response != null) {
        // Cache the signature
        _loadedSignatures[url] = response;
        print('Signature loaded and cached successfully');
        return response;
      } else {
        print('Failed to load signature data');
        return null;
      }
    } catch (e) {
      print('Error loading signature from URL: $e');
      return null;
    }
  }

  /// Signature document for one sheet (`entries/{id}/signatures/{sheet}`):
  /// stroke points per signed cell plus the customer names, taken from that
  /// sheet's own grid.
  Map<String, dynamic> _signaturePayload(int sheetNumber, Map<String, List<Point>> signaturePoints) {
    final grid = _sheetsGridData[sheetNumber] ?? const <List<String>>[];
    final points = <String, List<Map<String, dynamic>>>{};
    final names = <String, String>{};
    signaturePoints.forEach((key, pts) {
      points[key] = [
        for (final p in pts) {'dx': p.offset.dx, 'dy': p.offset.dy, 'type': p.type.index},
      ];
      final rc = key.split('-');
      final row = rc.length == 2 ? int.tryParse(rc[0]) : null;
      final col = rc.length == 2 ? int.tryParse(rc[1]) : null;
      if (row != null && col != null && row < grid.length && col < grid[row].length) {
        final cell = grid[row][col];
        if (cell.contains('/') && cell.contains('Signed')) names[key] = cell.split('/').first;
      }
    });
    return {'points': points, 'customerNames': names};
  }

  // Helper method to reconstruct signature from points
  Widget _buildSignatureFromPoints(List<Point> points) {
    if (points.isEmpty) {
      return Text('No signature', style: TextStyle(color: Colors.grey));
    }

    return CustomPaint(
      size: Size(200, 100), // Fixed size for signature display
      painter: SignaturePointsPainter(points),
    );
  }

  void _goToPreviousSheet() {
    if (_currentSheetNumber <= 1) return;
    setState(() {
      _currentSheetNumber--;
    });
    // Calculate totals for the new sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateAndUpdateTotals();
    });
  }

  void _goToNextSheet() {
    setState(() {
      _currentSheetNumber++;
      _initializeSheet(_currentSheetNumber);
    });
    // Calculate totals for the new sheet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateAndUpdateTotals();
    });
  }

  Future<void> _onSubmitPressed() async {
        final confirmed =
            await showFloatingConfirmationBottomSheet(
          context: context,
          title: 'Submit entry?',
          message:
              'Your log sheet will be saved to your account. Continue?',
          confirmLabel: 'Submit',
        );
        if (!confirmed || !mounted) return;

        setState(() {
          _isSubmitting = true;
        });

        try {
          final user =
              ref.read(authControllerProvider).value;
          if (user == null) {
            throw Exception(
              'No authenticated user found',
            );
          }

          _logSubmissionProgress(
            'User authenticated: ${user.uid}',
          );

          if (!_validateData()) {
            setState(() {
              _isSubmitting = false;
            });
            return;
          }

          _logSubmissionProgress(
            'Data validation passed',
          );

          // Check data size and warn if necessary
          _checkDataSize();

          // Show loading message
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Submitting entry...'),
                duration: Duration(seconds: 2),
              ),
            );
          }

          // Prepare the entry exactly as it will be stored. (No test writes,
          // and never a placeholder sheet if this fails: the draft stays.)
          final Map<String, dynamic> entryData;
          try {
            entryData = await _prepareEntryData(user.uid, user.email!);
          } catch (e) {
            throw Exception('Could not prepare the sheet: $e');
          }
          if ((entryData['sheets'] as Map).isEmpty) {
            throw Exception('Nothing to submit on this sheet.');
          }
          if (!_validateDataSize(entryData)) {
            setState(() {
              _isSubmitting = false;
            });
            return;
          }

          // 1) Keep it on this tablet first, so nothing is lost if the upload
          //    can't finish (offline, app closed, error).
          final entry = Map<String, dynamic>.from(entryData)
            ..remove('userRef')
            ..remove('locationRef');
          final signatures = <String, dynamic>{
            for (final e in _sheetsSignaturePoints.entries)
              // Only sheets that made it into the entry.
              if (e.value.isNotEmpty && (entry['sheets'] as Map).containsKey('${e.key}'))
                '${e.key}': _signaturePayload(e.key, e.value),
          };
          final item = await SheetOutbox.instance.add(
            entry: entry,
            signatures: signatures,
            receiptIds: Map<String, String>.from(_receiptIdsByCell),
          );
          _submitted = true;
          _logSubmissionProgress('Saved on this tablet as ${item.localId}');
          await _clearDraft();

          // 2) Upload now. If it can't finish it stays "waiting" and is
          //    retried from Sync on the home screen (and automatically).
          // Don't keep staff waiting long: after 25 s it carries on in the
          // background and the sheet shows as waiting until it's up.
          final uploaded = await SheetOutbox.instance
              .upload(item.localId)
              .timeout(const Duration(seconds: 25), onTimeout: () => false);
          _logSubmissionProgress(uploaded ? 'Uploaded' : 'Saved, upload waiting');
          if (!mounted) return;

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                uploaded
                    ? 'Entry submitted'
                    : 'Saved on this tablet. It will upload when the connection is back '
                        '(Sync on the home screen).',
              ),
              backgroundColor: uploaded ? Colors.green : Colors.orange,
              duration: Duration(seconds: uploaded ? 2 : 6),
            ),
          );

          // Wait a short moment to ensure the message is visible
          await Future.delayed(
            const Duration(milliseconds: 500),
          );

          if (mounted) {
            // Read synchronously: offline, waiting on the role must not hang.
            final role = ref.read(currentUserRoleProvider).valueOrNull;
            context.go(role == 'admin' ? '/admin' : '/home');
          }
        } catch (e) {
          print('Error submitting entry: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Error submitting entry: ${e.toString()}',
                ),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        } finally {
          if (mounted) {
            setState(() {
              _isSubmitting = false;
            });
          }
        }

  }

  /// Phones (either orientation) get a compact layout; tablets keep the
  /// original sheet layout unchanged.
  bool get _isPhone => MediaQuery.sizeOf(context).shortestSide < 600;

  @override
  Widget build(BuildContext context) {
    _syncLocationPrices();
    if (_isPhone) return _buildPhone(context);
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('New Entry'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBackPress,
        ),
      ),
      body: SafeArea(
        child: ScrollConfiguration(
          behavior: const _TwoDimensionalScrollBehavior(),
          child: Column(
            children: [
              // Main scrollable content area - padding is inside so content scrolls to full width
              Expanded(
                child: SingleChildScrollView(
                  primary: true,
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _horizontalController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 31.0),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final screenW = MediaQuery.of(context).size.width;
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: _totalGridWidth > screenW ? _totalGridWidth : screenW,
                              minHeight: 1,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: _totalGridWidth,
                                  child: _buildStaticDetails(),
                                ),
                                SizedBox(
                                  width: _totalGridWidth,
                                  child: _buildGrid(),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              // Fixed bottom controls area
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 31.0,
                  vertical: 8.0,
                ),
                decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Sheet navigation row
                    Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Sheet $_currentSheetNumber',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          if (_currentSheetNumber > 1)
                            TextButton(
                              onPressed: _goToPreviousSheet,
                              child: const Text('Previous Sheet'),
                            ),
                          const SizedBox(width: 16),
                          SizedBox(
                            height: 40,
                            width: MediaQuery.of(context).size.width * 0.2,
                            child: ElevatedButton(
                              onPressed: _goToNextSheet,
                              child: const Text('Next Sheet'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Submit button
                  SizedBox(
                    width: double.infinity,
                    height: 45,
                    child: ElevatedButton.icon(
                      onPressed: _isSubmitting ? null : _onSubmitPressed,
                      icon:
                          _isSubmitting
                              ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.send, size: 20),
                      label: Text(
                        _isSubmitting ? 'Submitting...' : 'Submit Entry',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    ),   // child: Scaffold
    );   // PopScope
  }

  // ── Phone layout ────────────────────────────────────────────────────────
  // Same sheet (_buildGrid) and the same actions as the tablet; only the
  // chrome around it is compacted so the grid gets the screen.

  Widget _buildPhone(BuildContext context) {
    final hasNext = _sheetsGridData.containsKey(_currentSheetNumber + 1);
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          toolbarHeight: 52,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBackPress,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sheet $_currentSheetNumber',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
              Text(
                DateFormat('EEE, MMM d').format(_selectedDate),
                style: const TextStyle(fontSize: 12, color: AppColors.slate),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Previous sheet',
              onPressed: _currentSheetNumber > 1 ? _goToPreviousSheet : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            IconButton(
              tooltip: hasNext ? 'Next sheet' : 'New sheet',
              onPressed: _goToNextSheet,
              icon: Icon(
                hasNext ? Icons.chevron_right_rounded : Icons.note_add_outlined,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, left: 2),
              child: FilledButton.icon(
                onPressed: _isSubmitting ? null : _onSubmitPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.forest,
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 16),
                label: Text(_isSubmitting ? 'Saving' : 'Submit'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPhoneInfoStrip(),
              const Divider(height: 1, color: AppColors.line),
              Expanded(
                child: ScrollConfiguration(
                  behavior: const _TwoDimensionalScrollBehavior(),
                  child: SingleChildScrollView(
                    primary: true,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _horizontalController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
                        child: SizedBox(
                          width: _totalGridWidth,
                          child: _buildGrid(),
                        ),
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

  /// One swipeable row replacing the tall "LOG SHEET / legends / date"
  /// header: location, cert #, date (tap to change) and the legend.
  Widget _buildPhoneInfoStrip() {
    return Consumer(
      builder: (context, ref, _) {
        final appState = ref.watch(appControllerProvider);
        final isAdmin = ref.watch(currentUserRoleProvider).valueOrNull == 'admin';
        final loc = _locationOverride ?? appState.nearestLocation;
        final name = loc?.name ?? '';
        final cert = loc?.certification ?? '';
        final address = (loc?.address ?? '').replaceAll('\n', ' ');
        return SizedBox(
          height: 50,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              _PhoneInfoChip(
                icon: Icons.location_on_rounded,
                label: name.isEmpty ? 'Detecting location…' : name,
                trailing: isAdmin ? Icons.expand_more_rounded : null,
                onTap: isAdmin
                    ? () => _showLocationPickerBottomSheet()
                    : (address.isEmpty ? null : () => showAppSnack(context, address)),
              ),
              if (cert.isNotEmpty) ...[
                const SizedBox(width: 8),
                _PhoneInfoChip(icon: Icons.verified_rounded, label: 'Cert # $cert'),
              ],
              const SizedBox(width: 8),
              _PhoneInfoChip(
                icon: Icons.calendar_today_rounded,
                label: DateFormat('MM/dd/yyyy').format(_selectedDate),
                trailing: Icons.expand_more_rounded,
                highlight: true,
                onTap: () => _showDatePicker(),
              ),
              const SizedBox(width: 8),
              _PhoneInfoChip(
                icon: Icons.menu_book_rounded,
                label: 'Legend',
                onTap: _showLegendSheet,
              ),
            ],
          ),
        );
      },
    );
  }

  void _showLegendSheet() {
    Widget row(String code, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  code,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
                ),
              ),
              Expanded(child: Text(text, style: const TextStyle(color: AppColors.navy))),
            ],
          ),
        );
    Widget heading(String t) => Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Text(
            t,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppColors.slate,
            ),
          ),
        );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Legend',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.navy),
                ),
                heading('BASIC LEGEND'),
                row('SW', 'Segregated by weight'),
                row('SC', 'Segregate by count'),
                row('C', 'Commingled (mix of CRV and non-CRV containers)'),
                row('SP', 'Scrap only (non-CRV materials)'),
                heading('OTHER COMMODITIES LEGEND'),
                row('B1', 'Bimetal'),
                row('P#2', 'HDPE (High Density Polyethylene)'),
                row('P#3', 'PVC (Vinyl)'),
                row('P#4', 'LDPE (Low Density Polyethylene)'),
                row('P#5', 'PP (Polypropylene)'),
                row('P#6', 'PS (Polystyrene)'),
                row('P#7', 'Other (includes multilayer and unspecified resins)'),
                row('SCRAP', 'Scrap (non-CRV, can be paid \$0.00)'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SignaturePointsPainter extends CustomPainter {
  final List<Point> points;

  SignaturePointsPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final paint =
        Paint()
          ..color = Colors.black
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;

    // Find the bounding box of the signature points to scale it correctly
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final point in points) {
      minX = min(minX, point.offset.dx);
      maxX = max(maxX, point.offset.dx);
      minY = min(minY, point.offset.dy);
      maxY = max(maxY, point.offset.dy);
    }

    final sigWidth = maxX - minX;
    final sigHeight = maxY - minY;

    if (sigWidth <= 0 || sigHeight <= 0) return;

    final scaleX = size.width / sigWidth;
    final scaleY = size.height / sigHeight;
    final scale = min(scaleX, scaleY) * 0.95; // Use 95% of the cell space

    // Center the signature within the cell
    final offsetX = (size.width - sigWidth * scale) / 2;
    final offsetY = (size.height - sigHeight * scale) / 2;

    // Draw lines between all consecutive points for now
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];

      final p1Scaled = Offset(
        (p1.offset.dx - minX) * scale + offsetX,
        (p1.offset.dy - minY) * scale + offsetY,
      );
      final p2Scaled = Offset(
        (p2.offset.dx - minX) * scale + offsetX,
        (p2.offset.dy - minY) * scale + offsetY,
      );

      canvas.drawLine(p1Scaled, p2Scaled, paint);
    }
  }

  @override
  bool shouldRepaint(SignaturePointsPainter oldDelegate) =>
      oldDelegate.points != points;
}


/// Compact pill used in the phone info strip.
class _PhoneInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool highlight;
  const _PhoneInfoChip({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = highlight ? AppColors.blueText : AppColors.navy;
    return Material(
      color: highlight ? AppColors.blueTint : AppColors.mist,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 2),
                Icon(trailing, size: 16, color: fg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
