import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:signature/signature.dart';

import '../config/brand.dart';
import '../config/receipt_config.dart';
import '../services/receipt_service.dart';

/// Customer-facing signature screen. Same contract as before: reads
/// `onSignatureComplete`, `onSignaturePointsComplete`, `existingName` and
/// `existingPoints` from the route's `extra`, calls the callbacks with the
/// strokes / PNG and the typed name, then pops.
///
/// New: an optional "Text me my receipt" phone number, handed to the receipt
/// screen through [ReceiptService.pendingCustomerPhone] so staff don't retype it.
///
/// When `idRequired` is true in `extra` (the row paid
/// [ReceiptConfig.idRequiredAt] or more), an I.D. # is required: Done stays
/// off until one is typed, and it is handed back through
/// `onCustomerIdComplete` (pre-filled from `existingId`).
class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key});

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _idController = TextEditingController();
  late final SignatureController _signatureController;
  bool _idRequired = false;
  void Function(String)? _onCustomerIdComplete;
  Function(Uint8List, String)? _onSignatureComplete;
  Function(List<Point>, String)? _onSignaturePointsComplete;
  bool _hasStrokes = false;
  bool _signing = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // A fresh signature screen never inherits a previous customer's number.
    ReceiptService.pendingCustomerPhone = null;
    _signatureController = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
      onDrawStart: () {
        if (!_signing) setState(() => _signing = true);
      },
      onDrawEnd: () {
        if (_signing) setState(() => _signing = false);
      },
    );
    _signatureController.addListener(_onSignatureChanged);
    _nameController.addListener(() => setState(() {}));
    _idController.addListener(() => setState(() {}));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extra = GoRouterState.of(context).extra;
      if (extra is! Map<String, dynamic>) return;

      if (extra.containsKey('onSignatureComplete')) {
        _onSignatureComplete =
            extra['onSignatureComplete'] as Function(Uint8List, String)?;
      }
      if (extra.containsKey('onSignaturePointsComplete')) {
        _onSignaturePointsComplete =
            extra['onSignaturePointsComplete'] as Function(List<Point>, String)?;
      }

      final onId = extra['onCustomerIdComplete'];
      if (onId is void Function(String)) _onCustomerIdComplete = onId;

      // Pre-fill existing name + signature when re-opening a signed cell.
      final existingName = extra['existingName'];
      final existingPoints = extra['existingPoints'];
      final existingId = extra['existingId'];
      if (mounted) {
        setState(() {
          _idRequired = extra['idRequired'] == true;
          if (existingId is String && existingId.isNotEmpty) {
            _idController.text = existingId;
          }
          if (existingName is String && existingName.isNotEmpty) {
            _nameController.text = existingName;
          }
          if (existingPoints is List<Point> && existingPoints.isNotEmpty) {
            _signatureController.value = List<Point>.from(existingPoints);
          }
        });
      }
    });
  }

  void _onSignatureChanged() {
    final has = _signatureController.isNotEmpty;
    if (has != _hasStrokes && mounted) setState(() => _hasStrokes = has);
  }

  @override
  void dispose() {
    _signatureController.removeListener(_onSignatureChanged);
    _nameController.dispose();
    _phoneController.dispose();
    _idController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  bool get _idOk => !_idRequired || ReceiptConfig.isValidCustomerId(_idController.text);

  bool get _ready => _hasStrokes && _nameController.text.trim().isNotEmpty && _idOk;

  /// Phones (either orientation) get the full-screen signing layout.
  bool get _isPhone => MediaQuery.sizeOf(context).shortestSide < 600;

  /// Phone: edit name / I.D. / phone in a small sheet so the pad keeps the
  /// screen.
  Future<void> _editField(_Field field) async {
    final phone = field == _Field.phone;
    final id = field == _Field.id;
    final controller = switch (field) {
      _Field.name => _nameController,
      _Field.id => _idController,
      _Field.phone => _phoneController,
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          16 + MediaQuery.viewInsetsOf(ctx).bottom + MediaQuery.paddingOf(ctx).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  switch (field) {
                    _Field.name => Icons.person_outline_rounded,
                    _Field.id => Icons.badge_outlined,
                    _Field.phone => Icons.sms_outlined,
                  },
                  color: phone ? AppColors.amber : AppColors.navy,
                ),
                const SizedBox(width: 8),
                Text(
                  switch (field) {
                    _Field.name => 'Your full name',
                    _Field.id => 'Driver license or I.D. #',
                    _Field.phone => 'Text me my receipt',
                  },
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.navy,
                  ),
                ),
                if (phone) ...[
                  const SizedBox(width: 6),
                  const Text('(optional)', style: TextStyle(color: AppColors.slate)),
                ],
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: phone ? TextInputType.phone : (id ? TextInputType.text : TextInputType.name),
              textCapitalization: switch (field) {
                _Field.name => TextCapitalization.words,
                _Field.id => TextCapitalization.characters,
                _Field.phone => TextCapitalization.none,
              },
              autocorrect: !id,
              inputFormatters: phone ? [_UsPhoneFormatter()] : null,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 20),
              decoration: _fieldDecoration(switch (field) {
                _Field.name => 'First and last name',
                _Field.id => 'e.g. D1234567',
                _Field.phone => '(916) 555-0123',
              }),
              onSubmitted: (_) => Navigator.of(ctx).pop(),
            ),
            if (phone) ...[
              const SizedBox(height: 8),
              const Text(
                ReceiptConfig.smsConsentText,
                style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF4A5263)),
              ),
            ],
            if (id) ...[
              const SizedBox(height: 8),
              Text(
                _idHelpText,
                style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF4A5263)),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                style: FilledButton.styleFrom(backgroundColor: AppColors.forest),
                child: const Text('Save', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  String get _idHelpText =>
      'Required for ${ReceiptConfig.idRequiredAtLabel} or more. '
      'Printed on your receipt. Staff will check your I.D.';

  void _clear() {
    HapticFeedback.selectionClick();
    _signatureController.clear();
  }

  Future<void> _submit() async {
    final customerName = _nameController.text.trim();
    if (customerName.isEmpty) {
      if (_isPhone) {
        await _editField(_Field.name);
        if (_nameController.text.trim().isEmpty) return;
        return _submit();
      }
      showAppSnack(context, 'Please type your name above the signature.', error: true);
      return;
    }
    if (!_signatureController.isNotEmpty) {
      showAppSnack(context, 'Please sign in the box.', error: true);
      return;
    }
    if (!_idOk) {
      if (_isPhone) {
        await _editField(_Field.id);
        if (!_idOk) return;
        return _submit();
      }
      showAppSnack(
        context,
        'An I.D. # is required for ${ReceiptConfig.idRequiredAtLabel} or more.',
        error: true,
      );
      return;
    }

    final phoneText = _phoneController.text.trim();
    String? phoneE164;
    if (phoneText.isNotEmpty) {
      phoneE164 = ReceiptService.normalizeUsPhone(phoneText);
      if (phoneE164 == null) {
        showAppSnack(context, 'That phone number looks incomplete — 10 digits please.',
            error: true);
        return;
      }
    }

    setState(() => _submitting = true);
    final points = _signatureController.points;
    final signatureBytes = await _signatureController.toPngBytes();
    if (!mounted) return;

    if (signatureBytes == null) {
      setState(() => _submitting = false);
      showAppSnack(context, 'Could not save the signature. Please try again.', error: true);
      return;
    }

    // Hand the number to the receipt screen that opens next.
    ReceiptService.pendingCustomerPhone = phoneE164;

    // The I.D. # first, so it is there when the receipt is issued right after.
    if (_idRequired) {
      _onCustomerIdComplete?.call(ReceiptConfig.cleanCustomerId(_idController.text));
    }

    var called = false;
    if (_onSignaturePointsComplete != null) {
      _onSignaturePointsComplete!(points, customerName);
      called = true;
    }
    if (_onSignatureComplete != null) {
      _onSignatureComplete!(signatureBytes, customerName);
      called = true;
    }

    if (called) {
      HapticFeedback.lightImpact();
      if (mounted) context.pop();
    } else {
      setState(() => _submitting = false);
      ReceiptService.pendingCustomerPhone = null;
      showAppSnack(context, 'Something went wrong — go back and tap the sign cell again.',
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final quick = reduce ? Duration.zero : const Duration(milliseconds: 200);

    return Scaffold(
      backgroundColor: AppColors.mist,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          // Header
          Container(
            color: Colors.white,
            child: SafeArea(
              bottom: false,
              child: Container(
                height: _isPhone ? 56 : 72,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.line)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to sheet',
                      icon: const Icon(Icons.arrow_back, color: AppColors.navy),
                      onPressed: () => context.pop(),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Customer signature',
                      style: TextStyle(fontSize: 15, color: AppColors.slate),
                    ),
                    const Spacer(),
                    const BrandMark(size: 36),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, c) {
                  if (_isPhone) return _buildPhoneBody(c, quick);
                  final hPad = c.maxWidth >= 860 ? 32.0 : 20.0;
                  final pad = _SignaturePadCard(
                    controller: _signatureController,
                    hasStrokes: _hasStrokes,
                    signing: _signing,
                    quick: quick,
                  );
                  final details = _DetailsCards(
                    nameController: _nameController,
                    phoneController: _phoneController,
                    idController: _idRequired ? _idController : null,
                    idHelp: _idHelpText,
                    sideBySide: c.maxWidth >= 640,
                  );
                  final actions = _ActionRow(
                    hasStrokes: _hasStrokes,
                    ready: _ready,
                    submitting: _submitting,
                    quick: quick,
                    onClear: _clear,
                    onDone: _submit,
                    wide: c.maxWidth >= 640,
                  );

                  // One widget tree for every height. Swapping layouts when
                  // the keyboard opens rebuilt the name field, which dropped
                  // focus and closed the keyboard straight away. Now the
                  // content just keeps a minimum height and scrolls when the
                  // keyboard leaves less room than that.
                  // A third card (I.D. #) stacked under the others needs room.
                  final minContentHeight =
                      _idRequired && c.maxWidth < 640 ? 700.0 : 520.0;
                  final fits = c.maxHeight >= minContentHeight;
                  return SingleChildScrollView(
                    // No scrolling when everything fits, so signing strokes
                    // never move the page. Only the physics changes, so the
                    // fields below keep their focus.
                    physics: fits
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    child: SizedBox(
                      height: fits ? c.maxHeight : minContentHeight,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 20, hPad, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: pad),
                            const SizedBox(height: 16),
                            details,
                            const SizedBox(height: 16),
                            actions,
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneBody(BoxConstraints c, Duration quick) {
    // Orientation from the screen, not the space left above the keyboard,
    // so opening the name sheet doesn't flip the layout behind it.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final pad = _SignaturePadCard(
      controller: _signatureController,
      hasStrokes: _hasStrokes,
      signing: _signing,
      quick: quick,
      compact: true,
    );
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final nameTile = _PhoneFieldTile(
      icon: Icons.person_outline_rounded,
      label: 'Name',
      value: name.isEmpty ? 'Tap to add your name' : name,
      missing: name.isEmpty,
      accent: AppColors.navy,
      onTap: () => _editField(_Field.name),
    );
    final id = _idController.text.trim();
    final idTile = _PhoneFieldTile(
      icon: Icons.badge_outlined,
      label: 'I.D. # (required)',
      value: id.isEmpty ? 'Tap to add I.D. #' : id,
      missing: !_idOk,
      accent: AppColors.navy,
      onTap: () => _editField(_Field.id),
    );
    final phoneTile = _PhoneFieldTile(
      icon: Icons.sms_outlined,
      label: 'Text receipt (optional)',
      value: phone.isEmpty ? 'Add phone' : phone,
      missing: false,
      accent: AppColors.amber,
      onTap: () => _editField(_Field.phone),
    );
    final actions = _ActionRow(
      hasStrokes: _hasStrokes,
      ready: _ready,
      submitting: _submitting,
      quick: quick,
      onClear: _clear,
      onDone: _submit,
      wide: false,
      compact: true,
    );

    if (landscape) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: pad),
            const SizedBox(width: 12),
            SizedBox(
              width: 230,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nameTile,
                  if (_idRequired) ...[
                    const SizedBox(height: 8),
                    idTile,
                  ],
                  const SizedBox(height: 8),
                  phoneTile,
                  const Spacer(),
                  actions,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: pad),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(flex: 5, child: nameTile),
              const SizedBox(width: 8),
              Expanded(flex: 4, child: phoneTile),
            ],
          ),
          if (_idRequired) ...[
            const SizedBox(height: 8),
            idTile,
          ],
          const SizedBox(height: 10),
          actions,
        ],
      ),
    );
  }
}

