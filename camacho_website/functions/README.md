# Receipt delivery backend (Twilio SMS + SendGrid email)

The Flutter app issues receipts (number + PDF in Storage + `receipts/{id}` doc).
When staff tap **Text** or **Email**, the app sets `sms.status` / `email.status`
to `pending`; these functions do the sending and report status back.

| Function | Trigger | What it does |
|---|---|---|
| `onReceiptWritten` | Firestore `receipts/{id}` | Sends SMS (Twilio) / email (SendGrid) for `pending` channels; writes `sid`, `status`, `error` |
| `twilioStatus` | `POST /twilio/status` | Twilio delivery webhook → `sms.status` = sent / delivered / undelivered / failed |
| `receipt` | `GET /r/{token}` | Public link in the SMS / QR: streams the receipt PDF, no login |

## One-time setup

1. **Firebase Blaze plan** — required for functions to call Twilio/SendGrid.
2. **Twilio** — done 2026-10-07 (A2P 10DLC, not toll-free):
   - Business Profile approved · Brand `BN0fbd16f2b5b88cea851b51d7cb2285cb` (Private corporation) approved.
   - Campaign `CMa8b63141070713d89711cfff39f01a56` (Account Notifications, verbal opt-in) — **in review**;
     no SMS will be delivered until it is approved.
   - Messaging Service `MG2828f414cd7d5c925cf660330c20eced` "Camacho Recycling Receipts",
     sender `+1 659 212 6871`.
   - Still needed: create an **API Key** (Account → API keys & tokens) for the secrets below.
3. **Secrets** (run from `camacho_website/`):
   ```bash
   firebase functions:secrets:set TWILIO_ACCOUNT_SID          # ACxxxxxxxx
   firebase functions:secrets:set TWILIO_API_KEY              # SKxxxxxxxx
   firebase functions:secrets:set TWILIO_API_SECRET
   firebase functions:secrets:set TWILIO_MESSAGING_SERVICE_SID # MGxxxxxxxx
   firebase functions:secrets:set TWILIO_AUTH_TOKEN           # for webhook signature check
   ```
   Email is optional. To turn it on later: set the two SendGrid secrets
   (`SENDGRID_API_KEY`, `SENDGRID_FROM`), add `ENABLE_EMAIL=true` to `functions/.env`,
   and redeploy. Until then the Email button reports "not configured".
4. **Deploy**
   ```bash
   cd camacho_website/functions && npm install && cd ..
   firebase deploy --only functions,hosting
   ```
5. **Receipt numbering** — in Firestore create `counters/receipts` with field
   `next` (number) = the next paper receipt number (e.g. `193`) so digital receipts
   continue the paper sequence. If missing, numbering starts at 1.

Sample SMS (matches the registered 10DLC campaign samples):

> Camacho Recycling: Thank you! Your receipt #193 for 10/07/2026 is ready. Total paid: $42.15. View/download: https://camachorecycling.us/r/x7k2q9AbCd3e. Reply STOP to opt out, HELP for help.

## Security rules to add (Firebase console)

Firestore — staff (signed-in users) can create/read receipts and request
delivery; only functions (admin SDK) change delivery results:

```
match /receipts/{id} {
  allow read, create: if request.auth != null;
  allow update: if request.auth != null
    && request.resource.data.diff(resource.data).affectedKeys()
         .hasOnly(['sms', 'email', 'printed', 'customerId', 'entryId', 'sheetNumber']);
}
match /counters/receipts {
  allow read, write: if request.auth != null;
}
```

Storage — PDFs are never public; customers get them through `/r/{token}`:

```
match /receipts/{file} {
  allow read, write: if request.auth != null;
}
```

## Testing before the campaign is approved

- Until the 10DLC campaign is approved, Twilio rejects sends from the number (error
  30034 / "unregistered") and the receipt's chip shows **Failed** with that error — that
  is expected. Everything else can be tested now: issue → PDF preview → print → QR /
  `/r/{token}` link in a browser → email (once SendGrid is set).
- In the app, the status chip on the receipt screen reflects `sms.status` live.
