import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../controllers/app_controller.dart';
import '../widgets/floating_confirmation_sheet.dart';
import '../widgets/logout_confirmation_sheet.dart';

/// One day's sheet counts by location for the chart.
class ChartDayData {
  final String dateKey;
  final DateTime date;
  final Map<String, int> sheetsByLocationId;

  const ChartDayData({
    required this.dateKey,
    required this.date,
    required this.sheetsByLocationId,
  });
}

/// Chart data for a date range (e.g. last 7 days).
class ChartDataResult {
  final List<ChartDayData> days;
  final int totalSheets;

  const ChartDataResult({required this.days, required this.totalSheets});
}

/// Selected location IDs for the chart filter. Null = all locations.
final chartSelectedLocationIdsProvider =
    StateProvider<Set<String>?>((ref) => null);

/// Date range for the chart. Defaults to last 7 days.
class ChartDateRange {
  final DateTime start;
  final DateTime end;

  const ChartDateRange({required this.start, required this.end});

  static ChartDateRange get defaultRange {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final start = end.subtract(const Duration(days: 6));
    return ChartDateRange(start: start, end: end);
  }
}

final chartDateRangeProvider =
    StateProvider<ChartDateRange>((ref) => ChartDateRange.defaultRange);

final chartDataProvider = FutureProvider<ChartDataResult>((ref) async {
  final range = ref.watch(chartDateRangeProvider);
  final startDate = DateTime(range.start.year, range.start.month, range.start.day);
  final endDate = DateTime(range.end.year, range.end.month, range.end.day);
  final startKey = DateFormat('yyyy-MM-dd').format(startDate);
  final endKey = DateFormat('yyyy-MM-dd').format(endDate);

  final snapshot = await FirebaseFirestore.instance
      .collection('entries')
      .where('entryDateKey', isGreaterThanOrEqualTo: startKey)
      .where('entryDateKey', isLessThanOrEqualTo: endKey)
      .get();

  final byDate = <String, Map<String, int>>{};
  int totalSheets = 0;

  for (final doc in snapshot.docs) {
    final data = doc.data();
    String? locationId = data['location'] as String?;
    if (locationId == null && data['locationRef'] != null) {
      locationId = (data['locationRef'] as DocumentReference).id;
    }
    final dateKey = data['entryDateKey'] as String? ?? '';
    if (dateKey.isEmpty) continue;
    final sheets = data['sheets'] as Map<String, dynamic>? ?? {};
    final count = sheets.length;
    totalSheets += count;
    byDate.putIfAbsent(dateKey, () => {});
    final locId = locationId ?? '';
    byDate[dateKey]![locId] = (byDate[dateKey]![locId] ?? 0) + count;
  }

  final days = <ChartDayData>[];
  for (int d = 0; d <= endDate.difference(startDate).inDays; d++) {
    final date = startDate.add(Duration(days: d));
    final key = DateFormat('yyyy-MM-dd').format(date);
    final byLoc = byDate[key] ?? {};
    days.add(ChartDayData(
      dateKey: key,
      date: date,
      sheetsByLocationId: Map.from(byLoc),
    ));
  }

  return ChartDataResult(days: days, totalSheets: totalSheets);
});

