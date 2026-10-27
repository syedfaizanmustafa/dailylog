import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../config/receipt_config.dart';
import '../models/receipt.dart';
import '../utils/receipt_code.dart';
import 'data_sync.dart';
import 'receipt_pdf_service.dart';

/// Issues receipts (sequential number + PDF in Storage + Firestore doc) and
/// requests delivery. Actual SMS/email sending happens in Cloud Functions
/// that watch the `receipts` collection (see `functions/`).
class ReceiptService {
  ReceiptService._();

  /// Phone number the customer typed on the signature screen ("Text me my
  /// receipt"). The receipt screen that opens right after signing reads it
  /// once to pre-fill the Text field, then clears it.
  static String? _pendingPhone;
  static DateTime? _pendingPhoneAt;

  static set pendingCustomerPhone(String? phone) {
    _pendingPhone = phone;
    _pendingPhoneAt = phone == null ? null : DateTime.now();
  }

  /// Returns the number only if it was entered in the last 2 minutes, so a
  /// number can never leak onto a later customer's receipt.
  static String? takePendingCustomerPhone() {
    final p = _pendingPhone;
    final at = _pendingPhoneAt;
    _pendingPhone = null;
    _pendingPhoneAt = null;
    if (p == null || at == null) return null;
    if (DateTime.now().difference(at) > const Duration(minutes: 2)) return null;
    return p;
  }

  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;

  static CollectionReference<Map<String, dynamic>> get _receipts =>
      _db.collection('receipts');

  // ── Issue ─────────────────────────────────────────────────────────────

  /// Allocates the next receipt number, renders the PDF, uploads it and
  /// writes the receipt document. Returns the issued receipt.
  ///
  /// Idempotent per log-sheet cell: if a receipt already exists for the same
  /// `(entryId | locationId+date, sheetNumber, row)` it is returned instead
  /// of issuing a duplicate number.
  static Future<ReceiptData> issue(
    ReceiptData draft, {
    required String issuedByUid,
  }) async {
    if (draft.isIssued) return draft;

    final existing = await findForCell(draft);
    if (existing != null) return existing;

    final number = await _allocateNumber();
    final code = await _codeFor(draft);
    final token = _randomToken();
    final docRef = _receipts.doc();

    var issued = draft.copyWith(
      id: docRef.id,
      receiptNumber: number,
      receiptCode: code,
      token: token,
      createdAt: DateTime.now(),
      createdBy: issuedByUid,
      pdfPath: '${ReceiptConfig.storageFolder}/${docRef.id}.pdf',
    );

    final bytes = await ReceiptPdfService.build(issued);
    await _storage.ref(issued.pdfPath!).putData(
          bytes,
          SettableMetadata(
            contentType: 'application/pdf',
            customMetadata: {
              'receiptNumber': number.toString(),
              'receiptCode': code,
              'token': token,
            },
          ),
        );

    // Receipt + its signature in one atomic write. Until "Speed up receipts"
    // has run, the signature is also kept inline for older app versions.
    final inline = await _inlineSignatures();
    final batch = _db.batch();
    batch.set(docRef, {
      ...issued.toFirestore(),
      if (inline && issued.signature.isNotEmpty)
        'signature': issued.signature.map((p) => p.toMap()).toList(),
      kSyncedAt: syncedNow(),
    });
    if (issued.signature.isNotEmpty) {
      batch.set(_signatureRef(docRef.id), _signatureDoc(issued.signature));
    }
    await batch.commit();
    SyncedCollection.receipts.touch();
    return issued;
  }

  // ── Signature (kept out of the receipt document) ───────────────────────

  static DocumentReference<Map<String, dynamic>> get _settingsRef =>
      _db.collection('appSettings').doc('receipts');

  /// True until an admin has run "Speed up receipts". Until then every
  /// device may still be on an older app version that reads the signature
  /// from the receipt itself, so new receipts keep an inline copy too.
  static Future<bool> _inlineSignatures() async {
    try {
      final d = await _settingsRef.get();
      return d.data()?['signaturesMoved'] != true;
    } catch (_) {
      return true; // can't tell: keep the safe (inline) copy
    }
  }

  static DocumentReference<Map<String, dynamic>> _signatureRef(String receiptId) =>
      _receipts.doc(receiptId).collection('private').doc('signature');

