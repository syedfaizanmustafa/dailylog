import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../controllers/auth_controller.dart';

class SubmittedScreen extends ConsumerStatefulWidget {
  const SubmittedScreen({super.key});

  @override
  ConsumerState<SubmittedScreen> createState() => _SubmittedScreenState();
}

class _SubmittedScreenState extends ConsumerState<SubmittedScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    try {
      final user = ref.read(authControllerProvider).value;
      if (user == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final querySnapshot =
          await FirebaseFirestore.instance
              .collection('entries')
              .where('userId', isEqualTo: user.uid)
              .get();

      final List<Map<String, dynamic>> entries = [];

      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final createdAt = DateTime.parse(data['createdAt']);
        final sheets = data['sheets'] as Map<String, dynamic>? ?? {};
        final sheetCount = sheets.length;

        // Calculate total amount from sheets data
        double totalAmount = 0.0;
        for (final sheet in sheets.values) {
          final sheetData = sheet['data'] as Map<String, dynamic>?;
          if (sheetData != null) {
            final values = sheetData['values'] as List<dynamic>? ?? [];
            // Sum up the paid amounts (columns 4, 9, 14, 19 - TOTAL PAID columns)
            for (int i = 0; i < values.length; i++) {
              final row = i ~/ 21;
              final col = i % 21;
              if (col == 4 || col == 9 || col == 14 || col == 19) {
                // TOTAL PAID columns
                final value = values[i].toString();
                if (value.isNotEmpty) {
                  try {
                    totalAmount += double.parse(value);
                  } catch (e) {
                    // Skip invalid numbers
                  }
                }
              }
            }
          }
        }

        entries.add({
          'id': doc.id,
          'date': createdAt,
          'reference': doc.id.substring(
            0,
            8,
          ), // Use first 8 chars of doc ID as reference
          'sheetCount': sheetCount,
          'amount': totalAmount,
          'email': data['email'] ?? '',
        });
      }

      setState(() {
        _entries = entries;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading entries: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      appBar: AppBar(
        title: Text(
          'SUBMITTED',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(letterSpacing: 1.2),
        ),
        centerTitle: true,
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            tooltip: 'Home',
            onPressed: () => context.go('/home'),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadEntries),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child:
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _entries.isEmpty
                      ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.inbox_outlined,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No submitted entries yet',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Your submitted entries will appear here',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      )
                      : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return GestureDetector(
                            onTap: () {
                              context.go('/view-entry/${entry['id']}');
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            DateFormat(
                                              'MM/dd/yyyy',
                                            ).format(entry['date'] as DateTime),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.copyWith(
                                              color:
                                                  Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${entry['reference']}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.copyWith(
                                              color:
                                                  Theme.of(
                                                    context,
                                                  ).colorScheme.secondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${entry['sheetCount']} sheet${entry['sheetCount'] == 1 ? '' : 's'}',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.copyWith(
                                              color:
                                                  Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${entry['email']}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(fontSize: 12),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '\$${entry['amount'].toStringAsFixed(2)}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
            ),
            Container(
              padding: const EdgeInsets.all(24.0),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: () => context.go('/new-entry'),
                child: const Text('NEW ENTRY'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
