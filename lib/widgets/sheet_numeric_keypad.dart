import 'package:flutter/material.dart';

/// Visual treatment for the in-app numeric pad.
enum SheetKeypadVisualMode {
  /// Normal cell edit (single tap).
  standard,

  /// Long-press pair edit: hint row only; pad colors match [standard].
  longPressPair,
}

/// In-app numeric pad (avoids the compact iOS floating number strip on tablets).
/// Key size scales down on narrow phones while staying slightly larger than
/// typical system number keys.
class SheetNumericKeypad extends StatelessWidget {
  const SheetNumericKeypad({
    super.key,
    required this.onKey,
    this.mode = SheetKeypadVisualMode.standard,
  });

  /// [key] is `0`–`9`, `.`, or `del` (backspace).
  final void Function(String key) onKey;

  /// [SheetKeypadVisualMode.longPressPair] adds a hint row only; colors match [standard].
  final SheetKeypadVisualMode mode;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['.', '0', 'del'],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final w = MediaQuery.sizeOf(context).width;
    final keyHeight = w < 340 ? 47.0 : (w < 400 ? 49.0 : 51.0);
    final gap = w < 360 ? 5.0 : 6.0;
    final fontSize = w < 360 ? 17.0 : 19.0;
    final iconSize = fontSize + 2;
    final pair = mode == SheetKeypadVisualMode.longPressPair;

    final backdrop = cs.surfaceContainerHighest.withValues(alpha: 0.35);

    final keyStyle = FilledButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size(0, keyHeight),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    final hintColor = cs.onSurfaceVariant;

    return Material(
      color: backdrop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(gap + 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pair) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    size: 20,
                    color: hintColor,
                  ),
                  SizedBox(width: gap + 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Long press · pair mode',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: hintColor,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        Text(
                          'Saved as first / second',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: hintColor.withValues(alpha: 0.92),
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: gap + 6),
            ],
            for (var i = 0; i < _rows.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i < _rows.length - 1 ? gap : 0),
                child: Row(
                  children: [
                    for (final k in _rows[i])
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: gap * 0.65),
                          child: SizedBox(
                            height: keyHeight,
                            width: double.infinity,
                            child: FilledButton.tonal(
                              style: keyStyle,
                              onPressed: () => onKey(k),
                              child:
                                  k == 'del'
                                      ? Icon(Icons.backspace_outlined, size: iconSize)
                                      : Text(
                                        k,
                                        style: TextStyle(
                                          fontSize: fontSize,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                            ),
                          ),
                        ),
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
