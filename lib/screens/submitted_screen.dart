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

        // Calculate total amount and section breakdowns from sheets data
        double totalAmount = 0.0;
        double aluminiumTotal = 0.0;
        double glassTotal = 0.0;
        double petePlasticTotal = 0.0;
        double otherCommoditiesTotal = 0.0;
        
        for (final sheet in sheets.values) {
          final sheetData = sheet['data'] as Map<String, dynamic>?;
          if (sheetData != null) {
            final values = sheetData['values'] as List<dynamic>? ?? [];
            // Calculate section totals from TOTAL PAID columns
            for (int i = 0; i < values.length; i++) {
              final row = i ~/ 21;
              final col = i % 21;
              final value = values[i].toString();
              
              if (value.isNotEmpty) {
                try {
                  final numValue = double.parse(value);
                  
                  if (col == 4) {
                    // Aluminium Total Paid
                    aluminiumTotal += numValue;
                    totalAmount += numValue;
                  } else if (col == 9) {
                    // Glass Total Paid
                    glassTotal += numValue;
                    totalAmount += numValue;
                  } else if (col == 14) {
                    // Pete Plastic Total Paid
                    petePlasticTotal += numValue;
                    totalAmount += numValue;
                  } else if (col == 19) {
                    // Other Commodities Total Paid
                    otherCommoditiesTotal += numValue;
                    totalAmount += numValue;
                  }
                } catch (e) {
                  // Skip invalid numbers
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
          'aluminiumTotal': aluminiumTotal,
          'glassTotal': glassTotal,
          'petePlasticTotal': petePlasticTotal,
          'otherCommoditiesTotal': otherCommoditiesTotal,
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

  Widget _buildSectionItem(String label, double amount, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[600],
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '\$${amount.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
            fontSize: 12,
          ),
        ),
      ],
    );
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
                                child: Column(
                                  children: [
                                    // Header row with date, reference, sheets, email, and total
                                    Row(
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
                                            '\$${(entry['amount'] as double?)?.toStringAsFixed(2) ?? '0.00'}',
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
                                    const SizedBox(height: 12),
                                    // Section breakdown row
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.grey[50],
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.grey[200]!),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Total Paid Breakdown',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  color: Colors.grey[700],
                                                ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: _buildSectionItem(
                                                  'Aluminium',
                                                  (entry['aluminiumTotal'] as double?) ?? 0.0,
                                                  Colors.blue[600]!,
                                                ),
                                              ),
                                              Expanded(
                                                child: _buildSectionItem(
                                                  'Glass',
                                                  (entry['glassTotal'] as double?) ?? 0.0,
                                                  Colors.green[600]!,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: _buildSectionItem(
                                                  'Pete Plastic',
                                                  (entry['petePlasticTotal'] as double?) ?? 0.0,
                                                  Colors.orange[600]!,
                                                ),
                                              ),
                                              Expanded(
                                                child: _buildSectionItem(
                                                  'Other Commodities',
                                                  (entry['otherCommoditiesTotal'] as double?) ?? 0.0,
                                                  Colors.purple[600]!,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
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
