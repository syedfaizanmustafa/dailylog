import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../controllers/auth_controller.dart';
import '../services/data_sync.dart';
import '../services/receipt_service.dart';
import '../utils/entry_stats.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Sections
// ─────────────────────────────────────────────────────────────────────────────

enum AdminSection {
  overview('/admin', 'Overview', Icons.space_dashboard_rounded),
  sheets('/admin/logs', 'Log sheets', Icons.assignment_rounded),
  receipts('/admin/receipts', 'Receipts', Icons.receipt_long_rounded),
  customers('/admin/customers', 'Customers', Icons.groups_rounded),
  locations('/admin/locations', 'Locations', Icons.location_on_rounded),

  /// Not a tab: opened from the account (profile) sheet.
  staff('/admin/users', 'Manage staff', Icons.manage_accounts_rounded);

  final String route;
  final String label;
  final IconData icon;
  const AdminSection(this.route, this.label, this.icon);

  /// Short label for the phone tab bar.
  String get shortLabel => this == AdminSection.sheets ? 'Sheets' : label;

  /// Sections shown as tabs / side-menu items.
  static const List<AdminSection> nav = [overview, sheets, receipts, customers, locations];

  bool get inNav => nav.contains(this);
}

/// Phone layout (bottom tabs, stacked rows) below this width.
const double kAdminPhoneWidth = 600;

bool isAdminPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kAdminPhoneWidth;

// ─────────────────────────────────────────────────────────────────────────────
// Shared admin data
// ─────────────────────────────────────────────────────────────────────────────

/// Live list of locations (sorted by name) for every admin screen.
final adminLocationsProvider = StreamProvider<List<AppLocation>>((ref) {
  return FirebaseFirestore.instance.collection('locations').snapshots().map(
    (snap) {
      final list = <AppLocation>[];
      for (final d in snap.docs) {
        final data = d.data();
        final loc = AppLocation.fromDoc(d) ??
            AppLocation(
              id: d.id,
              name: data['name']?.toString() ?? '',
              address: data['address']?.toString() ?? '',
              certification: data['certification']?.toString() ?? '',
              latitude: 0,
              longitude: 0,
            );
        list.add(loc);
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    },
  );
});

/// One colour per location, used everywhere (chart, sheet list, receipts).
const kLocationPalette = <Color>[
  AppColors.green,
  AppColors.blue,
  AppColors.amber,
  AppColors.purple,
  Color(0xFF00897B), // teal
  AppColors.red,
  AppColors.olive,
  AppColors.slate,
];

final locationColorsProvider = Provider<Map<String, Color>>((ref) {
  final locs = ref.watch(adminLocationsProvider).valueOrNull ?? const [];
  return {
    for (var i = 0; i < locs.length; i++)
      locs[i].id: kLocationPalette[i % kLocationPalette.length],
  };
});

DateTime _createdOf(Map<String, dynamic> d) {
  final v = d['createdAt'];
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v) ?? DateTime(2000);
  return DateTime(2000);
}

