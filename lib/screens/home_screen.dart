import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../controllers/auth_controller.dart';
import '../widgets/floating_confirmation_sheet.dart';
import '../widgets/logout_confirmation_sheet.dart';

// ── Data for the Home screen ──────────────────────────────────────────────

class DraftSummary {
  final int sheets;
  final int currentSheet;
  final int signedCustomers;
  const DraftSummary({
    required this.sheets,
    required this.currentSheet,
    required this.signedCustomers,
  });
}

/// Reads the saved New Entry draft (if any) for the "Continue draft" card.
final draftSummaryProvider = FutureProvider<DraftSummary?>((ref) async {
  ref.watch(hasDraftProvider);
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(kDraftSheetKey);
  if (raw == null) return null;
  try {
    final d = jsonDecode(raw) as Map<String, dynamic>;
    final sheets = (d['sheetsGridData'] as Map?)?.length ?? 1;
    var signed = 0;
    final sig = d['signaturePoints'] as Map?;
    sig?.forEach((_, cells) {
      if (cells is Map) signed += cells.length;
    });
    return DraftSummary(
      sheets: sheets == 0 ? 1 : sheets,
      currentSheet: (d['currentSheetNumber'] as num?)?.toInt() ?? 1,
      signedCustomers: signed,
    );
  } catch (_) {
    return const DraftSummary(sheets: 1, currentSheet: 1, signedCustomers: 0);
  }
});

