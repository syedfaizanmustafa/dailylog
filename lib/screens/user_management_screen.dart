import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../config/brand.dart';
import '../widgets/admin_shell.dart';
import '../widgets/floating_confirmation_sheet.dart';

/// Latest sheet per staff member → "last active" + where they work.
class _Activity {
  final DateTime at;
  final String location;
  const _Activity(this.at, this.location);
}

final _staffActivityProvider = FutureProvider<Map<String, _Activity>>((ref) async {
  final snap = await FirebaseFirestore.instance
      .collection('entries')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .get();
  final out = <String, _Activity>{};
  for (final d in snap.docs) {
    final data = d.data();
    final uid = data['userId']?.toString() ?? '';
    if (uid.isEmpty || out.containsKey(uid)) continue;
    final raw = data['createdAt'];
    final at = raw is Timestamp
        ? raw.toDate()
        : DateTime.tryParse(raw?.toString() ?? '');
    if (at == null) continue;
    out[uid] = _Activity(at, data['locationName']?.toString() ?? '');
  }
  return out;
});

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 2) return 'active now';
  if (d.inMinutes < 60) return 'last sheet ${d.inMinutes} min ago';
  if (d.inHours < 24) return 'last sheet ${d.inHours} h ago';
  if (d.inDays == 1) return 'last sheet yesterday';
  if (d.inDays < 7) return 'last sheet ${d.inDays} days ago';
  return 'last sheet ${DateFormat('MMM d').format(t)}';
}

/// Admin › Staff. Only admins create accounts (self-registration is off).
/// "Disable" replaces "Delete" so a former employee's sheets keep their name.
class UserManagementScreen extends ConsumerStatefulWidget {
  const UserManagementScreen({super.key});

