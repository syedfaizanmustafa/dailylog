import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Field set to the server time on every write to `entries` and `receipts`
/// (app and Cloud Functions). Delta sync asks only for documents whose
/// `syncedAt` is newer than the last sync.
const String kSyncedAt = 'syncedAt';

/// Server time for [kSyncedAt].
FieldValue syncedNow() => FieldValue.serverTimestamp();

/// Offline cache + delta sync for the admin screens.
///
/// The first load downloads the whole collection once; Firestore keeps it in
/// its on-device cache (size unlimited, see main.dart). After that, a load
/// reads the cache (instant) and asks the server only for documents changed
/// since the last sync, plus deletion markers. A full download runs again
/// once a week, when the cache looks incomplete, or on "Refresh all data".
///
/// Entries and receipts are never deleted except log sheets, which leave a
/// marker in `deletions` (see [markDeleted]).
class SyncedCollection {
  final String name;
  SyncedCollection._(this.name);

  static final entries = SyncedCollection._('entries');
  static final receipts = SyncedCollection._('receipts');

  static const _overlap = Duration(minutes: 10);
  static const _fullEvery = Duration(days: 7);

  /// Reuse a result this fresh instead of asking the server again (e.g.
  /// Overview and Customers opening one after the other).
  static const _reuseFor = Duration(seconds: 20);

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _col => _db.collection(name);

  String get _kAt => 'sync.$name.at';
  String get _kFullAt => 'sync.$name.fullAt';
  String get _kCount => 'sync.$name.count';

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _inFlight;
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? _last;
  DateTime? _lastAt;

  /// When the data was last brought up to date with the server.
  DateTime? get lastSynced => _lastAt;

  /// What this session already has, without waiting (null before the first
  /// load). Screens show it at once and refresh in the background.
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? get peek => _last;