// ── Screen ────────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String _firstName(String? email) {
    if (email == null || email.isEmpty) return '';
    final local = email.split('@').first.split(RegExp(r'[._-]')).first;
    if (local.isEmpty) return '';
    return local[0].toUpperCase() + local.substring(1);
  }

  Future<void> _startNewEntry(
    BuildContext context,
    WidgetRef ref,
    bool hasDraft,
  ) async {
    HapticFeedback.selectionClick();
    if (hasDraft) {
      final discard = await showFloatingConfirmationBottomSheet(
        context: context,
        title: 'You have a draft in progress',
        message:
            'Starting a new entry will discard the saved draft. To keep working on it, use Continue draft instead.',
        confirmLabel: 'Discard & start new',
        cancelLabel: 'Keep draft',
      );
      if (!discard) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kDraftSheetKey);
      ref.invalidate(hasDraftProvider);
    }
    if (context.mounted) context.push('/new-entry');
  }

  Future<void> _deleteDraft(BuildContext context, WidgetRef ref) async {
    final confirmed = await showFloatingConfirmationBottomSheet(
      context: context,
      title: 'Delete draft?',
      message: 'This will permanently discard your saved draft.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    if (!confirmed) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kDraftSheetKey);
    ref.invalidate(hasDraftProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).value;
    final hasDraft = ref.watch(hasDraftProvider).valueOrNull ?? false;
    final draft = ref.watch(draftSummaryProvider).valueOrNull;
    final app = ref.watch(appControllerProvider);
    final location = app.nearestLocation;
    final name = _firstName(user?.email);

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: Column(
        children: [
          _Header(
            locationLabel: location == null
                ? (app.initialized ? 'No yard selected' : 'Finding your yard…')
                : [
                    location.name,
                    if (location.certification.isNotEmpty)
                      location.certification,
                  ].join(' · '),
            onLocationTap: () {
              HapticFeedback.selectionClick();
              ref.read(appControllerProvider.notifier).refreshNearest();
            },
            onLogout: () => showLogoutConfirmationBottomSheet(context, ref),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(hasDraftProvider);
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Entrance(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 12,
                        children: [
                          Text(
                            name.isEmpty ? _greeting() : '${_greeting()}, $name',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              color: AppColors.navy,
                            ),
                          ),
                          if (user?.email != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                user!.email!,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: AppColors.slate,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    LayoutBuilder(
                      builder: (context, c) {
                        final hero = Entrance(
                          delay: const Duration(milliseconds: 60),
                          child: _NewEntryHero(
                            onTap: () => _startNewEntry(context, ref, hasDraft),
                          ),
                        );
                        Widget draftCard() => Entrance(
                              delay: const Duration(milliseconds: 120),
                              child: _DraftCard(
                                draft: draft,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  context.push('/new-entry');
                                },
                                onDelete: () => _deleteDraft(context, ref),
                              ),
                            );
                        // Staff only see "start a sheet" and their own draft:
                        // no daily counts or submitted-sheet history here.
                        if (!hasDraft) return hero;
                        if (c.maxWidth < 760) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              hero,
                              const SizedBox(height: 20),
                              draftCard(),
                            ],
                          );
                        }
                        // Draft card stretches to the hero's height.
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 2, child: hero),
                              const SizedBox(width: 20),
                              Expanded(child: draftCard()),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String locationLabel;
  final VoidCallback onLocationTap;
  final VoidCallback onLogout;
  const _Header({
    required this.locationLabel,
    required this.onLocationTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('EEEE, MMMM d').format(DateTime.now());
    return Container(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 32),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: [
              const BrandMark(size: 44),
              const SizedBox(width: 14),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Camacho Daily Log',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: AppColors.navy,
                    ),
                  ),
                  Text(
                    date,
                    style: const TextStyle(fontSize: 12, color: AppColors.slate),
                  ),
                ],
              ),
              const Spacer(),
              Material(
                color: const Color(0xFFEEF4E6),
                shape: const StadiumBorder(
                  side: BorderSide(color: AppColors.sageLight),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onLocationTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _PulseDot(),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(
                            locationLabel,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.forest,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Log out',
                icon: const Icon(Icons.logout, color: AppColors.navy),
                onPressed: onLogout,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.of(context).disableAnimations && !_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppColors.olive,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.olive.withOpacity(0.55 * (1 - t)),
                spreadRadius: 7 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NewEntryHero extends StatefulWidget {
  final VoidCallback onTap;
  const _NewEntryHero({required this.onTap});

  @override
  State<_NewEntryHero> createState() => _NewEntryHeroState();
}

class _NewEntryHeroState extends State<_NewEntryHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.of(context).disableAnimations && !_swing.isAnimating) {
      _swing.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _swing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New entry. Open a fresh daily log sheet.',
      child: Container(
        constraints: const BoxConstraints(minHeight: 280),
        decoration: BoxDecoration(
          color: AppColors.forest,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: AppColors.forest.withOpacity(0.35),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: PressScale(
          borderRadius: BorderRadius.circular(24),
          onTap: widget.onTap,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Ruled log-sheet lines from the logo, fading in to the right.
              const Positioned.fill(
                child: RuledLines(color: Color(0x14FFFFFF), spacing: 18, thickness: 2),
              ),
              Positioned(
                right: -150,
                top: -80,
                child: Opacity(
                  opacity: 0.55,
                  child: const SpinningBrandMark(
                    size: 460,
                    arc: AppColors.olive,
                    head: AppColors.sage,
                    reverse: true,
                  ),
                ),
              ),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 150,
                        height: 160,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            AnimatedBuilder(
                              animation: _swing,
                              builder: (context, child) => Transform.rotate(
                                angle: -0.24 *
                                    Curves.easeInOut.transform(_swing.value),
                                child: child,
                              ),
                              child: const BrandMark(
                                size: 140,
                                arc: AppColors.sageLight,
                                head: Colors.white,
                              ),
                            ),
                            Align(
                              alignment: const Alignment(1.0, 0.95),
                              child: Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: AppColors.forest, width: 4),
                                ),
                                child: const Icon(Icons.add_rounded,
                                    size: 38, color: AppColors.forest),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 28),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'START HERE',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.5,
                                color: AppColors.sageLight,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'New entry',
                              style: TextStyle(
                                fontSize: 44,
                                height: 1.05,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Tap anywhere to open a fresh daily log sheet',
                              style: TextStyle(
                                fontSize: 18,
                                color: Color(0xFFE3EEDA),
                              ),
                            ),
                          ],
                        ),
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
}

class _DraftCard extends StatelessWidget {
  final DraftSummary? draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _DraftCard({
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final detail = d == null
        ? 'Pick up where you left off'
        : [
            'Sheet ${d.currentSheet} of ${d.sheets}',
            '${d.signedCustomers} signed',
          ].join(' · ');
    return Container(
      decoration: BoxDecoration(
        color: AppColors.amberSoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF2B544), width: 2),
      ),
      child: PressScale(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 18),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2B544),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.edit_outlined, color: AppColors.navy),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Continue draft',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF6B4600)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Delete draft',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, color: AppColors.redText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