enum _Field { name, id, phone }

class _SignaturePadCard extends StatelessWidget {
  final SignatureController controller;
  final bool hasStrokes;
  final bool signing;
  final Duration quick;
  final bool compact;
  const _SignaturePadCard({
    required this.controller,
    required this.hasStrokes,
    required this.signing,
    required this.quick,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : const EdgeInsets.fromLTRB(24, 18, 24, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 12,
            children: [
              Text(
                'Please sign below',
                style: TextStyle(
                  fontSize: compact ? 20 : 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
              if (!compact)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Confirms you received payment',
                    style: TextStyle(fontSize: 14, color: AppColors.slate),
                  ),
                ),
            ],
          ),
          SizedBox(height: compact ? 8 : 12),
          Expanded(
            child: AnimatedContainer(
              duration: quick,
              decoration: BoxDecoration(
                color: const Color(0xFFFBFCFD),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: signing ? AppColors.blue : AppColors.field,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  // Signature baseline with an ✕ mark (behind the strokes).
                  Positioned(
                    left: compact ? 20 : 40,
                    right: compact ? 20 : 40,
                    bottom: compact ? 36 : 56,
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 6),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Color(0xFF8D99AE), width: 2),
                        ),
                      ),
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(Icons.close, color: Color(0xFF8D99AE), size: 22),
                      ),
                    ),
                  ),
                  // Hint — fades on the first stroke.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: hasStrokes ? 0 : 1,
                        duration: quick,
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.draw_outlined,
                                size: 34, color: Color(0xFF8D99AE)),
                            SizedBox(height: 8),
                            Text(
                              'Sign here with your finger',
                              style: TextStyle(fontSize: 16, color: Color(0xFF8D99AE)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Signature(
                      controller: controller,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _fieldDecoration(String hint) {
  OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: w),
      );
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    enabledBorder: b(AppColors.field, 1),
    focusedBorder: b(AppColors.blue, 2),
  );
}