  static Map<String, dynamic> _signatureDoc(List<ReceiptSignaturePoint> points) => {
        'points': points.map((p) => p.toMap()).toList(),
        kSyncedAt: syncedNow(),
      };

  /// Stroke points of an issued receipt: from its own signature document, or
  /// from the receipt itself for receipts saved before the move.
  static Future<List<ReceiptSignaturePoint>> loadSignature(String receiptId) async {
    final doc = await _signatureRef(receiptId).get();
    final raw = doc.data()?['points'];
    if (raw is List && raw.isNotEmpty) {
      return [
        for (final e in raw)
          if (e is Map) ReceiptSignaturePoint.fromMap(Map<String, dynamic>.from(e)),
      ];
    }
    final legacy = await _receipts.doc(receiptId).get();
    final old = legacy.data()?['signature'];
    if (old is List) {
      return [
        for (final e in old)
          if (e is Map) ReceiptSignaturePoint.fromMap(Map<String, dynamic>.from(e)),
      ];
    }
    return const [];
  }

  /// [r] with its signature loaded (no-op for drafts and receipts that
  /// already have it).
  static Future<ReceiptData> withSignature(ReceiptData r) async {
    if (r.signature.isNotEmpty || r.id == null) return r;
    final points = await loadSignature(r.id!);
    return points.isEmpty ? r : r.copyWith(signature: points);
  }

