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

  Future<void> _approveEntry() async {
    if (_entryData == null) return;
    
    try {
      await FirebaseFirestore.instance
          .collection('entries')
          .doc(widget.entryId)
          .update({
        'approved': true,
        'approvedAt': DateTime.now().toIso8601String(),
      });
      
      setState(() {
        _entryData!['approved'] = true;
        _entryData!['approvedAt'] = DateTime.now().toIso8601String();
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Entry approved successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error approving entry: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

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
  double _parseCellValue(String value) {
    if (value.isEmpty) return 0.0;

    // Handle dual values like "2/4" - calculate as 2 + 4 = 6
    if (value.contains('/')) {
      final parts = value.split('/');
      if (parts.length == 2) {
        final part1 = double.tryParse(parts[0].trim()) ?? 0.0;
        final part2 = double.tryParse(parts[1].trim()) ?? 0.0;
        return part1 + part2;
      }
    }

    // Handle single values
    return double.tryParse(value.trim()) ?? 0.0;
  }

  // Helper method to get column width for totals row
  double _getColumnWidth(int col) {
    if (col < 4) return colWidth; // ALUMINIUM
    if (col == 4) return paidColWidth; // ALUMINIUM paid
    if (col < 9) return colWidth; // GLASS
    if (col == 9) return paidColWidth; // GLASS paid
    if (col < 14) return colWidth; // PETE PLASTIC
    if (col == 14) return paidColWidth; // PETE PLASTIC paid
    if (col == 15) return colWidth; // CODE
    if (col < 20) return colWidth; // OTHER COMMODITIES
    if (col == 20) return paidColWidth; // OTHER COMMODITIES paid
    return colWidth; // Default
  }

  void _editCell(int row, int col, {bool isLongPress = false}) {
    if (_isReadOnly) return;

    // Handle SP and SW columns with long press for dual input
    if (_isSpOrSwColumn(col) && isLongPress) {
      // For view-only mode, we'll just show a simple dialog
      _showDualInputDialog(row, col);
      return;
    }

    // Handle signature cells (column 21)
    if (col == 21) {
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

  Future<void> _showDualInputDialog(int row, int col) async {
    TextEditingController controllerA = TextEditingController();
    TextEditingController controllerB = TextEditingController();

    // Parse existing value if it's in a/b format
    String currentValue = _currentGridData[row][col];
    if (currentValue.contains('/')) {
      final parts = currentValue.split('/');
      if (parts.length == 2) {
        controllerA.text = parts[0].trim();
        controllerB.text = parts[1].trim();
      }
    } else if (currentValue.isNotEmpty) {
      controllerA.text = currentValue;
    }

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Enter values for cell [${row + 1}, ${col + 1}] (Long Press Mode)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controllerA,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter value A',
                  border: OutlineInputBorder(),
                  labelText: 'Value A',
                ),
              ),
              SizedBox(height: 8),
              TextField(
                controller: controllerB,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Enter value B',
                  border: OutlineInputBorder(),
                  labelText: 'Value B',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final valueA = controllerA.text.trim();
                final valueB = controllerB.text.trim();
                if (valueA.isNotEmpty && valueB.isNotEmpty) {
                  Navigator.pop(context, {'a': valueA, 'b': valueB});
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please enter both values'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      setState(() {
        _currentGridData[row][col] = '${result['a']}/${result['b']}';
      });
    }
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
    final entryDate = _entryData?['entryDate'] != null 
        ? DateTime.parse(_entryData!['entryDate'])
        : DateTime.now();
    final location = _entryData?['location'] as String? ?? 'Unknown Location';
    final isApproved = _entryData?['approved'] == true;
    final reference = _entryData?['reference'] as String? ?? 'N/A';
    final serialNumber = _entryData?['serialNumber'] as String? ?? 'N/A';
    
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
          // Header row with location and approval status
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Location: $location',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Date: ${DateFormat('MM/dd/yyyy').format(entryDate)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isApproved ? Colors.green[100] : Colors.orange[100],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isApproved ? Colors.green : Colors.orange,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      isApproved ? 'APPROVED' : 'PENDING',
                      style: TextStyle(
                        color: isApproved ? Colors.green[800] : Colors.orange[800],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (!isApproved)
                    ElevatedButton.icon(
                      onPressed: () => _approveEntry(),
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Details row with reference and serial number
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reference: $reference',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Serial Number: $serialNumber',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Sheet $_currentSheetNumber of ${_sheetsGridData.length}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Created: ${DateFormat('MM/dd/yyyy HH:mm').format(_createdAt ?? DateTime.now())}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _horizontalController,
      child: Column(
        children: [
          // Section headers (top row)
          Row(
            children: [
              for (int i = 0; i < 4; i++)
                Container(
                  width: (colWidth * 3 + colWidth + paidColWidth),
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
              // Extra Total Paid block (visual alignment like NewEntry)
              Container(
                width: colWidth,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  border: Border(
                    top: BorderSide(color: Colors.black, width: 2),
                    right: BorderSide(color: Colors.black, width: 2),
                    bottom: BorderSide.none,
                    left: BorderSide(color: Colors.black, width: 2),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '',
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
                // Optional label alignment like NewEntry (Total Paid small box)
                if (i == 3)
                  Container(
                    width: colWidth,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      border: const Border(
                        left: BorderSide(color: Colors.black, width: 1),
                        right: BorderSide(color: Colors.black, width: 1),
                      ),
                    ),
                    child: const Text(
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
                    border: const Border(
                      top: BorderSide.none,
                      right: BorderSide(color: Colors.black, width: 2),
                      bottom: BorderSide(color: Colors.black, width: 0),
                      left: BorderSide(color: Colors.black, width: 2),
                    ),
                  ),
                  child: const Column(
                    children: [
                      Text(
                        'Total Paid',
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
                child: const Text(
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
              // ALUMINIUM section headers (columns 0-4)
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
              // GLASS section headers (columns 5-9)
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
              // #1 PETE PLASTIC section headers (columns 10-14)
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
          // Grid rows (vertical scroll)
          SizedBox(
            height: 48.0 * rowCount,
            width: 3 * (colWidth * 4 + paidColWidth) + colWidth + (colWidth * 4 + paidColWidth + signColWidth),
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: rowCount,
              itemBuilder: (context, row) {
                return Row(
                  children: [
                    // ALUMINIUM section (columns 0-4)
                    for (int col = 0; col < 4; col++)
                      GestureDetector(
                        onTap: _isReadOnly ? null : () => _editCell(row, col),
                        onLongPress: _isReadOnly ? null : (_isSpOrSwColumn(col) ? () => _editCell(row, col, isLongPress: true) : null),
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: _isReadOnly ? Colors.grey[50] : Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // ALUMINIUM paid column (column 4)
                    GestureDetector(
                      onTap: _isReadOnly ? null : () => _editCell(row, 4),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
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
                        onTap: _isReadOnly ? null : () => _editCell(row, col),
                        onLongPress: _isReadOnly ? null : (_isSpOrSwColumn(col) ? () => _editCell(row, col, isLongPress: true) : null),
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: _isReadOnly ? Colors.grey[50] : Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // GLASS paid column (column 9)
                    GestureDetector(
                      onTap: _isReadOnly ? null : () => _editCell(row, 9),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
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
                        onTap: _isReadOnly ? null : () => _editCell(row, col),
                        onLongPress: _isReadOnly ? null : (_isSpOrSwColumn(col) ? () => _editCell(row, col, isLongPress: true) : null),
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: _isReadOnly ? Colors.grey[50] : Colors.white,
                          ),
                          child: Text(
                            _currentGridData[row][col],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // #1 PETE PLASTIC paid column (column 14)
                    GestureDetector(
                      onTap: _isReadOnly ? null : () => _editCell(row, 14),
                      child: Container(
                        width: paidColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
                        ),
                        child: Text(
                          _currentGridData[row][14],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    // CODE column (column 15)
                    GestureDetector(
                      onTap: _isReadOnly ? null : () => _editCell(row, 15),
                      child: Container(
                        width: colWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
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
                        onTap: _isReadOnly ? null : () => _editCell(row, col),
                        onLongPress: _isReadOnly ? null : (_isSpOrSwColumn(col) ? () => _editCell(row, col, isLongPress: true) : null),
                        child: Container(
                          width: colWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: _isReadOnly ? Colors.grey[50] : Colors.white,
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
                        color: _isReadOnly ? Colors.grey[50] : Colors.white,
                      ),
                      child: Text(
                        _currentGridData[row][20],
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Customer sign (column 21)
                    GestureDetector(
                      onTap: _isReadOnly ? null : () => _editCell(row, 21),
                      child: Container(
                        width: signColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: _isReadOnly ? Colors.grey[50] : Colors.white,
                        ),
                        child: _buildSignatureCell(row, 21),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          // Totals header row (matching new entry screen)
          Row(
            children: [
              // ALUMINIUM totals
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
              // GLASS totals
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
              // #1 PETE PLASTIC totals
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
                  'TP-PE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // CODE totals
              Container(
                width: colWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'Code',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // OTHER COMMODITIES totals
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
              // SP column for OTHER COMMODITIES
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
              // Total Paid column
              // Grand Total (merged TP and GRAND TOTAL)
              Container(
                width: signColWidth + paidColWidth,
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
          // Add an empty editable row below with calculated totals
          Builder(
            builder: (context) {
              // Calculate totals for each column
              final totals = List.generate(22, (col) {
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
                  return count > 0 ? 'Count: $count' : '';
                } else {
                  double total = 0.0;
                  for (int row = 0; row < rowCount; row++) {
                    if (row < _currentGridData.length &&
                        col < _currentGridData[row].length) {
                      total += _parseCellValue(_currentGridData[row][col]);
                    }
                  }
                  return total.toStringAsFixed(2);
                }
              });

              // Calculate grand total of the "Total Paid" column (column 20)
              double grandTotal = 0.0;
              for (int row = 0; row < rowCount; row++) {
                if (row < _currentGridData.length &&
                    20 < _currentGridData[row].length) {
                  grandTotal += _parseCellValue(_currentGridData[row][20]);
                }
              }

              return Row(
                children: [
                  for (int col = 0; col < 20; col++)
                    Container(
                      width: _getColumnWidth(col),
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black, width: 1),
                        color: Colors.blue[50], // Different color to indicate it's the totals row
                      ),
                      child: Text(
                        totals[col],
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
                    width: signColWidth + paidColWidth,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 1),
                      color: Colors.orange[50], // Special color for grand total cell
                    ),
                    child: Text(
                      grandTotal.toStringAsFixed(2),
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
