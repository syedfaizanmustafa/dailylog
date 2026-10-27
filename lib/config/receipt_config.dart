/// Configuration for customer receipts (numbering, hosted links, SMS copy).
///
/// Keep this file free of secrets. Twilio credentials live only in
/// Cloud Functions secrets (see `functions/README.md`).
class ReceiptConfig {
  ReceiptConfig._();

  /// Public base URL that serves a receipt PDF for a given token.
  /// Backed by the `receipt` Cloud Function via a Firebase Hosting rewrite
  /// (`/r/**`). Change this if the site moves to a custom domain.
  static const String receiptBaseUrl = 'https://camachorecycling.us/r';

  /// Business name printed on receipts and used in the SMS body.
  static const String businessName = 'Camacho Recycling';

  /// Firestore document that holds the sequential receipt counter.
  /// Structure: `counters/receipts { next: <int> }`.
  static const String counterCollection = 'counters';
  static const String counterDocId = 'receipts';

  /// If the counter document does not exist yet, numbering starts here.
  /// Set `counters/receipts.next` in the Firebase console to continue from
  /// the last paper receipt number (e.g. 193).
  static const int firstReceiptNumber = 1;

  /// Storage folder for generated receipt PDFs.
  static const String storageFolder = 'receipts';

  /// Consent copy shown above the phone field. This wording was registered
  /// with the A2P 10DLC campaign (verbal opt-in at the counter) — keep it in
  /// sync with Twilio Trust Hub if it ever changes.
  static const String smsConsentText =
      'By providing your number you agree to receive a one-time receipt text '
      'from $businessName for this transaction. Msg & data rates may apply. '
      'Reply STOP to opt out, HELP for help.';

  static String receiptUrl(String token) => '$receiptBaseUrl/$token';

  /// A customer paid this much or more on one row: staff can't finish the
  /// signature, issue the receipt or submit the sheet without an I.D. #.
  static const double idRequiredAt = 100.0;

  static bool idRequiredFor(double total) => total >= idRequiredAt - 0.005;

  /// "$100" for messages.
  static String get idRequiredAtLabel => '\$${idRequiredAt.toStringAsFixed(0)}';

  /// A typed I.D. # is accepted when it has at least 4 letters or digits.
  static bool isValidCustomerId(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length >= 4;

  /// Upper-case, trimmed, single spaces.
  static String cleanCustomerId(String s) =>
      s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
}
