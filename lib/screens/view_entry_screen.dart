import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:signature/signature.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

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

  /// Total width for header and grid (same as New Entry) so header and table align.
  double get _totalGridWidth =>
      4 * (colWidth * 4 + paidColWidth) + signColWidth + 32.0 + colWidth;

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
      _entryData = Map<String, dynamic>.from(data);

      // Fallback: if entry has no locationCertification (e.g. older entries), fetch from location doc
      final locationId = _entryData!['location'] as String?;
      final existingCert = _entryData!['locationCertification'] as String?;
      if ((existingCert == null || existingCert.isEmpty) && locationId != null && locationId.isNotEmpty) {
        try {
          final locSnap = await FirebaseFirestore.instance
              .collection('locations')
              .doc(locationId)
              .get();
          if (locSnap.exists) {
            final cert = locSnap.data()?['certification'] as String?;
            if (cert != null && cert.isNotEmpty) {
              _entryData!['locationCertification'] = cert;
            }
          }
        } catch (_) {}
      }

      _userEmail = _entryData!['email'] ?? '';
      _createdAt = DateTime.parse(_entryData!['createdAt']);

      print(
        'ViewEntryScreen: Entry data loaded - Email: $_userEmail, Created: $_createdAt',
      );

      // Load sheets data
      final sheets = _entryData!['sheets'] as Map<String, dynamic>? ?? {};
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

  // Helper method to convert signature points to PDF image
  Future<pw.ImageProvider?> _signaturePointsToPdfImage(
    List<SignaturePoint> points,
    double width,
    double height,
    pw.Document pdf,
  ) async {
    if (points.length < 2) return null;

    // Find bounding box
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
    if (sigWidth <= 0 || sigHeight <= 0) return null;

    // Create a picture recorder to render the signature
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // Calculate scale to fit in the cell
    final scaleX = width / sigWidth;
    final scaleY = height / sigHeight;
    final scale = min(scaleX, scaleY) * 0.9;

    // Center the signature
    final offsetX = (width - sigWidth * scale) / 2;
    final offsetY = (height - sigHeight * scale) / 2;

    // Draw signature lines
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];

      if (p1.type == 1 || p2.type == 1) {
        final x1 = (p1.dx - minX) * scale + offsetX;
        final y1 = (p1.dy - minY) * scale + offsetY;
        final x2 = (p2.dx - minX) * scale + offsetX;
        final y2 = (p2.dy - minY) * scale + offsetY;

        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
      }
    }

    // Convert picture to image
    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;

    final imageBytes = byteData.buffer.asUint8List();
    
    // Create PDF image
    return pw.MemoryImage(imageBytes);
  }

  Future<void> _generateAndSharePDF() async {
    if (_entryData == null) return;

    try {
      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Generating PDF...'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      final pdf = pw.Document();
      final entryDate = _entryData!['entryDate'] != null 
          ? DateTime.parse(_entryData!['entryDate'])
          : DateTime.now();
      final location = _entryData!['location'] as String? ?? 'Unknown Location';
      final isApproved = _entryData!['approved'] == true;
      final reference = _entryData!['reference'] as String? ?? 'N/A';
      final locationCertificationPdf = _entryData!['locationCertification'] as String?;
      final certificationDisplayPdf = (locationCertificationPdf != null && locationCertificationPdf.isNotEmpty)
          ? locationCertificationPdf
          : reference;
      final serialNumber = _entryData!['serialNumber'] as String? ?? 'N/A';

      // Same content as scroll view: static details (LOG SHEET + legends) + grid only; fit to page preserving aspect ratio
      final locationName = _entryData!['locationName'] as String?;
      final locationAddress = _entryData!['locationAddress'] as String?;
      final locationIdOrName = _entryData!['location'] as String? ?? '';
      final locationDisplay = (locationName != null && locationName.isNotEmpty)
          ? locationName
          : (locationAddress != null && locationAddress.isNotEmpty)
              ? locationAddress
              : (locationIdOrName.isNotEmpty ? locationIdOrName : 'Unknown Location');
      final formattedDate = DateFormat('MM/dd/yyyy').format(entryDate);
      const double pdfCellWidth = 32.0;
      const double pdfPaidCellWidth = 40.0;
      const double pdfSignCellWidth = 100.0;
      final double pdfContentWidth = 20 * pdfCellWidth + 4 * pdfPaidCellWidth + pdfSignCellWidth;

      for (final sheetEntry in _sheetsGridData.entries) {
        final sheetNumber = sheetEntry.key;
        final gridData = sheetEntry.value;

        final signatureImages = <String, pw.ImageProvider?>{};
        const double signCellHeight = 20.0;

        for (int row = 0; row < rowCount; row++) {
          final signatureKey = '$row-21';
          final signaturePoints = _sheetsSignaturePoints[sheetNumber]?[signatureKey];
          if (signaturePoints != null && signaturePoints.isNotEmpty) {
            final imageProvider = await _signaturePointsToPdfImage(
              signaturePoints,
              pdfSignCellWidth - 4,
              signCellHeight - 4,
              pdf,
            );
            signatureImages[signatureKey] = imageProvider;
          }
        }

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4.landscape,
            margin: const pw.EdgeInsets.all(10),
            build: (pw.Context context) {
              return pw.FittedBox(
                fit: pw.BoxFit.contain,
                alignment: pw.Alignment.topLeft,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisSize: pw.MainAxisSize.min,
                  children: [
                    _buildPDFStaticDetails(pdfContentWidth, certificationDisplayPdf, locationDisplay, formattedDate),
                    pw.SizedBox(height: 5),
                    _buildPDFGrid(gridData, sheetNumber, signatureImages),
                  ],
                ),
              );
            },
          ),
        );
      }

      // Save PDF directly to file
      final pdfBytes = await pdf.save();
      
      // Create filename using already defined variables (use locationDisplay for readable name)
      final locationNameForFile = locationDisplay.replaceAll(' ', '_').replaceAll('/', '_');
      final fileName = 'Entry_${locationNameForFile}_${DateFormat('yyyyMMdd').format(entryDate)}_${widget.entryId.substring(0, 8)}.pdf';
      
      // Save to file first
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(pdfBytes);
      
      // Share the PDF file (opens share dialog to save/share)
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: fileName,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF saved: $fileName'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating PDF: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// PDF version of the scroll-view header: LOG SHEET block, BASIC LEGEND, OTHER COMMODITIES + DATE (same layout as on screen).
  pw.Widget _buildPDFStaticDetails(double contentWidth, String reference, String address, String formattedDate) {
    final w1 = contentWidth * (2 / 11);
    final w2 = contentWidth * (3 / 11);
    final w3 = contentWidth * (6 / 11);
    const double greyBarWidthFactor = 0.75;
    const double leftPaddingUnderLabel = 5;
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: w1,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text('LOG SHEET', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                pw.SizedBox(height: 4),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      mainAxisSize: pw.MainAxisSize.min,
                      children: [
                        pw.Text('CERTIFICATION #', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                        pw.Text('RECYCLER NAME', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                        pw.Text('ADDRESS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                      ],
                    ),
                    pw.SizedBox(width: 4),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        mainAxisSize: pw.MainAxisSize.min,
                        children: [
                          pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text(reference, style: const pw.TextStyle(fontSize: 7))),
                          pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text('Camacho RECYCLING', style: const pw.TextStyle(fontSize: 7))),
                          pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text(address.length > 40 ? '${address.substring(0, 40)}...' : address, style: const pw.TextStyle(fontSize: 7), maxLines: 2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(
            width: w2,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Container(
                  width: w2 * greyBarWidthFactor,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                  color: PdfColors.grey300,
                  child: pw.Text('BASIC LEGEND', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                ),
                pw.SizedBox(height: 1),
                pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text('SW   SEGREGATED BY WEIGHT', style: const pw.TextStyle(fontSize: 6))),
                pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text('SC   SEGREGATE BY COUNT', style: const pw.TextStyle(fontSize: 6))),
                pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text('C    COMMINGLED (MIX CRV/NON-CRV)', style: const pw.TextStyle(fontSize: 6))),
                pw.Padding(padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel), child: pw.Text('SP   SCRAP ONLY (NON-CRV)', style: const pw.TextStyle(fontSize: 6))),
              ],
            ),
          ),
          pw.SizedBox(
            width: w3,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Container(
                  width: w3 * greyBarWidthFactor,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                  color: PdfColors.grey300,
                  child: pw.Text('OTHER COMMODITIES LEGEND', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                ),
                pw.SizedBox(height: 2),
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel),
                  child: pw.Text('B1 BIMETAL  P#2 HDPE  P#3 PVC  P#4 LDPE  P#5 PP  P#6 PS  P#7 Other', style: const pw.TextStyle(fontSize: 5)),
                ),
                pw.SizedBox(height: 2),
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: leftPaddingUnderLabel),
                  child: pw.Row(
                    mainAxisSize: pw.MainAxisSize.min,
                    children: [
                      pw.Text('DATE: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7)),
                      pw.Text(formattedDate, style: const pw.TextStyle(fontSize: 7)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPDFGrid(
    List<List<String>> gridData,
    int sheetNumber,
    Map<String, pw.ImageProvider?> signatureImages,
  ) {
    // Reduced sizes to fit on one page
    const double cellWidth = 32.0;
    const double cellHeight = 20.0;
    const double paidCellWidth = 40.0;
    const double signCellWidth = 100.0;

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.black, width: 1),
      columnWidths: {
        0: const pw.FixedColumnWidth(cellWidth), // SW
        1: const pw.FixedColumnWidth(cellWidth), // SC
        2: const pw.FixedColumnWidth(cellWidth), // C
        3: const pw.FixedColumnWidth(cellWidth), // SP
        4: const pw.FixedColumnWidth(paidCellWidth), // ALUMINIUM paid
        5: const pw.FixedColumnWidth(cellWidth), // SW
        6: const pw.FixedColumnWidth(cellWidth), // SC
        7: const pw.FixedColumnWidth(cellWidth), // C
        8: const pw.FixedColumnWidth(cellWidth), // SP
        9: const pw.FixedColumnWidth(paidCellWidth), // GLASS paid
        10: const pw.FixedColumnWidth(cellWidth), // SW
        11: const pw.FixedColumnWidth(cellWidth), // SC
        12: const pw.FixedColumnWidth(cellWidth), // C
        13: const pw.FixedColumnWidth(cellWidth), // SP
        14: const pw.FixedColumnWidth(paidCellWidth), // PETE paid
        15: const pw.FixedColumnWidth(cellWidth), // CODE
        16: const pw.FixedColumnWidth(cellWidth), // SW
        17: const pw.FixedColumnWidth(cellWidth), // SC
        18: const pw.FixedColumnWidth(cellWidth), // C
        19: const pw.FixedColumnWidth(cellWidth), // SP
        20: const pw.FixedColumnWidth(paidCellWidth), // OTHER paid
        21: const pw.FixedColumnWidth(signCellWidth), // SIGN
      },
      children: [
        // Section headers row - all 22 columns
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            // ALUMINIUM section (5 cells)
            _buildPDFCell('ALUMINIUM', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', paidCellWidth, cellHeight, PdfColors.grey300),
            // GLASS section (5 cells)
            _buildPDFCell('GLASS', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', paidCellWidth, cellHeight, PdfColors.grey300),
            // PETE PLASTIC section (5 cells)
            _buildPDFCell('#1 PETE PLASTIC', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', paidCellWidth, cellHeight, PdfColors.grey300),
            // CODE (1 cell)
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            // OTHER COMMODITIES section (5 cells)
            _buildPDFCell('OTHER COMMODITIES', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', cellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('', paidCellWidth, cellHeight, PdfColors.grey300),
            // SIGN (1 cell)
            _buildPDFCell('CUSTOMER SIGN AND NAME OR I.D.', signCellWidth, cellHeight, PdfColors.grey300),
          ],
        ),
        // Sub-header row - all 22 columns
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            // ALUMINIUM section
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('NON-CRV\nWEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('Total\nPaid', paidCellWidth, cellHeight * 1.5, PdfColors.grey300),
            // GLASS section
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('NON-CRV\nWEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('Total\nPaid', paidCellWidth, cellHeight * 1.5, PdfColors.grey300),
            // PETE PLASTIC section
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('NON-CRV\nWEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('Total\nPaid', paidCellWidth, cellHeight * 1.5, PdfColors.grey300),
            // CODE
            _buildPDFCell('', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            // OTHER COMMODITIES section
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('CRV WEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('NON-CRV\nWEIGHT', cellWidth, cellHeight * 1.5, PdfColors.grey200),
            _buildPDFCell('Total\nPaid', paidCellWidth, cellHeight * 1.5, PdfColors.grey300),
            // SIGN
            _buildPDFCell('CUSTOMER SIGN AND NAME OR I.D.', signCellWidth, cellHeight * 1.5, PdfColors.grey200),
          ],
        ),
        // Column headers row
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            _buildPDFCell('SW', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('SC', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('C', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SP', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('ALUMINIUM', paidCellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SW', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('SC', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('C', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SP', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('GLASS', paidCellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SW', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('SC', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('C', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SP', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('PETE', paidCellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('Code', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('SW', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('SC', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('C', cellWidth, cellHeight, PdfColors.grey200),
            _buildPDFCell('SP', cellWidth, cellHeight, PdfColors.blue100),
            _buildPDFCell('', paidCellWidth, cellHeight, PdfColors.grey300),
            _buildPDFCell('SIGN/ID', signCellWidth, cellHeight, PdfColors.grey200),
          ],
        ),
        // Data rows
        ...List.generate(rowCount, (row) {
          return pw.TableRow(
            children: [
              // ALUMINIUM section
              _buildPDFCell(gridData[row][0], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][1], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][2], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][3], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][4], paidCellWidth, cellHeight, PdfColors.white),
              // GLASS section
              _buildPDFCell(gridData[row][5], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][6], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][7], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][8], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][9], paidCellWidth, cellHeight, PdfColors.white),
              // PETE PLASTIC section
              _buildPDFCell(gridData[row][10], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][11], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][12], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][13], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][14], paidCellWidth, cellHeight, PdfColors.white),
              // CODE
              _buildPDFCell(gridData[row][15], cellWidth, cellHeight, PdfColors.white),
              // OTHER COMMODITIES section
              _buildPDFCell(gridData[row][16], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][17], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][18], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][19], cellWidth, cellHeight, PdfColors.white),
              _buildPDFCell(gridData[row][20], paidCellWidth, cellHeight, PdfColors.white),
              // Signature cell
              _buildPDFSignatureCell(row, 21, signCellWidth, cellHeight, sheetNumber, signatureImages),
            ],
          );
        }),
        // Totals row
        _buildPDFTotalsRow(gridData, cellWidth, paidCellWidth, signCellWidth, cellHeight),
      ],
    );
  }

  pw.Widget _buildPDFCell(String text, double width, double height, PdfColor bgColor) {
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(color: bgColor),
      child: pw.Padding(
        padding: const pw.EdgeInsets.all(1),
        child: pw.Text(
          text,
          style: const pw.TextStyle(fontSize: 7),
          textAlign: pw.TextAlign.center,
          maxLines: 2,
          overflow: pw.TextOverflow.clip,
        ),
      ),
    );
  }

  pw.Widget _buildPDFMergedCell(String text, double width, double height) {
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: const pw.BoxDecoration(color: PdfColors.grey300),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  pw.Widget _buildPDFSignatureCell(
    int row,
    int col,
    double width,
    double height,
    int sheetNumber,
    Map<String, pw.ImageProvider?> signatureImages,
  ) {
    final signatureKey = '$row-$col';
    final customerName = _sheetsCustomerNames[sheetNumber]?[signatureKey] ?? '';
    final signatureImage = signatureImages[signatureKey];
    final hasSignature = signatureImage != null;
    
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: const pw.BoxDecoration(color: PdfColors.white),
      child: pw.Padding(
        padding: const pw.EdgeInsets.all(2),
        child: hasSignature
            ? pw.Stack(
                children: [
                  // Customer name at top if available
                  if (customerName.isNotEmpty)
                    pw.Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: pw.Text(
                        customerName,
                        style: pw.TextStyle(
                          fontSize: 6,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue700,
                        ),
                        textAlign: pw.TextAlign.center,
                        maxLines: 1,
                      ),
                    ),
                  // Signature image
                  pw.Positioned(
                    top: customerName.isNotEmpty ? 8 : 0,
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: pw.Image(
                      signatureImage!,
                      fit: pw.BoxFit.contain,
                    ),
                  ),
                ],
              )
            : pw.Text(
                customerName.isNotEmpty ? customerName : '',
                style: pw.TextStyle(
                  fontSize: 6,
                  color: PdfColors.black,
                ),
                textAlign: pw.TextAlign.center,
                maxLines: 2,
                overflow: pw.TextOverflow.clip,
              ),
      ),
    );
  }

  pw.TableRow _buildPDFTotalsRow(
    List<List<String>> gridData,
    double cellWidth,
    double paidCellWidth,
    double signCellWidth,
    double cellHeight,
  ) {
    // Calculate totals
    double aluminiumTotal = 0.0;
    double glassTotal = 0.0;
    double peteTotal = 0.0;
    double otherTotal = 0.0;
    double grandTotal = 0.0;

    for (int row = 0; row < rowCount; row++) {
      aluminiumTotal += _parseCellValue(gridData[row][4]);
      glassTotal += _parseCellValue(gridData[row][9]);
      peteTotal += _parseCellValue(gridData[row][14]);
      otherTotal += _parseCellValue(gridData[row][20]);
    }

    grandTotal = aluminiumTotal + glassTotal + peteTotal + otherTotal;

    // Calculate individual column totals for display
    final columnTotals = List.generate(20, (col) {
      double total = 0.0;
      for (int row = 0; row < rowCount; row++) {
        if (row < gridData.length && col < gridData[row].length) {
          total += _parseCellValue(gridData[row][col]);
        }
      }
      return total;
    });

    return pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.orange50),
      children: [
        // ALUMINIUM section (columns 0-4)
        _buildPDFCell(columnTotals[0].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[1].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[2].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[3].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(
          aluminiumTotal.toStringAsFixed(2),
          paidCellWidth,
          cellHeight,
          PdfColors.orange50,
        ),
        // GLASS section (columns 5-9)
        _buildPDFCell(columnTotals[5].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[6].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[7].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[8].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(
          glassTotal.toStringAsFixed(2),
          paidCellWidth,
          cellHeight,
          PdfColors.orange50,
        ),
        // PETE PLASTIC section (columns 10-14)
        _buildPDFCell(columnTotals[10].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[11].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[12].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[13].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(
          peteTotal.toStringAsFixed(2),
          paidCellWidth,
          cellHeight,
          PdfColors.orange50,
        ),
        // CODE (column 15) - show count
        _buildPDFCell('', cellWidth, cellHeight, PdfColors.orange50),
        // OTHER COMMODITIES section (columns 16-20)
        _buildPDFCell(columnTotals[16].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[17].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[18].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(columnTotals[19].toStringAsFixed(2), cellWidth, cellHeight, PdfColors.orange50),
        _buildPDFCell(
          otherTotal.toStringAsFixed(2),
          paidCellWidth,
          cellHeight,
          PdfColors.orange50,
        ),
        // SIGN column - show GRAND TOTAL
        _buildPDFCell(
          'GRAND TOTAL\n${grandTotal.toStringAsFixed(2)}',
          signCellWidth,
          cellHeight,
          PdfColors.orange50,
        ),
      ],
    );
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
          if (_entryData != null)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Download PDF',
              onPressed: _generateAndSharePDF,
            ),
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
              Builder(
                builder: (context) {
                  final isApproved = _entryData?['approved'] == true;
                  return Container(
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
                        // Left: Entry ID, Created Date, Sheet count in a column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Entry ID: ${widget.entryId.length > 8 ? '${widget.entryId.substring(0, 8)}...' : widget.entryId}',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w500),
                              ),
                              if (_createdAt != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Created: ${DateFormat('MM/dd/yyyy HH:mm').format(_createdAt!)}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.grey[600]),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                'Sheets: ${_sheetsGridData.length}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                        // Right: Pending tag and Approve button
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
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
                            if (!isApproved) ...[
                              const SizedBox(height: 8),
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
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),

            // Main scrollable content area - header and grid in same horizontal scroll (like New Entry)
            Expanded(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: _horizontalController,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildStaticDetails(),
                          _buildGrid(),
                        ],
                      ),
                    ),
                  ),
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
    final formattedDate = DateFormat('MM/dd/yyyy').format(entryDate);
    final reference = _entryData?['reference'] as String? ?? 'N/A';
    final locationCertification = _entryData?['locationCertification'] as String?;
    final certificationDisplay = (locationCertification != null && locationCertification.isNotEmpty)
        ? locationCertification
        : reference;
    final locationName = _entryData?['locationName'] as String?;
    final locationAddress = _entryData?['locationAddress'] as String?;
    final locationIdOrName = _entryData?['location'] as String? ?? '';
    final locationDisplay = (locationName != null && locationName.isNotEmpty)
        ? locationName
        : (locationAddress != null && locationAddress.isNotEmpty)
            ? locationAddress
            : (locationIdOrName.isNotEmpty ? locationIdOrName : 'Unknown Location');

    return SizedBox(
      width: _totalGridWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // LOG SHEET DETAILS (far left) - same layout as New Entry
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LOG SHEET',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              certificationDisplay,
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
                              locationDisplay.replaceAll('\n', ' '),
                              softWrap: true,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // BASIC LEGEND - same as New Entry
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    alignment: Alignment.centerLeft,
                    color: Colors.grey[300],
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'BASIC LEGEND',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
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
            // OTHER COMMODITIES LEGEND + DATE (read-only) - same as New Entry
            Expanded(
              flex: 6,
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
                          padding: const EdgeInsets.symmetric(
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
                      const SizedBox(width: 24),
                      Text(
                        'DATE:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        flex: 2,
                        child: Text(
                          formattedDate,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
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
    ),
    );
  }

  Widget _buildGrid() {
    return SizedBox(
      width: _totalGridWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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