  @override
  ConsumerState<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends ConsumerState<UserManagementScreen> {
  final _searchController = TextEditingController();
  String _search = '';
  final Set<String> _busy = {};
  String? _justAdded;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> get _users =>
      FirebaseFirestore.instance.collection('users');

  Future<void> _setRole(AdminUser u, String role) async {
    if (u.role == role) return;
    setState(() => _busy.add(u.id));
    try {
      await _users.doc(u.id).update({'role': role});
      if (mounted) {
        showAppSnack(context, '${u.displayName} is now ${role == 'admin' ? 'an admin' : 'staff'}');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(u.id));
    }
  }

  Future<void> _setDisabled(AdminUser u, bool disabled) async {
    if (disabled) {
      final ok = await showFloatingConfirmationBottomSheet(
        context: context,
        title: 'Disable ${u.displayName}?',
        message:
            "They won't be able to sign in. Their sheets and receipts stay on file under their name. You can re-enable them any time.",
        confirmLabel: 'Disable',
        cancelLabel: 'Cancel',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => _busy.add(u.id));
    try {
      await _users.doc(u.id).update({
        'disabled': disabled,
        'disabledAt': disabled ? FieldValue.serverTimestamp() : null,
      });
      if (mounted) {
        showAppSnack(context, disabled ? '${u.displayName} disabled' : '${u.displayName} re-enabled');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(u.id));
    }
  }

  Future<void> _remove(AdminUser u) async {
    final ok = await showFloatingConfirmationBottomSheet(
      context: context,
      title: 'Remove ${u.displayName}?',
      message:
          'Removes their staff record from this list. Their sign-in account is not deleted — keep them disabled instead if you might need them again.',
      confirmLabel: 'Remove',
      cancelLabel: 'Cancel',
    );
    if (!ok || !mounted) return;
    try {
      await _users.doc(u.id).delete();
      if (mounted) showAppSnack(context, '${u.displayName} removed');
    } catch (e) {
      if (mounted) showAppSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _showAddStaff() async {
    final uid = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AddStaffDialog(),
    );
    if (uid != null && mounted) {
      setState(() => _justAdded = uid);
      showAppSnack(context, 'Staff account created');
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _justAdded = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(adminUsersProvider);
    final activity = ref.watch(_staffActivityProvider).valueOrNull ?? const {};
    final me = FirebaseAuth.instance.currentUser?.uid;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final hPad = narrow ? 16.0 : 28.0;

    final all = usersAsync.valueOrNull ?? const <AdminUser>[];
    final users = all.where((u) {
      if (_search.isEmpty) return true;
      return '${u.name} ${u.email}'.toLowerCase().contains(_search);
    }).toList();
    final activeCount = all.where((u) => !u.disabled).length;

    return AdminShell(
      section: AdminSection.staff,
      title: 'Manage staff',
      subtitle: usersAsync.hasValue
          ? '$activeCount active${all.length > activeCount ? ' · ${all.length - activeCount} disabled' : ''}'
          : null,
      actions: [
        AdminSearchField(
          controller: _searchController,
          hint: 'Search name or email',
          width: width < kAdminPhoneWidth ? 220 : (narrow ? 200 : 260),
          onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
        ),
        FilledButton.icon(
          onPressed: _showAddStaff,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.forest,
            minimumSize: const Size(0, 44),
          ),
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
          label: const Text('Add staff'),
        ),
      ],
      child: usersAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.forest),
        ),
        error: (e, _) => Center(child: Text(friendlyError(e))),
        data: (_) => ListView(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: AppColors.blueTint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: AppColors.blueText),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Only admins create accounts. Disabling someone keeps their sheets and receipts under their name.',
                      style: TextStyle(fontSize: 13, color: AppColors.blueText),
                    ),
                  ),
                ],
              ),
            ),
            if (users.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(
                  child: Text('No staff match', style: TextStyle(color: AppColors.slate)),
                ),
              ),
            for (var i = 0; i < users.length; i++)
              Entrance(
                delay: Duration(milliseconds: i < 12 ? 30 * i : 0),
                dy: 8,
                child: _StaffRow(
                  user: users[i],
                  activity: activity[users[i].id],
                  isMe: users[i].id == me,
                  busy: _busy.contains(users[i].id),
                  highlight: users[i].id == _justAdded,
                  compact: narrow,
                  phone: width < kAdminPhoneWidth,
                  onRole: (r) => _setRole(users[i], r),
                  onDisable: (v) => _setDisabled(users[i], v),
                  onRemove: () => _remove(users[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  final AdminUser user;
  final _Activity? activity;
  final bool isMe;
  final bool busy;
  final bool highlight;
  final bool compact;
  final bool phone;
  final ValueChanged<String> onRole;
  final ValueChanged<bool> onDisable;
  final VoidCallback onRemove;

  const _StaffRow({
    required this.user,
    required this.activity,
    required this.isMe,
    required this.busy,
    required this.highlight,
    required this.compact,
    this.phone = false,
    required this.onRole,
    required this.onDisable,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = user.disabled;
    final avatarBg = disabled
        ? AppColors.line
        : user.isAdmin
            ? AppColors.purpleTint
            : AppColors.blueTint;
    final avatarFg = disabled
        ? AppColors.slate
        : user.isAdmin
            ? AppColors.purpleText
            : AppColors.blueText;

    final detail = disabled
        ? 'Disabled · history kept'
        : [
            if (user.email.isNotEmpty && !compact) user.email,
            if (activity != null)
              [
                if (activity!.location.isNotEmpty) activity!.location,
                _ago(activity!.at),
              ].join(' · ')
            else
              'no sheets yet',
          ].join(' · ');

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (disabled) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: () => onDisable(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.greenText,
              side: const BorderSide(color: AppColors.green),
              minimumSize: const Size(0, 40),
            ),
            child: const Text('Re-enable'),
          ),
          IconButton(
            tooltip: 'Remove from list',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
          ),
        ],
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoleToggle(
            role: user.isAdmin ? 'admin' : 'user',
            enabled: !isMe,
            onChanged: onRole,
          ),
          if (isMe)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(width: 40, child: Center(child: Text('You', style: TextStyle(color: AppColors.slate, fontSize: 12)))),
            )
          else
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz_rounded, color: AppColors.slate),
              onSelected: (v) {
                if (v == 'disable') onDisable(true);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'disable',
                  child: Text('Disable sign-in', style: TextStyle(color: AppColors.red)),
                ),
              ],
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: highlight ? AppColors.greenTint : Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Opacity(
          opacity: disabled ? 0.7 : 1,
          child: _layout(
            avatar: CircleAvatar(
                radius: 22,
                backgroundColor: avatarBg,
                child: Text(
                  user.initials,
                  style: TextStyle(color: avatarFg, fontWeight: FontWeight.w700),
                ),
              ),
            info: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.navy,
                              decoration: disabled ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                        if (highlight) ...[
                          const SizedBox(width: 8),
                          const StatusPill(
                            label: 'Just added',
                            bg: AppColors.green,
                            fg: Colors.white,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: phone ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.slate),
                    ),
                  ],
                ),
            trailing: trailing,
          ),
        ),
      ),
    );
  }

  /// Tablet: one row. Phone: controls drop to a second line under the name.
  Widget _layout({
    required Widget avatar,
    required Widget info,
    required Widget trailing,
  }) {
    if (!phone) {
      return Row(
        children: [
          avatar,
          const SizedBox(width: 14),
          Expanded(child: info),
          const SizedBox(width: 10),
          trailing,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            avatar,
            const SizedBox(width: 14),
            Expanded(child: info),
          ],
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(left: 58),
          child: Align(alignment: Alignment.centerLeft, child: trailing),
        ),
      ],
    );
  }
}