  /// One-time move of signatures stored inside older receipt documents into
  /// their own document, so lists of receipts download ~1 KB per receipt
  /// instead of ~10–50 KB. Copy and removal happen in the same atomic batch,
  /// per receipt. Safe to run again (it skips receipts already moved).
  /// Returns how many receipts were moved.
  ///
  /// Only run once every iPad and phone has this app version: older versions
  /// read the signature from the receipt document. From then on new receipts
  /// are saved without the inline copy.
  static Future<int> moveOldSignatures({void Function(int done, int total)? onProgress}) async {
    // Flag first, so receipts issued while this runs are already saved the
    // new way and none is missed.
    await _settingsRef.set({
      'signaturesMoved': true,
      'movedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
    final snap = await _receipts.get(const GetOptions(source: Source.server));
    final todo = snap.docs.where((d) {
      final sig = d.data()['signature'];
      return sig is List && sig.isNotEmpty;
    }).toList();
    var done = 0;
    onProgress?.call(0, todo.length);
    // 2 writes per receipt, each carrying the signature: 50 receipts per
    // batch stays well under Firestore's 500-write and 10 MB request limits.
    const chunk = 50;
    for (var i = 0; i < todo.length; i += chunk) {
      final batch = _db.batch();
      for (final d in todo.skip(i).take(chunk)) {
        batch.set(_signatureRef(d.id), {
          'points': d.data()['signature'],
          kSyncedAt: syncedNow(),
        });
        batch.update(d.reference, {
          'signature': FieldValue.delete(),
          kSyncedAt: syncedNow(),
        });
      }
      await batch.commit();
      done = min(i + chunk, todo.length);
      onProgress?.call(done, todo.length);
    }
    SyncedCollection.receipts.touch();
    return done;
  }

  /// `LL-YYMMDD-SS-RR` for a draft; adds `-2`, `-3`… if that exact code was
  /// already used (two iPads logging the same sheet/row the same day).
  static Future<String> _codeFor(ReceiptData d) async {
    var location = 0;
    final locId = d.locationId;
    if (locId != null && locId.isNotEmpty) {
      try {
        final loc = await _db.collection('locations').doc(locId).get();
        location = (loc.data()?['number'] as num?)?.toInt() ?? 0;
      } catch (_) {}
    }
    for (var copy = 1; copy < 50; copy++) {
      final code = ReceiptCode.build(
        location: location,
        date: d.date,
        sheet: d.sheetNumber,
        row: d.row + 1,
        copy: copy,
      );
      try {
        final taken = await _receipts.where('receiptCode', isEqualTo: code).limit(1).get();
        if (taken.docs.isEmpty) return code;
      } catch (_) {
        return code; // offline / index trouble: never block issuing
      }
    }
    return ReceiptCode.build(location: location, date: d.date, sheet: d.sheetNumber, row: d.row + 1);
  }

  /// Re-issues an existing receipt with corrected sheet data: same number,
  /// same customer link (token) and delivery history; the PDF in Storage and
  /// the receipt document are replaced. Admin only (see firestore.rules).
  static Future<ReceiptData> reissue(ReceiptData existing, ReceiptData draft) async {
    final id = existing.id;
    if (id == null) throw StateError('Receipt has no id');
    final path = existing.pdfPath ?? '${ReceiptConfig.storageFolder}/$id.pdf';
    final updated = draft.copyWith(
      id: id,
      receiptNumber: existing.receiptNumber,
      receiptCode: existing.receiptCode,
      token: existing.token,
      customerId: existing.customerId.isNotEmpty ? existing.customerId : null,
      pdfPath: path,
      sms: existing.sms,
      email: existing.email,
      printed: existing.printed,
      createdAt: existing.createdAt,
      createdBy: existing.createdBy,
    );
    final full = await withSignature(updated);
    final bytes = await ReceiptPdfService.build(full);
    await _storage.ref(path).putData(
          bytes,
          SettableMetadata(
            contentType: 'application/pdf',
            customMetadata: {
              'receiptNumber': '${existing.receiptNumber ?? ''}',
              'receiptCode': existing.receiptCode ?? '',
              'token': existing.token ?? '',
            },
          ),
        );
    // update(), not set(): delivery status (sms/email/printed) may have
    // changed since this receipt was loaded and must not be rolled back.
    final data = updated.toFirestore()
      ..remove('sms')
      ..remove('email')
      ..remove('printed')
      ..remove('createdAt')
      ..remove('createdBy');
    final inline = await _inlineSignatures();
    final batch = _db.batch();
    batch.update(_receipts.doc(id), {
      ...data,
      'reissuedAt': DateTime.now().toIso8601String(),
      // Inline copy only until "Speed up receipts" has run (older app
      // versions read it); after that the signature doc is the only copy.
      'signature': inline && full.signature.isNotEmpty
          ? full.signature.map((p) => p.toMap()).toList()
          : FieldValue.delete(),
      kSyncedAt: syncedNow(),
    });
    if (full.signature.isNotEmpty) {
      batch.set(_signatureRef(id), _signatureDoc(full.signature));
    }
    await batch.commit();
    SyncedCollection.receipts.touch();
    return full;
  }

  /// Regenerates the PDF bytes for preview/print without touching Storage.
  /// Loads the signature first if [r] doesn't have it.
  static Future<Uint8List> render(ReceiptData r) async =>
      ReceiptPdfService.build(await withSignature(r));

  /// Quick PDF without the signature (a grey box marks its place), shown
  /// while the signature loads.
  static Future<Uint8List> renderWithoutSignature(ReceiptData r) =>
      ReceiptPdfService.build(r, signaturePending: true);

  /// Looks for an already-issued receipt for the same sheet cell.
  static Future<ReceiptData?> findForCell(ReceiptData d) async {
    try {
      Query<Map<String, dynamic>> q = _receipts
          .where('sheetNumber', isEqualTo: d.sheetNumber)
          .where('row', isEqualTo: d.row);
      if (d.entryId != null) {
        q = q.where('entryId', isEqualTo: d.entryId);
      } else {
        q = q
            .where('entryDateKey', isEqualTo: d.entryDateKey)
            .where('locationId', isEqualTo: d.locationId)
            .where('entryId', isNull: true);
      }
      final snap = await q.limit(1).get();
      if (snap.docs.isEmpty) return null;
      return ReceiptData.fromFirestore(snap.docs.first);
    } catch (_) {
      // A missing composite index must not block issuing a receipt.
      return null;
    }
  }

  static Future<ReceiptData?> getById(String id) async {
    final doc = await _receipts.doc(id).get();
    if (!doc.exists) return null;
    return ReceiptData.fromFirestore(doc);
  }

  static Stream<ReceiptData?> watch(String id) =>
      _receipts.doc(id).snapshots().map(
            (d) => d.exists ? ReceiptData.fromFirestore(d) : null,
          );

  /// All receipts issued for a submitted log-sheet entry.
  static Future<List<ReceiptData>> forEntry(String entryId) async {
    final snap = await _receipts.where('entryId', isEqualTo: entryId).get();
    final list = snap.docs.map(ReceiptData.fromFirestore).toList()
      ..sort((a, b) => (a.receiptNumber ?? 0).compareTo(b.receiptNumber ?? 0));
    return list;
  }

  // ── Delivery ──────────────────────────────────────────────────────────

  /// Queues an SMS with the receipt link. [phoneE164] must be `+1XXXXXXXXXX`.
  /// The Cloud Function picks up `sms.status == 'pending'`.
  static Future<void> requestSms(String receiptId, String phoneE164) async {
    await _receipts.doc(receiptId).update({
      'sms': ReceiptDelivery(
        requested: true,
        to: phoneE164,
        status: 'pending',
        updatedAt: DateTime.now(),
      ).toMap(),
      kSyncedAt: syncedNow(),
    });
  }

  static Future<void> requestEmail(String receiptId, String email) async {
    await _receipts.doc(receiptId).update({
      'email': ReceiptDelivery(
        requested: true,
        to: email.trim(),
        status: 'pending',
        updatedAt: DateTime.now(),
      ).toMap(),
      kSyncedAt: syncedNow(),
    });
  }

  static Future<void> markPrinted(String receiptId) =>
      _receipts.doc(receiptId).update({'printed': true, kSyncedAt: syncedNow()});

  /// Saves the customer's ID number and regenerates the stored PDF so the
  /// hosted/texted copy matches what is printed.
  static Future<ReceiptData> updateCustomerId(
    ReceiptData r,
    String customerId,
  ) async {
    final updated = (await withSignature(r)).copyWith(customerId: customerId.trim());
    if (updated.id == null) return updated;
    if (updated.pdfPath != null) {
      final bytes = await ReceiptPdfService.build(updated);
      await _storage.ref(updated.pdfPath!).putData(
            bytes,
            SettableMetadata(contentType: 'application/pdf'),
          );
    }
    await _receipts
        .doc(updated.id!)
        .update({'customerId': updated.customerId, kSyncedAt: syncedNow()});
    return updated;
  }

  /// After a log sheet is submitted, attach the entry id (and the possibly
  /// re-numbered sheet) to receipts that were issued while it was a draft.
  static Future<void> linkToEntry({
    required Map<String, String> receiptIdsByCell, // "sheet-row" -> receiptId
    required String entryId,
    required Map<int, int> sheetNumberMapping,
  }) async {
    if (receiptIdsByCell.isEmpty) return;
    final batch = _db.batch();
    receiptIdsByCell.forEach((cellKey, receiptId) {
      final parts = cellKey.split('-');
      final oldSheet = int.tryParse(parts.first) ?? 1;
      batch.update(_receipts.doc(receiptId), {
        'entryId': entryId,
        'sheetNumber': sheetNumberMapping[oldSheet] ?? oldSheet,
        kSyncedAt: syncedNow(),
      });
    });
    await batch.commit();
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Transactional counter so two iPads can never hand out the same number.
  static Future<int> _allocateNumber() async {
    final ref = _db
        .collection(ReceiptConfig.counterCollection)
        .doc(ReceiptConfig.counterDocId);
    return _db.runTransaction<int>((tx) async {
      final snap = await tx.get(ref);
      final next = snap.exists
          ? ((snap.data()?['next'] as num?)?.toInt() ??
              ReceiptConfig.firstReceiptNumber)
          : ReceiptConfig.firstReceiptNumber;
      tx.set(ref, {
        'next': next + 1,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      return next;
    });
  }

  /// URL-safe, unguessable token for the hosted receipt link.
  static String _randomToken([int length = 12]) {
    const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }

  // ── Phone helpers ─────────────────────────────────────────────────────

  /// Normalises a typed US number to E.164 (`+1XXXXXXXXXX`); null if invalid.
  static String? normalizeUsPhone(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return null;
  }

  /// `(707) 555-0123` for display.
  static String formatUsPhone(String e164) {
    final d = e164.replaceAll(RegExp(r'\D'), '');
    if (d.length != 11) return e164;
    return '(${d.substring(1, 4)}) ${d.substring(4, 7)}-${d.substring(7)}';
  }

  static bool looksLikeEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());
}
