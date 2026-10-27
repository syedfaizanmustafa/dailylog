import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'data_sync.dart';

/// Upload state of one submitted log-sheet entry kept on this tablet.
enum OutboxStatus { waiting, uploading, uploaded }

/// One submitted entry as stored on the tablet (a JSON file).
class OutboxItem {
  final Map<String, dynamic> data;
  OutboxItem(this.data);

  String get localId => data['localId'] as String;
  DateTime get createdAt => DateTime.tryParse('${data['createdAt']}') ?? DateTime(2000);
  String get dateKey => '${(data['entry'] as Map?)?['entryDateKey'] ?? ''}';
  DateTime? get entryDate => DateTime.tryParse(dateKey);
  String get locationName {
    final e = data['entry'] as Map? ?? const {};
    final n = '${e['locationName'] ?? ''}'.trim();
    return n.isNotEmpty ? n : 'No location';
  }

  int get sheetCount => ((data['entry'] as Map?)?['sheets'] as Map?)?.length ?? 0;
  bool get uploaded => data['status'] == 'uploaded';
  String? get lastError => data['lastError'] as String?;
  DateTime? get uploadedAt => DateTime.tryParse('${data['uploadedAt'] ?? ''}');
}

/// Keeps every submitted entry on the tablet for 30 days and uploads it to
/// Firebase, retrying until it is there.
///
/// Submitting first saves the entry as a file here, then uploads it. If the
/// tablet is offline or the upload fails part-way, the entry stays here
/// marked "waiting" and is retried from the Sync button, when the app comes
/// back to the foreground, and when the home screen opens.
///
/// Uploading is safe to repeat: the entry document records this upload's id
/// (`uploadIds`), so a retry after a half-finished attempt never adds the
/// sheets twice; signatures and receipt links are plain overwrites.
class SheetOutbox extends ChangeNotifier with WidgetsBindingObserver {
  SheetOutbox._();
  static final SheetOutbox instance = SheetOutbox._();

  static const _keepFor = Duration(days: 30);
  static const _timeout = Duration(seconds: 20);

  final List<OutboxItem> _items = [];
  final Set<String> _uploading = {};
  Future<void>? _loading;
  bool _started = false;
  Future<void> _queue = Future.value();

  /// Newest first: everything from the last 30 days plus anything not
  /// uploaded yet (never dropped while waiting).
  List<OutboxItem> get items => List.unmodifiable(_items);
  int get waitingCount => _items.where((i) => !i.uploaded).length;
  bool get syncing => _uploading.isNotEmpty;

  OutboxStatus statusOf(OutboxItem i) => _uploading.contains(i.localId)
      ? OutboxStatus.uploading
      : (i.uploaded ? OutboxStatus.uploaded : OutboxStatus.waiting);

