import 'dart:math' show cos, sin, sqrt, asin;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

class AppLocation {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;

  const AppLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  static AppLocation? fromDoc(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>;
      final coords = (data['coordinates'] as Map<String, dynamic>?) ?? {};
      final lat = (coords['lat'] as num?)?.toDouble();
      final lng = (coords['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return AppLocation(
        id: doc.id,
        name: data['name']?.toString() ?? '',
        address: data['address']?.toString() ?? '',
        latitude: lat,
        longitude: lng,
      );
    } catch (_) {
      return null;
    }
  }
}

class AppState {
  final List<AppLocation> locations;
  final AppLocation? nearestLocation;
  final Position? currentPosition;
  final bool initialized;

  const AppState({
    required this.locations,
    required this.nearestLocation,
    required this.currentPosition,
    required this.initialized,
  });

  AppState copyWith({
    List<AppLocation>? locations,
    AppLocation? nearestLocation,
    Position? currentPosition,
    bool? initialized,
  }) {
    return AppState(
      locations: locations ?? this.locations,
      nearestLocation: nearestLocation ?? this.nearestLocation,
      currentPosition: currentPosition ?? this.currentPosition,
      initialized: initialized ?? this.initialized,
    );
  }

  const AppState.initial()
      : locations = const [],
        nearestLocation = null,
        currentPosition = null,
        initialized = false;
}

class AppController extends StateNotifier<AppState> {
  AppController() : super(const AppState.initial()) {
    _initialize();
  }

  Future<void> _initialize() async {
    // On fresh app start, always fetch fresh locations
    final locations = await _fetchLocationsOnce();
    final position = await _getPositionWithFallback();
    final nearest = _computeNearestWithLogging(locations, position, source: 'initialize');
    state = state.copyWith(
      locations: locations,
      currentPosition: position,
      nearestLocation: nearest,
      initialized: true,
    );
  }

  Future<List<AppLocation>> _fetchLocationsOnce() async {
    final query = await FirebaseFirestore.instance
        .collection('locations')
        .orderBy('name')
        .get();
    final list = <AppLocation>[];
    for (final doc in query.docs) {
      final loc = AppLocation.fromDoc(doc);
      if (loc != null) list.add(loc);
    }
    return list;
  }

  AppLocation? _computeNearest(List<AppLocation> locations, Position? p) {
    if (p == null || locations.isEmpty) return null;
    double best = double.infinity;
    AppLocation? bestLoc;
    for (final loc in locations) {
      final d = _haversineDistanceKm(p.latitude, p.longitude, loc.latitude, loc.longitude);
      if (d < best) {
        best = d;
        bestLoc = loc;
      }
    }
    return bestLoc;
  }

  AppLocation? _computeNearestWithLogging(List<AppLocation> locations, Position? p, {required String source}) {
    if (p == null || locations.isEmpty) {
      // ignore: avoid_print
      print('[AppController] No position or locations for nearest calculation ($source)');
      return null;
    }
    double best = double.infinity;
    AppLocation? bestLoc;
    for (final loc in locations) {
      final d = _haversineDistanceKm(p.latitude, p.longitude, loc.latitude, loc.longitude);
      // ignore: avoid_print
      print('[AppController] Distance to "${loc.name}" (${loc.latitude},${loc.longitude}) = ${d.toStringAsFixed(3)} km');
      if (d < best) {
        best = d;
        bestLoc = loc;
      }
    }
    if (bestLoc != null) {
      // ignore: avoid_print
      print('[AppController] Nearest ($source): ${bestLoc.name} at ${best.toStringAsFixed(3)} km');
    }
    return bestLoc;
  }

  double _haversineDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * asin(sqrt(a));
    return earthRadiusKm * c;
  }

  double _deg2rad(double deg) => deg * (3.141592653589793 / 180.0);

  Future<Position?> _getPositionWithFallback() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }

      try {
        // Try a quick fix first for speed
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          return last;
        }
      } catch (_) {}

      // Fall back to a fresh high-accuracy reading
      return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);
    } catch (e) {
      // ignore: avoid_print
      print('[AppController] Error getting position: $e');
      return null;
    }
  }

  // Public: Recalculate nearest location (and optionally refetch locations)
  Future<void> refreshNearest({bool refetchLocations = true}) async {
    List<AppLocation> locations = state.locations;
    if (refetchLocations || locations.isEmpty) {
      locations = await _fetchLocationsOnce();
    }

    final position = await _getPositionWithFallback();

    final nearest = _computeNearestWithLogging(locations, position, source: 'refresh');
    state = state.copyWith(
      locations: locations,
      currentPosition: position,
      nearestLocation: nearest,
      initialized: true,
    );
  }
}

final appControllerProvider = StateNotifierProvider<AppController, AppState>((ref) {
  return AppController();
});


