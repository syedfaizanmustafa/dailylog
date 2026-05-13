import 'package:flutter/material.dart';

import 'sheet_numeric_keypad.dart';

/// One read-only numeric field and the standard in-app keypad (regular cell tap).
class SingleNumericCellEditor extends StatefulWidget {
  const SingleNumericCellEditor({
    super.key,
    required this.cellLabel,
    this.showHeading = true,
    required this.initialValue,
    this.showActions = false,
    this.onCancel,
    this.onSave,
  });

  final String cellLabel;
  final bool showHeading;
  final String initialValue;
  final bool showActions;
  final VoidCallback? onCancel;
  final void Function(String value)? onSave;

  @override
  State<SingleNumericCellEditor> createState() => SingleNumericCellEditorState();
}

class SingleNumericCellEditorState extends State<SingleNumericCellEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  String get value => _controller.text.trim();

  /// Empty is allowed (clear cell). Non-empty must parse as a number.
  bool validate() {
    final t = value;
    if (t.isEmpty) return true;
    return double.tryParse(t) != null;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onKeypadKey(String key) {
    final t = _controller.text;
    if (key == 'del') {
      if (t.isEmpty) return;
      _controller.text = t.substring(0, t.length - 1);
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      setState(() {});
      return;
    }
    if (key == '.') {
      if (t.contains('.')) return;
      if (t.isEmpty) {
        _controller.text = '0.';
      } else {
        _controller.text = '$t.';
      }
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
      setState(() {});
      return;
    }
    _controller.text = '$t$key';
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    setState(() {});
  }

  void _trySave(BuildContext context) {
    if (!validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid number or leave empty.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    widget.onSave?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 380;
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
          controller: _controller,
          focusNode: _focus,
          readOnly: true,
          showCursor: true,
          keyboardType: TextInputType.none,
          enableInteractiveSelection: false,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            isDense: narrow,
            labelText: 'Value',
            border: const OutlineInputBorder(),
            contentPadding: narrow
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 10)
                : null,
          ),
          onTap: () {
            _focus.requestFocus();
            setState(() {});
          },
        ),
        SizedBox(height: narrow ? 8 : 10),
        SheetNumericKeypad(onKey: _onKeypadKey),
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
