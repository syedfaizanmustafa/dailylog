import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/brand.dart';
import '../config/receipt_config.dart';
import '../controllers/auth_controller.dart';
import '../models/receipt.dart';
import '../services/receipt_service.dart';
import '../utils/receipt_code.dart';

/// Pushes the receipt screen. Pass either a [draft] to issue a new receipt
/// or a [receiptId] to re-open an existing one.
Future<void> openReceiptScreen(
  BuildContext context, {
  ReceiptData? draft,
  String? receiptId,
  void Function(ReceiptData issued)? onIssued,
}) {
  return context.push('/receipt', extra: <String, dynamic>{
    'draft': draft,
    'receiptId': receiptId,
    'onIssued': onIssued,
  });
}

/// Shows one customer receipt (PDF preview) with the actions the counter
/// needs right after the customer signs: Print, Text, Email, QR, Share.
class ReceiptScreen extends ConsumerStatefulWidget {
  final ReceiptData? draft;
  final String? receiptId;

  /// Called once a draft has been issued (so the caller can remember the id).
  final void Function(ReceiptData issued)? onIssued;

  const ReceiptScreen({super.key, this.draft, this.receiptId, this.onIssued})
      : assert(draft != null || receiptId != null);

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  ReceiptData? _receipt;
  Uint8List? _pdfBytes;
  int _pdfVersion = 0;
  bool _issuing = true;
  String? _issueError;
  StreamSubscription<ReceiptData?>? _sub;

