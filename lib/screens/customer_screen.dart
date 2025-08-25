import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:signature/signature.dart';
import 'dart:typed_data';

class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key});

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  final _amountController = TextEditingController();
  late final SignatureController _signatureController;
  Function(Uint8List)? _onSignatureComplete;
  Function(List<Point>)? _onSignaturePointsComplete;

  @override
  void initState() {
    super.initState();
    _signatureController = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    );

    // Extract callback from router extra data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extra = GoRouterState.of(context).extra;
      print('Router extra data: $extra');
      print('Extra data type: ${extra.runtimeType}');

      if (extra is Map<String, dynamic>) {
        print('Extra data keys: ${extra.keys}');
        if (extra.containsKey('onSignatureComplete')) {
          _onSignatureComplete =
              extra['onSignatureComplete'] as Function(Uint8List)?;
          print('Image callback extracted successfully');
        } else {
          print('No onSignatureComplete key found in extra data');
        }

        if (extra.containsKey('onSignaturePointsComplete')) {
          _onSignaturePointsComplete =
              extra['onSignaturePointsComplete'] as Function(List<Point>)?;
          print('Points callback extracted successfully');
        } else {
          print('No onSignaturePointsComplete key found in extra data');
        }
      } else {
        print('Extra data is not a Map<String, dynamic>');
      }
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      appBar: AppBar(
        title: Text(
          'CUSTOMER',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(letterSpacing: 1.2),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/new-entry'),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Signature',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Container(
              height: MediaQuery.of(context).size.height * .6,
              width: MediaQuery.of(context).size.width,
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
              child: Signature(
                controller: _signatureController,
                backgroundColor: Colors.white,
              ),
            ),
            Column(
              children: [
                const SizedBox(height: 12),
                InkWell(
                  onTap: () {
                    _signatureController.clear();
                  },
                  child: const Text('Clear'),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.only(left: 20, right: 20, bottom: 25),
        child: ElevatedButton(
          onPressed: () async {
            print('Submit button pressed');

            if (!_signatureController.isNotEmpty) {
              print('Signature is empty, showing error');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Please provide a signature before submitting'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            print('Signature is not empty, processing...');

            // Get signature points
            final points = _signatureController.points;
            print('Signature points count: ${points.length}');
            print('Points type: ${points.runtimeType}');
            if (points.isNotEmpty) {
              print('First point: ${points.first}');
            }

            // Get signature image as well (for backward compatibility)
            final signatureBytes = await _signatureController.toPngBytes();

            if (signatureBytes == null) {
              print('Failed to convert signature to PNG');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Failed to process signature'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            print(
              'Signature converted successfully, bytes length: ${signatureBytes.length}',
            );

            // Call both callbacks if available
            bool success = false;

            if (_onSignaturePointsComplete != null) {
              print('Calling onSignaturePointsComplete callback');
              _onSignaturePointsComplete!(points);
              success = true;
            }

            if (_onSignatureComplete != null) {
              print('Calling onSignatureComplete callback');
              _onSignatureComplete!(signatureBytes);
              success = true;
            }

            if (success) {
              print('Callbacks completed, navigating back');
              if (mounted) {
                context.pop();
              }
            } else {
              print('No callbacks available');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Error: Signature callbacks not available'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
          child: const Text('SUBMIT'),
        ),
      ),
    );
  }
}