/// Location numbers used in receipt codes (`02-261008-03-07`). Any location
/// without one gets the next free number, in the order locations were
/// created. Watched by every admin page, so numbering happens on its own.
final locationNumbersProvider = StreamProvider<Map<String, int>>((ref) {
  return FirebaseFirestore.instance.collection('locations').snapshots().map((snap) {
    final numbers = <String, int>{};
    var highest = 0;
    final missing = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final d in snap.docs) {
      final n = (d.data()['number'] as num?)?.toInt();
      if (n != null && n > 0) {
        numbers[d.id] = n;
        if (n > highest) highest = n;
      } else {
        missing.add(d);
      }
    }
    if (missing.isNotEmpty) {
      missing.sort((a, b) {
        final c = _createdOf(a.data()).compareTo(_createdOf(b.data()));
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      final batch = FirebaseFirestore.instance.batch();
      for (final d in missing) {
        highest++;
        numbers[d.id] = highest;
        batch.update(d.reference, {'number': highest});
      }
      batch.commit().catchError((Object e) {
        debugPrint('Could not number locations: $e');
      });
    }
    return numbers;
  });
});

Color colorForLocation(Map<String, Color> colors, String? id) =>
    (id == null ? null : colors[id]) ?? AppColors.slate;

class AdminUser {
  final String id;
  final String name;
  final String email;
  final String role;
  final bool disabled;
  const AdminUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.disabled,
  });

  bool get isAdmin => role == 'admin';

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : (email.isNotEmpty ? email : 'Unknown');

  String get initials {
    final parts = displayName
        .replaceAll(RegExp(r'@.*'), '')
        .split(RegExp(r'[\s._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  /// "Ricardo C." style label for tables.
  String get shortName {
    final parts = displayName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || displayName.contains('@')) return displayName;
    return '${parts.first} ${parts[1][0]}.';
  }
}

final adminUsersProvider = StreamProvider<List<AdminUser>>((ref) {
  return FirebaseFirestore.instance.collection('users').snapshots().map((snap) {
    final list = snap.docs.map((d) {
      final data = d.data();
      return AdminUser(
        id: d.id,
        name: data['name']?.toString() ?? '',
        email: data['email']?.toString() ?? '',
        role: data['role']?.toString() ?? 'user',
        disabled: data['disabled'] == true,
      );
    }).toList();
    list.sort((a, b) {
      if (a.disabled != b.disabled) return a.disabled ? 1 : -1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  });
});

/// Sheets waiting for approval (badge on the nav). Invalidate after approving.
final pendingApprovalCountProvider = FutureProvider<int>((ref) async {
  final agg = await FirebaseFirestore.instance
      .collection('entries')
      .where('approved', isEqualTo: false)
      .count()
      .get();
  return agg.count ?? 0;
});

// ─────────────────────────────────────────────────────────────────────────────
// Shell
// ─────────────────────────────────────────────────────────────────────────────

/// Navy side navigation + page header shared by all admin screens.
/// Wide (≥ 1100 px): full labels. Narrower: icon rail.
class AdminShell extends ConsumerWidget {
  final AdminSection section;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  final Widget? floatingActionButton;

  const AdminShell({
    super.key,
    required this.section,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps location numbers (used in receipt codes) assigned.
    ref.watch(locationNumbersProvider);
    final width = MediaQuery.sizeOf(context).width;
    if (width < kAdminPhoneWidth) return _buildPhone(context, ref);
    final compactNav = width < 1100;
    final narrow = width < 760;
    final hPad = narrow ? 16.0 : 28.0;

    return Scaffold(
      backgroundColor: AppColors.mist,
      floatingActionButton: floatingActionButton,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AdminNav(section: section, compact: compactNav),
          Expanded(
            child: SafeArea(
              left: false,
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 22, hPad, 14),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: 12,
                      spacing: 12,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: AppColors.navy,
                              ),
                            ),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  subtitle!,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppColors.slate,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (actions.isNotEmpty)
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: actions,
                          ),
                      ],
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Phone: compact header, filters in a sideways-scrolling row, bottom tabs.
  Widget _buildPhone(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingApprovalCountProvider).valueOrNull ?? 0;
    return Scaffold(
      backgroundColor: AppColors.mist,
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(section.inNav ? 16 : 4, 10, 4, 8),
              child: Row(
                children: [
                  if (section.inNav)
                    Container(
                      width: 38,
                      height: 38,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.cream,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const BrandMark(size: 26),
                    )
                  else
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.navy),
                      onPressed: () => context.canPop() ? context.pop() : context.go('/admin'),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.slate,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Account',
                    icon: const Icon(Icons.account_circle_outlined, color: AppColors.navy, size: 28),
                    onPressed: () => showAdminAccountSheet(context, ref),
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty)
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  itemCount: actions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Center(child: actions[i]),
                ),
              ),
            Expanded(child: child),
          ],
        ),
      ),
      bottomNavigationBar: !section.inNav ? null : NavigationBar(
        height: 66,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        indicatorColor: AppColors.navy.withValues(alpha: 0.1),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: AdminSection.nav.indexOf(section),
        onDestinationSelected: (i) {
          final target = AdminSection.nav[i];
          if (target != section) _showTab(context, ref, target);
        },
        destinations: [
          for (final s in AdminSection.nav)
            NavigationDestination(
              label: s.shortLabel,
              icon: Badge(
                isLabelVisible: s == AdminSection.sheets && pending > 0,
                backgroundColor: const Color(0xFFF2B544),
                textColor: AppColors.navy,
                label: Text('$pending'),
                child: Icon(s.icon, color: AppColors.slate),
              ),
              selectedIcon: Badge(
                isLabelVisible: s == AdminSection.sheets && pending > 0,
                backgroundColor: const Color(0xFFF2B544),
                textColor: AppColors.navy,
                label: Text('$pending'),
                child: Icon(s.icon, color: AppColors.navy),
              ),
            ),
        ],
      ),
    );
  }
}

