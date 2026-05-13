import 'package:flutter/material.dart';

import 'sheet_numeric_keypad.dart';

void _applyInitialToControllers(String v, TextEditingController a, TextEditingController b) {
  final t = v.trim();
  if (t.isEmpty) return;
  if (t.contains('/')) {
    final parts = t.split('/');
    if (parts.length >= 2) {
      a.text = parts[0].trim();
      b.text = parts.sublist(1).join('/').trim();
      return;
    }
  }
  final comma = t.indexOf(',');
  if (comma >= 0) {
    a.text = t.substring(0, comma).trim();
    b.text = t.substring(comma + 1).trim();
    return;
  }
  a.text = t;
}

/// Two read-only numeric fields plus an on-screen keypad. Used for **long press**
/// on SP/SW columns: values save with `/`. Regular tap uses [SingleNumericCellEditor]
/// (one number).
class DualNumericCellEditor extends StatefulWidget {
  const DualNumericCellEditor({
    super.key,
    required this.cellLabel,
    this.showHeading = true,
    required this.initialValue,
    this.pairDelimiter = ',',
    this.longPressPairMode = false,
    this.secondFieldOptional = true,
    this.showActions = false,
    this.onCancel,
    this.onSave,
  });

  /// Column name and row, e.g. `SW · Row 3`. Shown inside the sheet unless [showHeading] is false.
  final String cellLabel;
  /// When false, the parent should show [cellLabel] (e.g. [AlertDialog.title]) to avoid duplication.
  final bool showHeading;
  final String initialValue;
  /// Character between the two numbers when both are set (`','` for tap, `'/'` for long-press).
  final String pairDelimiter;
  /// When true, the keypad shows the long-press hint row; colors match a normal tap.
  final bool longPressPairMode;
  /// When false (long-press pair entry), the second field is required.
  final bool secondFieldOptional;
  final bool showActions;
  final VoidCallback? onCancel;
  final void Function(String value)? onSave;

  @override
  State<DualNumericCellEditor> createState() => DualNumericCellEditorState();
}

class DualNumericCellEditorState extends State<DualNumericCellEditor> {
  late final TextEditingController _a;
  late final TextEditingController _b;
  late final FocusNode _focusA;
  late final FocusNode _focusB;

  TextEditingController get _activeController =>
      _focusB.hasFocus ? _b : _a;

  @override
  void initState() {
    super.initState();
    _a = TextEditingController();
    _b = TextEditingController();
    _focusA = FocusNode();
    _focusB = FocusNode();
    _applyInitialToControllers(widget.initialValue, _a, _b);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusA.requestFocus();
    });
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    _focusA.dispose();
    _focusB.dispose();
    super.dispose();
  }

  String get valueA => _a.text.trim();

  String get valueB => _b.text.trim();

  String get combinedValue {
    final x = valueA;
    final y = valueB;
    if (x.isEmpty && y.isEmpty) return '';
    if (y.isEmpty) return x;
    if (x.isEmpty) return '';
    return '$x${widget.pairDelimiter}$y';
  }

  /// Returns false if the second field has a value but the first does not.
  bool validate() {
    final x = valueA;
    final y = valueB;
    if (y.isNotEmpty && x.isEmpty) return false;
    return true;
  }

  void _onKeypadKey(String key) {
    final c = _activeController;
    final t = c.text;
    if (key == 'del') {
      if (t.isEmpty) {
        if (_focusB.hasFocus) {
          _focusA.requestFocus();
          setState(() {});
        }
        return;
      }
      c.text = t.substring(0, t.length - 1);
      c.selection = TextSelection.collapsed(offset: c.text.length);
      setState(() {});
      return;
    }
    if (key == '.') {
      if (t.contains('.')) return;
      if (t.isEmpty) {
        c.text = '0.';
      } else {
        c.text = '$t.';
      }
      c.selection = TextSelection.collapsed(offset: c.text.length);
      setState(() {});
      return;
    }
    c.text = '$t$key';
    c.selection = TextSelection.collapsed(offset: c.text.length);
    setState(() {});
  }

  void _trySave(BuildContext context) {
    if (!validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter the first number before the second.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final v = combinedValue;
    final x = valueA;
    final y = valueB;
    if (x.isNotEmpty && double.tryParse(x) == null) {
      _invalidNumberSnack(context);
      return;
    }
    if (y.isNotEmpty && double.tryParse(y) == null) {
      _invalidNumberSnack(context);
      return;
    }
    widget.onSave?.call(v);
  }

  void _invalidNumberSnack(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Enter valid numbers.'), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 380;
    final fieldStyle = theme.textTheme.bodyLarge;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeading) ...[
          Text(
            widget.cellLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: narrow ? 8 : 10),
        ],
        TextField(
          controller: _a,
          focusNode: _focusA,
          readOnly: true,
          showCursor: true,
          keyboardType: TextInputType.none,
          enableInteractiveSelection: false,
          style: fieldStyle,
          decoration: InputDecoration(
            isDense: narrow,
            labelText: 'First number',
            border: const OutlineInputBorder(),
            contentPadding: narrow
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
                : null,
          ),
          onTap: () {
            _focusA.requestFocus();
            setState(() {});
          },
        ),
        SizedBox(height: narrow ? 8 : 10),
        TextField(
          controller: _b,
          focusNode: _focusB,
          readOnly: true,
          showCursor: true,
          keyboardType: TextInputType.none,
          enableInteractiveSelection: false,
          style: fieldStyle,
          decoration: InputDecoration(
            isDense: narrow,
            labelText: 'Second number',
            border: const OutlineInputBorder(),
            hintText: widget.secondFieldOptional ? 'Optional' : null,
            contentPadding: narrow
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
                : null,
          ),
          onTap: () {
            _focusB.requestFocus();
            setState(() {});
          },
        ),
        SizedBox(height: narrow ? 8 : 10),
        SheetNumericKeypad(
          mode:
              widget.longPressPairMode
                  ? SheetKeypadVisualMode.longPressPair
                  : SheetKeypadVisualMode.standard,
          onKey: _onKeypadKey,
        ),
        if (widget.showActions) ...[
          SizedBox(height: narrow ? 12 : 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
              ),
              SizedBox(width: narrow ? 8 : 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => _trySave(context),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
