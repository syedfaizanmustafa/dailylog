import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../models/location_prices.dart';
import 'admin_shell.dart';

const _colors = {'aluminum': AppColors.blue, 'glass': AppColors.green, 'pete': AppColors.amber};

/// Admin: edit one location's $/lb prices (Aluminum, Glass, PETE and the
/// other-commodity codes). Changes apply to entries started after the save;
/// entries already started keep their prices. Each save is kept in the price
/// history.
Future<void> showLocationPriceEditor({
  required BuildContext context,
  required AppLocation location,
  required LocationPrices? current,
  required List<PriceChange> history,
  required Map<String, (String, LocationPrices)> otherLocations,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (_) => _PriceEditor(
      location: location,
      current: current,
      history: history,
      otherLocations: otherLocations,
    ),
  );
}

class _PriceEditor extends ConsumerStatefulWidget {
  final AppLocation location;
  final LocationPrices? current;
  final List<PriceChange> history;
  final Map<String, (String, LocationPrices)> otherLocations;

  const _PriceEditor({
    required this.location,
    required this.current,
    required this.history,
    required this.otherLocations,
  });

  @override
  ConsumerState<_PriceEditor> createState() => _PriceEditorState();
}

class _PriceEditorState extends ConsumerState<_PriceEditor> {
  /// Aluminum / Glass / PETE.
  late final Map<String, TextEditingController> _main;

  /// Other commodities by code. Empty = priced by hand on the sheet.
  late final Map<String, TextEditingController> _other;

  bool _saving = false;
  bool _showHistory = false;

  LocationPrices get _base => widget.current ?? LocationPrices.standard;

  @override
  void initState() {
    super.initState();
    _main = {
      for (final k in LocationPrices.mainKeys)
        k: TextEditingController(text: LocationPrices.edit(_base[k])),
    };
    _other = {
      for (final (code, _) in kOtherCommodityCodes)
        code: TextEditingController(
          text: _base.otherFor(code) == null ? '' : LocationPrices.edit(_base.otherFor(code)!),
        ),
    };
  }

  @override
  void dispose() {
    for (final c in [..._main.values, ..._other.values]) {
      c.dispose();
    }
    super.dispose();
  }

  (double?, String?) _readMain(String k) => LocationPrices.parse(_main[k]!.text);
  (double?, String?) _readOther(String code) =>
      LocationPrices.parse(_other[code]!.text, optional: true);

  /// What is typed, or null while any field has an error.
  LocationPrices? get _entered {
    final v = {for (final k in LocationPrices.mainKeys) k: _readMain(k)};
    if (v.values.any((x) => x.$1 == null)) return null;
    final other = <String, double>{};
    for (final (code, _) in kOtherCommodityCodes) {
      final (value, error) = _readOther(code);
      if (error != null) return null;
      if (value != null) other[code] = value;
    }
    return LocationPrices(
      aluminum: v['aluminum']!.$1!,
      glass: v['glass']!.$1!,
      pete: v['pete']!.$1!,
      other: other,
    );
  }

  bool get _changed {
    final e = _entered;
    if (e == null) return false;
    return widget.current == null || !e.sameAs(widget.current!);
  }

  void _copyFrom(LocationPrices p) {
    setState(() {
      for (final k in LocationPrices.mainKeys) {
        _main[k]!.text = LocationPrices.edit(p[k]);
      }
      for (final (code, _) in kOtherCommodityCodes) {
        final v = p.otherFor(code);
        _other[code]!.text = v == null ? '' : LocationPrices.edit(v);
      }
    });
  }

  String _show(double? v) => v == null ? 'by hand' : '${LocationPrices.fmt(v)}/lb';

  /// Lines that differ from the saved prices, for the confirm dialog.
  List<(String, String, String)> _changes(LocationPrices next) {
    final old = widget.current;
    final out = <(String, String, String)>[];
    for (final k in LocationPrices.mainKeys) {
      final before = old?[k];
      if (before == null || (before - next[k]).abs() > 1e-9) {
        out.add((LocationPrices.labels[k]!, before == null ? '—' : _show(before), _show(next[k])));
      }
    }
    for (final (code, label) in kOtherCommodityCodes) {
      final before = old?.otherFor(code);
      final after = next.otherFor(code);
      final same = before == null ? after == null : (after != null && (before - after).abs() < 1e-9);
      if (!same) out.add(('$code $label', _show(before), _show(after)));
    }
    return out;
  }