  /// Every document of the collection, up to date with the server.
  /// [full] forces a complete download.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> load({bool full = false}) {
    final last = _last, at = _lastAt;
    if (!full && last != null && at != null && DateTime.now().difference(at) < _reuseFor) {
      return Future.value(last);
    }
    final running = _inFlight;
    if (running != null && !full) return running;
    late final Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> f;
    f = _load(full).whenComplete(() {
      if (identical(_inFlight, f)) _inFlight = null;
    });
    _inFlight = f;
    return f;
  }

  /// Remove documents this device just deleted from the session copy, so
  /// nothing shows them before the next sync.
  void dropLocal(Iterable<String> ids) {
    final gone = ids.toSet();
    final last = _last;
    if (last != null) _last = last.where((d) => !gone.contains(d.id)).toList();
  }

  /// Forget the in-memory copy so the next [load] asks the server (after
  /// this device changed something).
  void touch() {
    _lastAt = null;
    _inFlight = null;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _load(bool full) async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_kAt);
    final fullAt = prefs.getInt(_kFullAt);
    final count = prefs.getInt(_kCount);
    final now = DateTime.now();

    var needFull = full ||
        at == null ||
        fullAt == null ||
        now.difference(DateTime.fromMillisecondsSinceEpoch(fullAt)) > _fullEvery;

    List<QueryDocumentSnapshot<Map<String, dynamic>>> cached = const [];
    if (!needFull) {
      final mem = _last;
      if (mem != null) {
        // Already in memory this session: only the delta below runs, no
        // re-read of the whole on-device cache.
        cached = mem;
      } else {
        try {
          cached = (await _col.get(const GetOptions(source: Source.cache))).docs;
        } catch (_) {
          needFull = true;
        }
        // The phone cleared Firestore's cache: download everything again.
        if (count != null && count > 0 && cached.length < count * 0.9) needFull = true;
      }
    }

    if (needFull) return _fullLoad(prefs);

    try {
      final since = DateTime.fromMillisecondsSinceEpoch(at!).subtract(_overlap);
      // Older app versions don't write syncedAt yet: also pick up anything
      // created in the last two days (createdAt is a local ISO string, so the
      // margin covers time zones). With no watermark yet (0), count from now.
      final createdFrom = at == 0 ? now : since;
      final createdSince = createdFrom.subtract(const Duration(days: 2)).toIso8601String();
      final results = await Future.wait([
        _col
            .where(kSyncedAt, isGreaterThan: Timestamp.fromDate(since))
            .get(const GetOptions(source: Source.server)),
        _col
            .where('createdAt', isGreaterThanOrEqualTo: createdSince)
            .get(const GetOptions(source: Source.server)),
      ]);
      // Throws if the server's deletion markers can't be read, so the
      // watermark doesn't move past markers we never saw.
      final deleted = await _deletedIds(since: since);

      final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
        for (final d in cached) d.id: d,
      };
      var newest = at;
      var changed = false;
      for (final snap in results) {
        for (final d in snap.docs) {
          newest = max(newest, _syncedMs(d) ?? 0);
          final old = byId[d.id];
          // Same document, same server stamp: keep the copy we have (and
          // its converted data), it hasn't changed.
          if (old != null && _syncedMs(old) == _syncedMs(d)) continue;
          byId[d.id] = d;
          changed = true;
        }
      }
      for (final id in deleted) {
        if (byId.remove(id) != null) changed = true;
      }

      await prefs.setInt(_kAt, newest);
      // Nothing changed: hand back the very same list, so screens can see
      // that and skip rebuilding.
      final docs = changed ? byId.values.toList() : cached;
      await prefs.setInt(_kCount, docs.length);
      _remember(docs);
      return docs;
    } catch (e) {
      // Offline or the delta query failed: show what the phone has (the
      // watermark stays, so the next load asks again).
      debugPrint('Sync $name: delta failed, using cache: $e');
      if (cached.isNotEmpty) return _withoutDeleted(cached);
      return _fullLoad(prefs);
    }
  }

  /// [docs] minus the ones flagged by deletion markers already on the device.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _withoutDeleted(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    final gone = await _cachedDeletedIds();
    return gone.isEmpty ? docs : docs.where((d) => !gone.contains(d.id)).toList();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fullLoad(SharedPreferences prefs) async {
    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _col.get(const GetOptions(source: Source.server));
    } catch (e) {
      // Offline: fall back to whatever the device already has. Prefs are
      // left alone so the full download runs again next time.
      debugPrint('Sync $name: full download failed, using cache: $e');
      final cached = (await _col.get(const GetOptions(source: Source.cache))).docs;
      if (cached.isEmpty) rethrow;
      return _withoutDeleted(cached);
    }
    final deleted = await _deletedIds();
    final docs = snap.docs.where((d) => !deleted.contains(d.id)).toList();
    var newest = 0;
    for (final d in docs) {
      newest = max(newest, _syncedMs(d) ?? 0);
    }
    // No document has syncedAt yet (data from before this version): the
    // watermark stays 0, so the next delta picks up every document that gets
    // a syncedAt from now on, whatever this device's clock says.
    await prefs.setInt(_kAt, newest);
    await prefs.setInt(_kFullAt, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_kCount, docs.length);
    _remember(docs);
    return docs;
  }

  void _remember(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    _last = docs;
    _lastAt = DateTime.now();
  }

  static int? _syncedMs(DocumentSnapshot<Map<String, dynamic>> d) {
    final v = d.data()?[kSyncedAt];
    return v is Timestamp ? v.millisecondsSinceEpoch : null;
  }

  void _addMarkers(Set<String> out, QuerySnapshot<Map<String, dynamic>> s) {
    for (final d in s.docs) {
      if (d.data()['collection'] == name) out.add(d.data()['docId']?.toString() ?? d.id);
    }
  }

  /// Deletion markers already on the device.
  Future<Set<String>> _cachedDeletedIds() async {
    final out = <String>{};
    try {
      _addMarkers(out, await _db.collection('deletions').get(const GetOptions(source: Source.cache)));
    } catch (_) {}
    return out;
  }

  /// Ids deleted from this collection: cached markers plus the server's
  /// (all of them on a full load, only new ones on a delta). On a delta a
  /// server error is rethrown so the caller keeps its watermark.
  Future<Set<String>> _deletedIds({DateTime? since}) async {
    final col = _db.collection('deletions');
    final out = await _cachedDeletedIds();
    try {
      _addMarkers(
        out,
        await (since == null
                ? col
                : col.where(kSyncedAt, isGreaterThan: Timestamp.fromDate(since)))
            .get(const GetOptions(source: Source.server)),
      );
    } catch (e) {
      debugPrint('Sync $name: deletions not read: $e');
      if (since != null) rethrow;
    }
    return out;
  }

  /// Leaves a deletion marker so other devices drop [docId] on their next
  /// sync. Add it to the same batch that deletes the document.
  static void markDeleted(WriteBatch batch, String collection, String docId) {
    batch.set(_db.collection('deletions').doc('${collection}_$docId'), {
      'collection': collection,
      'docId': docId,
      kSyncedAt: syncedNow(),
    });
  }

  /// Pull-to-refresh: the next load asks the server for changes even if the
  /// last one was just now.
  static void touchAll() {
    entries.touch();
    receipts.touch();
  }

  /// Brings both collections up to date; true if anything changed since the
  /// last load (so a screen knows whether to recompute).
  static Future<bool> refreshChanged() async {
    final before = (entries.peek, receipts.peek);
    try {
      await Future.wait([entries.load(), receipts.load()]);
    } catch (_) {
      return false;
    }
    return !identical(before.$1, entries.peek) || !identical(before.$2, receipts.peek);
  }

  /// "Refresh all data": full download of both collections.
  static Future<void> refreshAll() async {
    await Future.wait([entries.load(full: true), receipts.load(full: true)]);
  }
}

/// Bumped after "Refresh all data" (or the signature move) so screens that
/// read synced data load again.
final syncTickProvider = StateProvider<int>((ref) => 0);

/// The admin tab just switched to (its route) and a counter, so a tab that
/// was already open refreshes quietly in the background when shown again.
final adminTabShownProvider = StateProvider<(String, int)>((ref) => ('', 0));

final Expando<Map<String, dynamic>> _dataCache = Expando('syncedData');

/// A synced document's data, converted once and then reused. Firestore's
/// `data()` builds a fresh copy of the whole document on every call, which
/// made sorting/filtering hundreds of documents slow. Receipts' inline
/// signature (older receipts) is left out: lists never draw it.
Map<String, dynamic> syncedData(DocumentSnapshot<Map<String, dynamic>> d) {
  final hit = _dataCache[d];
  if (hit != null) return hit;
  final raw = d.data() ?? const <String, dynamic>{};
  final m = Map<String, dynamic>.from(raw);
  if (d.reference.parent.id == 'receipts') m.remove('signature');
  _dataCache[d] = m;
  return m;
}
