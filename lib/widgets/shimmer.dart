import 'package:flutter/material.dart';

import '../config/brand.dart';

/// Loading placeholders ("skeletons") with a moving shine, used instead of
/// spinners while content loads. Draw the rough shape of what's coming with
/// [SkeletonBox] / [SkeletonLine] inside one [Shimmer].
///
/// Respects "Reduce motion": the shine is turned off and the shapes stay
/// still.
class Shimmer extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const Shimmer({super.key, required this.child, this.enabled = true});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final still = !widget.enabled || MediaQuery.of(context).disableAnimations;
    if (still) {
      _c.stop();
    } else if (!_c.isAnimating) {
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
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [Color(0x00FFFFFF), Color(0x99FFFFFF), Color(0x00FFFFFF)],
            stops: const [0.35, 0.5, 0.65],
            transform: _Slide(t),
          ).createShader(rect),
          child: child,
        );
      },
    );
  }
}

/// Moves the gradient from off the left edge to off the right edge.
class _Slide extends GradientTransform {
  final double t;
  const _Slide(this.t);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

/// A grey block standing in for content.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const SkeletonBox({super.key, this.width, required this.height, this.radius = 10});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFFE6E9EE),
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// A line of "text" as a fraction of the available width.
class SkeletonLine extends StatelessWidget {
  final double widthFactor;
  final double height;
  const SkeletonLine({super.key, this.widthFactor = 1, this.height = 12});

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: SkeletonBox(height: height, radius: height / 2),
      );
}

/// A white card holding skeleton lines, like a list row.
class SkeletonCard extends StatelessWidget {
  final double height;
  final bool leading;
  const SkeletonCard({super.key, this.height = 76, this.leading = true});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            if (leading) ...[
              const SkeletonBox(width: 40, height: 40, radius: 12),
              const SizedBox(width: 12),
            ],
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLine(widthFactor: 0.55, height: 13),
                  SizedBox(height: 9),
                  SkeletonLine(widthFactor: 0.8, height: 10),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const SkeletonBox(width: 56, height: 14, radius: 7),
          ],
        ),
      );
}

/// A list of [SkeletonCard]s — the default for list screens.
class SkeletonList extends StatelessWidget {
  final int count;
  final EdgeInsetsGeometry padding;
  final double itemHeight;
  const SkeletonList({
    super.key,
    this.count = 8,
    this.padding = const EdgeInsets.all(16),
    this.itemHeight = 76,
  });

  @override
  Widget build(BuildContext context) => Shimmer(
        child: ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          itemCount: count,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, __) => SkeletonCard(height: itemHeight),
        ),
      );
}

/// Dashboard placeholder: a row of KPI tiles, a chart and a few rows.
class SkeletonDashboard extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  const SkeletonDashboard({super.key, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) => Shimmer(
        child: ListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          children: [
            const SkeletonLine(widthFactor: 0.4, height: 20),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth >= 760 ? 4 : 2;
                final w = (c.maxWidth - (cols - 1) * 12) / cols;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (var i = 0; i < 4; i++) SkeletonBox(width: w, height: 92, radius: 16),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            const SkeletonBox(height: 220, radius: 18),
            const SizedBox(height: 16),
            for (var i = 0; i < 3; i++) ...[
              const SkeletonCard(height: 64),
              const SizedBox(height: 10),
            ],
          ],
        ),
      );
}
