/* eslint-disable no-console */
/**
 * Camacho Recycling — customer receipt delivery.
 *
 *  • onReceiptWritten  Firestore trigger: when a receipt's sms/email status is
 *                      set to "pending" by the app, send it (Twilio / SendGrid).
 *  • twilioStatus      Twilio status webhook → updates sms.status live.
 *  • receipt           Public GET /r/{token} → streams the receipt PDF.
 *
 * Secrets (set once with `firebase functions:secrets:set NAME`):
 *   TWILIO_ACCOUNT_SID, TWILIO_API_KEY, TWILIO_API_SECRET,
 *   TWILIO_MESSAGING_SERVICE_SID, TWILIO_AUTH_TOKEN (webhook validation),
 *
 * Email is optional: to enable it later, run
 *   firebase functions:secrets:set SENDGRID_API_KEY
 *   firebase functions:secrets:set SENDGRID_FROM     (e.g. receipts@camachorecycling.us)
 * and set ENABLE_EMAIL=true in functions/.env (or `firebase functions:config`).
 */

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();
setGlobalOptions({ region: "us-central1", maxInstances: 10 });

const db = admin.firestore();
const bucket = admin.storage().bucket();

// ── Config ────────────────────────────────────────────────────────────────
const TWILIO_ACCOUNT_SID = defineSecret("TWILIO_ACCOUNT_SID");
const TWILIO_API_KEY = defineSecret("TWILIO_API_KEY");
const TWILIO_API_SECRET = defineSecret("TWILIO_API_SECRET");
const TWILIO_MESSAGING_SERVICE_SID = defineSecret("TWILIO_MESSAGING_SERVICE_SID");
const TWILIO_AUTH_TOKEN = defineSecret("TWILIO_AUTH_TOKEN");
// Email (SendGrid) is opt-in. When ENABLE_EMAIL is not "true", the email
// channel is reported as "failed · not configured" and no secrets are required.
const ENABLE_EMAIL = process.env.ENABLE_EMAIL === "true";
const SENDGRID_API_KEY = ENABLE_EMAIL ? defineSecret("SENDGRID_API_KEY") : null;
const SENDGRID_FROM = ENABLE_EMAIL ? defineSecret("SENDGRID_FROM") : null;

// Public base of the hosted site (Firebase Hosting). Receipt links are
// `${RECEIPT_BASE_URL}/r/{token}`; the Twilio status webhook is
// `${RECEIPT_BASE_URL}/twilio/status`.
const RECEIPT_BASE_URL = defineString("RECEIPT_BASE_URL", {
  default: "https://camachorecycling.us",
});
const BUSINESS_NAME = defineString("BUSINESS_NAME", {
  default: "Camacho Recycling",
});

const receiptUrl = (token) => `${RECEIPT_BASE_URL.value()}/r/${token}`;

// ── Helpers ───────────────────────────────────────────────────────────────

function nowIso() {
  return new Date().toISOString();
}

// Server time on every receipt write so the app's delta sync picks the change
// up (see lib/services/data_sync.dart).
function syncedAt() {
  return admin.firestore.FieldValue.serverTimestamp();
}

/**
 * Atomically moves `receipts/{id}.{channel}.status` from "pending" to
 * "sending". Returns the receipt data if this invocation won the claim,
 * or null if another invocation already took it (prevents double sends).
 */
async function claim(ref, channel) {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return null;
    const data = snap.data();
    const d = data[channel] || {};
    if (d.status !== "pending") return null;
    tx.update(ref, {
      [`${channel}.status`]: "sending",
      [`${channel}.updatedAt`]: nowIso(),
      syncedAt: syncedAt(),
    });
    return data;
  });
}

async function setStatus(ref, channel, fields) {
  const update = { [`${channel}.updatedAt`]: nowIso(), syncedAt: syncedAt() };
  for (const [k, v] of Object.entries(fields)) {
    update[`${channel}.${k}`] = v;
  }
  await ref.update(update);
}

