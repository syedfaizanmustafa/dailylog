import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../models/location_prices.dart';
import '../widgets/admin_shell.dart';
import '../widgets/floating_confirmation_sheet.dart';
import '../widgets/location_price_editor.dart';
import '../widgets/shimmer.dart';

/// Sheets per location over the last 7 days (shown on each card).
final _locationWeekProvider = FutureProvider<Map<String, int>>((ref) async {
  final fmt = DateFormat('yyyy-MM-dd');
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
  final snap = await FirebaseFirestore.instance
      .collection('entries')
      .where('entryDateKey', isGreaterThanOrEqualTo: fmt.format(start))
      .get();
  final out = <String, int>{};
  for (final d in snap.docs) {
    final data = d.data();
    String? id = data['location'] is String ? data['location'] as String : null;
    if ((id == null || id.isEmpty) && data['locationRef'] is DocumentReference) {
      id = (data['locationRef'] as DocumentReference).id;
    }
    if (id == null || id.isEmpty) continue;
    final sheets = data['sheets'] is Map ? (data['sheets'] as Map).length : 0;
    out[id] = (out[id] ?? 0) + sheets;
  }
  return out;
});

/// Admin › Locations. Each yard keeps one colour everywhere in the admin.
class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen> {
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('locations');

  Future<void> _delete(AppLocation loc) async {
    final ok = await showFloatingConfirmationBottomSheet(
      context: context,
      title: 'Delete ${loc.name.isEmpty ? 'this location' : loc.name}?',
      message:
          'iPads will stop matching to this yard. Sheets already logged here keep their location name. This cannot be undone.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!ok || !mounted) return;
    try {
      await _col.doc(loc.id).delete();
      _afterChange();
      if (mounted) showAppSnack(context, 'Location deleted');
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    }
  }

  /// Keep the staff-side "nearest location" list in sync.
  void _afterChange() {
    ref.read(appControllerProvider.notifier).refreshNearest().catchError((_) {});
  }

  Future<void> _edit([AppLocation? loc]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationForm(location: loc),
    );
    if (saved == true && mounted) {
      _afterChange();
      showAppSnack(context, loc == null ? 'Location added' : 'Location saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminLocationsProvider);
    final colors = ref.watch(locationColorsProvider);
    final week = ref.watch(_locationWeekProvider).valueOrNull ?? const <String, int>{};
    final numbers = ref.watch(locationNumbersProvider).valueOrNull ?? const <String, int>{};
    final prices = ref.watch(allLocationPricesProvider).valueOrNull ?? const {};
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final hPad = narrow ? 16.0 : 28.0;
    final count = async.valueOrNull?.length;

    return AdminShell(
      section: AdminSection.locations,
      title: 'Locations',
      subtitle: count == null ? null : '$count yard${count == 1 ? '' : 's'}',
      actions: [
        FilledButton.icon(
          onPressed: () => _edit(),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.forest,
            minimumSize: const Size(0, 44),
          ),
          icon: const Icon(Icons.add_location_alt_rounded, size: 20),
          label: const Text('Add location'),
        ),
      ],
      child: async.when(
        loading: () => const SkeletonList(count: 4, itemHeight: 150),
        error: (e, _) => Center(child: Text(friendlyError(e))),
        data: (locations) {
          if (locations.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.location_off_rounded, size: 56, color: AppColors.field),
                  const SizedBox(height: 12),
                  const Text('No locations yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text('Add your first yard so iPads can match to it.',
                      style: TextStyle(color: AppColors.slate)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => _edit(),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.forest),
                    child: const Text('Add location'),
                  ),
                ],
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 1000 ? 3 : c.maxWidth >= 640 ? 2 : 1;
              const gap = 16.0;
              final w = (c.maxWidth - hPad * 2 - gap * (cols - 1)) / cols;
              return ListView(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
                children: [
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < locations.length; i++)
                        SizedBox(
                          width: w,
                          child: Entrance(
                            delay: Duration(milliseconds: 40 * i),
                            child: _LocationCard(
                              location: locations[i],
                              color: colorForLocation(colors, locations[i].id),
                              sheetsThisWeek: week[locations[i].id] ?? 0,
                              number: numbers[locations[i].id],
                              prices: prices[locations[i].id]?.$1,
                              pricesLoaded: prices.isNotEmpty,
                              onEditPrices: () => showLocationPriceEditor(
                                context: context,
                                location: locations[i],
                                current: prices[locations[i].id]?.$1,
                                history: prices[locations[i].id]?.$2 ?? const [],
                                otherLocations: {
                                  for (final l in locations)
                                    if (l.id != locations[i].id && prices[l.id]?.$1 != null)
                                      l.id: (l.name, prices[l.id]!.$1!),
                                },
                              ),
                              onEdit: () => _edit(locations[i]),
                              onDelete: () => _delete(locations[i]),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Each location keeps one colour everywhere — overview chart, log sheets and receipts.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.slate),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final AppLocation location;
  final Color color;
  final int sheetsThisWeek;
  final int? number;
  final LocationPrices? prices;
  final bool pricesLoaded;
  final VoidCallback onEditPrices;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LocationCard({
    required this.location,
    required this.color,
    required this.sheetsThisWeek,
    this.number,
    this.prices,
    this.pricesLoaded = false,
    required this.onEditPrices,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasCoords = location.latitude != 0 || location.longitude != 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Colour band with the logo arc as a "pin"
            Container(
              height: 64,
              color: color.withValues(alpha: 0.14),
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    right: -30,
                    top: -40,
                    // Faint watermark so the header's icons and text stay clear.
                    child: Opacity(
                      opacity: 0.12,
                      child: BrandMark(size: 140, arc: color, head: color),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          child: const Icon(Icons.location_on_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            location.name.isEmpty ? '(Unnamed)' : location.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.navy,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit',
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_rounded, color: AppColors.navy, size: 20),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red, size: 20),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    location.address.isEmpty ? 'No address on file' : location.address,
                    style: TextStyle(
                      color: location.address.isEmpty ? AppColors.slate : AppColors.navy,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (number != null)
                        StatusPill(
                          label: 'Location ${number.toString().padLeft(2, '0')}',
                          bg: AppColors.navy,
                          fg: Colors.white,
                          icon: Icons.tag_rounded,
                        ),
                      StatusPill(
                        label: location.certification.isEmpty
                            ? 'No cert #'
                            : 'Cert # ${location.certification}',
                        bg: location.certification.isEmpty ? AppColors.redTint : AppColors.cream,
                        fg: location.certification.isEmpty ? AppColors.redText : AppColors.forest,
                        icon: Icons.verified_rounded,
                      ),
                      StatusPill(
                        label: '$sheetsThisWeek sheet${sheetsThisWeek == 1 ? '' : 's'} this week',
                        bg: AppColors.mist,
                        fg: AppColors.navy,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _PricesStrip(prices: prices, loaded: pricesLoaded, onEdit: onEditPrices),
                  if (hasCoords) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.my_location_rounded, size: 15, color: AppColors.slate),
                        const SizedBox(width: 6),
                        Text(
                          '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.slate,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 10),
                    const Text(
                      'No GPS position — iPads can’t auto-match to this yard',
                      style: TextStyle(fontSize: 12.5, color: AppColors.redText),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add / edit form
// ─────────────────────────────────────────────────────────────────────────────

/// Prices on a location card: the three $/lb prices and an Edit button,
/// or a red "not set" warning.
class _PricesStrip extends StatelessWidget {
  final LocationPrices? prices;
  final bool loaded;
  final VoidCallback onEdit;
  const _PricesStrip({required this.prices, required this.loaded, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final p = prices;
    final missing = loaded && p == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: missing ? AppColors.redTint : AppColors.cream,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.sell_outlined, size: 18, color: missing ? AppColors.redText : AppColors.forest),
          const SizedBox(width: 8),
          Expanded(
            child: p == null
                ? Text(
                    missing ? 'Prices not set · sheets use standard prices' : 'Loading prices…',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: missing ? AppColors.redText : AppColors.slate,
                    ),
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      for (final (k, label) in const [('aluminum', 'Alum.'), ('glass', 'Glass'), ('pete', 'PETE')])
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '$label ', style: const TextStyle(color: AppColors.slate)),
                            TextSpan(
                              text: LocationPrices.fmt(p[k]),
                              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy),
                            ),
                          ]),
                          style: const TextStyle(fontSize: 13),
                        ),
                      const Text('per lb', style: TextStyle(fontSize: 12, color: AppColors.slate)),
                      if (p.other.isNotEmpty)
                        Text(
                          '+ ${p.other.length} other ${p.other.length == 1 ? 'code' : 'codes'}',
                          style: const TextStyle(fontSize: 12, color: AppColors.slate),
                        ),
                    ],
                  ),
          ),
          TextButton(
            onPressed: onEdit,
            child: Text(p == null ? 'Set prices' : 'Edit prices',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _LocationForm extends StatefulWidget {
  final AppLocation? location;
  const _LocationForm({this.location});

  @override
  State<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends State<_LocationForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.location?.name ?? '');
  late final _address = TextEditingController(text: widget.location?.address ?? '');
  late final _cert = TextEditingController(text: widget.location?.certification ?? '');
  late final _lat = TextEditingController(
    text: _coord(widget.location?.latitude),
  );
  late final _lng = TextEditingController(
    text: _coord(widget.location?.longitude),
  );
  bool _saving = false;
  bool _locating = false;
  String? _error;

  static String _coord(double? v) => v == null || v == 0 ? '' : v.toString();

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _cert.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _useHere() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('Location permission is off for this app. Turn it on in Settings.');
      }
      final p = await Geolocator.getCurrentPosition();
      _lat.text = p.latitude.toStringAsFixed(6);
      _lng.text = p.longitude.toStringAsFixed(6);
      HapticFeedback.selectionClick();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final data = <String, dynamic>{
        'name': _name.text.trim(),
        'coordinates': {
          'lat': double.parse(_lat.text.trim()),
          'lng': double.parse(_lng.text.trim()),
        },
        'address': _address.text.trim(),
        'certification': _cert.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final col = FirebaseFirestore.instance.collection('locations');
      if (widget.location == null) {
        data['createdAt'] = FieldValue.serverTimestamp();
        await col.add(data);
      } else {
        await col.doc(widget.location!.id).update(data);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e);
      });
    }
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.field),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.navy, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.red, width: 2),
        ),
      );

  String? _num(String? v, double min, double max) {
    final d = double.tryParse(v?.trim() ?? '');
    if (d == null) return 'Required';
    if (d < min || d > max) return 'Out of range';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.location != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      editing ? 'Edit location' : 'Add location',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: _dec('Location name', hint: 'e.g. Rio Linda'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _address,
                      decoration: _dec('Address (printed on receipts)'),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _cert,
                      textCapitalization: TextCapitalization.characters,
                      decoration: _dec('Certification #', hint: 'RC-xxxxx'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _lat,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                            decoration: _dec('Latitude'),
                            validator: (v) => _num(v, -90, 90),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _lng,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                            decoration: _dec('Longitude'),
                            validator: (v) => _num(v, -180, 180),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _locating || _saving ? null : _useHere,
                        icon: _locating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.my_location_rounded, size: 18),
                        label: const Text("Use this iPad's location"),
                      ),
                    ),
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.redTint,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!, style: const TextStyle(color: AppColors.redText)),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.forest,
                              minimumSize: const Size(0, 50),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(editing ? 'Save' : 'Add location'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
