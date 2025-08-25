import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/auth_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:signature/signature.dart';

class NewEntryScreen extends ConsumerStatefulWidget {
  const NewEntryScreen({super.key});

  @override
  ConsumerState<NewEntryScreen> createState() => _NewEntryScreenState();
}

class _NewEntryScreenState extends ConsumerState<NewEntryScreen> {
  final int rowCount = 15;
  static const double colWidth = 80;
  static const double paidColWidth = 80;
  static const double signColWidth = 220;
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
  final List<String> columnHeaders = [
    // ALUMINIUM
    'SW', 'SC', 'C', 'SP', 'ALUMINIUM',
    // GLASS
    'SW', 'SC', 'C', 'SP', 'GLASS',
    // #1 PETE PLASTIC
    'SW', 'SC', 'C', 'SP', 'PETE',
    // OTHER COMMODITIES
    'SW', 'SC', 'C', 'SP', 'CODE',
    // CUSTOMER SIGN
    'SIGN/ID',
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
  late List<List<String>> gridData;
  final ScrollController _horizontalController = ScrollController();

  Map<String, Uint8List> _signatureImages = {};

  // Map to store grid data for each sheet
  final Map<int, List<List<String>>> _sheetsGridData = {};
  // Map to store signatures for each sheet
  final Map<int, Map<String, Uint8List>> _sheetsSignatures = {};

  // Loading state for submission
  bool _isSubmitting = false;

  // Map to cache loaded signature images
  final Map<String, Uint8List> _loadedSignatures = {};

  // Map to store signature points for each sheet
  final Map<int, Map<String, List<Point>>> _sheetsSignaturePoints = {};

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
    // Initialize the first sheet
    _initializeSheet(1);
    // Calculate initial totals
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateAndUpdateTotals();
    });
  }

  void _initializeSheet(int sheetNumber) {
    if (!_sheetsGridData.containsKey(sheetNumber)) {
      _sheetsGridData[sheetNumber] = List.generate(
        rowCount + 1, // +1 for the totals row
        (_) => List.generate(21, (_) => ''),
      );
      _sheetsSignatures[sheetNumber] = {};
      _sheetsSignaturePoints[sheetNumber] = {};
    } else {
      // Ensure the totals row exists
      if (_sheetsGridData[sheetNumber]!.length <= rowCount) {
        _sheetsGridData[sheetNumber]!.add(List.generate(21, (_) => ''));
      }
    }
  }

  List<List<String>> get _currentGridData =>
      _sheetsGridData[_currentSheetNumber]!;
  Map<String, Uint8List> get _currentSignatures =>
      _sheetsSignatures[_currentSheetNumber]!;

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  // Helper method to check if a column is SP or SW
  bool _isSpOrSwColumn(int col) {
    // SW columns: 0, 5, 10, 15 (first column of each section)
    // SP columns: 3, 8, 13, 18 (fourth column of each section)
    return col == 0 ||
        col == 3 ||
        col == 5 ||
        col == 8 ||
        col == 10 ||
        col == 13 ||
        col == 15 ||
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

  // Method to calculate totals for each column and update the last row
  void _calculateAndUpdateTotals() {
    if (_currentGridData.length <= rowCount) {
      _currentGridData.add(List.generate(21, (_) => ''));
    }

    // Calculate totals for each column (0 to 20)
    for (int col = 0; col < 21; col++) {
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

    // Calculate grand total of all "Total Paid" columns (TP-AL, TP-GL, TP-PL, TP-CODE)
    // These are at columns 4, 9, 14, and 19 (5th column of each section)
    double grandTotal = 0.0;
    final totalPaidColumns = [4, 9, 14, 19];

    for (int col in totalPaidColumns) {
      if (col < _currentGridData[rowCount].length) {
        grandTotal += _parseCellValue(_currentGridData[rowCount][col]);
      }
    }

    // Update the last cell (column 20) with the grand total
    if (_currentGridData[rowCount].length > 20) {
      _currentGridData[rowCount][20] = grandTotal.toStringAsFixed(2);
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

    if (col == 20) {
      await context.push(
        '/customer',
        extra: {
          'onSignatureComplete': (Uint8List signatureBytes) {
            setState(() {
              _currentSignatures['$row-$col'] = signatureBytes;
              _currentGridData[row][col] = 'Signed';
            });
            // Calculate totals after updating the cell
            _calculateAndUpdateTotals();
          },
          'onSignaturePointsComplete': (List<Point> signaturePoints) {
            setState(() {
              _sheetsSignaturePoints[_currentSheetNumber] ??= {};
              _sheetsSignaturePoints[_currentSheetNumber]!['$row-$col'] =
                  signaturePoints;
              print(
                'Saved ${signaturePoints.length} signature points for cell $row-$col',
              );
            });
          },
        },
      );
    } else if (col == 17) {
      // CODE column in OTHER COMMODITIES section
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
                ],
              ),
            ),
          );
        },
      );
      if (result != null) {
        setState(() {
          _currentGridData[row][col] = result;
        });
        // Calculate totals after updating the cell
        _calculateAndUpdateTotals();
      }
    } else {
      TextEditingController controller = TextEditingController(text: value);
      String? result = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Enter value for cell [${row + 1}, ${col + 1}]'),
                SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Enter value',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
                SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, controller.text),
                  child: Text('Save'),
                ),
                SizedBox(height: 12),
              ],
            ),
          );
        },
      );
      if (result != null) {
        setState(() {
          _currentGridData[row][col] = result;
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
    TextEditingController controllerA = TextEditingController();
    TextEditingController controllerB = TextEditingController();

    // Parse existing value if it's in a/b format
    if (currentValue.contains('/')) {
      final parts = currentValue.split('/');
      if (parts.length == 2) {
        controllerA.text = parts[0].trim();
        controllerB.text = parts[1].trim();
      }
    } else if (currentValue.isNotEmpty) {
      controllerA.text = currentValue;
    }

    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Enter values for cell [${row + 1}, ${col + 1}] (Long Press Mode)',
              ),
              SizedBox(height: 12),
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
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: Text('Cancel'),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
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
                  ),
                ],
              ),
              SizedBox(height: 12),
            ],
          ),
        );
      },
    );

    if (result != null) {
      setState(() {
        _currentGridData[row][col] = '${result['a']}/${result['b']}';
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
    return ListTile(
      title: Text(code),
      subtitle: Text(description),
      onTap: () => Navigator.pop(context, code),
    );
  }

  Widget _buildSignatureCell(int row, int col) {
    final signatureKey = '$row-$col';

    // Check if we have local signature points (for current session)
    final signaturePoints =
        _sheetsSignaturePoints[_currentSheetNumber]?[signatureKey];

    if (signaturePoints != null && signaturePoints.isNotEmpty) {
      return CustomPaint(
        size: Size.infinite,
        painter: SignaturePointsPainter(signaturePoints),
      );
    }

    // Fallback to text for empty cells
    return Text(_currentGridData[row][col], overflow: TextOverflow.ellipsis);
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
    final String today = DateFormat('MM/dd/yyyy').format(DateTime.now());
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'RC340765.001',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'Camacho RECYCLING',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            '1935 Anderson Road',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            'Davis CA',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            '95616',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 14,
                            ),
                          ),
                        ],
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
                        child: Container(
                          child: Text(
                            today,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
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
                ],
              ),
            ),
          ],
        ),
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
                          onTap: () => _editCell(row, sec * 5 + col),
                          onLongPress:
                              _isSpOrSwColumn(sec * 5 + col)
                                  ? () => _editCell(
                                    row,
                                    sec * 5 + col,
                                    isLongPress: true,
                                  )
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
                              _currentGridData[row][sec * 5 + col],
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      // Paid column
                      GestureDetector(
                        onTap: () => _editCell(row, sec * 5 + 4),
                        child: Container(
                          width: paidColWidth,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 1),
                            color: Colors.white,
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
                      onTap: () => _editCell(row, 20),
                      child: Container(
                        width: signColWidth,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          color: Colors.white,
                        ),
                        child: _buildSignatureCell(row, 20),
                      ),
                    ),
                  ],
                );
              },
            ),
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
              Container(
                width: paidColWidth,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border.all(color: Colors.black, width: 1),
                ),
                child: Text(
                  'TP',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              // Grand Total
              Container(
                width: signColWidth,
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
              // Ensure gridData has an extra row for this editable row
              if (_currentGridData.length <= rowCount) {
                _currentGridData.add(List.generate(21, (_) => ''));
              }
              return Row(
                children: [
                  for (int col = 0; col < 21; col++)
                    Container(
                      width: colWidthsForEditableRow(col),
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black, width: 1),
                        color:
                            col == 20
                                ? Colors
                                    .orange[50] // Special color for grand total cell
                                : Colors
                                    .blue[50], // Different color to indicate it's the totals row
                      ),
                      child: Text(
                        _currentGridData[rowCount][col],
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color:
                              col == 20 ? Colors.orange[800] : Colors.black87,
                          fontSize: col == 20 ? 14 : 12,
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
    if (col == 20) return signColWidth;
    if (col % 5 == 4) return paidColWidth;
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
      'email': email,
      'createdAt': DateTime.now().toIso8601String(),
      'sheets': {},
    };

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

        // Convert to safe format
        final safeGridData = _convertGridDataToSafeFormat(sanitizedGridData);

        entryData['sheets'][sheetNumber.toString()] = {
          'data': safeGridData,
          'hasSignatures': signaturePoints.isNotEmpty,
          'signatureCount': signaturePoints.length,
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

    return entryData;
  }

  // Simple save method that just saves basic info
  Future<void> _saveBasicEntry(String userId, String userName) async {
    try {
      print('=== SAVING BASIC ENTRY ===');

      final entryRef = FirebaseFirestore.instance.collection('entries').doc();

      final basicEntry = {
        'userId': userId,
        'userName': userName,
        'createdAt': DateTime.now().toIso8601String(),
        'entryType': 'basic',
        'hasGridData': false,
        'sheetCount': _sheetsGridData.length,
      };

      print('Basic entry data: $basicEntry');
      await entryRef.set(basicEntry);
      print('Basic entry saved successfully');
    } catch (e) {
      print('Basic entry save failed: $e');
      throw e;
    }
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

  // Test method to create minimal valid data
  Future<Map<String, dynamic>> _createTestData(
    String userId,
    String email,
  ) async {
    return {
      'userId': userId,
      'email': email,
      'createdAt': DateTime.now().toIso8601String(),
      'sheets': {
        '1': {
          'data': {
            'rows': 15,
            'columns': 21,
            'values': List.generate(15 * 21, (index) => ''),
          },
          'signatures': {},
        },
      },
    };
  }

  // Basic Firestore connectivity test
  Future<void> _testFirestoreConnection() async {
    try {
      print('=== TESTING FIRESTORE CONNECTION ===');

      final testRef = FirebaseFirestore.instance.collection('test').doc();
      final testData = {
        'test': true,
        'timestamp': DateTime.now().toIso8601String(),
        'message': 'Connection test',
      };

      print('Test data: $testData');
      await testRef.set(testData);
      print('Firestore connection test successful');

      // Clean up test document
      await testRef.delete();
      print('Test document cleaned up');
    } catch (e) {
      print('Firestore connection test failed: $e');
      throw Exception('Firestore connection failed: $e');
    }
  }

  // Minimal test to isolate Firestore issue
  Future<void> _testMinimalFirestore() async {
    try {
      print('=== MINIMAL FIRESTORE TEST ===');

      // Test 1: Basic document creation
      final testRef = FirebaseFirestore.instance.collection('test').doc();
      final minimalData = {'test': 'minimal', 'timestamp': '2024-01-01'};

      print('Test 1: Creating minimal document...');
      await testRef.set(minimalData);
      print('Test 1: Success');

      // Test 2: Document with array
      final testRef2 = FirebaseFirestore.instance.collection('test').doc();
      final arrayData = {
        'test': 'array',
        'data': ['a', 'b', 'c'],
      };

      print('Test 2: Creating document with array...');
      await testRef2.set(arrayData);
      print('Test 2: Success');

      // Test 3: Document with nested structure (similar to your data)
      final testRef3 = FirebaseFirestore.instance.collection('test').doc();
      final nestedData = {
        'userId': 'test-user',
        'userName': 'Test User',
        'createdAt': '2024-01-01',
        'sheets': {
          '1': {
            'data': {
              'rows': 1,
              'columns': 21,
              'values': [
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
                '',
              ],
            },
            'signatures': {},
          },
        },
      };

      print('Test 3: Creating document with nested structure...');
      await testRef3.set(nestedData);
      print('Test 3: Success');

      // Clean up
      await testRef.delete();
      await testRef2.delete();
      await testRef3.delete();
      print('All test documents cleaned up');
    } catch (e) {
      print('Minimal Firestore test failed: $e');
      print('Error type: ${e.runtimeType}');
      throw e;
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

  // Helper method to save signature points to subcollection
  Future<void> _saveSignaturePointsToSubcollection(
    String entryId,
    String sheetNumber,
    Map<String, List<Point>> signaturePoints,
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

      signaturePoints.forEach((key, points) {
        serializedPoints[key] =
            points.map((point) {
              // Serialize each point into a map of its properties
              return {
                'dx': point.offset.dx,
                'dy': point.offset.dy,
                'type': point.type.index, // 0 for move, 1 for draw
              };
            }).toList();
      });

      await subcollectionRef.set({
        'points': serializedPoints,
        'createdAt': DateTime.now().toIso8601String(),
      });

      print('Signature points saved successfully');
    } catch (e) {
      print('Error saving signature points: $e');
      throw e;
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: 'Home',
            onPressed: () => context.go('/home'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              try {
                await ref.read(authControllerProvider.notifier).signOut();
                if (mounted) {
                  context.go('/');
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error signing out: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Main scrollable content area
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _horizontalController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_buildStaticDetails(), _buildGrid()],
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
                        'Sheet $_currentSheetNumber',
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
                                });
                                // Calculate totals for the new sheet
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _calculateAndUpdateTotals();
                                });
                              },
                              child: const Text('Previous Sheet'),
                            ),
                          const SizedBox(width: 16),
                          SizedBox(
                            height: 40,
                            width: MediaQuery.of(context).size.width * 0.2,
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _currentSheetNumber++;
                                  _initializeSheet(_currentSheetNumber);
                                });
                                // Calculate totals for the new sheet
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _calculateAndUpdateTotals();
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
                  // Submit button
                  SizedBox(
                    width: double.infinity,
                    height: 45,
                    child: ElevatedButton.icon(
                      onPressed:
                          _isSubmitting
                              ? null
                              : () async {
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

                                  _logSubmissionProgress(
                                    'Testing Firestore connection...',
                                  );

                                  // Test Firestore connection first
                                  await _testFirestoreConnection();

                                  _logSubmissionProgress(
                                    'Running minimal Firestore tests...',
                                  );

                                  // Run minimal tests to isolate the issue
                                  await _testMinimalFirestore();

                                  _logSubmissionProgress(
                                    'Preparing Firestore data',
                                  );

                                  // For debugging: try with test data first
                                  Map<String, dynamic> entryData;
                                  try {
                                    entryData = await _prepareEntryData(
                                      user.uid,
                                      user.email!,
                                    );
                                  } catch (e) {
                                    print('Error preparing entry data: $e');
                                    // Fallback to test data
                                    print('Falling back to test data');
                                    entryData = await _createTestData(
                                      user.uid,
                                      user.email!,
                                    );
                                  }

                                  // Validate data size before attempting to save
                                  if (!_validateDataSize(entryData)) {
                                    setState(() {
                                      _isSubmitting = false;
                                    });
                                    return;
                                  }

                                  // Save the full entry data
                                  final entryRef =
                                      FirebaseFirestore.instance
                                          .collection('entries')
                                          .doc();
                                  await entryRef.set(entryData);

                                  // Save signature points to subcollections
                                  for (final entry
                                      in _sheetsSignaturePoints.entries) {
                                    final sheetNumber = entry.key;
                                    final signaturePoints = entry.value;

                                    if (signaturePoints.isNotEmpty) {
                                      try {
                                        await _saveSignaturePointsToSubcollection(
                                          entryRef.id,
                                          sheetNumber.toString(),
                                          signaturePoints,
                                        );
                                        print(
                                          'Saved signature points for sheet $sheetNumber',
                                        );
                                      } catch (e) {
                                        print(
                                          'Error saving signature points for sheet $sheetNumber: $e',
                                        );
                                        // Continue with other sheets even if one fails
                                      }
                                    }
                                  }

                                  _logSubmissionProgress(
                                    'Successfully saved to Firestore',
                                  );

                                  if (!mounted) return;

                                  // Show success message
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Entry submitted successfully',
                                      ),
                                      backgroundColor: Colors.green,
                                    ),
                                  );

                                  // Wait a short moment to ensure the message is visible
                                  await Future.delayed(
                                    const Duration(milliseconds: 500),
                                  );

                                  // Navigate to submitted screen
                                  if (mounted) {
                                    context.go('/submitted');
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
                              },
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