function smsBody(receipt) {
  // Keep in sync with the sample messages registered on the A2P 10DLC campaign.
  const total = Number(receipt.grandTotal || 0).toFixed(2);
  const d = receipt.date ? new Date(receipt.date) : new Date();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const date = `${mm}/${dd}/${d.getFullYear()}`;
  return (
    `${BUSINESS_NAME.value()}: Thank you! Your receipt #${receipt.receiptCode || receipt.receiptNumber} ` +
    `for ${date} is ready. Total paid: $${total}. ` +
    `View/download: ${receiptUrl(receipt.token)}. ` +
    `Reply STOP to opt out, HELP for help.`
  );
}

// ── Firestore trigger ─────────────────────────────────────────────────────

exports.onReceiptWritten = onDocumentWritten(
  {
    document: "receipts/{receiptId}",
    secrets: [
      TWILIO_ACCOUNT_SID,
      TWILIO_API_KEY,
      TWILIO_API_SECRET,
      TWILIO_MESSAGING_SERVICE_SID,
      ...(ENABLE_EMAIL ? [SENDGRID_API_KEY, SENDGRID_FROM] : []),
    ],
  },
  async (event) => {
    const after = event.data?.after;
    if (!after || !after.exists) return;
    const data = after.data();
    const ref = after.ref;

    const jobs = [];
    if (data.sms?.status === "pending") jobs.push(sendSms(ref));
    if (data.email?.status === "pending") jobs.push(sendEmail(ref));
    await Promise.all(jobs);
  },
);

async function sendSms(ref) {
  const receipt = await claim(ref, "sms");
  if (!receipt) return;

  try {
    const twilio = require("twilio");
    const client = twilio(TWILIO_API_KEY.value(), TWILIO_API_SECRET.value(), {
      accountSid: TWILIO_ACCOUNT_SID.value(),
    });

    const msg = await client.messages.create({
      to: receipt.sms.to,
      messagingServiceSid: TWILIO_MESSAGING_SERVICE_SID.value(),
      body: smsBody(receipt),
      statusCallback: `${RECEIPT_BASE_URL.value()}/twilio/status`,
    });

    await setStatus(ref, "sms", {
      status: msg.status || "queued", // queued | accepted | sending …
      sid: msg.sid,
      error: null,
      sentAt: nowIso(),
    });
    console.log(`SMS queued for receipt ${ref.id}: ${msg.sid}`);
  } catch (err) {
    console.error(`SMS failed for receipt ${ref.id}`, err);
    await setStatus(ref, "sms", {
      status: "failed",
      error: `${err.code || ""} ${err.message || err}`.trim(),
    });
  }
}