class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasDraft = ref.watch(hasDraftProvider).valueOrNull ?? false;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(
          'Admin Dashboard',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        elevation: 0,
        scrolledUnderElevation: 4,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: IconButton.filledTonal(
              icon: const Icon(Icons.logout_rounded),
              tooltip: 'Sign out',
              onPressed: () => showLogoutConfirmationBottomSheet(context, ref),
            ),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _WelcomeHeader(theme: theme, colorScheme: colorScheme),
          ),
          SliverToBoxAdapter(
            child: _SheetsChartSection(theme: theme, colorScheme: colorScheme),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.touch_app_rounded,
                    size: 20,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Quick actions',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildOptionTile(
                  context,
                  title: 'Manage Users',
                  description: 'Add, edit, or remove user accounts',
                  icon: Icons.people_rounded,
                  iconColor: colorScheme.primary,
                  onTap: () => context.push('/admin/users'),
                ),
                _buildOptionTile(
                  context,
                  title: hasDraft ? 'Edit Draft' : 'New Entry',
                  description: hasDraft
                      ? 'Continue your saved draft'
                      : 'Create a new daily log entry',
                  icon: hasDraft ? Icons.edit_note : Icons.add_circle_rounded,
                  iconColor: colorScheme.tertiary,
                  onTap: () => context.push('/new-entry'),
                ),
                if (hasDraft)
                  _buildOptionTile(
                    context,
                    title: 'Delete Draft',
                    description: 'Discard the saved draft permanently',
                    icon: Icons.delete_outline_rounded,
                    iconColor: colorScheme.error,
                    onTap: () async {
                      final confirmed =
                          await showFloatingConfirmationBottomSheet(
                        context: context,
                        title: 'Delete draft?',
                        message:
                            'This will permanently discard your saved draft.',
                        confirmLabel: 'Delete',
                        cancelLabel: 'Cancel',
                      );
                      if (!confirmed) return;
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.remove(kDraftSheetKey);
                      ref.invalidate(hasDraftProvider);
                    },
                  ),
                _buildOptionTile(
                  context,
                  title: 'Manage Log Sheets',
                  description: 'View and manage daily log entries',
                  icon: Icons.assignment_rounded,
                  iconColor: const Color(0xFF4A6FA5), // blue matte
                  onTap: () => context.push('/admin/logs'),
                ),
                _buildOptionTile(
                  context,
                  title: 'Manage Locations',
                  description: 'Add and edit locations',
                  icon: Icons.location_on_rounded,
                  iconColor: Colors.teal,
                  onTap: () => context.push('/admin/locations'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionTile(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outline.withOpacity(0.3),
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: iconColor.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: iconColor,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withOpacity(0.7),
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 14,
                  color: colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({
    required this.theme,
    required this.colorScheme,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Welcome back',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Admin',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'What would you like to manage?',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetsChartSection extends ConsumerWidget {
  const _SheetsChartSection({
    required this.theme,
    required this.colorScheme,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;

  static const Color _chartBackground = Color(0xFF2C2C2E);
  static const Color _chartText = Color(0xFFE5E5EA);
  static const Color _chartTextMuted = Color(0xFF8E8E93);
  static const List<Color> _chartBarColors = [
    Color(0xFF64B5F6), // light blue (primary over dark)
    Color(0xFF4FC3F7), // cyan blue
    Color(0xFF81C784), // light green
    Color(0xFFAED581), // light lime
    Color(0xFFFFB74D), // amber
    Color(0xFFBA68C8), // purple
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chartAsync = ref.watch(chartDataProvider);
    final locations = ref.watch(appControllerProvider).locations;
    final selectedIds = ref.watch(chartSelectedLocationIdsProvider);
    final dateRange = ref.watch(chartDateRangeProvider);
    final sortedLocations = List.of(locations)..sort((a, b) => a.name.compareTo(b.name));
    final effectiveIds = selectedIds ?? sortedLocations.map((l) => l.id).toSet();
    final filteredLocations = sortedLocations.where((l) => effectiveIds.contains(l.id)).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _chartBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _chartTextMuted.withValues(alpha: 0.2),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bar_chart_rounded,
                  size: 22,
                  color: _chartBarColors.first,
                ),
                const SizedBox(width: 8),
                Text(
                  'Sheets',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: _chartText,
                  ),
                ),
                const Spacer(),
                chartAsync.when(
                  data: (result) => Text(
                    'total ${result.totalSheets}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: _chartTextMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.calendar_month_rounded),
                  tooltip: 'Date range',
                  color: _chartTextMuted,
                  onPressed: () => _showDateFilterBottomSheet(context, ref, dateRange),
                ),
                IconButton(
                  icon: const Icon(Icons.filter_list_rounded),
                  tooltip: 'Filter locations',
                  color: _chartTextMuted,
                  onPressed: () => _showLocationFilterBottomSheet(context, ref, sortedLocations, effectiveIds),
                ),
              ],
            ),
            chartAsync.when(
              data: (result) {
                if (result.days.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 24, bottom: 16),
                    child: Center(
                      child: Text(
                        'No data for this period.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _chartTextMuted,
                        ),
                      ),
                    ),
                  );
                }
                final periodStart = result.days.first.date;
                final periodEnd = result.days.last.date;
                final periodLabel =
                    '${DateFormat('MMM d, yyyy').format(periodStart)} – ${DateFormat('MMM d, yyyy').format(periodEnd)}';
                final maxY = _maxY(result.days, filteredLocations);
                final interval = (maxY / 4).clamp(1.0, double.infinity);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        periodLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _chartText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 200,
                      child: BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          maxY: maxY,
                          barGroups: result.days.asMap().entries.map((entry) {
                            final dayIndex = entry.key;
                            final day = entry.value;
                            final stackItems = <BarChartRodStackItem>[];
                            double fromY = 0;
                            for (int i = 0; i < filteredLocations.length; i++) {
                              final loc = filteredLocations[i];
                              final count = (day.sheetsByLocationId[loc.id] ?? 0).toDouble();
                              if (count > 0) {
                                final toY = fromY + count;
                                stackItems.add(
                                  BarChartRodStackItem(
                                    fromY,
                                    toY,
                                    _chartBarColors[i % _chartBarColors.length],
                                  ),
                                );
                                fromY = toY;
                              }
                            }
                            if (stackItems.isEmpty) {
                              stackItems.add(
                                BarChartRodStackItem(
                                  0,
                                  0.5,
                                  _chartTextMuted.withValues(alpha: 0.3),
                                ),
                              );
                            }
                            return BarChartGroupData(
                              x: dayIndex,
                              barRods: [
                                BarChartRodData(
                                  toY: stackItems.isEmpty ? 0.5 : fromY,
                                  fromY: 0,
                                  rodStackItems: stackItems.isEmpty
                                      ? [
                                          BarChartRodStackItem(
                                            0,
                                            0.5,
                                            _chartTextMuted.withValues(alpha: 0.2),
                                          ),
                                        ]
                                      : stackItems,
                                  color: Colors.transparent,
                                  width: 20,
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                ),
                              ],
                              showingTooltipIndicators: [],
                            );
                          }).toList(),
                          titlesData: FlTitlesData(
                            show: true,
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                getTitlesWidget: (value, meta) {
                                  final i = value.toInt();
                                  if (i >= 0 && i < result.days.length) {
                                    final d = result.days[i].date;
                                    final dayOfWeek = DateFormat('EEE').format(d);
                                    final dateStr = DateFormat('M/d').format(d);
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          Text(
                                            dayOfWeek,
                                            style: theme.textTheme.labelSmall?.copyWith(
                                              color: _chartTextMuted,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            dateStr,
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: _chartText,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                                reservedSize: 44,
                                interval: 1,
                              ),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                getTitlesWidget: (value, meta) {
                                  return Text(
                                    value >= 1000 ? '${(value / 1000).round()}k' : value.toInt().toString(),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: _chartTextMuted,
                                    ),
                                  );
                                },
                                reservedSize: 28,
                                interval: interval,
                              ),
                            ),
                            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: true,
                            horizontalInterval: interval,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: _chartTextMuted.withValues(alpha: 0.15),
                              strokeWidth: 1,
                            ),
                            getDrawingVerticalLine: (value) => FlLine(
                              color: _chartTextMuted.withValues(alpha: 0.1),
                              strokeWidth: 1,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                        ),
                        duration: const Duration(milliseconds: 150),
                      ),
                    ),
                  ],
                );
              },
              loading: () => Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _chartBarColors.first,
                    ),
                  ),
                ),
              ),
              error: (_, __) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Could not load chart data.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: _chartTextMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _maxY(List<ChartDayData> days, List<AppLocation> locations) {
    double max = 0;
    for (final day in days) {
      double sum = 0;
      for (final loc in locations) {
        sum += (day.sheetsByLocationId[loc.id] ?? 0).toDouble();
      }
      if (sum > max) max = sum;
    }
    if (max <= 0) return 4;
    if (max <= 4) return 4;
    return (max * 1.2).ceilToDouble();
  }

  void _showDateFilterBottomSheet(
    BuildContext context,
    WidgetRef ref,
    ChartDateRange currentRange,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: _DateFilterBottomSheet(
        theme: theme,
        colorScheme: colorScheme,
        initialStart: currentRange.start,
        initialEnd: currentRange.end,
        onApply: (start, end) {
          ref.read(chartDateRangeProvider.notifier).state =
              ChartDateRange(start: start, end: end);
          Navigator.of(ctx).pop();
        },
        ),
      ),
    );
  }

  void _showLocationFilterBottomSheet(
    BuildContext context,
    WidgetRef ref,
    List<AppLocation> locations,
    Set<String> currentSelection,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: _LocationFilterBottomSheet(
          theme: theme,
          colorScheme: colorScheme,
          locations: locations,
          initialSelection: Set.from(currentSelection),
          onApply: (selectedIds) {
            ref.read(chartSelectedLocationIdsProvider.notifier).state =
                selectedIds.length == locations.length ? null : selectedIds;
            Navigator.of(ctx).pop();
          },
        ),
      ),
    );
  }
}

