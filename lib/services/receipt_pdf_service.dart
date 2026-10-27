import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Canvas, Colors, Offset, Paint, StrokeCap;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../config/receipt_config.dart';
import '../models/receipt.dart';

/// Renders a [ReceiptData] into a PDF that mirrors the paper
/// "Recycler Certification / Receipt" form (half-letter, landscape).
class ReceiptPdfService {
  ReceiptPdfService._();

  /// 8.5 x 5.5 in — same footprint as the paper receipt pad.
  static const PdfPageFormat pageFormat = PdfPageFormat(
    8.5 * PdfPageFormat.inch,
    5.5 * PdfPageFormat.inch,
    marginAll: 0.3 * PdfPageFormat.inch,
  );

  static const _black = PdfColors.black;
  static const _grey = PdfColors.grey700;

  /// [signaturePending]: draw a light placeholder where the signature goes
  /// (on-screen preview while the signature loads; never printed or shared).
  static Future<Uint8List> build(ReceiptData r, {bool signaturePending = false}) async {
    final doc = pw.Document(
      title: 'Receipt ${r.receiptNumberLabel} - ${ReceiptConfig.businessName}',
      author: ReceiptConfig.businessName,
    );

    final sigImage = await _signatureImage(r.signature, 220, 44);

    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8);
    final label = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7.5);
    final value = const pw.TextStyle(fontSize: 8);
    final small = const pw.TextStyle(fontSize: 6.2);

    doc.addPage(
      pw.Page(
        pageFormat: pageFormat,
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _header(r, label, value, bold),
              pw.SizedBox(height: 6),
              _table(r, label, value, bold),
              pw.SizedBox(height: 6),
              _footer(r, sigImage, label, value, small, signaturePending: signaturePending),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  // ── Header ────────────────────────────────────────────────────────────

  static pw.Widget _header(
    ReceiptData r,
    pw.TextStyle label,
    pw.TextStyle value,
    pw.TextStyle bold,
  ) {
    pw.Widget row(String l, String v) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 118, child: pw.Text(l, style: label)),
            pw.Expanded(child: pw.Text(v, style: value)),
          ],
        );

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          flex: 3,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              row('RECYCLER\nCERTIFICATION NO.', r.certification),
              pw.SizedBox(height: 4),
              row(
                'RECYCLER NAME &\nADDRESS (OPTIONAL)',
                [r.recyclerName, r.recyclerAddress]
                    .where((s) => s.trim().isNotEmpty)
                    .join('\n'),
              ),
            ],
          ),
        ),
        pw.Expanded(
          flex: 2,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('RECEIPT NO.', style: label),
                  pw.SizedBox(width: 8),
                  pw.Container(
                    // Wider for the location/date/sheet/row code (02-261008-03-07).
                    width: r.receiptNumberLabel.length > 8 ? 160 : 120,
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(bottom: pw.BorderSide(width: 0.8)),
                    ),
                    child: pw.Text(
                      r.receiptNumberLabel,
                      textAlign: pw.TextAlign.center,
                      maxLines: 1,
                      style: pw.TextStyle(
                        fontSize: r.receiptNumberLabel.length > 8 ? 14 : 16,
                        font: pw.Font.timesBold(),
                      ),
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.end,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('DATE', style: label),
                  pw.SizedBox(width: 8),
                  pw.Container(
                    width: 120,
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(bottom: pw.BorderSide(width: 0.8)),
                    ),
                    child: pw.Text(
                      r.formattedDate,
                      textAlign: pw.TextAlign.center,
                      style: value,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Table ─────────────────────────────────────────────────────────────

  static const _colWidths = <int, pw.TableColumnWidth>{
    0: pw.FixedColumnWidth(78), // MATERIAL
    1: pw.FixedColumnWidth(52), // BASIS
    2: pw.FixedColumnWidth(84), // TOTAL WEIGHT OR COUNT
    3: pw.FixedColumnWidth(66), // PRICE PER POUND
    4: pw.FixedColumnWidth(74), // TOTAL REFUND VALUE
    5: pw.FixedColumnWidth(66), // TOTAL PAID
    6: pw.FlexColumnWidth(1), // REJECTED / OUT OF SALE
  };

  static pw.Widget _table(
    ReceiptData r,
    pw.TextStyle label,
    pw.TextStyle value,
    pw.TextStyle bold,
  ) {
    final byMaterial = <ReceiptMaterial, ReceiptLine>{};
    for (final l in r.lines) {
      // If two lines land on the same material (rare), merge the money.
      final existing = byMaterial[l.material];
      byMaterial[l.material] = existing == null
          ? l
          : ReceiptLine(
              material: l.material,
              basis: [existing.basis, l.basis]
                  .where((s) => s.isNotEmpty)
                  .join(', '),
              weightOrCount: [existing.weightOrCount, l.weightOrCount]
                  .where((s) => s.isNotEmpty)
                  .join(' / '),
              pounds: existing.pounds + l.pounds,
              pricePerPound: existing.pricePerPound ?? l.pricePerPound,
              totalPaid: existing.totalPaid + l.totalPaid,
              note: [existing.note, l.note]
                  .where((s) => s.isNotEmpty)
                  .join('; '),
            );
    }

    pw.Widget head(String text) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          child: pw.Text(text, style: label, textAlign: pw.TextAlign.center),
        );

    pw.Widget cell(String text,
            {pw.TextAlign align = pw.TextAlign.center, bool strong = false}) =>
        pw.Container(
          height: 15,
          alignment: align == pw.TextAlign.left
              ? pw.Alignment.centerLeft
              : align == pw.TextAlign.right
                  ? pw.Alignment.centerRight
                  : pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(horizontal: 3),
          child: pw.Text(
            text,
            style: strong ? bold : value,
            textAlign: align,
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
          ),
        );

    String money(double v) => v == 0 ? '' : '\$${v.toStringAsFixed(2)}';
    String price(double? v) => v == null || v == 0
        ? ''
        : '\$${v < 1 ? v.toStringAsFixed(3) : v.toStringAsFixed(2)}';

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          head('MATERIAL'),
          head('BASIS'),
          head('TOTAL WEIGHT\nOR COUNT'),
          head('PRICE PER\nPOUND\n(OPTIONAL)'),
          head('TOTAL REFUND\nVALUE\n(OPTIONAL)'),
          head('TOTAL PAID'),
          head('INDICATE IF REJECTED\nOR OUT OF SALE\nCONTAINERS'),
        ],
      ),
      for (final m in ReceiptMaterial.values)
        // The scrap row is extra to the state form: only print it when used.
        if (m != ReceiptMaterial.scrap || byMaterial.containsKey(m))
        pw.TableRow(
          children: [
            cell(m.label, align: pw.TextAlign.left, strong: true),
            cell(byMaterial[m]?.basis ?? ''),
            cell(byMaterial[m]?.weightOrCount ?? ''),
            cell(price(byMaterial[m]?.pricePerPound)),
            cell(money(byMaterial[m]?.totalPaid ?? 0)),
            cell(money(byMaterial[m]?.totalPaid ?? 0), strong: true),
            cell(byMaterial[m]?.note ?? '', align: pw.TextAlign.left),
          ],
        ),
    ];

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Table(
          columnWidths: _colWidths,
          border: pw.TableBorder.all(color: _black, width: 0.7),
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
          children: rows,
        ),
        // Grand total row: label + boxed amount aligned under TOTAL PAID.
        pw.Row(
          children: [
            pw.SizedBox(width: 78 + 52 + 84 + 66),
            pw.Container(
              width: 74,
              height: 18,
              alignment: pw.Alignment.centerRight,
              padding: const pw.EdgeInsets.only(right: 4),
              child: pw.Text('GRAND TOTAL', style: label),
            ),
            pw.Container(
              width: 66,
              height: 18,
              alignment: pw.Alignment.center,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _black, width: 1.2),
              ),
              child: pw.Text(
                '\$${r.grandTotal.toStringAsFixed(2)}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────

  static pw.Widget _footer(
    ReceiptData r,
    pw.ImageProvider? sigImage,
    pw.TextStyle label,
    pw.TextStyle value,
    pw.TextStyle small, {
    bool signaturePending = false,
  }) {
    pw.Widget signLine(String l, pw.Widget child) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.SizedBox(width: 78, child: pw.Text(l, style: label)),
            pw.Expanded(
              child: pw.Container(
                decoration: const pw.BoxDecoration(
                  border: pw.Border(bottom: pw.BorderSide(width: 0.7)),
                ),
                padding: const pw.EdgeInsets.only(bottom: 1, left: 4),
                child: child,
              ),
            ),
          ],
        );

    final legend = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('**INCLUDES MULTILAYER AND OTHER UNSPECIFIED RESINS',
            style: small.copyWith(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 3),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 34, child: pw.Text('BASIS:', style: label)),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('SW  SEGREGATED BAY WEIGHT', style: small),
                pw.Text('SC  SEGREGATED BAY COUNT', style: small),
                pw.Text('S*  24 OZ. OR LESS / BAY OVER 24 OZ.', style: small),
                pw.Text('C*  COMMINGLED', style: small),
                pw.Text('SP*  SCRAP', style: small),
              ],
            ),
          ],
        ),
      ],
    );

    final signatureBlock = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        signLine(
          "SELLER'S SIGNATURE",
          pw.SizedBox(
            height: 30,
            child: sigImage == null
                ? (signaturePending
                    ? pw.Align(
                        alignment: pw.Alignment.bottomLeft,
                        child: pw.Container(
                          width: 150,
                          height: 22,
                          margin: const pw.EdgeInsets.only(bottom: 2),
                          decoration: pw.BoxDecoration(
                            color: PdfColors.grey200,
                            borderRadius: pw.BorderRadius.circular(3),
                          ),
                        ),
                      )
                    : pw.SizedBox())
                : pw.Align(
                    alignment: pw.Alignment.bottomLeft,
                    child: pw.Image(sigImage, fit: pw.BoxFit.contain),
                  ),
          ),
        ),
        pw.SizedBox(height: 5),
        signLine('PRINTED NAME:', pw.Text(r.customerName, style: value)),
        pw.SizedBox(height: 5),
        signLine('I.D. #', pw.Text(r.customerId, style: value)),
      ],
    );

    final online = r.token == null
        ? pw.SizedBox()
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: ReceiptConfig.receiptUrl(r.token!),
                width: 46,
                height: 46,
                drawText: false,
              ),
              pw.SizedBox(height: 2),
              pw.Text('View online', style: small.copyWith(color: _grey)),
            ],
          );

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(flex: 5, child: legend),
        pw.SizedBox(width: 8),
        pw.Expanded(flex: 5, child: signatureBlock),
        pw.SizedBox(width: 8),
        online,
      ],
    );
  }

  // ── Signature rasteriser ─────────────────────────────────────────────

  /// Draws the stroke points into a transparent PNG sized [width]x[height]
  /// (logical points; rendered at 3x for crisp printing).
  static Future<pw.ImageProvider?> _signatureImage(
    List<ReceiptSignaturePoint> points,
    double width,
    double height,
  ) async {
    if (points.length < 2) return null;

    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in points) {
      minX = min(minX, p.dx);
      maxX = max(maxX, p.dx);
      minY = min(minY, p.dy);
      maxY = max(maxY, p.dy);
    }
    final sigW = maxX - minX;
    final sigH = maxY - minY;
    if (sigW <= 0 || sigH <= 0) return null;

    const scaleUp = 3.0;
    final w = width * scaleUp;
    final h = height * scaleUp;
    final scale = min(w / sigW, h / sigH) * 0.92;
    final offX = (w - sigW * scale) / 2;
    final offY = (h - sigH * scale) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.2 * scaleUp
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (a.type == 1 || b.type == 1) {
        canvas.drawLine(
          Offset((a.dx - minX) * scale + offX, (a.dy - minY) * scale + offY),
          Offset((b.dx - minX) * scale + offX, (b.dy - minY) * scale + offY),
          paint,
        );
      }
    }

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return pw.MemoryImage(bytes.buffer.asUint8List());
  }
}
