import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';

class LogSheetsScreen extends ConsumerStatefulWidget {
  const LogSheetsScreen({super.key});

  @override
  ConsumerState<LogSheetsScreen> createState() => _LogSheetsScreenState();
}

class _LogSheetsScreenState extends ConsumerState<LogSheetsScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedFilter = 'all'; // 'all', 'pending', 'approved', 'rejected'
  bool _isLoading = true;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    try {
      final querySnapshot =
          await FirebaseFirestore.instance
              .collection('entries')
              .orderBy('createdAt', descending: true)
              .get();

      final List<Map<String, dynamic>> entries = [];

      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final createdAt = DateTime.parse(data['createdAt']);
        final sheets = data['sheets'] as Map<String, dynamic>? ?? {};
        final sheetCount = sheets.length;
        final email = data['email'] ?? '';
        final userId = data['userId'] ?? '';

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
          'reference': doc.id.substring(0, 8),
          'sheetCount': sheetCount,
          'amount': totalAmount,
          'email': email,
          'userId': userId,
          'type': 'entry',
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

  Future<void> _updateLogStatus(String logId, String newStatus) async {
    try {
      await FirebaseFirestore.instance.collection('logs').doc(logId).update({
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Log status updated successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating log status: $e')),
        );
      }
    }
  }

  Future<void> _deleteLog(String logId) async {
    try {
      await FirebaseFirestore.instance.collection('logs').doc(logId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Log deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting log: $e')));
      }
    }
  }

  Future<void> _deleteEntry(String entryId) async {
    try {
      await FirebaseFirestore.instance
          .collection('entries')
          .doc(entryId)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry deleted successfully')),
        );
        _loadEntries(); // Reload the entries
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting entry: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Log Sheets'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadEntries),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search logs and entries...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon:
                        _searchQuery.isNotEmpty
                            ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                });
                              },
                            )
                            : null,
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value.toLowerCase();
                    });
                  },
                ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('All'),
                        selected: _selectedFilter == 'all',
                        onSelected: (selected) {
                          setState(() {
                            _selectedFilter = 'all';
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Pending'),
                        selected: _selectedFilter == 'pending',
                        onSelected: (selected) {
                          setState(() {
                            _selectedFilter = 'pending';
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Approved'),
                        selected: _selectedFilter == 'approved',
                        onSelected: (selected) {
                          setState(() {
                            _selectedFilter = 'approved';
                          });
                        },
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Rejected'),
                        selected: _selectedFilter == 'rejected',
                        onSelected: (selected) {
                          setState(() {
                            _selectedFilter = 'rejected';
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : Column(
                      children: [
                        // Submitted Entries Section
                        if (_entries.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.assignment, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'Submitted Sheets',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            flex: 1,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: _entries.length,
                              itemBuilder: (context, index) {
                                final entry = _entries[index];
                                final date = entry['date'] as DateTime;
                                final email = entry['email'] as String;

                                // Apply search filter
                                if (_searchQuery.isNotEmpty) {
                                  final searchLower =
                                      _searchQuery.toLowerCase();
                                  if (!email.toLowerCase().contains(
                                        searchLower,
                                      ) &&
                                      !entry['reference']
                                          .toString()
                                          .toLowerCase()
                                          .contains(searchLower)) {
                                    return const SizedBox.shrink();
                                  }
                                }

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor:
                                          Theme.of(context).colorScheme.primary,
                                      child: const Icon(
                                        Icons.assignment,
                                        color: Colors.white,
                                      ),
                                    ),
                                    title: Text(
                                      DateFormat('MMM d, y').format(date),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Reference: ${entry['reference']}',
                                        ),
                                        Text('Email: $email'),
                                        Text(
                                          '${entry['sheetCount']} sheet${entry['sheetCount'] == 1 ? '' : 's'} - \$${entry['amount'].toStringAsFixed(2)}',
                                        ),
                                      ],
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.visibility),
                                          onPressed: () {
                                            context.push(
                                              '/view-entry/${entry['id']}',
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                          ),
                                          onPressed: () {
                                            showDialog(
                                              context: context,
                                              builder:
                                                  (context) => AlertDialog(
                                                    title: const Text(
                                                      'Delete Entry',
                                                    ),
                                                    content: Text(
                                                      'Are you sure you want to delete this entry for ${entry['email']}?',
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed:
                                                            () => Navigator.pop(
                                                              context,
                                                            ),
                                                        child: const Text(
                                                          'Cancel',
                                                        ),
                                                      ),
                                                      TextButton(
                                                        onPressed: () {
                                                          Navigator.pop(
                                                            context,
                                                          );
                                                          _deleteEntry(
                                                            entry['id'],
                                                          );
                                                        },
                                                        child: const Text(
                                                          'Delete',
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],

                        // Logs Section
                        Expanded(
                          flex: 1,
                          child: StreamBuilder<QuerySnapshot>(
                            stream:
                                FirebaseFirestore.instance
                                    .collection('logs')
                                    .orderBy('createdAt', descending: true)
                                    .snapshots(),
                            builder: (context, snapshot) {
                              if (snapshot.hasError) {
                                return Center(
                                  child: Text('Error: ${snapshot.error}'),
                                );
                              }

                              if (snapshot.connectionState ==
                                  ConnectionState.waiting) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }

                              final logs =
                                  snapshot.data!.docs.where((doc) {
                                    final data =
                                        doc.data() as Map<String, dynamic>;
                                    final status =
                                        data['status']?.toString() ?? '';
                                    final customerName =
                                        data['customerName']
                                            ?.toString()
                                            .toLowerCase() ??
                                        '';
                                    final description =
                                        data['description']
                                            ?.toString()
                                            .toLowerCase() ??
                                        '';

                                    // Apply status filter
                                    if (_selectedFilter != 'all' &&
                                        status != _selectedFilter) {
                                      return false;
                                    }

                                    // Apply search filter
                                    return customerName.contains(
                                          _searchQuery,
                                        ) ||
                                        description.contains(_searchQuery);
                                  }).toList();

                              if (logs.isEmpty && _entries.isEmpty) {
                                return const Center(
                                  child: Text('No logs or entries found'),
                                );
                              }

                              if (logs.isEmpty) {
                                return const SizedBox.shrink();
                              }

                              return Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16.0,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.note, size: 20),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Log Entries',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: ListView.builder(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      itemCount: logs.length,
                                      itemBuilder: (context, index) {
                                        final log = logs[index];
                                        final data =
                                            log.data() as Map<String, dynamic>;
                                        final customerName =
                                            data['customerName'] ??
                                            'No customer';
                                        final description =
                                            data['description'] ??
                                            'No description';
                                        final status =
                                            data['status'] ?? 'pending';
                                        final createdAt =
                                            (data['createdAt'] as Timestamp?)
                                                ?.toDate() ??
                                            DateTime.now();
                                        final createdBy =
                                            data['createdBy'] ?? 'Unknown';

                                        return Card(
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 4,
                                          ),
                                          child: ExpansionTile(
                                            leading: CircleAvatar(
                                              backgroundColor: _getStatusColor(
                                                status,
                                              ),
                                              child: Text(
                                                status[0].toUpperCase(),
                                              ),
                                            ),
                                            title: Text(customerName),
                                            subtitle: Text(
                                              'Created by $createdBy on ${DateFormat('MMM d, y').format(createdAt)}',
                                            ),
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.all(
                                                  16.0,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'Description: $description',
                                                    ),
                                                    const SizedBox(height: 16),
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceEvenly,
                                                      children: [
                                                        if (status ==
                                                            'pending') ...[
                                                          ElevatedButton(
                                                            onPressed:
                                                                () =>
                                                                    _updateLogStatus(
                                                                      log.id,
                                                                      'approved',
                                                                    ),
                                                            style: ElevatedButton.styleFrom(
                                                              backgroundColor:
                                                                  Colors.green,
                                                            ),
                                                            child: const Text(
                                                              'Approve',
                                                            ),
                                                          ),
                                                          ElevatedButton(
                                                            onPressed:
                                                                () =>
                                                                    _updateLogStatus(
                                                                      log.id,
                                                                      'rejected',
                                                                    ),
                                                            style:
                                                                ElevatedButton.styleFrom(
                                                                  backgroundColor:
                                                                      Colors
                                                                          .red,
                                                                ),
                                                            child: const Text(
                                                              'Reject',
                                                            ),
                                                          ),
                                                        ],
                                                        IconButton(
                                                          icon: const Icon(
                                                            Icons.delete,
                                                            color: Colors.red,
                                                          ),
                                                          onPressed: () {
                                                            showDialog(
                                                              context: context,
                                                              builder:
                                                                  (
                                                                    context,
                                                                  ) => AlertDialog(
                                                                    title: const Text(
                                                                      'Delete Log',
                                                                    ),
                                                                    content: Text(
                                                                      'Are you sure you want to delete this log for $customerName?',
                                                                    ),
                                                                    actions: [
                                                                      TextButton(
                                                                        onPressed:
                                                                            () => Navigator.pop(
                                                                              context,
                                                                            ),
                                                                        child: const Text(
                                                                          'Cancel',
                                                                        ),
                                                                      ),
                                                                      TextButton(
                                                                        onPressed: () {
                                                                          Navigator.pop(
                                                                            context,
                                                                          );
                                                                          _deleteLog(
                                                                            log.id,
                                                                          );
                                                                        },
                                                                        child: const Text(
                                                                          'Delete',
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                            );
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'approved':
        return Colors.green;
      case 'rejected':
        return Colors.red;
      case 'pending':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}
