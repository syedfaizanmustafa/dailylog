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
}
