import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../controllers/app_controller.dart';

class LogSheetsScreen extends ConsumerStatefulWidget {
  const LogSheetsScreen({super.key});

  @override
  ConsumerState<LogSheetsScreen> createState() => _LogSheetsScreenState();
}

class _LogSheetsScreenState extends ConsumerState<LogSheetsScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedFilter = 'all'; // 'all', 'pending', 'approved'
  bool _isLoading = true;
  List<Map<String, dynamic>> _entries = [];
  String? _selectedLocationId;
  final Set<String> _approvingEntries = {};

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
            for (int i = 0; i < values.length; i++) {
              final col = i % 21;
              final value = values[i].toString();
              if (value.isEmpty) continue;
              try {
                final numValue = double.parse(value);
                if (col == 4) {
                  aluminiumTotal += numValue; totalAmount += numValue;
                } else if (col == 9) {
                  glassTotal += numValue; totalAmount += numValue;
                } else if (col == 14) {
                  petePlasticTotal += numValue; totalAmount += numValue;
                } else if (col == 19) {
                  otherCommoditiesTotal += numValue; totalAmount += numValue;
                }
              } catch (_) {}
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
          'aluminiumTotal': aluminiumTotal,
          'glassTotal': glassTotal,
          'petePlasticTotal': petePlasticTotal,
          'otherCommoditiesTotal': otherCommoditiesTotal,
          'approved': (data['approved'] as bool?) ?? false,
          'locationId': (data['location'] is String && (data['location'] as String).isNotEmpty)
              ? data['location'] as String
              : (data['locationRef'] is DocumentReference
                  ? (data['locationRef'] as DocumentReference).id
                  : null),
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

  Future<void> _approveEntry(String entryId) async {
    setState(() {
      _approvingEntries.add(entryId);
    });
    try {
      await FirebaseFirestore.instance.collection('entries').doc(entryId).update({
        'approved': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry approved')),
        );
        _loadEntries();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error approving entry: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _approvingEntries.remove(entryId);
        });
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
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
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
                      InputChip(
                        label: Text(_selectedLocationId == null
                            ? 'Location'
                            : 'Location: ' + (ref.read(appControllerProvider).locations.firstWhere(
                                  (l) => l.id == _selectedLocationId!,
                                  orElse: () => const AppLocation(id: '', name: 'Unknown', address: '', latitude: 0, longitude: 0),
                                ).name)),
                        onPressed: () {
                          final locations = ref.read(appControllerProvider).locations;
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            builder: (context) {
                              return SafeArea(
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text('Filter by Location', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                          TextButton(
                                            onPressed: () {
                                              setState(() {
                                                _selectedLocationId = null;
                                              });
                                              Navigator.of(context).pop();
                                            },
                                            child: const Text('Clear'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Flexible(
                                        child: ListView.builder(
                                          shrinkWrap: true,
                                          itemCount: locations.length,
                                          itemBuilder: (context, index) {
                                            final loc = locations[index];
                                            final selected = _selectedLocationId == loc.id;
                                            return ListTile(
                                              title: Text(loc.name.isEmpty ? '(Unnamed location)' : loc.name),
                                              subtitle: loc.address.isNotEmpty ? Text(loc.address) : null,
                                              trailing: selected ? const Icon(Icons.check, color: Colors.green) : null,
                                              onTap: () {
                                                setState(() {
                                                  _selectedLocationId = loc.id;
                                                });
                                                Navigator.of(context).pop();
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                        onDeleted: _selectedLocationId == null
                            ? null
                            : () {
                                setState(() {
                                  _selectedLocationId = null;
                                });
                              },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.only(top: 48.0),
                  child: Center(child: CircularProgressIndicator()),
                )
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
                          Consumer(
                            builder: (context, ref, _) {
                              // Filter entries based on current filter state
                              final filteredEntries = _entries.where((entry) {
                                final isApproved = entry['approved'] == true;
                                
                                // Apply approval filter
                                if (_selectedFilter == 'approved' && !isApproved) {
                                  return false;
                                }
                                if (_selectedFilter == 'pending' && isApproved) {
                                  return false;
                                }
                                
                                // Apply location filter
                                if (_selectedLocationId != null) {
                                  final locId = entry['locationId'] as String?;
                                  if (locId == null || locId != _selectedLocationId) {
                                    return false;
                                  }
                                }
                                
                                // Apply search filter
                                if (_searchQuery.isNotEmpty) {
                                  final searchLower = _searchQuery.toLowerCase();
                                  final email = entry['email'] as String;
                                  final reference = entry['reference'].toString();
                                  if (!email.toLowerCase().contains(searchLower) &&
                                      !reference.toLowerCase().contains(searchLower)) {
                                    return false;
                                  }
                                }
                                
                                return true;
                              }).toList();
                              
                              return ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount: filteredEntries.length,
                                itemBuilder: (context, index) {
                                  final entry = filteredEntries[index];
                                  final date = entry['date'] as DateTime;
                                  final email = entry['email'] as String;
                                  final isApproved = entry['approved'] == true;

                                return GestureDetector(
                                  onTap: () => context.push('/view-entry/${entry['id']}'),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(vertical: 6),
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
                                          Row(
                                            children: [
                                              Expanded(
                                                flex: 2,
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      DateFormat('MM/dd/yyyy').format(date),
                                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                        color: Theme.of(context).colorScheme.primary,
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      '${entry['reference']}',
                                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                        color: Theme.of(context).colorScheme.secondary,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Expanded(
                                                flex: 2,
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '${entry['sheetCount']} sheet${entry['sheetCount'] == 1 ? '' : 's'}',
                                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                        color: Theme.of(context).colorScheme.primary,
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      email,
                                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  '\$${(entry['amount'] as double?)?.toStringAsFixed(2) ?? '0.00'}',
                                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                                  textAlign: TextAlign.right,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          // Section breakdown, matching SubmittedScreen style
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
                                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                                          const SizedBox(height: 12),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.end,
                                            children: [
                                              IconButton(
                                                icon: const Icon(Icons.visibility),
                                                tooltip: 'View',
                                                onPressed: () => context.push('/view-entry/${entry['id']}'),
                                              ),
                                              if ((entry['approved'] as bool?) != true)
                                                OutlinedButton.icon(
                                                  onPressed: _approvingEntries.contains(entry['id'] as String) ? null : () => _approveEntry(entry['id'] as String),
                                                  icon: _approvingEntries.contains(entry['id'] as String)
                                                      ? const SizedBox(
                                                          width: 16,
                                                          height: 16,
                                                          child: CircularProgressIndicator(strokeWidth: 2),
                                                        )
                                                      : const Icon(Icons.check, size: 18),
                                                  label: Text(_approvingEntries.contains(entry['id'] as String) ? 'Approving...' : 'Approve'),
                                                ),
                                              IconButton(
                                                icon: const Icon(Icons.delete, color: Colors.red),
                                                tooltip: 'Delete',
                                                onPressed: () {
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('Delete Entry'),
                                                      content: Text('Are you sure you want to delete this entry for ${entry['email']}?'),
                                                      actions: [
                                                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                                                        TextButton(
                                                          onPressed: () {
                                                            Navigator.pop(context);
                                                            _deleteEntry(entry['id']);
                                                          },
                                                          child: const Text('Delete'),
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
                                  ),
                                );
                              },
                            );
                            },
                          ),
                        ],


                      ],
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
}
