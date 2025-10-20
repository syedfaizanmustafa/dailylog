import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
              final role = userData['role'] as String? ?? 'user';

              if (role == 'admin') {
                return '/admin';
              }
            }
            return '/home';
          } catch (e) {
            print('Error getting user role from Firestore: $e');
            // If Firestore fails, default to home screen
            return '/home';
          }
        }

        return null;
      } catch (e) {
        print('Error in router redirect: $e');
        // If there's an error, redirect to login
        return '/';
      }
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
      GoRoute(
        path: '/new-entry',
        builder: (context, state) => const NewEntryScreen(),
      ),
      GoRoute(
        path: '/customer',
        builder: (context, state) => const CustomerScreen(),
      ),
      GoRoute(
        path: '/submitted',
        builder: (context, state) => const SubmittedScreen(),
      ),
      GoRoute(
        path: '/view-entry/:entryId',
        builder:
            (context, state) =>
                ViewEntryScreen(entryId: state.pathParameters['entryId']!),
      ),
      GoRoute(path: '/admin', builder: (context, state) => const AdminScreen()),
      GoRoute(
        path: '/admin/users',
        builder: (context, state) => const UserManagementScreen(),
      ),
      GoRoute(
        path: '/admin/logs',
        builder: (context, state) => const LogSheetsScreen(),
      ),
      GoRoute(
        path: '/admin/locations',
        builder: (context, state) => const LocationsScreen(),
      ),
    ],
  );
});