  bool _showIssuedBanner = false;
  Timer? _bannerTimer;
  bool _emailOpen = false;

  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  bool _sendingSms = false;
  bool _sendingEmail = false;
  bool _savingId = false;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _bannerTimer?.cancel();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _issuing = true;
      _issueError = null;
    });
    String? pendingPhone;
    var freshlyIssued = false;
    try {
      ReceiptData r;
      if (widget.receiptId != null) {
        final loaded = await ReceiptService.getById(widget.receiptId!);
        if (loaded == null) throw Exception('Receipt not found');
        r = loaded;
      } else {
        pendingPhone = ReceiptService.takePendingCustomerPhone();
        final uid = ref.read(authControllerProvider).value?.uid ?? 'unknown';
        // Render a local preview first so the screen is never blank, then
        // issue the number (needs network).
        _pdfBytes = await ReceiptService.render(widget.draft!);
        if (mounted) setState(() => _receipt = widget.draft);
        r = await ReceiptService.issue(widget.draft!, issuedByUid: uid);
        freshlyIssued = true;
        widget.onIssued?.call(r);
      }
      final bytes = await ReceiptService.render(r);
      if (!mounted) return;
      setState(() {
        _receipt = r;
        _pdfBytes = bytes;
        _pdfVersion++;
        _issuing = false;
        _idCtrl.text = r.customerId;
        if (r.sms.to.isNotEmpty) {
          _phoneCtrl.text = ReceiptService.formatUsPhone(r.sms.to);
        } else if (pendingPhone != null) {
          _phoneCtrl.text = ReceiptService.formatUsPhone(pendingPhone);
        }
        if (r.email.to.isNotEmpty) {
          _emailCtrl.text = r.email.to;
          _emailOpen = true;
        }
      });
      if (freshlyIssued) {
        HapticFeedback.mediumImpact();
        setState(() => _showIssuedBanner = true);
        _bannerTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted) setState(() => _showIssuedBanner = false);
        });
      }
      _sub?.cancel();
      if (r.id != null) {
        _sub = ReceiptService.watch(r.id!).listen((live) {
          if (live != null && mounted) setState(() => _receipt = live);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _issuing = false;
        _issueError = friendlyError(e);
      });
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────

  Future<void> _sendSms() async {
    final r = _receipt;
    if (r == null || !r.isIssued) return;
    final e164 = ReceiptService.normalizeUsPhone(_phoneCtrl.text);
    if (e164 == null) {
      showAppSnack(context, 'Enter a 10-digit US phone number.', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _sendingSms = true);
    try {
      await ReceiptService.requestSms(r.id!, e164);
      HapticFeedback.lightImpact();
      if (mounted) {
        showAppSnack(context, 'Sending to ${ReceiptService.formatUsPhone(e164)}');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sendingSms = false);
    }
  }

  Future<void> _sendEmail() async {
    final r = _receipt;
    if (r == null || !r.isIssued) return;
    final email = _emailCtrl.text.trim();
    if (!ReceiptService.looksLikeEmail(email)) {
      showAppSnack(context, 'Enter a valid email address.', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _sendingEmail = true);
    try {
      await ReceiptService.requestEmail(r.id!, email);
      if (mounted) showAppSnack(context, 'Sending to $email');
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sendingEmail = false);
    }
  }

  Future<void> _saveCustomerId() async {
    final r = _receipt;
    if (r == null || !r.isIssued) return;
    if (_idCtrl.text.trim() == r.customerId) return;
    setState(() => _savingId = true);
    try {
      final updated = await ReceiptService.updateCustomerId(r, _idCtrl.text);
      final bytes = await ReceiptService.render(updated);
      if (!mounted) return;
      setState(() {
        _receipt = updated;
        _pdfBytes = bytes;
        _pdfVersion++;
      });
      showAppSnack(context, 'I.D. # saved on the receipt');
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _savingId = false);
    }
  }

  Future<void> _print() async {
    final r = _receipt;
    final bytes = _pdfBytes;
    if (r == null || bytes == null) return;
    setState(() => _printing = true);
    try {
      final ok = await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'Receipt ${r.receiptNumberLabel}',
      );
      if (ok && r.isIssued) await ReceiptService.markPrinted(r.id!);
    } catch (e) {
      if (mounted) showAppSnack(context, 'Printing failed: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  /// Saves the PDF straight into the app's folder in the Files app
  /// (Files › On My iPad › Camacho Daily Log › Receipts). No share sheet.
  Future<void> _saveToFiles() async {
    final r = _receipt;
    final bytes = _pdfBytes;
    if (r == null || bytes == null) return;
    if (kIsWeb) {
      await _share();
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/Receipts');
      await dir.create(recursive: true);
      final file = File('${dir.path}/Receipt_${r.receiptNumberLabel}.pdf');
      await file.writeAsBytes(bytes, flush: true);
      HapticFeedback.lightImpact();
      if (!mounted) return;
      final where = Platform.isIOS
          ? 'Files › On My ${MediaQuery.sizeOf(context).shortestSide >= 600 ? 'iPad' : 'iPhone'} › Camacho Daily Log › Receipts'
          : file.path;
      showAppSnack(context, 'Saved Receipt_${r.receiptNumberLabel}.pdf to $where');
    } catch (e) {
      if (mounted) showAppSnack(context, 'Could not save the PDF: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _share() async {
    final r = _receipt;
    final bytes = _pdfBytes;
    if (r == null || bytes == null) return;
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'Receipt_${r.receiptNumberLabel}.pdf',
    );
  }

  Future<void> _copyLink() async {
    final token = _receipt?.token;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: ReceiptConfig.receiptUrl(token)));
    HapticFeedback.selectionClick();
    if (mounted) showAppSnack(context, 'Link copied');
  }

  void _done() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final r = _receipt;
    final title = r == null
        ? 'Receipt'
        : r.isIssued
            ? '#${r.receiptNumberLabel}'
            : 'Receipt (issuing…)';
    final quick = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 250);

    return Scaffold(
      backgroundColor: AppColors.mist,
      body: Column(
        children: [
          // Header
          Container(
            color: Colors.white,
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 72,
                padding: EdgeInsets.symmetric(
                    horizontal: MediaQuery.sizeOf(context).width < 600 ? 4 : 16),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.line)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back, color: AppColors.navy),
                      onPressed: _done,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      flex: 3,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.navy,
                        ),
                      ),
                    ),
                    if (r != null && r.customerName.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.blueTint,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            r.customerName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.blueText,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (_pdfBytes != null) ...[
                      IconButton(
                        tooltip: 'Save PDF to Files',
                        icon: const Icon(Icons.save_alt_rounded, color: AppColors.navy),
                        onPressed: _saveToFiles,
                      ),
                      IconButton(
                        tooltip: 'Share PDF',
                        icon: const Icon(Icons.ios_share, color: AppColors.navy),
                        onPressed: _share,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Issued banner
          AnimatedSize(
            duration: quick,
            curve: Curves.easeOutCubic,
            child: _showIssuedBanner && r != null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: _IssuedBanner(receipt: r, duration: quick),
                  )
                : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  final preview = _buildPreview(quick);
                  final panel = _buildPanel(context, quick);
                  if (wide) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: 20),
                          SizedBox(
                            width: (constraints.maxWidth * 0.34).clamp(340.0, 400.0),
                            child: panel,
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      SizedBox(height: constraints.maxHeight * 0.42, child: preview),
                      Expanded(child: panel),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(Duration quick) {
    final bytes = _pdfBytes;
    if (bytes == null) {
      return Center(
        child: _issueError != null
            ? _ErrorBox(message: _issueError!, onRetry: _load)
            : const CircularProgressIndicator(),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: const Color(0xFFDDE2E8),
        child: TweenAnimationBuilder<double>(
          key: ValueKey('receipt-anim-$_pdfVersion'),
          tween: Tween(begin: 0.96, end: 1),
          duration: quick,
          curve: Curves.easeOutCubic,
          builder: (context, s, child) => Transform.scale(scale: s, child: child),
          child: PdfPreview(
            key: ValueKey('receipt-pdf-$_pdfVersion'),
            build: (_) async => bytes,
            useActions: false,
            canChangeOrientation: false,
            canChangePageFormat: false,
            canDebug: false,
            allowPrinting: false,
            allowSharing: false,
            maxPageWidth: 900,
            previewPageMargin: const EdgeInsets.all(16),
            pdfPreviewPageDecoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _field(String hint, IconData icon, {Widget? suffix, Color? border}) {
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: AppColors.slate),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      enabledBorder: b(border ?? AppColors.field, 1),
      disabledBorder: b(AppColors.line, 1),
      focusedBorder: b(AppColors.blue, 2),
    );
  }

  Widget _spinner([Color color = Colors.white]) => SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2.2, color: color),
      );

  Widget _buildPanel(BuildContext context, Duration quick) {
    final r = _receipt;
    final issued = r?.isIssued == true;
    final smsFailed = r != null &&
        r.sms.requested &&
        (r.sms.status == 'failed' || r.sms.status == 'undelivered');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          // ── Status ──
          if (_issuing)
            const _InfoRow(icon: Icons.hourglass_top, text: 'Issuing receipt number…')
          else if (_issueError != null)
            _InfoRow(
              icon: Icons.error_outline,
              color: AppColors.redText,
              text: "Couldn't issue the receipt. Check the connection and retry.",
              trailing: TextButton(onPressed: _load, child: const Text('Retry')),
            )
          else if (r != null) ...[
            Text(
              '${r.formattedDate}  ·  Total paid \$${r.grandTotal.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 14, color: AppColors.slate),
            ),
            // Receipt code decoded: location · date · sheet · row.
            if (ReceiptCode.decode(r.receiptCode ?? '') != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  ReceiptCode.decode(r.receiptCode!)!.describe(),
                  style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                ),
              ),
          ],
          const SizedBox(height: 16),

          // ── Print ──
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _pdfBytes == null || _printing ? null : _print,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.navy,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: _printing ? _spinner() : const Icon(Icons.print_outlined),
              label: Text(r?.printed == true ? 'Print again' : 'Print receipt'),
            ),
          ),
          const SizedBox(height: 10),

          // ── Save / share the PDF ──
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _pdfBytes == null || r == null ? null : _saveToFiles,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.navy,
                      side: const BorderSide(color: AppColors.field),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Save to Files'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _pdfBytes == null || r == null ? null : _share,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.navy,
                      side: const BorderSide(color: AppColors.field),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── Text ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.amberSoft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.amberLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Text receipt',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6B4600),
                        ),
                      ),
                    ),
                    if (r != null && r.sms.requested)
                      _StatusChip(r.sms, duration: quick),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _phoneCtrl,
                        enabled: issued && !_sendingSms,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [_UsPhoneFormatter()],
                        style: const TextStyle(fontSize: 16),
                        decoration: _field('(916) 555-0123', Icons.sms_outlined,
                            border: const Color(0xFFE8D3A0)),
                        onSubmitted: (_) => _sendSms(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: issued && !_sendingSms ? _sendSms : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.amber,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        icon: _sendingSms ? _spinner() : const Icon(Icons.send, size: 18),
                        label: Text(r?.sms.requested == true ? 'Resend' : 'Send'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  ReceiptConfig.smsConsentText,
                  style: TextStyle(fontSize: 11, height: 1.5, color: Color(0xFF6B4600)),
                ),
              ],
            ),
          ),

          // ── Failure explained ──
          AnimatedSize(
            duration: quick,
            child: smsFailed
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.redTint,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Text not delivered',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.redText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _smsFailureReason(r?.sms.error),
                            style: const TextStyle(fontSize: 13, color: Color(0xFF6E1C12)),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 18),

          // ── Email (collapsed until SendGrid is set up) ──
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _emailOpen = !_emailOpen),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.field),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mail_outline, size: 18, color: AppColors.navy),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Email receipt', style: TextStyle(fontSize: 15)),
                    ),
                    if (r != null && r.email.requested)
                      _StatusChip(r.email, duration: quick)
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.purpleTint,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Coming soon',
                          style: TextStyle(fontSize: 12, color: AppColors.purpleText),
                        ),
                      ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: _emailOpen ? 0.5 : 0,
                      duration: quick,
                      child: const Icon(Icons.expand_more, color: AppColors.slate),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: quick,
            child: _emailOpen
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: TextField(
                      controller: _emailCtrl,
                      enabled: issued && !_sendingEmail,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: _field(
                        'name@example.com',
                        Icons.alternate_email,
                        suffix: _sendingEmail
                            ? Padding(
                                padding: const EdgeInsets.all(14),
                                child: _spinner(AppColors.navy),
                              )
                            : IconButton(
                                tooltip: 'Send email',
                                icon: const Icon(Icons.send),
                                onPressed: issued ? _sendEmail : null,
                              ),
                      ),
                      onSubmitted: (_) => _sendEmail(),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 18),

          // ── ID # ──
          const Text(
            'Customer I.D. # (optional)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _idCtrl,
            enabled: issued && !_savingId,
            textCapitalization: TextCapitalization.characters,
            decoration: _field(
              'Driver license / ID number',
              Icons.badge_outlined,
              suffix: _savingId
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: _spinner(AppColors.navy),
                    )
                  : IconButton(
                      tooltip: 'Save',
                      icon: const Icon(Icons.check),
                      onPressed: issued ? _saveCustomerId : null,
                    ),
            ),
            onSubmitted: (_) => _saveCustomerId(),
          ),
          const SizedBox(height: 20),

          // ── QR ──
          if (r?.token != null)
            Row(
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1),
                  duration: quick,
                  curve: Curves.easeOutBack,
                  builder: (context, s, child) => Transform.scale(scale: s, child: child),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.blue, width: 2),
                    ),
                    child: QrImageView(
                      data: ReceiptConfig.receiptUrl(r!.token!),
                      size: 96,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Scan to open',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          foregroundColor: AppColors.blue,
                        ),
                        onPressed: _copyLink,
                        icon: const Icon(Icons.link, size: 18),
                        label: const Text('Copy link'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.navy),
              ),
              onPressed: _done,
              child: const Text('Back to sheet'),
            ),
          ),
        ],
      ),
    );
  }

  String _smsFailureReason(String? error) {
    final e = error ?? '';
    if (e.contains('30034') || e.contains('30032') || e.contains('unregistered')) {
      return "Texting isn't approved by the carriers yet. Print the receipt or show the QR code instead.";
    }
    if (e.contains('21610') || e.contains('30004')) {
      return 'This customer replied STOP earlier, so texts to them are blocked.';
    }
    if (e.contains('21211') || e.contains('21614') || e.contains('30006')) {
      return "That number can't receive texts (landline or invalid). Check it or print instead.";
    }
    if (e.contains('30003') || e.contains('30005')) {
      return "The phone is switched off or the number isn't in service.";
    }
    return 'The text could not be delivered. Print the receipt or show the QR code instead.';
  }
}

