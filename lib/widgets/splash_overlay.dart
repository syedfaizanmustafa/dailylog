import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/brand.dart';
import '../controllers/app_controller.dart';
import '../controllers/auth_controller.dart';
import '../services/sheet_outbox.dart';

/// Launch splash (design "Splash A"): forest green, the logo's arrows settle
/// in, its stripes fill in top to bottom like lines being written, then
/// CAMACHO · RECYCLING · DAILY LOG fades up. A thin bar and one status line
/// show the real start-up steps (signing in, finding the yard, syncing
/// sheets). It leaves as soon as those are done; every step has a time limit
/// so it can never get stuck (e.g. offline). Drawn over the app on cold start
/// only; the native launch screen is the same plain green, so there's no jump.
class SplashOverlay extends ConsumerStatefulWidget {
  final VoidCallback onFinished;
  const SplashOverlay({super.key, required this.onFinished});

  @override
  ConsumerState<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends ConsumerState<SplashOverlay> with TickerProviderStateMixin {
  static const _forest = AppColors.forest;
  static const _cream = AppColors.cream;
  static const _sageLight = AppColors.sageLight;

  /// Logo + wordmark entrance.
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  /// Fade out at the end.
  late final AnimationController _out =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  static const _steps = ['Signing you in…', 'Finding your yard…', 'Syncing sheets…'];
  int _step = 0;
  double _progress = 0.08;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _intro.value = 1; // Reduce Motion: the logo is simply there
    } else {
      _intro.forward();
    }
    unawaited(_run());
  }

  @override
  void dispose() {
    _intro.dispose();
    _out.dispose();
    super.dispose();
  }

  void _set(int step, double progress) {
    if (!mounted) return;
    setState(() {
      _step = step;
      _progress = progress;
    });
  }

  /// Polls [done] until true or [limit] passes.
  Future<void> _waitFor(bool Function() done, Duration limit) async {
    final until = DateTime.now().add(limit);
    while (mounted && !done() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  Future<void> _run() async {
    final started = DateTime.now();
    try {
      // 1) Signing in: wait for Firebase to restore the session.
      _set(0, 0.25);
      await _waitFor(() => !ref.read(authControllerProvider).isLoading, const Duration(seconds: 4));
      final user = ref.read(authControllerProvider).valueOrNull;

      if (user != null) {
        // 2) Finding the yard (and the role, which picks home vs admin).
        _set(1, 0.55);
        await Future.wait([
          ref.read(currentUserRoleProvider.future).timeout(
                const Duration(seconds: 3),
                onTimeout: () => 'user',
              ),
          _waitFor(() => ref.read(appControllerProvider).initialized, const Duration(seconds: 2)),
        ]);

        // 3) Syncing sheets saved on this tablet (carries on in the
        //    background if it needs longer).
        _set(2, 0.82);
        await SheetOutbox.instance.syncAll().timeout(
              const Duration(milliseconds: 1200),
              onTimeout: () => 0,
            );
      }
    } catch (_) {
      // Never block start-up on the splash.
    }

    _set(_step, 1);
    // Let the logo finish drawing (only matters on very fast starts).
    final shown = DateTime.now().difference(started);
    const minimum = Duration(milliseconds: 1500);
    if (shown < minimum && !_intro.isCompleted) {
      await Future<void>.delayed(minimum - shown);
    }
    if (!mounted) return;
    if (MediaQuery.of(context).disableAnimations) {
      widget.onFinished();
      return;
    }
    await _out.forward();
    if (mounted) widget.onFinished();
  }

  /// [t] mapped into [begin]..[end] of the intro, eased.
  double _seg(double begin, double end, [Curve curve = Curves.easeOutCubic]) {
    final v = ((_intro.value - begin) / (end - begin)).clamp(0.0, 1.0);
    return curve.transform(v);
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).shortestSide < 600;
    final logoW = phone ? 150.0 : 230.0;
    final logoH = logoW * BrandLogo.height / BrandLogo.width;
    final word = phone ? 26.0 : 34.0;

    return FadeTransition(
      opacity: ReverseAnimation(_out),
      child: Material(
        color: _forest,
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _intro,
            builder: (context, _) {
              final arrows = _seg(0.0, 0.35);
              final strips = _seg(0.22, 0.75, Curves.easeInOutCubic);
              final words = _seg(0.55, 0.95);
              return Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          label: 'Camacho Recycling Daily Log',
                          image: true,
                          child: SizedBox(
                            width: logoW,
                            height: logoH,
                            child: Stack(
                              children: [
                                // Arrows settle in.
                                Opacity(
                                  opacity: arrows,
                                  child: Transform.rotate(
                                    angle: (1 - arrows) * -14 * math.pi / 180,
                                    child: Transform.scale(
                                      scale: 0.86 + 0.14 * arrows,
                                      child: SvgPicture.string(
                                        BrandLogo.arrows(_cream),
                                        width: logoW,
                                        height: logoH,
                                      ),
                                    ),
                                  ),
                                ),
                                // Stripes fill in top to bottom, like writing.
                                ClipRect(
                                  clipper: _TopReveal(strips),
                                  child: SvgPicture.string(
                                    BrandLogo.strips(_sageLight),
                                    width: logoW,
                                    height: logoH,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: phone ? 22 : 26),
                        Opacity(
                          opacity: words,
                          child: Transform.translate(
                            offset: Offset(0, 10 * (1 - words)),
                            child: Column(
                              children: [
                                Text(
                                  'CAMACHO',
                                  style: TextStyle(
                                    fontSize: word,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: word * 0.16,
                                    color: _cream,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'RECYCLING · DAILY LOG',
                                  style: TextStyle(
                                    fontSize: word * 0.45,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: word * 0.3,
                                    color: _sageLight,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Progress + what's happening.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: MediaQuery.sizeOf(context).height * 0.11,
                    child: Column(
                      children: [
                        SizedBox(
                          width: 200,
                          height: 4,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: Stack(
                              children: [
                                Container(color: Colors.white.withValues(alpha: 0.16)),
                                TweenAnimationBuilder<double>(
                                  tween: Tween(end: _progress),
                                  duration: const Duration(milliseconds: 420),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, v, _) => FractionallySizedBox(
                                    widthFactor: v,
                                    child: Container(color: _sageLight),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a),
                              child: child,
                            ),
                          ),
                          child: Text(
                            _steps[_step],
                            key: ValueKey(_step),
                            style: const TextStyle(fontSize: 14, color: Color(0xFFDCE8D2)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 20,
                    child: Text(
                      'CA CRV certified recycling',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, letterSpacing: 1, color: Color(0x8CFAF8F1)),
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

/// Clips to the top [t] fraction of the child (0 = nothing, 1 = all).
class _TopReveal extends CustomClipper<Rect> {
  final double t;
  const _TopReveal(this.t);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, size.height * t);

  @override
  bool shouldReclip(covariant _TopReveal old) => old.t != t;
}
