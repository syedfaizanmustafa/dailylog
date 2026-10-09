import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../controllers/auth_controller.dart';
import '../screens/login_screen.dart';
import '../screens/register_screen.dart';
import '../screens/forgot_password_screen.dart';
import '../screens/home_screen.dart';
import '../screens/new_entry_screen.dart';
import '../screens/customer_screen.dart';
import '../screens/submitted_screen.dart';
import '../screens/view_entry_screen.dart';
import '../screens/admin_screen.dart';
import '../screens/user_management_screen.dart';
import '../screens/log_sheets_screen.dart';
import '../screens/locations_screen.dart';
import '../screens/receipt_screen.dart';
import '../screens/admin_receipts_screen.dart';
import '../screens/admin_customers_screen.dart';
import '../models/receipt.dart';

/// Fade-through: the new page fades in while rising 16 px. Used for the
/// redesigned screens; the New Entry / View Entry sheet keeps the default
/// platform transition.
CustomTransitionPage<void> _fadePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Horizontal slide along the counter flow (signature → receipt).
CustomTransitionPage<void> _slidePage(GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.of(context).disableAnimations) return child;
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authControllerProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) async {
      try {
        final isAuthenticated = authState.value != null;
        final isProtectedRoute =
            state.matchedLocation != '/' &&
            state.matchedLocation != '/register' &&
            state.matchedLocation != '/forgot-password';

        if (!isAuthenticated && isProtectedRoute) {
          return '/';
        }

        // Only redirect from login screen if authenticated
        if (isAuthenticated && state.matchedLocation == '/') {
          try {
            // Get user role from Firestore
            final userDoc =
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(authState.value!.uid)
                    .get();

            if (userDoc.exists) {
              final userData = userDoc.data() as Map<String, dynamic>;
              // Disabled staff (Admin › Staff) are signed straight back out.
              if (userData['disabled'] == true) {
                await FirebaseAuth.instance.signOut();
                return null;
              }
              final role = userData['role'] as String? ?? 'user';

              if (role == 'admin') {
                return '/admin';
              }
            }
            return '/home';
          } catch (e) {
            debugPrint('Error getting user role from Firestore: $e');
            // If Firestore fails, default to home screen
            return '/home';
          }
        }

        return null;
      } catch (e) {
        debugPrint('Error in router redirect: $e');
        // If there's an error, redirect to login
        return '/';
      }
    },
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => _fadePage(state, const LoginScreen()),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        pageBuilder:
            (context, state) => _fadePage(state, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: '/home',
        pageBuilder: (context, state) => _fadePage(state, const HomeScreen()),
      ),
      GoRoute(
        path: '/new-entry',
        builder: (context, state) => const NewEntryScreen(),
      ),
      GoRoute(
        path: '/customer',
        pageBuilder: (context, state) => _slidePage(state, const CustomerScreen()),
      ),
      GoRoute(
        path: '/submitted',
        pageBuilder: (context, state) => _fadePage(state, const SubmittedScreen()),
      ),
      GoRoute(
        path: '/view-entry/:entryId',
        builder:
            (context, state) =>
                ViewEntryScreen(
                  entryId: state.pathParameters['entryId']!,
                  initialSheet: int.tryParse(state.uri.queryParameters['sheet'] ?? ''),
                  initialRow: int.tryParse(state.uri.queryParameters['row'] ?? ''),
                ),
      ),
      GoRoute(
        path: '/receipt',
        pageBuilder: (context, state) {
          final extra = state.extra is Map
              ? Map<String, dynamic>.from(state.extra as Map)
              : <String, dynamic>{};
          return _slidePage(
            state,
            ReceiptScreen(
              draft: extra['draft'] as ReceiptData?,
              receiptId: extra['receiptId'] as String?,
              onIssued: extra['onIssued'] as void Function(ReceiptData)?,
            ),
          );
        },
      ),
      GoRoute(
        path: '/admin',
        pageBuilder: (context, state) => _fadePage(state, const AdminScreen()),
      ),
      GoRoute(
        path: '/admin/users',
        pageBuilder:
            (context, state) => _fadePage(state, const UserManagementScreen()),
      ),
      GoRoute(
        path: '/admin/logs',
        pageBuilder: (context, state) => _fadePage(
          state,
          LogSheetsScreen(
            initialFilter: state.uri.queryParameters['filter'] ?? 'all',
          ),
        ),
      ),
      GoRoute(
        path: '/admin/receipts',
        pageBuilder: (context, state) => _fadePage(
          state,
          AdminReceiptsScreen(
            initialFilter: state.uri.queryParameters['filter'] ?? 'all',
          ),
        ),
      ),
      GoRoute(
        path: '/admin/customers',
        pageBuilder: (context, state) => _fadePage(state, const AdminCustomersScreen()),
      ),
      GoRoute(
        path: '/admin/locations',
        pageBuilder: (context, state) => _fadePage(state, const LocationsScreen()),
      ),
    ],
  );
});