BoxDecoration _cardDecoration({Color? outline}) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: outline == null ? null : Border.all(color: outline, width: 2),
      boxShadow: [
        BoxShadow(
          color: AppColors.navy.withOpacity(0.06),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ],
    );

/// Name + optional phone, side by side under the signature pad.
class _DetailsCards extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController phoneController;

  /// Shown (and required) only when set.
  final TextEditingController? idController;
  final String idHelp;
  final bool sideBySide;
  const _DetailsCards({
    required this.nameController,
    required this.phoneController,
    this.idController,
    this.idHelp = '',
    required this.sideBySide,
  });

  @override
  Widget build(BuildContext context) {
    final name = Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.person_outline_rounded, size: 18, color: AppColors.navy),
              SizedBox(width: 8),
              Text(
                'Your full name',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 18),
            decoration: _fieldDecoration('First and last name'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Printed on your receipt next to your signature.',
            style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF4A5263)),
          ),
        ],
      ),
    );

    final phone = Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(outline: AppColors.amberLine),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.sms_outlined, size: 18, color: AppColors.amber),
              SizedBox(width: 8),
              Text(
                'Text me my receipt',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              SizedBox(width: 6),
              Text('(optional)', style: TextStyle(color: AppColors.slate)),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            inputFormatters: [_UsPhoneFormatter()],
            style: const TextStyle(fontSize: 18),
            decoration: _fieldDecoration('(916) 555-0123'),
          ),
          const SizedBox(height: 8),
          const Text(
            ReceiptConfig.smsConsentText,
            style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF4A5263)),
          ),
        ],
      ),
    );

    final idc = idController;
    final idCard = idc == null
        ? null
        : Container(
            padding: const EdgeInsets.all(20),
            decoration: _cardDecoration(
              outline: ReceiptConfig.isValidCustomerId(idc.text)
                  ? null
                  : AppColors.amberLine,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 18, color: AppColors.navy),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Driver license or I.D. #',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    SizedBox(width: 6),
                    Text('(required)',
                        style: TextStyle(color: AppColors.amberText, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: idc,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 18),
                  decoration: _fieldDecoration('e.g. D1234567'),
                ),
                const SizedBox(height: 8),
                Text(
                  idHelp,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF4A5263)),
                ),
              ],
            ),
          );

    if (!sideBySide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          name,
          if (idCard != null) ...[const SizedBox(height: 16), idCard],
          const SizedBox(height: 16),
          phone,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 2, child: name),
        if (idCard != null) ...[
          const SizedBox(width: 16),
          Expanded(flex: 2, child: idCard),
        ],
        const SizedBox(width: 16),
        Expanded(flex: 3, child: phone),
      ],
    );
  }
}

