import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../services/sheet_outbox.dart';

/// Sheets submitted on this tablet in the last 30 days, with their upload
/// status. Opened from the Sync button on the home screen; opening it also
/// uploads anything still waiting. Shows only date, location and status
/// (no money or customer counts).
class TabletSheetsScreen extends ConsumerStatefulWidget {
  const TabletSheetsScreen({super.key});

  @override
  ConsumerState<TabletSheetsScreen> createState() => _TabletSheetsScreenState();
}

class _TabletSheetsScreenState extends ConsumerState<TabletSheetsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAll(quiet: true));
  }

  Future<void> _syncAll({bool quiet = false}) async {
    final outbox = SheetOutbox.instance;
    if (outbox.waitingCount == 0 && quiet) return;
    final left = await outbox.syncAll();
    if (!mounted || (quiet && left == 0)) return;
    showAppSnack(
      context,
      left == 0
          ? 'All sheets are uploaded'
          : '$left ${left == 1 ? 'sheet is' : 'sheets are'} still waiting. Check the connection and try again.',
      error: left > 0,
    );
  }

  Future<void> _uploadOne(OutboxItem item) async {
    HapticFeedback.selectionClick();
    final ok = await SheetOutbox.instance.upload(item.localId);
    if (!mounted) return;
    showAppSnack(context, ok ? 'Uploaded' : 'Not uploaded yet. Check the connection and try again.', error: !ok);
  }

  @override
  Widget build(BuildContext context) {
    final outbox = ref.watch(sheetOutboxProvider);
    final items = outbox.items;
    final waiting = outbox.waitingCount;
    final hPad = MediaQuery.sizeOf(context).width >= 760 ? 28.0 : 16.0;

    return Scaffold(
      backgroundColor: AppColors.mist,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back, color: AppColors.navy),
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Sheets on this tablet',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.navy)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.forest),
              onPressed: outbox.syncing ? null : () => _syncAll(),
              icon: outbox.syncing
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync_rounded, size: 20),
              label: Text(outbox.syncing ? 'Syncing…' : 'Sync all'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _syncAll(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 32),
          children: [
            _Banner(waiting: waiting),
            const SizedBox(height: 14),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    'No sheets submitted on this tablet in the last 30 days.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.slate, fontSize: 15),
                  ),
                ),
              )
            else
              for (final item in items) ...[
                _SheetRow(
                  item: item,
                  status: outbox.statusOf(item),
                  onUpload: () => _uploadOne(item),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final int waiting;
  const _Banner({required this.waiting});

  @override
  Widget build(BuildContext context) {
    final ok = waiting == 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ok ? AppColors.greenTint : AppColors.amberSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ok ? AppColors.green.withValues(alpha: 0.35) : AppColors.amberLine),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.cloud_done_rounded : Icons.cloud_upload_rounded,
              color: ok ? AppColors.greenText : AppColors.amberText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ok
                  ? 'Everything submitted on this tablet is uploaded. Sheets stay here for 30 days.'
                  : '$waiting ${waiting == 1 ? 'sheet is' : 'sheets are'} saved on this tablet but not uploaded yet. '
                      'They upload automatically when the connection is back, or tap Sync all.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                color: ok ? AppColors.greenText : AppColors.amberText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final OutboxItem item;
  final OutboxStatus status;
  final VoidCallback onUpload;
  const _SheetRow({required this.item, required this.status, required this.onUpload});

  @override
  Widget build(BuildContext context) {
    final date = item.entryDate;
    final title = date == null ? 'Sheet' : DateFormat('EEE, MMM d').format(date);
    final n = item.sheetCount;
    final waiting = status == OutboxStatus.waiting;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: waiting ? AppColors.amberLine : AppColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.sageLight, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.description_outlined, color: AppColors.forest, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.navy)),
                const SizedBox(height: 2),
                Text(
                  '${item.locationName} · $n ${n == 1 ? 'sheet' : 'sheets'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AppColors.slate),
                ),
                if (waiting && item.lastError != null) ...[
                  const SizedBox(height: 2),
                  Text(item.lastError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.amberText)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusTag(status: status, onUpload: onUpload),
        ],
      ),
    );
  }
}

/// Uploaded ✓ (green) · Uploading… · Upload (amber, tap to retry).
class _StatusTag extends StatelessWidget {
  final OutboxStatus status;
  final VoidCallback onUpload;
  const _StatusTag({required this.status, required this.onUpload});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case OutboxStatus.uploaded:
        return _chip(
          bg: AppColors.greenTint,
          fg: AppColors.greenText,
          icon: const Icon(Icons.cloud_done_rounded, size: 16, color: AppColors.greenText),
          label: 'Uploaded',
        );
      case OutboxStatus.uploading:
        return _chip(
          bg: AppColors.blueTint,
          fg: AppColors.blueText,
          icon: const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.blueText)),
          label: 'Uploading…',
        );
      case OutboxStatus.waiting:
        return Semantics(
          button: true,
          label: 'Not uploaded. Tap to upload',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onUpload,
            child: _chip(
              bg: AppColors.amberSoft,
              fg: AppColors.amberText,
              border: AppColors.amberLine,
              icon: const Icon(Icons.cloud_upload_rounded, size: 16, color: AppColors.amberText),
              label: 'Upload',
            ),
          ),
        );
    }
  }

  Widget _chip({required Color bg, required Color fg, required Widget icon, required String label, Color? border}) =>
      Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: border == null ? null : Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
          ],
        ),
      );
}