class _CupertinoDatePickerSheet extends StatefulWidget {
  const _CupertinoDatePickerSheet({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_CupertinoDatePickerSheet> createState() =>
      _CupertinoDatePickerSheetState();
}

class _CupertinoDatePickerSheetState extends State<_CupertinoDatePickerSheet> {
  late DateTime _picked;

  @override
  void initState() {
    super.initState();
    _picked = widget.initialDate;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 48),
              Text(
                'Select date',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_picked),
                child: const Text('Done'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: theme.brightness,
                primaryColor: colorScheme.primary,
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _picked,
                minimumDate: widget.firstDate,
                maximumDate: widget.lastDate,
                onDateTimeChanged: (DateTime value) {
                  setState(() => _picked = value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateFilterBottomSheet extends StatefulWidget {
  const _DateFilterBottomSheet({
    required this.theme,
    required this.colorScheme,
    required this.initialStart,
    required this.initialEnd,
    required this.onApply,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final DateTime initialStart;
  final DateTime initialEnd;
  final void Function(DateTime start, DateTime end) onApply;

  @override
  State<_DateFilterBottomSheet> createState() => _DateFilterBottomSheetState();
}

class _DateFilterBottomSheetState extends State<_DateFilterBottomSheet> {
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    _start = DateTime(widget.initialStart.year, widget.initialStart.month, widget.initialStart.day);
    _end = DateTime(widget.initialEnd.year, widget.initialEnd.month, widget.initialEnd.day);
  }

  static Future<DateTime?> _showCupertinoDatePickerSheet({
    required BuildContext context,
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: _CupertinoDatePickerSheet(
          initialDate: initialDate,
          firstDate: firstDate,
          lastDate: lastDate,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final colorScheme = widget.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outline.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Date range',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  title: Text(
                    'From',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  subtitle: Text(
                    DateFormat('MMM d, yyyy').format(_start),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () async {
                    final picked = await _showCupertinoDatePickerSheet(
                      context: context,
                      initialDate: _start,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null && mounted) {
                      setState(() {
                        _start = picked;
                        if (_end.isBefore(_start)) _end = _start;
                      });
                    }
                  },
                ),
              ),
              Expanded(
                child: ListTile(
                  title: Text(
                    'To',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  subtitle: Text(
                    DateFormat('MMM d, yyyy').format(_end),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () async {
                    final picked = await _showCupertinoDatePickerSheet(
                      context: context,
                      initialDate: _end,
                      firstDate: _start,
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null && mounted) {
                      setState(() => _end = picked);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => widget.onApply(_start, _end),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

class _LocationFilterBottomSheet extends ConsumerStatefulWidget {
  const _LocationFilterBottomSheet({
    required this.theme,
    required this.colorScheme,
    required this.locations,
    required this.initialSelection,
    required this.onApply,
  });

  final ThemeData theme;
  final ColorScheme colorScheme;
  final List<AppLocation> locations;
  final Set<String> initialSelection;
  final void Function(Set<String> selectedIds) onApply;

  @override
  ConsumerState<_LocationFilterBottomSheet> createState() =>
      _LocationFilterBottomSheetState();
}

class _LocationFilterBottomSheetState
    extends ConsumerState<_LocationFilterBottomSheet> {
  late Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    _selectedIds = Set.from(widget.initialSelection);
  }

  static Color _colorAt(ColorScheme scheme, int index) {
    const accents = [
      _Accent.primary,
      _Accent.secondary,
      _Accent.tertiary,
      _Accent.teal,
      _Accent.orange,
      _Accent.purple,
    ];
    return accents[index % accents.length].resolve(scheme);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final colorScheme = widget.colorScheme;
    final locations = widget.locations;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outline.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Filter by location',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedIds = locations.map((l) => l.id).toSet();
                  });
                },
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _selectedIds = {});
                },
                child: const Text('Clear'),
              ),
            ],
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: locations.length,
              itemBuilder: (context, index) {
                final loc = locations[index];
                final color = _colorAt(colorScheme, index);
                final isSelected = _selectedIds.contains(loc.id);
                return CheckboxListTile(
                  value: isSelected,
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedIds.add(loc.id);
                      } else {
                        _selectedIds.remove(loc.id);
                      }
                    });
                  },
                  title: Text(loc.name),
                  secondary: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => widget.onApply(Set.from(_selectedIds)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

enum _Accent {
  primary,
  secondary,
  tertiary,
  teal,
  orange,
  purple,
}

extension on _Accent {
  Color resolve(ColorScheme scheme) {
    switch (this) {
      case _Accent.primary:
        return scheme.primary;
      case _Accent.secondary:
        return scheme.secondary;
      case _Accent.tertiary:
        return scheme.tertiary;
      case _Accent.teal:
        return Colors.teal;
      case _Accent.orange:
        return Colors.orange;
      case _Accent.purple:
        return Colors.purple;
    }
  }
}