/// Clear (left) and Done (right) along the bottom edge.
class _ActionRow extends StatelessWidget {
  final bool hasStrokes;
  final bool ready;
  final bool submitting;
  final Duration quick;
  final VoidCallback onClear;
  final VoidCallback onDone;
  final bool wide;
  final bool compact;
  const _ActionRow({
    required this.hasStrokes,
    required this.ready,
    required this.submitting,
    required this.quick,
    required this.onClear,
    required this.onDone,
    required this.wide,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = compact ? 56.0 : 64.0;
    final clear = SizedBox(
      height: h,
      child: OutlinedButton.icon(
        onPressed: hasStrokes && !submitting ? onClear : null,
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.redTint,
          foregroundColor: AppColors.redText,
          side: const BorderSide(color: Color(0xFFF0C4BE)),
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: const Icon(Icons.refresh, size: 20),
        label: Text(compact ? 'Clear' : 'Clear signature', style: const TextStyle(fontSize: 16)),
      ),
    );

    final done = SizedBox(
      height: h,
      child: AnimatedContainer(
        duration: quick,
        decoration: BoxDecoration(
          color: ready ? AppColors.forest : AppColors.field,
          borderRadius: BorderRadius.circular(16),
          boxShadow: ready
              ? [
                  BoxShadow(
                    color: AppColors.forest.withOpacity(0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ]
              : const [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: submitting ? null : onDone,
            child: Center(
              child: submitting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedScale(
                          scale: ready ? 1 : 0.4,
                          duration: quick,
                          child: AnimatedOpacity(
                            opacity: ready ? 1 : 0,
                            duration: quick,
                            child: const Icon(Icons.check_rounded,
                                color: Colors.white, size: 24),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Done',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: ready ? Colors.white : AppColors.slate,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );

    return Row(
      children: [
        clear,
        SizedBox(width: compact ? 10 : 16),
        if (wide) const Spacer(),
        if (wide) SizedBox(width: 380, child: done) else Expanded(child: done),
      ],
    );
  }
}

/// Formats digits as `(XXX) XXX-XXXX` while typing.
class _UsPhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('1')) {
      digits = digits.substring(1);
    }
    if (digits.length > 10) digits = digits.substring(0, 10);

    final b = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i == 0) b.write('(');
      if (i == 3) b.write(') ');
      if (i == 6) b.write('-');
      b.write(digits[i]);
    }
    final text = b.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Phone: tappable name / phone tile under the signature pad.
class _PhoneFieldTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool missing;
  final Color accent;
  final VoidCallback onTap;
  const _PhoneFieldTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.missing,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: missing ? AppColors.amberLine : AppColors.line,
              width: missing ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.slate),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: missing ? AppColors.amberText : AppColors.navy,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.edit_rounded, size: 16, color: AppColors.slate),
            ],
          ),
        ),
      ),
    );
  }
}