async function sendEmail(ref) {
  const receipt = await claim(ref, "email");
  if (!receipt) return;

  try {
    if (!ENABLE_EMAIL) {
      throw new Error("Email receipts are not configured yet");
    }
    const apiKey = SENDGRID_API_KEY.value();
    const from = SENDGRID_FROM.value();
    if (!apiKey || !from) {
      throw new Error("SENDGRID_API_KEY / SENDGRID_FROM not configured");
    }
    const sgMail = require("@sendgrid/mail");
    sgMail.setApiKey(apiKey);

    const [pdf] = await bucket.file(receipt.pdfPath).download();
    const total = Number(receipt.grandTotal || 0).toFixed(2);
    const link = receiptUrl(receipt.token);

    await sgMail.send({
      to: receipt.email.to,
      from: { email: from, name: BUSINESS_NAME.value() },
      subject: `${BUSINESS_NAME.value()} receipt #${receipt.receiptCode || receipt.receiptNumber}`,
      text:
        `Thank you, ${receipt.customerName || "customer"}.\n\n` +
        `Receipt #${receipt.receiptCode || receipt.receiptNumber} — total paid $${total}.\n` +
        `Your receipt is attached and also available at ${link}\n`,
      html:
        `<p>Thank you, ${escapeHtml(receipt.customerName || "customer")}.</p>` +
        `<p><strong>Receipt #${receipt.receiptCode || receipt.receiptNumber}</strong> — total paid <strong>$${total}</strong>.</p>` +
        `<p>Your receipt is attached and also available at <a href="${link}">${link}</a>.</p>`,
      attachments: [
        {
          content: pdf.toString("base64"),
          filename: `Receipt_${receipt.receiptCode || receipt.receiptNumber}.pdf`,
          type: "application/pdf",
          disposition: "attachment",
        },
      ],
    });

    await setStatus(ref, "email", {
      status: "sent",
      error: null,
      sentAt: nowIso(),
    });
    console.log(`Email sent for receipt ${ref.id}`);
  } catch (err) {
    console.error(`Email failed for receipt ${ref.id}`, err);
    await setStatus(ref, "email", {
      status: "failed",
      error: `${err.code || ""} ${err.message || err}`.trim(),
    });
  }
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── Twilio status webhook ────────────────────────────────────────────────

exports.twilioStatus = onRequest(
  { secrets: [TWILIO_AUTH_TOKEN], invoker: "public" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("Method not allowed");
      return;
    }

    // Validate the request really came from Twilio (when the token is set).
    const authToken = TWILIO_AUTH_TOKEN.value();
    if (authToken) {
      const twilio = require("twilio");
      const signature = req.get("X-Twilio-Signature") || "";
      const url = `${RECEIPT_BASE_URL.value()}/twilio/status`;
      if (!twilio.validateRequest(authToken, signature, url, req.body)) {
        console.warn("Rejected Twilio webhook with bad signature");
        res.status(403).send("Invalid signature");
        return;
      }
    }

    const sid = req.body.MessageSid;
    const status = req.body.MessageStatus; // queued|sent|delivered|undelivered|failed
    const errorCode = req.body.ErrorCode || null;
    if (!sid || !status) {
      res.status(400).send("Missing MessageSid/MessageStatus");
      return;
    }

    const snap = await db
      .collection("receipts")
      .where("sms.sid", "==", sid)
      .limit(1)
      .get();
    if (!snap.empty) {
      await setStatus(snap.docs[0].ref, "sms", {
        status,
        error: errorCode ? `Twilio error ${errorCode}` : null,
      });
    }
    res.status(204).send("");
  },
);

// ── Public receipt link ──────────────────────────────────────────────────

exports.receipt = onRequest({ cors: false, invoker: "public" }, async (req, res) => {
  // Hosting rewrites "/r/{token}" here; also accept "?t={token}".
  const parts = req.path.split("/").filter(Boolean);
  const token = parts[parts.length - 1] || req.query.t;
  if (!token || !/^[A-Za-z0-9]{8,32}$/.test(String(token))) {
    res.status(404).send(notFoundPage());
    return;
  }

  const snap = await db
    .collection("receipts")
    .where("token", "==", String(token))
    .limit(1)
    .get();
  if (snap.empty) {
    res.status(404).send(notFoundPage());
    return;
  }

  const receipt = snap.docs[0].data();
  try {
    const [pdf] = await bucket.file(receipt.pdfPath).download();
    res.set("Content-Type", "application/pdf");
    res.set(
      "Content-Disposition",
      `inline; filename="Receipt_${receipt.receiptCode || receipt.receiptNumber}.pdf"`,
    );
    res.set("Cache-Control", "private, max-age=300");
    res.set("X-Robots-Tag", "noindex");
    res.status(200).send(pdf);
  } catch (err) {
    console.error(`PDF missing for token ${token}`, err);
    res.status(404).send(notFoundPage());
  }
});

function notFoundPage() {
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Receipt not found</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#edf2f4;color:#2b2d42;
display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:24px}
.card{background:#fff;border-radius:16px;padding:32px;max-width:420px;text-align:center;
box-shadow:0 10px 30px rgba(0,0,0,.08)}h1{font-size:20px;margin:0 0 8px}p{margin:0;color:#555}</style>
</head><body><div class="card"><h1>Receipt not found</h1>
<p>This link may have been typed incorrectly. Please ask the counter to resend your receipt.</p>
</div></body></html>`;
}
