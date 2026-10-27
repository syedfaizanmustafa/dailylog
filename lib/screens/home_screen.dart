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
import '../services/sheet_outbox.dart';
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
                            yard: location?.name,
                            // Beside the draft card on wide screens it gets 2/3.
                            width: hasDraft && c.maxWidth >= 760
                                ? (c.maxWidth - 20) * 2 / 3
                                : c.maxWidth,
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
                    const SizedBox(height: 18),
                    const Entrance(
                      delay: Duration(milliseconds: 160),
                      child: _SyncButton(),
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

/// Opens "Sheets on this tablet" (last 30 days, upload status) and uploads
/// anything waiting. Shows a count only when something isn't uploaded.
class _SyncButton extends ConsumerStatefulWidget {
  const _SyncButton();

  @override
  ConsumerState<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends ConsumerState<_SyncButton> {
  @override
  void initState() {
    super.initState();
    // Home opened: quietly retry anything still waiting.
    SheetOutbox.instance.syncAll();
  }

  @override
  Widget build(BuildContext context) {
    final outbox = ref.watch(sheetOutboxProvider);
    final waiting = outbox.waitingCount;
    final syncing = outbox.syncing;
    final warn = waiting > 0;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          HapticFeedback.selectionClick();
          context.push('/tablet-sheets');
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: warn ? AppColors.amberLine : AppColors.line, width: warn ? 2 : 1),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: warn ? AppColors.amberSoft : AppColors.sageLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: syncing
                          ? const Padding(
                              padding: EdgeInsets.all(11),
                              child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.forest),
                            )
                          : Icon(
                              warn ? Icons.cloud_upload_rounded : Icons.cloud_done_rounded,
                              color: warn ? AppColors.amberText : AppColors.forest,
                            ),
                    ),
                    if (warn)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.red,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text('$waiting',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sync',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.navy)),
                    const SizedBox(height: 2),
                    Text(
                      syncing
                          ? 'Uploading…'
                          : warn
                              ? '$waiting not uploaded yet · tap to upload'
                              : 'All sheets on this tablet are uploaded',
                      style: TextStyle(fontSize: 13, color: warn ? AppColors.amberText : AppColors.slate),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.slate),
            ],
          ),
        ),
      ),
    );
  }
}

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

/// The one big action on the staff home screen: start today's log sheet.
/// Left: date + yard, title, and a clear "Start new sheet" button. Right: a
/// small log-sheet illustration with a plus badge that floats gently
/// (still when "Reduce motion" is on). The whole card is the tap target.
class _NewEntryHero extends StatefulWidget {
  final VoidCallback onTap;
  final String? yard;

  /// Width the card gets (decided by the home layout; no LayoutBuilder here
  /// because the card can sit in an IntrinsicHeight row next to the draft).
  final double width;
  const _NewEntryHero({required this.onTap, required this.width, this.yard});

  @override
  State<_NewEntryHero> createState() => _NewEntryHeroState();
}

class _NewEntryHeroState extends State<_NewEntryHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _float.stop();
    } else if (!_float.isAnimating) {
      _float.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('EEEE, MMMM d').format(DateTime.now());
    final yard = widget.yard;
    return Semantics(
      button: true,
      label: 'New entry. Start a new daily log sheet for today.',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 280),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.forest, Color(0xFF2E4426)],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: AppColors.forest.withValues(alpha: 0.30),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: PressScale(
          borderRadius: BorderRadius.circular(24),
          onTap: widget.onTap,
          child: Builder(
            builder: (context) {
              final roomy = widget.width >= 600; // room for the illustration
              final big = widget.width >= 460;
              return Stack(
                children: [
                  // Faint brand mark, bottom-left: texture, not a focal point.
                  Positioned(
                    left: -60,
                    bottom: -70,
                    child: Opacity(
                      opacity: 0.08,
                      child: const BrandMark(size: 240, arc: Colors.white, head: Colors.white),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(big ? 36 : 24, 28, 24, 28),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Today + yard, so staff know which sheet this starts.
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.today_rounded, size: 16, color: AppColors.sageLight),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        yard == null || yard.isEmpty ? today : '$today · $yard',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.sageLight,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'New entry',
                                style: TextStyle(
                                  fontSize: big ? 46 : 36,
                                  height: 1.0,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'Weigh in, fill the rows, get signatures.',
                                style: TextStyle(fontSize: 17, height: 1.35, color: Color(0xFFDCE8D2)),
                              ),
                              const SizedBox(height: 22),
                              // The visible button (the whole card is tappable).
                              Container(
                                height: 56,
                                padding: const EdgeInsets.fromLTRB(22, 0, 8, 0),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.12),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Start new sheet',
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.forest,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: const BoxDecoration(
                                        color: AppColors.forest,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 22),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (roomy) ...[
                          const SizedBox(width: 20),
                          AnimatedBuilder(
                            animation: _float,
                            builder: (context, child) {
                              final t = Curves.easeInOut.transform(_float.value);
                              return Transform.translate(offset: Offset(0, -6 * t), child: child);
                            },
                            child: const _SheetIllustration(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A small paper log sheet: header, material columns, ruled rows and a
/// signature line, with a plus badge. Purely decorative.
class _SheetIllustration extends StatelessWidget {
  const _SheetIllustration();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, Color c) => Container(
          width: w,
          height: 7,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
        );
    const rowLine = Color(0xFFE6EBE1);
    return SizedBox(
      width: 210,
      height: 230,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: 6,
            top: 4,
            child: Transform.rotate(
              angle: 0.05,
              child: Container(
                width: 184,
                height: 214,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                decoration: BoxDecoration(
                  color: AppColors.cream,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        BrandMark(size: 18),
                        SizedBox(width: 6),
                        Text(
                          'DAILY LOG',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                            color: AppColors.navy,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final (label, color) in const [
                          ('AL', AppColors.blue),
                          ('GL', AppColors.green),
                          ('PET', AppColors.amber),
                        ]) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(label,
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: color)),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < 5; i++)
                      Container(
                        height: 20,
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: rowLine, width: 1.4)),
                        ),
                        alignment: Alignment.centerLeft,
                        child: i < 3
                            ? Row(
                                children: [
                                  bar(22.0 + (i * 7) % 14, const Color(0xFFCBD6C2)),
                                  const SizedBox(width: 10),
                                  bar(16.0 + (i * 5) % 12, const Color(0xFFCBD6C2)),
                                  const Spacer(),
                                  bar(26, AppColors.sage.withValues(alpha: 0.55)),
                                ],
                              )
                            : null,
                      ),
                    const Spacer(),
                    // Signature line
                    SizedBox(
                      height: 22,
                      width: double.infinity,
                      child: CustomPaint(painter: _SignaturePainter()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The "new" badge.
          Positioned(
            left: 0,
            bottom: 0,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.olive,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(Icons.add_rounded, size: 38, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short signature squiggle over a baseline.
class _SignaturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = const Color(0xFFB9C4AF)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, size.height - 2), Offset(size.width, size.height - 2), base);
    final ink = Paint()
      ..color = AppColors.navy.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final h = size.height;
    final p = Path()
      ..moveTo(size.width * 0.38, h * 0.70)
      ..cubicTo(size.width * 0.44, h * 0.05, size.width * 0.50, h * 0.05, size.width * 0.52, h * 0.65)
      ..cubicTo(size.width * 0.55, h * 0.95, size.width * 0.60, h * 0.20, size.width * 0.66, h * 0.55)
      ..cubicTo(size.width * 0.72, h * 0.85, size.width * 0.80, h * 0.30, size.width * 0.96, h * 0.45);
    canvas.drawPath(p, ink);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