/// Animated two-way Admin / Staff switch.
class _RoleToggle extends StatelessWidget {
  final String role;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const _RoleToggle({required this.role, required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const w = 76.0;
    final isAdmin = role == 'admin';
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        width: w * 2 + 8,
        height: 40,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.mist,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: isAdmin ? Alignment.centerLeft : Alignment.centerRight,
              child: Container(
                width: w,
                decoration: BoxDecoration(
                  color: isAdmin ? AppColors.purple : AppColors.navy,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            Row(
              children: [
                for (final (value, label) in const [('admin', 'Admin'), ('user', 'Staff')])
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: enabled ? () => onChanged(value) : null,
                    child: SizedBox(
                      width: w,
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: role == value ? Colors.white : AppColors.navy,
                          ),
                          child: Text(label),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add staff
// ─────────────────────────────────────────────────────────────────────────────

class _AddStaffDialog extends StatefulWidget {
  const _AddStaffDialog();

  @override
  State<_AddStaffDialog> createState() => _AddStaffDialogState();
}

class _AddStaffDialogState extends State<_AddStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String _role = 'user';
  bool _sendLink = true;
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Creates the sign-in account on a *secondary* Firebase app so the admin
  /// stays signed in (creating a user on the main app would switch the iPad
  /// to the new account).
  Future<String> _createAccount() async {
    FirebaseApp app;
    try {
      app = Firebase.app('staffCreator');
    } catch (_) {
      app = await Firebase.initializeApp(
        name: 'staffCreator',
        options: Firebase.app().options,
      );
    }
    final auth = FirebaseAuth.instanceFor(app: app);
    final email = _email.text.trim();
    final cred = await auth.createUserWithEmailAndPassword(
      email: email,
      password: _password.text,
    );
    final uid = cred.user!.uid;
    try {
      // Written as the new user, which the Firestore rules allow.
      await FirebaseFirestore.instanceFor(app: app).collection('users').doc(uid).set({
        'name': _name.text.trim(),
        'email': email,
        'role': _role,
        'disabled': false,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': FirebaseAuth.instance.currentUser?.uid,
      });
      if (_sendLink) {
        await auth.sendPasswordResetEmail(email: email);
      }
    } finally {
      await auth.signOut();
    }
    return uid;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final uid = await _createAccount();
      if (mounted) Navigator.of(context).pop(uid);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (e.code) {
          'email-already-in-use' => 'That email already has an account.',
          'invalid-email' => "That email address doesn't look right.",
          'weak-password' => 'Use a password with at least 6 characters.',
          _ => e.message ?? 'Could not create the account.',
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = friendlyError(e);
      });
    }
  }

  InputDecoration _dec(String label, {Widget? suffix, String? helper}) => InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.field),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.navy, width: 2),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isAdminPhone(context) ? 16 : 40,
        vertical: 24,
      ),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Add staff',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.navy),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'They sign in on any iPad with this email and password.',
                    style: TextStyle(color: AppColors.slate),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('Full name'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: _dec('Email'),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return 'Enter an email';
                      if (!t.contains('@') || !t.contains('.')) return 'Enter a valid email';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autocorrect: false,
                    decoration: _dec(
                      'Temporary password',
                      helper: 'At least 6 characters',
                      suffix: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Use at least 6 characters' : null,
                  ),
                  const SizedBox(height: 16),
                  const Text('Role', style: TextStyle(fontSize: 13, color: AppColors.slate)),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _RoleToggle(
                      role: _role,
                      enabled: !_saving,
                      onChanged: (r) => setState(() => _role = r),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _sendLink,
                    activeColor: AppColors.green,
                    onChanged: _saving ? null : (v) => setState(() => _sendLink = v),
                    title: const Text('Email them a link to set their own password',
                        style: TextStyle(fontSize: 14)),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: _error == null
                        ? const SizedBox.shrink()
                        : Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.redTint,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(_error!, style: const TextStyle(color: AppColors.redText)),
                          ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.forest,
                            minimumSize: const Size(0, 50),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Create account'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