class _AdminNav extends ConsumerWidget {
  final AdminSection section;
  final bool compact;
  const _AdminNav({required this.section, required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingApprovalCountProvider).valueOrNull ?? 0;
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: compact ? 84 : 236,
      color: AppColors.navy,
      child: ClipRect(
        child: Stack(
          children: [
            // Faint logo watermark at the bottom of the rail.
            Positioned(
              left: -90,
              bottom: -70,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.07,
                  child: BrandMark(
                    size: 300,
                    arc: Colors.white,
                    head: Colors.white,
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 16,
                topInset + 18,
                compact ? 12 : 16,
                bottomInset + 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo
                  Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: AppColors.cream,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const BrandMark(size: 32),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Camacho',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'Admin',
                              style: TextStyle(
                                color: Color(0xFFB6BDCB),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 28),
                  for (final s in AdminSection.nav)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _NavItem(
                        section: s,
                        selected: s == section,
                        compact: compact,
                        badge: s == AdminSection.sheets && pending > 0
                            ? pending
                            : null,
                      ),
                    ),
                  const Spacer(),
                  _AccountCard(
                    compact: compact,
                    onTap: () => showAdminAccountSheet(context, ref),
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

class _NavItem extends ConsumerWidget {
  final AdminSection section;
  final bool selected;
  final bool compact;
  final int? badge;
  const _NavItem({
    required this.section,
    required this.selected,
    required this.compact,
    this.badge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fg = selected ? Colors.white : const Color(0xFFD5DAE2);
    final badgeWidget = badge == null
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFF2B544),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$badge',
              style: const TextStyle(
                color: AppColors.navy,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          );

    final item = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: selected ? null : () => _showTab(context, ref, section),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 46,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white.withValues(alpha: 0.13)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: compact
                ? Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Icon(section.icon, color: fg, size: 22),
                      if (badgeWidget != null)
                        Positioned(right: 6, top: 4, child: badgeWidget),
                    ],
                  )
                : Row(
                    children: [
                      Icon(section.icon, color: fg, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          section.label,
                          style: TextStyle(
                            color: fg,
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (badgeWidget != null) badgeWidget,
                    ],
                  ),
          ),
        ),
    );
    return compact ? Tooltip(message: section.label, child: item) : item;
  }
}

/// Bottom of the side menu: who is signed in. Opens the account sheet
/// (Manage staff, Sign out).
class _AccountCard extends ConsumerWidget {
  final bool compact;
  final VoidCallback onTap;
  const _AccountCard({required this.compact, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUser = FirebaseAuth.instance.currentUser;
    final users = ref.watch(adminUsersProvider).valueOrNull ?? const <AdminUser>[];
    final me = users.where((u) => u.id == authUser?.uid).firstOrNull;
    final name = me?.displayName ?? (authUser?.email?.split('@').first ?? 'Account');
    final initials = me?.initials ?? (name.isNotEmpty ? name[0].toUpperCase() : '?');

    final avatar = Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.sageLight,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        initials,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.forest),
      ),
    );

    final card = Material(
      color: AppColors.forest,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? 6 : 10),
          child: compact
              ? Center(child: avatar)
              : Row(
                  children: [
                    avatar,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Text(
                            'Account · Manage staff',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppColors.sageLight, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.unfold_more_rounded, color: Colors.white, size: 20),
                  ],
                ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: 'Account: $name',
      child: compact ? Tooltip(message: 'Account · $name', child: card) : card,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared pieces
// ─────────────────────────────────────────────────────────────────────────────

/// White rounded card used across admin pages.
class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  const AdminCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Small coloured pill (status, counts).
class StatusPill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;
  const StatusPill({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });

  factory StatusPill.approved() => const StatusPill(
        label: 'Approved',
        bg: AppColors.greenTint,
        fg: AppColors.greenText,
      );
  factory StatusPill.pending() => const StatusPill(
        label: 'Pending',
        bg: AppColors.amberTint,
        fg: AppColors.amberText,
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class LocationDot extends StatelessWidget {
  final Color color;
  final double size;
  const LocationDot(this.color, {super.key, this.size = 10});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Segmented pill selector ("Today · 7 days · 30 days").
class SegmentedPills<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final Color background;
  const SegmentedPills({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.background = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in options)
            GestureDetector(
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: v == value ? AppColors.navy : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: v == value ? FontWeight.w600 : FontWeight.w400,
                    color: v == value ? Colors.white : AppColors.navy,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Outlined white button used for filters ("All locations ▾").
class AdminFilterButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final Color? dot;
  const AdminFilterButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.expand_more_rounded,
    this.active = false,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.blueTint : Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? AppColors.blue : AppColors.field,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot != null) ...[
                LocationDot(dot!),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: active ? AppColors.blueText : AppColors.navy,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                icon,
                size: 18,
                color: active ? AppColors.blueText : AppColors.slate,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search box in the admin style.
class AdminSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  const AdminSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width = 280,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 44,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.slate, fontSize: 14),
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon:
              const Icon(Icons.search_rounded, color: AppColors.slate, size: 20),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, v, _) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.field),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.navy, width: 2),
          ),
        ),
      ),
    );
  }
}