  Future<void> _save() async {
    final next = _entered;
    if (next == null) return;
    final changes = _changes(next);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Save prices for ${widget.location.name}?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, before, after) in changes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      Expanded(child: Text('$before → $after')),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Entries started at this location from now on use these prices, on every device. '
                'Entries already started (and submitted sheets) keep the prices they started with.',
                style: TextStyle(fontSize: 13, color: AppColors.slate),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Back')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.forest),
            child: const Text('Save prices'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final users = ref.read(adminUsersProvider).valueOrNull ?? const <AdminUser>[];
      final me = users.where((u) => u.id == user?.uid).firstOrNull;
      await LocationPrices.save(
        locationId: widget.location.id,
        prices: next,
        byUid: user?.uid ?? '',
        byName: me?.displayName ?? user?.email ?? 'Admin',
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text('Prices saved for ${widget.location.name}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnack(context, 'Prices not saved: ${friendlyError(e)}', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entered = _entered;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Prices · ${widget.location.name}',
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.navy)),
            const SizedBox(height: 4),
            const Text(
              'Price per pound of SW weight. New Entry multiplies the weight by these to fill '
              'Total Paid. Staff can still lower a row\'s Total Paid for a discount.',
              style: TextStyle(fontSize: 13, color: AppColors.slate),
            ),
            const SizedBox(height: 10),
            if (widget.current == null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.amberSoft,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.amberLine),
                ),
                child: const Text(
                  'No prices set for this location yet. Sheets here use the standard prices '
                  'below until you save.',
                  style: TextStyle(fontSize: 13, color: AppColors.amberText),
                ),
              )
            else if (widget.current!.updatedAt != null)
              Text(
                'Last changed ${DateFormat('MMM d, yyyy h:mm a').format(widget.current!.updatedAt!.toLocal())}'
                '${widget.current!.updatedByName.isEmpty ? '' : ' by ${widget.current!.updatedByName}'}',
                style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
              ),
            if (widget.otherLocations.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<LocationPrices>(
                  onSelected: _copyFrom,
                  itemBuilder: (_) => [
                    for (final e in widget.otherLocations.values)
                      PopupMenuItem(
                        value: e.$2,
                        child: Text(
                          '${e.$1}:  ${LocationPrices.fmt(e.$2.aluminum)} · ${LocationPrices.fmt(e.$2.glass)} · ${LocationPrices.fmt(e.$2.pete)}',
                        ),
                      ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 18, color: AppColors.blue),
                        SizedBox(width: 6),
                        Text('Copy prices from another location',
                            style: TextStyle(color: AppColors.blue, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            for (final k in LocationPrices.mainKeys) _mainField(k),
            const SizedBox(height: 4),
            const Text('Other commodities',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy)),
            const SizedBox(height: 2),
            const Text(
              'Leave a code empty to keep pricing it by hand on the sheet. Use 0 for codes you take '
              'without paying (e.g. scrap).',
              style: TextStyle(fontSize: 12.5, color: AppColors.slate),
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth >= 520 ? 2 : 1;
                final w = (c.maxWidth - (cols - 1) * 12) / cols;
                return Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    for (final (code, label) in kOtherCommodityCodes)
                      SizedBox(width: w, child: _otherField(code, label)),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      foregroundColor: AppColors.navy,
                      side: const BorderSide(color: AppColors.field),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: AppColors.forest,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _saving || entered == null || !_changed ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_rounded),
                    label: Text(entered == null
                        ? 'Fix the prices above'
                        : (_changed ? 'Save prices' : 'No changes')),
                  ),
                ),
              ],
            ),
            if (widget.history.isNotEmpty) ...[
              const SizedBox(height: 14),
              InkWell(
                onTap: () => setState(() => _showHistory = !_showHistory),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.history_rounded, size: 18, color: AppColors.slate),
                      const SizedBox(width: 6),
                      Text('Price history (${widget.history.length})',
                          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy)),
                      Icon(_showHistory ? Icons.expand_less : Icons.expand_more, color: AppColors.slate),
                    ],
                  ),
                ),
              ),
              if (_showHistory)
                for (final h in widget.history.take(15))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${DateFormat('MMM d, yyyy h:mm a').format(h.at.toLocal())}'
                      '${h.byName.isEmpty ? '' : ' · ${h.byName}'}\n'
                      'Al ${LocationPrices.fmt(h.prices.aluminum)} · Glass ${LocationPrices.fmt(h.prices.glass)}'
                      ' · PETE ${LocationPrices.fmt(h.prices.pete)}'
                      '${h.prices.other.isEmpty ? '' : ' · ${h.prices.other.entries.map((e) => '${e.key} ${LocationPrices.fmt(e.value)}').join(' · ')}'}',
                      style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.slate),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  static final _priceInput = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.$]'))];

  Widget _mainField(String k) {
    final (value, error) = _readMain(k);
    final example = value == null ? null : NumberFormat.currency(symbol: '\$').format(value * 10);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 18),
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: _colors[k], borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _main[k],
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: _priceInput,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: LocationPrices.labels[k],
                prefixText: '\$ ',
                suffixText: '/ lb',
                errorText: error,
                helperText: error != null
                    ? null
                    : [
                        if (widget.current != null) 'Now ${LocationPrices.fmt(widget.current![k])}',
                        if (example != null) '10 lb pays $example',
                      ].join('  ·  '),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _otherField(String code, String label) {
    final (_, error) = _readOther(code);
    final now = widget.current?.otherFor(code);
    return TextField(
      controller: _other[code],
      enabled: !_saving,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: _priceInput,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        isDense: true,
        labelText: '$code · $label',
        hintText: 'By hand',
        prefixText: '\$ ',
        suffixText: '/ lb',
        errorText: error,
        helperText: error != null || widget.current == null
            ? null
            : 'Now ${now == null ? 'by hand' : LocationPrices.fmt(now)}',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
