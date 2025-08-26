import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:signature/signature.dart';

// Custom signature point class to avoid Point constructor issues
class SignaturePoint {
  final double dx;
  final double dy;
  final int type; // 0 for move, 1 for draw

  SignaturePoint(this.dx, this.dy, this.type);

  Offset get offset => Offset(dx, dy);
}

class ViewEntryScreen extends ConsumerStatefulWidget {
  final String entryId;

  const ViewEntryScreen({super.key, required this.entryId});

  @override
  ConsumerState<ViewEntryScreen> createState() => _ViewEntryScreenState();
}

class _ViewEntryScreenState extends ConsumerState<ViewEntryScreen> {
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

  late List<List<String>> _currentGridData;
  final ScrollController _horizontalController = ScrollController();

  // Map to store grid data for each sheet
  final Map<int, List<List<String>>> _sheetsGridData = {};

  // Loading state
  bool _isLoading = true;
  bool _isReadOnly = true;
  bool _isSaving = false;

  // Map to store signature points for each sheet
  final Map<int, Map<String, List<SignaturePoint>>> _sheetsSignaturePoints = {};
  // Map to store customer names for each sheet
  final Map<int, Map<String, String>> _sheetsCustomerNames = {};

  // Entry data
  Map<String, dynamic>? _entryData;
  String? _userEmail;
  DateTime? _createdAt;

  @override
  void initState() {
    super.initState();
    print('ViewEntryScreen: Initializing with entryId: ${widget.entryId}');
    _loadEntryData();
  }