  /// Loads the saved entries and retries waiting ones now and whenever the
  /// app comes back to the foreground.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    // Uploads need a signed-in user: retry as soon as someone signs in.
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) unawaited(syncAll());
    });
    await _ensureLoaded();
    unawaited(syncAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncAll());
  }

  // ── Storage ───────────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sheet_outbox');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String localId) async => File('${(await _dir()).path}/$localId.json');

  /// Loads the saved entries once per launch; every caller waits for the
  /// same load (so an entry added meanwhile is never dropped).
  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final dir = await _dir();
      final cutoff = DateTime.now().subtract(_keepFor);
      final found = <OutboxItem>[];
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          final item = OutboxItem(Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map));
          // Uploaded and older than 30 days: no longer kept on the tablet.
          if (item.uploaded && item.createdAt.isBefore(cutoff)) {
            await f.delete();
            continue;
          }
          found.add(item);
        } catch (e) {
          debugPrint('Outbox: unreadable ${f.path}: $e');
        }
      }
      found.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final known = _items.map((i) => i.localId).toSet();
      _items.addAll(found.where((i) => !known.contains(i.localId)));
      _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('Outbox: could not load: $e');
      _loading = null; // try again next time
    }
    notifyListeners();
  }

  /// Writes [item] to its file (atomically: temp file, then rename).
  Future<void> _save(OutboxItem item) async {
    final f = await _file(item.localId);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(item.data), flush: true);
    await tmp.rename(f.path);
  }

  static String newLocalId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    final rand = List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
    return 'u${DateTime.now().millisecondsSinceEpoch}$rand';
  }

  /// Saves a submitted entry on the tablet (call before clearing the draft).
  ///
  /// [entry] is the entry document without DocumentReferences (they are
  /// rebuilt from `userId` / `location` when uploading). [signatures] is per
  /// sheet: `{'1': {'points': {...}, 'customerNames': {...}}}`.
  /// [receiptIds] maps "sheet-row" to receipt ids issued on the sheet.
  Future<OutboxItem> add({
    required Map<String, dynamic> entry,
    required Map<String, dynamic> signatures,
    required Map<String, String> receiptIds,
  }) async {
    await _ensureLoaded();
    final item = OutboxItem({
      'v': 1,
      'localId': newLocalId(),
      'createdAt': DateTime.now().toIso8601String(),
      'entry': entry,
      'signatures': signatures,
      'receiptIds': receiptIds,
      // Id for a brand-new entry document, fixed now so a retry reuses it.
      'newEntryId': FirebaseFirestore.instance.collection('entries').doc().id,
      'status': 'waiting',
      'steps': <String, bool>{},
    });
    await _save(item);
    _items.insert(0, item);
    notifyListeners();
    return item;
  }

  // ── Upload ────────────────────────────────────────────────────────────

  /// Uploads every waiting entry, one at a time. Returns how many are still
  /// waiting afterwards.
  Future<int> syncAll() async {
    await _ensureLoaded();
    for (final item in _items.where((i) => !i.uploaded).toList()) {
      await upload(item.localId);
    }
    return waitingCount;
  }

  /// Uploads one entry. Returns true when it is fully in Firebase. Runs one
  /// upload at a time (queued) so the Sync button and auto-retry never race.
  Future<bool> upload(String localId) {
    final c = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _upload(localId));
      } catch (_) {
        c.complete(false);
      }
    });
    return c.future;
  }

  Future<bool> _upload(String localId) async {
    final item = _items.where((i) => i.localId == localId).firstOrNull;
    if (item == null || item.uploaded) return item != null;
    if (FirebaseAuth.instance.currentUser == null) return false; // signed out
    _uploading.add(localId);
    notifyListeners();
    final d = item.data;
    final steps = Map<String, dynamic>.from(d['steps'] as Map? ?? const {});
    try {
      if (steps['entry'] != true) {
        await _uploadEntry(item).timeout(_timeout);
        steps['entry'] = true;
        d['steps'] = steps;
        await _save(item);
      }
      final entryId = d['entryId'] as String;
      final sheetMap = Map<String, dynamic>.from(d['sheetMap'] as Map? ?? const {});

      if (steps['signatures'] != true) {
        final sigs = Map<String, dynamic>.from(d['signatures'] as Map? ?? const {});
        final entryRef = FirebaseFirestore.instance.collection('entries').doc(entryId);
        await Future.wait([
          for (final e in sigs.entries)
            // Only sheets that are in the entry (never guess a number: in a
            // merge that could overwrite another tablet's signatures).
            if (sheetMap.containsKey(e.key))
            entryRef
                .collection('signatures')
                .doc('${sheetMap[e.key] ?? e.key}')
                .set({
              ...Map<String, dynamic>.from(e.value as Map),
              'createdAt': DateTime.now().toIso8601String(),
            }),
        ]).timeout(_timeout);
        steps['signatures'] = true;
        d['steps'] = steps;
        await _save(item);
      }

      if (steps['receipts'] != true) {
        // Attach receipts issued on these sheets to the entry, one by one: a
        // receipt that no longer exists is skipped instead of blocking the
        // whole upload forever.
        final ids = Map<String, String>.from(d['receiptIds'] as Map? ?? const {});
        final receipts = FirebaseFirestore.instance.collection('receipts');
        await Future.wait([
          for (final e in ids.entries)
            if (sheetMap.containsKey(e.key.split('-').first))
              receipts.doc(e.value).update({
                'entryId': entryId,
                'sheetNumber': (sheetMap[e.key.split('-').first] as num).toInt(),
                kSyncedAt: syncedNow(),
              }).catchError((Object err) {
                if (err is FirebaseException && err.code == 'not-found') return;
                throw err;
              }),
        ]).timeout(_timeout);
        steps['receipts'] = true;
        d['steps'] = steps;
      }

      d['status'] = 'uploaded';
      d['uploadedAt'] = DateTime.now().toIso8601String();
      d.remove('lastError');
      await _save(item);
      SyncedCollection.entries.touch();
      return true;
    } catch (e) {
      d['lastError'] = e is TimeoutException || '$e'.contains('unavailable') || '$e'.contains('network')
          ? 'No connection. Will try again.'
          : 'Upload failed: $e';
      d['lastAttemptAt'] = DateTime.now().toIso8601String();
      try {
        await _save(item);
      } catch (_) {}
      return false;
    } finally {
      _uploading.remove(localId);
      notifyListeners();
    }
  }

  /// Puts the sheets into Firebase: merges into the entry for the same
  /// location and day if one exists, else creates the entry. Records the
  /// target entry and sheet numbers in [item].
  Future<void> _uploadEntry(OutboxItem item) async {
    final db = FirebaseFirestore.instance;
    final d = item.data;
    final localId = item.localId;
    final entry = Map<String, dynamic>.from(d['entry'] as Map);
    final sheets = Map<String, dynamic>.from(entry['sheets'] as Map? ?? const {});
    const server = GetOptions(source: Source.server);

    // Already uploaded by an earlier attempt that didn't get to record it?
    final done = await db
        .collection('entries')
        .where('uploadIds', arrayContains: localId)
        .limit(1)
        .get(server);
    if (done.docs.isNotEmpty) {
      final doc = done.docs.first;
      final rec = (doc.data()['uploads'] as Map?)?[localId] as Map?;
      d['entryId'] = doc.id;
      d['sheetMap'] = Map<String, dynamic>.from(rec?['sheets'] as Map? ?? {for (final k in sheets.keys) k: int.parse(k)});
      return;
    }

    final locationId = entry['location'] as String?;
    final dateKey = entry['entryDateKey'] as String?;
    DocumentReference<Map<String, dynamic>>? existing;
    if (locationId != null && locationId.isNotEmpty && dateKey != null) {
      final q = await db
          .collection('entries')
          .where('location', isEqualTo: locationId)
          .where('entryDateKey', isEqualTo: dateKey)
          .limit(1)
          .get(server);
      if (q.docs.isNotEmpty) existing = q.docs.first.reference;
    }

    if (existing != null) {
      // Merge: next free sheet numbers, decided inside a transaction so two
      // tablets uploading at once can't take the same numbers.
      final ref = existing;
      final map = await db.runTransaction<Map<String, int>>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data() ?? const <String, dynamic>{};
        // An earlier attempt (timed out on this side) already merged these
        // sheets: reuse its numbers instead of adding them again.
        if (((data['uploadIds'] as List?) ?? const []).contains(localId)) {
          final rec = (((data['uploads'] as Map?)?[localId] as Map?)?['sheets'] as Map?) ?? const {};
          return {for (final e in rec.entries) '${e.key}': (e.value as num).toInt()};
        }
        final current = Map<String, dynamic>.from(data['sheets'] as Map? ?? const {});
        var next = 1;
        for (final k in current.keys) {
          final n = int.tryParse(k);
          if (n != null && n >= next) next = n + 1;
        }
        final ordered = sheets.keys.toList()..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
        final m = <String, int>{for (final k in ordered) k: next++};
        tx.update(ref, {
          for (final k in ordered) 'sheets.${m[k]}': sheets[k],
          'uploadIds': FieldValue.arrayUnion([localId]),
          'uploads.$localId': {'sheets': m, 'at': DateTime.now().toIso8601String()},
          'updatedAt': DateTime.now().toIso8601String(),
          kSyncedAt: syncedNow(),
        });
        return m;
      });
      d['entryId'] = ref.id;
      d['sheetMap'] = map;
      return;
    }

    // New entry, with the id fixed when the sheet was saved on the tablet.
    // A transaction (not a plain write) so it never sits queued on the
    // tablet while offline and lands later behind a retry's back.
    final ref = db.collection('entries').doc(d['newEntryId'] as String);
    final identity = <String, int>{for (final k in sheets.keys) k: int.parse(k)};
    final userId = entry['userId'] as String?;
    await db.runTransaction<void>((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return; // created by an earlier attempt
      tx.set(ref, {
        ...entry,
        if (userId != null) 'userRef': db.collection('users').doc(userId),
        if (locationId != null && locationId.isNotEmpty)
          'locationRef': db.collection('locations').doc(locationId),
        'uploadIds': [localId],
        'uploads': {
          localId: {'sheets': identity, 'at': DateTime.now().toIso8601String()},
        },
        kSyncedAt: syncedNow(),
      });
    });
    d['entryId'] = ref.id;
    d['sheetMap'] = identity;
  }
}

/// Rebuilds widgets when the outbox changes (Sync button badge, list).
final sheetOutboxProvider = ChangeNotifierProvider<SheetOutbox>((ref) => SheetOutbox.instance);