// ── Small widgets ───────────────────────────────────────────────────────

class _IssuedBanner extends StatelessWidget {
  final ReceiptData receipt;
  final Duration duration;
  const _IssuedBanner({required this.receipt, required this.duration});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, -12 * (1 - t)), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.green,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, color: AppColors.green, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              'Receipt #${receipt.receiptNumberLabel} issued',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                '${receipt.formattedDate} · Total paid \$${receipt.grandTotal.toStringAsFixed(2)}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFDDF2E5), fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final ReceiptDelivery d;
  final Duration duration;
  const _StatusChip(this.d, {required this.duration});

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Color dot;
    late final String label;
    switch (d.status) {
      case 'delivered':
        bg = AppColors.greenTint;
        fg = AppColors.greenText;
        dot = AppColors.green;
        label = 'Delivered';
        break;
      case 'sent':
        bg = AppColors.blueTint;
        fg = AppColors.blueText;
        dot = AppColors.blue;
        label = 'Sent';
        break;
      case 'pending':
        bg = AppColors.amberTint;
        fg = AppColors.amberText;
        dot = AppColors.amber;
        label = 'Queued';
        break;
      case 'queued':
      case 'accepted':
      case 'sending':
        bg = AppColors.blueTint;
        fg = AppColors.blueText;
        dot = AppColors.blue;
        label = 'Sending…';
        break;
      case 'undelivered':
      case 'failed':
        bg = AppColors.redTint;
        fg = AppColors.redText;
        dot = AppColors.red;
        label = 'Failed';
        break;
      default:
        bg = AppColors.line;
        fg = AppColors.navy;
        dot = AppColors.slate;
        label = d.status;
    }
    return Tooltip(
      message: d.error ?? '${d.to} · ${d.status}',
      child: AnimatedSwitcher(
        duration: duration,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(anim), child: child),
        ),
        child: AnimatedContainer(
          key: ValueKey(label),
          duration: duration,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final Widget? trailing;
  const _InfoRow({
    required this.icon,
    required this.text,
    this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color ?? AppColors.slate),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 14, color: color ?? AppColors.navy)),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.receipt_long, size: 48, color: AppColors.field),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
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