  Future<void> _loadEntryData() async {
    print('ViewEntryScreen: Loading entry data for ID: ${widget.entryId}');
    try {
      final docSnapshot =
          await FirebaseFirestore.instance
              .collection('entries')
              .doc(widget.entryId)
              .get();

      if (!docSnapshot.exists) {
        print('ViewEntryScreen: Entry not found in Firestore');
        throw Exception('Entry not found');
      }

      print('ViewEntryScreen: Entry found, loading data...');
      final data = docSnapshot.data()!;
      _entryData = data;
      _userEmail = data['email'] ?? '';
      _createdAt = DateTime.parse(data['createdAt']);

      print(
        'ViewEntryScreen: Entry data loaded - Email: $_userEmail, Created: $_createdAt',
      );

      // Load sheets data
      final sheets = data['sheets'] as Map<String, dynamic>? ?? {};
      print('ViewEntryScreen: Found ${sheets.length} sheets');

      for (final entry in sheets.entries) {
        final sheetNumber = int.parse(entry.key);
        final sheetData = entry.value as Map<String, dynamic>;

        // Load grid data
        final gridDataMap = sheetData['data'] as Map<String, dynamic>?;
        if (gridDataMap != null) {
          final values = gridDataMap['values'] as List<dynamic>? ?? [];
          final rows = gridDataMap['rows'] as int? ?? 15;
          final cols = gridDataMap['columns'] as int? ?? 21;

          final gridData = List.generate(rows, (row) {
            return List.generate(cols, (col) {
              final index = row * cols + col;
              return index < values.length ? values[index].toString() : '';
            });
          });

          _sheetsGridData[sheetNumber] = gridData;
          print(
            'ViewEntryScreen: Loaded sheet $sheetNumber with ${gridData.length} rows',
          );
        }

        // Load signature points
        try {
          final signaturePointsDoc =
              await FirebaseFirestore.instance
                  .collection('entries')
                  .doc(widget.entryId)
                  .collection('signatures')
                  .doc(sheetNumber.toString())
                  .get();

          if (signaturePointsDoc.exists) {
            print(
              'ViewEntryScreen: Found signature points for sheet $sheetNumber',
            );
            final pointsData = signaturePointsDoc.data()!;
            final pointsMap = <String, List<SignaturePoint>>{};

            final serializedPoints =
                pointsData['points'] as Map<String, dynamic>?;
            if (serializedPoints != null) {
              for (final pointEntry in serializedPoints.entries) {
                final signatureKey = pointEntry.key;
                final pointsList = pointEntry.value as List<dynamic>;

                final points =
                    pointsList.map((pointData) {
                      final pointMap = pointData as Map<String, dynamic>;
                      return SignaturePoint(
                        (pointMap['dx'] as num).toDouble(),
                        (pointMap['dy'] as num).toDouble(),
                        pointMap['type'] as int,
                      );
                    }).toList();

                pointsMap[signatureKey] = points;
                print(
                  'ViewEntryScreen: Loaded ${points.length} points for signature $signatureKey',
                );
              }
            }

            _sheetsSignaturePoints[sheetNumber] = pointsMap;
            
            // Load customer names if available
            final customerNamesData = pointsData['customerNames'] as Map<String, dynamic>?;
            if (customerNamesData != null) {
              final customerNamesMap = <String, String>{};
              customerNamesData.forEach((key, value) {
                customerNamesMap[key] = value.toString();
              });
              _sheetsCustomerNames[sheetNumber] = customerNamesMap;
              print(
                'ViewEntryScreen: Loaded ${customerNamesMap.length} customer names for sheet $sheetNumber',
              );
            }
            
            print(
              'ViewEntryScreen: Loaded ${pointsMap.length} signatures for sheet $sheetNumber',
            );
          }
        } catch (e) {
          print('Error loading signature points for sheet $sheetNumber: $e');
        }
      }

      // Initialize the first sheet
      if (_sheetsGridData.isNotEmpty) {
        _currentSheetNumber = _sheetsGridData.keys.first;
        _initializeSheet(_currentSheetNumber);
        print('ViewEntryScreen: Initialized sheet $_currentSheetNumber');
      }

      setState(() {
        _isLoading = false;
      });
      print('ViewEntryScreen: Data loading completed successfully');
    } catch (e) {
      print('Error loading entry data: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading entry: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _initializeSheet(int sheetNumber) {
    if (_sheetsGridData.containsKey(sheetNumber)) {
      _currentGridData = List.from(_sheetsGridData[sheetNumber]!);
    } else {
      _currentGridData = List.generate(
        rowCount,
        (index) => List.filled(21, ''),
      );
    }
  }

  void _toggleEditMode() {
    setState(() {
      _isReadOnly = !_isReadOnly;
    });
  }

  void _editCell(int row, int col) {
    if (_isReadOnly) return;

    // Handle signature cells (column 20)
    if (col == 20) {
      context.push(
        '/customer',
        extra: {
          'onSignatureComplete': (Uint8List signatureBytes) {
            setState(() {
              _currentGridData[row][col] = 'Signed';
            });
          },
          'onSignaturePointsComplete': (List<Point> signaturePoints) {
            setState(() {
              _sheetsSignaturePoints[_currentSheetNumber] ??= {};
              _sheetsSignaturePoints[_currentSheetNumber]!['$row-$col'] =
                  signaturePoints
                      .map(
                        (point) => SignaturePoint(
                          point.offset.dx,
                          point.offset.dy,
                          point.type.index,
                        ),
                      )
                      .toList();
              print(
                'Saved ${signaturePoints.length} signature points for cell $row-$col',
              );
            });
          },
        },
      );
      return;
    }

    // Handle regular cells
    final textController = TextEditingController(
      text: _currentGridData[row][col],
    );

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Edit Cell (Row ${row + 1}, Col ${col + 1})'),
            content: TextField(
              controller: textController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Value',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                setState(() {
                  _currentGridData[row][col] = value;
                });
                Navigator.of(context).pop();
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _currentGridData[row][col] = textController.text;
                  });
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  Future<void> _saveChanges() async {
    if (_isReadOnly) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // Save current sheet data
      _sheetsGridData[_currentSheetNumber] = List.from(_currentGridData);

      // Update the entry in Firestore
      final updatedSheets = <String, dynamic>{};

      for (final entry in _sheetsGridData.entries) {
        final sheetNumber = entry.key;
        final sheetGridData = entry.value;

        // Convert grid data to the format expected by Firestore
        final values = <String>[];
        for (int row = 0; row < sheetGridData.length; row++) {
          for (int col = 0; col < sheetGridData[row].length; col++) {
            values.add(sheetGridData[row][col]);
          }
        }

        updatedSheets[sheetNumber.toString()] = {
          'data': {
            'rows': sheetGridData.length,
            'columns': sheetGridData[0].length,
            'values': values,
          },
          'hasSignatures':
              _sheetsSignaturePoints[sheetNumber]?.isNotEmpty ?? false,
          'signatureCount': _sheetsSignaturePoints[sheetNumber]?.length ?? 0,
        };
      }

      await FirebaseFirestore.instance
          .collection('entries')
          .doc(widget.entryId)
          .update({
            'sheets': updatedSheets,
            'updatedAt': DateTime.now().toIso8601String(),
          });

      // Save signature points to subcollections if any exist
      for (final entry in _sheetsSignaturePoints.entries) {
        final sheetNumber = entry.key;
        final signaturePoints = entry.value;

        if (signaturePoints.isNotEmpty) {
          try {
            await _saveSignaturePointsToSubcollection(
              widget.entryId,
              sheetNumber.toString(),
              signaturePoints,
            );
            print('Saved signature points for sheet $sheetNumber');
          } catch (e) {
            print('Error saving signature points for sheet $sheetNumber: $e');
            // Continue with other sheets even if one fails
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Changes saved successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error saving changes: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving changes: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.background,
        appBar: AppBar(
          title: const Text('Loading Entry...'),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isReadOnly ? 'View Entry' : 'Edit Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: 'Home',
            onPressed: () => context.go('/home'),
          ),
          if (_entryData != null)
            IconButton(
              icon: Icon(_isReadOnly ? Icons.edit : Icons.save),
              onPressed: _isReadOnly ? _toggleEditMode : _saveChanges,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Entry info header
            if (_entryData != null)
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Entry ID: ${widget.entryId.substring(0, 8)}...',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          if (_createdAt != null)
                            Text(
                              'Created: ${DateFormat('MM/dd/yyyy HH:mm').format(_createdAt!)}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey[600]),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Sheets: ${_sheetsGridData.length}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          if (_userEmail != null)
                            Text(
                              _userEmail!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey[600]),
                              textAlign: TextAlign.end,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            // Main scrollable content area
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStaticDetails(),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _horizontalController,
                      child: _buildGrid(),
                    ),
                  ],
                ),
              ),
            ),

            // Fixed bottom controls area
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
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
                        'Sheet $_currentSheetNumber of ${_sheetsGridData.length}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          if (_currentSheetNumber > 1)
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _currentSheetNumber--;
                                  _initializeSheet(_currentSheetNumber);
                                });
                              },
                              child: const Text('Previous Sheet'),
                            ),
                          const SizedBox(width: 16),
                          if (_currentSheetNumber < _sheetsGridData.length)
                            SizedBox(
                              height: 40,
                              width: MediaQuery.of(context).size.width * 0.2,
                              child: ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    _currentSheetNumber++;
                                    _initializeSheet(_currentSheetNumber);
                                  });
                                },
                                child: const Text('Next Sheet'),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Bottom buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => context.go('/submitted'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey[300],
                            foregroundColor: Colors.black,
                          ),
                          child: const Text('Back to List'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      if (!_isReadOnly)
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _isSaving ? null : _saveChanges,
                            child:
                                _isSaving
                                    ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Text('Save Changes'),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticDetails() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily Log Sheet',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Date: ${DateFormat('MM/dd/yyyy').format(DateTime.now())}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Sheet Number: $_currentSheetNumber',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return Column(
      children: [
        // Section headers (top row)
        Row(
          children: [
            for (int i = 0; i < 4; i++)
              Container(
                width:
                    colWidth * 3 +
                    colWidth +
                    paidColWidth, // 3 CRV + 1 NON-CRV + 1 PAID
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
                width: colWidth * 3,
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
              // TOTAL PAID (spans 1 column, paidColWidth)
              Container(
                width: paidColWidth,
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'TOTAL PAID',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
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
            for (int i = 0; i < 4; i++) ...[
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
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'SP',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
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
                  sectionHeaders[i],
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
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
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        // Grid rows (vertical scroll)
        SizedBox(
          height: 48.0 * rowCount,
          width: 4 * (colWidth * 4 + paidColWidth) + signColWidth,
          child: ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rowCount,
            itemBuilder: (context, row) {
              return Row(
                children: [
                  for (int sec = 0; sec < 4; sec++) ...[
                    for (int col = 0; col < 4; col++)
                      GestureDetector(
                        onTap:
                            _isReadOnly
                                ? null
                                : () => _editCell(row, sec * 5 + col),
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: _isReadOnly ? Colors.grey[50] : Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][sec * 5 + col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // Paid column
                    GestureDetector(
                      onTap:
                          _isReadOnly
                              ? null
                              : () => _editCell(row, sec * 5 + 4),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][sec * 5 + 4],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  // Customer sign
                  GestureDetector(
                    onTap: _isReadOnly ? null : () => _editCell(row, 20),
                    child: Container(
                      width: signColWidth,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black, width: 1),
                        color: _isReadOnly ? Colors.grey[50] : Colors.white,
                      ),
                      child: _buildSignatureCell(row, 20),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSignatureCell(int row, int col) {
    // Check if we have signature points for this cell
    final signatureKey = '$row-$col';
    final signaturePoints =
        _sheetsSignaturePoints[_currentSheetNumber]?[signatureKey];
    final customerName = _sheetsCustomerNames[_currentSheetNumber]?[signatureKey];

    if (signaturePoints != null && signaturePoints.isNotEmpty) {
      // If we have a customer name, show both name and signature
      if (customerName != null && customerName.isNotEmpty) {
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
            // Signature
            Expanded(
              flex: 3,
              child: CustomPaint(
                painter: SignaturePointsPainter(signaturePoints),
                size: const Size(double.infinity, double.infinity),
              ),
            ),
          ],
        );
      } else {
        // Just show signature without name
        return CustomPaint(
          painter: SignaturePointsPainter(signaturePoints),
          size: const Size(double.infinity, double.infinity),
        );
      }
    }

    // No signature, show empty cell or edit icon if in edit mode
    if (_isReadOnly) {
      return Container(); // Empty container for read-only mode
    } else {
      return const Icon(Icons.edit, size: 16, color: Colors.grey);
    }
  }

  Future<void> _saveSignaturePointsToSubcollection(
    String entryId,
    String sheetNumber,
    Map<String, List<SignaturePoint>> signaturePoints,
  ) async {
    try {
      print(
        'Saving signature points to subcollection for entry $entryId, sheet $sheetNumber',
      );

      final subcollectionRef = FirebaseFirestore.instance
          .collection('entries')
          .doc(entryId)
          .collection('signatures')
          .doc(sheetNumber);

      // Convert points to serializable format
      final serializedPoints = <String, List<Map<String, dynamic>>>{};
      final customerNames = <String, String>{}; // Store customer names

      signaturePoints.forEach((key, points) {
        serializedPoints[key] =
            points.map((point) {
              // Serialize each point into a map of its properties
              return {
                'dx': point.dx,
                'dy': point.dy,
                'type': point.type, // 0 for move, 1 for draw
              };
            }).toList();
        
        // Get customer name if available
        final customerName = _sheetsCustomerNames[sheetNumber]?[key];
        if (customerName != null && customerName.isNotEmpty) {
          customerNames[key] = customerName;
        }
      });

      await subcollectionRef.set({
        'points': serializedPoints,
        'customerNames': customerNames, // Add customer names to storage
        'createdAt': DateTime.now().toIso8601String(),
      });

      print('Signature points and customer names saved successfully');
    } catch (e) {
      print('Error saving signature points: $e');
      throw e;
    }
  }
}

class SignaturePointsPainter extends CustomPainter {
  final List<SignaturePoint> points;

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
      minX = min(minX, point.dx);
      maxX = max(maxX, point.dx);
      minY = min(minY, point.dy);
      maxY = max(maxY, point.dy);
    }

    final sigWidth = maxX - minX;
    final sigHeight = maxY - minY;

    if (sigWidth <= 0 || sigHeight <= 0) return;

    final scaleX = size.width / sigWidth;
    final scaleY = size.height / sigHeight;
    final scale = min(scaleX, scaleY) * 0.95;

    // Center the signature within the cell
    final offsetX = (size.width - sigWidth * scale) / 2;
    final offsetY = (size.height - sigHeight * scale) / 2;

    // Draw lines between all consecutive points
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];

      final p1Scaled = Offset(
        (p1.dx - minX) * scale + offsetX,
        (p1.dy - minY) * scale + offsetY,
      );
      final p2Scaled = Offset(
        (p2.dx - minX) * scale + offsetX,
        (p2.dy - minY) * scale + offsetY,
      );

      canvas.drawLine(p1Scaled, p2Scaled, paint);
    }
  }

  @override
  bool shouldRepaint(SignaturePointsPainter oldDelegate) =>
      oldDelegate.points != points;
}