/// KPI tile with count-up number.
class KpiTile extends StatelessWidget {
  final String label;
  final double value;
  final String Function(double) format;
  final String? footnote;
  final Color accent;
  final Color valueColor;
  final bool filled;
  final VoidCallback? onTap;

  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.format,
    this.footnote,
    required this.accent,
    required this.valueColor,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final labelColor = filled ? const Color(0xFFDDF2E5) : AppColors.slate;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: labelColor)),
          const SizedBox(height: 2),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: value),
            duration: reduce ? Duration.zero : const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(
              format(v),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: filled ? Colors.white : valueColor,
              ),
            ),
          ),
          if (footnote != null)
            Text(
              footnote!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: labelColor),
            ),
        ],
      ),
    );
    // Top accent bar drawn inside a clip (a one-sided Border can't be
    // combined with borderRadius).
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: filled ? accent : Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!filled) Container(height: 4, color: accent),
            body,
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return PressScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: content,
    );
  }
}

/// Bottom-sheet list to pick one location (or all).
/// First chip in a filter row: which locations are shown. Opens
/// [showLocationMultiPickerSheet].
class LocationFilterChip extends StatelessWidget {
  final String label;
  final List<Color> dots;
  final bool active;
  final VoidCallback onTap;
  const LocationFilterChip({
    super.key,
    required this.label,
    required this.dots,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : AppColors.navy;
    return Semantics(
      button: true,
      label: 'Location filter: $label',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 40,
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            color: active ? AppColors.forest : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? AppColors.forest : AppColors.field),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dots.isEmpty)
                Icon(Icons.place_outlined, size: 18, color: fg)
              else
                for (final c in dots)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                  ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}


/// Location filter sheet: all locations, one, or several. Returns the chosen
/// ids (empty = all locations), or null when dismissed.
Future<Set<String>?> showLocationMultiPickerSheet({
  required BuildContext context,
  required List<AppLocation> locations,
  required Map<String, Color> colors,
  required Set<String> selected,
  String subtitle = 'Show all locations, one, or several.',
}) {
  var picked = Set<String>.from(selected);
  return showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) {
          final all = picked.isEmpty;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text('Locations',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.navy)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(subtitle,
                      style: TextStyle(fontSize: 13, color: AppColors.slate)),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      CheckboxListTile(
                        value: all,
                        activeColor: AppColors.forest,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('All locations', style: TextStyle(fontWeight: FontWeight.w600)),
                        onChanged: (_) => setSheet(() => picked = {}),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      for (final l in locations)
                        CheckboxListTile(
                          value: picked.contains(l.id),
                          activeColor: AppColors.forest,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Row(
                            children: [
                              LocationDot(colorForLocation(colors, l.id)),
                              const SizedBox(width: 10),
                              Expanded(child: Text(l.name, overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              picked.add(l.id);
                            } else {
                              picked.remove(l.id);
                            }
                            // Every location ticked = all locations.
                            if (picked.length == locations.length) picked = {};
                          }),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              foregroundColor: AppColors.navy,
                              side: const BorderSide(color: AppColors.field),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () => setSheet(() => picked = {}),
                            child: const Text('Clear'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              backgroundColor: AppColors.forest,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () => Navigator.of(sheetContext).pop(picked),
                            child: Text(all
                                ? 'Show all locations'
                                : 'Show ${picked.length} location${picked.length == 1 ? '' : 's'}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
}

Future<void> showLocationPickerSheet({
  required BuildContext context,
  required List<AppLocation> locations,
  required Map<String, Color> colors,
  required String? selectedId,
  required ValueChanged<String?> onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Location',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.public_rounded,
                        color: AppColors.slate),
                    title: const Text('All locations'),
                    trailing: selectedId == null
                        ? const Icon(Icons.check_rounded, color: AppColors.green)
                        : null,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onSelected(null);
                    },
                  ),
                  for (final loc in locations)
                    ListTile(
                      leading: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: LocationDot(colorForLocation(colors, loc.id),
                            size: 12),
                      ),
                      title: Text(
                          loc.name.isEmpty ? '(Unnamed location)' : loc.name),
                      subtitle: loc.address.isNotEmpty ? Text(loc.address) : null,
                      trailing: selectedId == loc.id
                          ? const Icon(Icons.check_rounded,
                              color: AppColors.green)
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        onSelected(loc.id);
                      },
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


// ─────────────────────────────────────────────────────────────────────────────
// Materials (Aluminum / Glass / PETE / Other) — same colours as the original
// Manage Log Sheets breakdown: blue, green, orange, purple.
// ─────────────────────────────────────────────────────────────────────────────

class CommodityStyle {
  final Color main;
  final Color tint;
  final Color text;
  final IconData icon;
  const CommodityStyle(this.main, this.tint, this.text, this.icon);
}

const kMaterialStyles = <String, CommodityStyle>{
  'Aluminum': CommodityStyle(AppColors.blue, AppColors.blueTint, AppColors.blueText, Icons.local_drink_rounded),
  'Glass': CommodityStyle(AppColors.green, AppColors.greenTint, AppColors.greenText, Icons.wine_bar_rounded),
  'PETE plastic': CommodityStyle(AppColors.amber, AppColors.amberTint, AppColors.amberText, Icons.water_drop_rounded),
  'Other': CommodityStyle(AppColors.purple, AppColors.purpleTint, AppColors.purpleText, Icons.category_rounded),
};

/// Pounds exactly as weighed: up to 2 decimals, no rounding to whole
/// numbers (636.5 stays 636.5, 413.4 stays 413.4, 120 stays 120).
String formatLb(double v) => NumberFormat('#,##0.##').format(v);

String formatMoney(double v, {bool cents = false}) =>
    NumberFormat.currency(symbol: '\$', decimalDigits: cents ? 2 : 0).format(v);

/// Coloured "Aluminum 120 lb · $54" chips for one sheet or location.
class MaterialChips extends StatelessWidget {
  final MaterialTotals totals;
  final bool showPaid;
  final bool dense;
  const MaterialChips({
    super.key,
    required this.totals,
    this.showPaid = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final rows = totals.rows.where((r) => r.$2 > 0 || r.$3 > 0).toList();
    if (rows.isEmpty) {
      return Text(
        'No material weights entered',
        style: TextStyle(fontSize: dense ? 11.5 : 12.5, color: AppColors.slate),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (label, lb, paid) in rows)
          Container(
            padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
            decoration: BoxDecoration(
              color: kMaterialStyles[label]!.tint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${label == 'PETE plastic' ? 'PETE' : label} ${formatLb(lb)} lb'
              '${showPaid && paid > 0 ? ' · ${formatMoney(paid)}' : ''}',
              style: TextStyle(
                fontSize: dense ? 11.5 : 12.5,
                fontWeight: FontWeight.w600,
                color: kMaterialStyles[label]!.text,
              ),
            ),
          ),
      ],
    );
  }
}


/// Thin bar split by each material's share of the amount paid.
class MaterialShareBar extends StatelessWidget {
  final MaterialTotals totals;
  final double height;
  const MaterialShareBar({super.key, required this.totals, this.height = 6});

  @override
  Widget build(BuildContext context) {
    final parts = totals.rows.where((r) => r.$3 > 0).toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                flex: (parts[i].$3 * 100).round() < 1 ? 1 : (parts[i].$3 * 100).round(),
                child: ColoredBox(color: kMaterialStyles[parts[i].$1]!.main),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Aligned grid of the four materials (2 columns on narrow cards, 4 on wide):
/// icon, name, pounds and dollars. Empty materials are dimmed, not hidden,
/// so every card lines up the same way.
class MaterialGrid extends StatelessWidget {
  final MaterialTotals totals;
  const MaterialGrid({super.key, required this.totals});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 520 ? 4 : 2;
        const gap = 8.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (label, lb, paid) in totals.rows)
              SizedBox(
                width: w,
                child: Opacity(
                  opacity: lb > 0 || paid > 0 ? 1 : 0.45,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    decoration: BoxDecoration(
                      color: kMaterialStyles[label]!.tint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            kMaterialStyles[label]!.icon,
                            size: 16,
                            color: kMaterialStyles[label]!.main,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label == 'PETE plastic' ? 'PETE' : label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: kMaterialStyles[label]!.text,
                                ),
                              ),
                              Text(
                                lb > 0 ? '${formatLb(lb)} lb' : '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: kMaterialStyles[label]!.text,
                                ),
                              ),
                              Text(
                                paid > 0 ? formatMoney(paid) : '\$0',
                                maxLines: 1,
                                style: const TextStyle(fontSize: 12, color: AppColors.slate),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}


/// One compact row of the four materials: colour key + name, pounds, dollars.
/// Used on phone cards where the 2×2 grid is too tall.
class MaterialStrip extends StatelessWidget {
  final MaterialTotals totals;
  const MaterialStrip({super.key, required this.totals});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, lb, paid) in totals.rows)
          Expanded(
            child: Opacity(
              opacity: lb > 0 || paid > 0 ? 1 : 0.4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: kMaterialStyles[label]!.main,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          label == 'PETE plastic' ? 'PETE' : label == 'Aluminum' ? 'Alum.' : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: kMaterialStyles[label]!.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    lb > 0 ? '${formatLb(lb)} lb' : '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.navy,
                    ),
                  ),
                  Text(
                    paid > 0 ? formatMoney(paid) : '\$0',
                    maxLines: 1,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.slate),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// New entry FAB (Overview only) and account sheet
// ─────────────────────────────────────────────────────────────────────────────

/// Floating "New entry" / "Continue draft" button shown on the Overview.
class AdminNewEntryFab extends ConsumerWidget {
  const AdminNewEntryFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasDraft = ref.watch(hasDraftProvider).valueOrNull ?? false;
    return FloatingActionButton.extended(
      heroTag: 'admin-new-entry',
      backgroundColor: AppColors.forest,
      foregroundColor: Colors.white,
      elevation: 3,
      onPressed: () async {
        await context.push('/new-entry');
        ref.invalidate(hasDraftProvider);
      },
      icon: Icon(hasDraft ? Icons.edit_note_rounded : Icons.add_rounded),
      label: Text(
        hasDraft ? 'Continue draft' : 'New entry',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Bottom sheet with who is signed in and the Sign out action.
Future<void> showAdminAccountSheet(BuildContext context, WidgetRef ref) {
  final authUser = FirebaseAuth.instance.currentUser;
  final users = ref.read(adminUsersProvider).valueOrNull ?? const <AdminUser>[];
  final me = users.where((u) => u.id == authUser?.uid).firstOrNull;
  final name = me?.displayName ?? (authUser?.email ?? 'Admin');
  final email = me?.email ?? authUser?.email ?? '';
  final initials = me?.initials ?? (name.isNotEmpty ? name[0].toUpperCase() : '?');

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      var signingOut = false;
      return StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: AppColors.purpleTint,
                        child: Text(
                          initials,
                          style: const TextStyle(
                            color: AppColors.purpleText,
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppColors.navy,
                              ),
                            ),
                            if (email.isNotEmpty)
                              Text(
                                email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, color: AppColors.slate),
                              ),
                          ],
                        ),
                      ),
                      const StatusPill(
                        label: 'Admin',
                        bg: AppColors.purpleTint,
                        fg: AppColors.purpleText,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Divider(height: 1, color: AppColors.line),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.navy,
                        side: const BorderSide(color: AppColors.field),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: signingOut
                          ? null
                          : () {
                              Navigator.of(sheetCtx).pop();
                              showAdminTab(context, ref, AdminSection.staff.route);
                            },
                      icon: const Icon(Icons.manage_accounts_rounded),
                      label: const Text('Manage staff', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: signingOut
                              ? null
                              : () {
                                  Navigator.of(sheetCtx).pop();
                                  _runDataTask(
                                    context,
                                    ref,
                                    title: 'Refreshing all data…',
                                    done: (_) => 'All data refreshed',
                                    task: (_) async {
                                      await SyncedCollection.refreshAll();
                                      return 0;
                                    },
                                  );
                                },
                          icon: const Icon(Icons.sync_rounded, size: 20),
                          label: const Text('Refresh all data'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: signingOut
                              ? null
                              : () {
                                  Navigator.of(sheetCtx).pop();
                                  _confirmMoveSignatures(context, ref);
                                },
                          icon: const Icon(Icons.bolt_rounded, size: 20),
                          label: const Text('Speed up receipts'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.redTint,
                        foregroundColor: AppColors.redText,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: signingOut
                          ? null
                          : () async {
                              setSheet(() => signingOut = true);
                              try {
                                await ref.read(authControllerProvider.notifier).signOut();
                                if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                                if (context.mounted) context.go('/');
                              } catch (e) {
                                setSheet(() => signingOut = false);
                                if (context.mounted) {
                                  showAppSnack(context, friendlyError(e), error: true);
                                }
                              }
                            },
                      icon: signingOut
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.logout_rounded),
                      label: const Text('Sign out', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}


/// One-time move of signatures out of older receipts (see
/// [ReceiptService.moveOldSignatures]).
Future<void> _confirmMoveSignatures(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Speed up receipts?'),
      content: const Text(
        'Older receipts keep the customer\'s signature inside the receipt itself, which makes '
        'every list of receipts slow to load. This moves each signature to its own record '
        '(copied and removed in one step per receipt, nothing is lost). Receipts and PDFs look '
        'exactly the same.\n\nOnly run it once every iPad and phone has the latest app version '
        '(older versions read the signature from the receipt itself). Run it once, on Wi-Fi; '
        'it downloads all receipts one time.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.forest),
          child: const Text('Start'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await _runDataTask(
    context,
    ref,
    title: 'Moving signatures…',
    done: (n) => n == 0 ? 'Receipts are already up to date' : 'Moved $n signatures. Receipts load faster now.',
    task: (progress) => ReceiptService.moveOldSignatures(onProgress: progress),
  );
}

/// Runs a data task behind a small progress dialog, then reloads screens.
Future<void> _runDataTask(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String Function(int result) done,
  required Future<int> Function(void Function(int done, int total) progress) task,
}) async {
  final status = ValueNotifier<String>('');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.forest),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, v, __) => Text(v.isEmpty ? title : '$title\n$v'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  final nav = Navigator.of(context, rootNavigator: true);
  final container = ProviderScope.containerOf(context, listen: false);
  var popped = false;
  void close() {
    if (popped) return;
    popped = true;
    nav.pop();
  }

  try {
    final n = await task((d, t) => status.value = t == 0 ? '' : '$d of $t');
    close();
    container.read(syncTickProvider.notifier).state++;
    if (context.mounted) showAppSnack(context, done(n));
  } catch (e) {
    close();
    if (context.mounted) showAppSnack(context, friendlyError(e), error: true);
  }
  // `status` is left to the garbage collector: the dialog may still be
  // animating out and listening to it.
}


/// Switch admin tab instantly (tabs stay alive) and let it refresh quietly.
/// A plain tab ([location] without a query) keeps the tab's own filters; a
/// location with a query (e.g. '/admin/logs?filter=pending' from an
/// Overview card) applies that filter.
void showAdminTab(BuildContext context, WidgetRef ref, String location) {
  // The tab being left stays mounted: don't leave its keyboard/focus up.
  FocusManager.instance.primaryFocus?.unfocus();
  final (_, n) = ref.read(adminTabShownProvider);
  ref.read(adminTabShownProvider.notifier).state = (location, n + 1);
  final uri = Uri.parse(location);
  final section = AdminSection.values.where((s) => s.route == uri.path).firstOrNull;
  final shell = StatefulNavigationShell.maybeOf(context);
  if (shell != null && section != null && uri.queryParameters.isEmpty) {
    shell.goBranch(section.index); // branch order = AdminSection order
  } else {
    context.go(location);
  }
}

void _showTab(BuildContext context, WidgetRef ref, AdminSection target) =>
    showAdminTab(context, ref, target.route);
