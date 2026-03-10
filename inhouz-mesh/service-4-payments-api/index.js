// =============================================================================
// Service 4: Payments API
// Role: GKE — handles payment processing
// Communicates with:
//   - Service 5 (Notifications, Cloud Run) via internal ALB:
//     http://service-5-notifications-cloudrun.api.internal
// Receives callbacks from:
//   - Service 5 (Notifications, Cloud Run) via internal Nginx:
//     http://service-4-payments-api.k8s.api.internal/notification-callback
// =============================================================================

const express = require("express");
const axios = require("axios");

const app = express();
const PORT = process.env.PORT || 3002;

// Internal ALB DNS — resolves to 10.10.1.50 inside the VPC
const NOTIFICATIONS_CLOUDRUN_URL =
  process.env.NOTIFICATIONS_CLOUDRUN_URL ||
  "http://service-5-notifications-cloudrun.api.internal";

app.use(express.json());

// Health check
app.get("/healthz", (req, res) => {
  res.json({ status: "ok", service: "service-4-payments-api" });
});

// Returns payments and triggers a notification via Service 5 (Cloud Run)
app.get("/payments", async (req, res) => {
  const payments = [
    { id: "PAY-001", amount: 149.99, currency: "USD", status: "completed" },
    { id: "PAY-002", amount: 59.99, currency: "USD", status: "processing" },
  ];

  let notification = null;
  let notificationError = null;

  try {
    // Calling Service 5 (Cloud Run) via Internal ALB
    const response = await axios.post(
      `${NOTIFICATIONS_CLOUDRUN_URL}/notify`,
      {
        event: "payments_fetched",
        payment_ids: payments.map((p) => p.id),
        timestamp: new Date().toISOString(),
      },
      { timeout: 5000 }
    );
    notification = response.data;
  } catch (err) {
    notificationError = `Failed to reach Service 5 (Notifications Cloud Run): ${err.message}`;
  }

  res.json({
    service: "service-4-payments-api",
    location: "GKE",
    payments,
    notification_from_service_5: notification || { error: notificationError },
    communication_path: `GKE Pod → ${NOTIFICATIONS_CLOUDRUN_URL} → Internal ALB → Cloud Run`,
  });
});

// Callback endpoint — Service 5 (Cloud Run) calls this to confirm notification delivery
app.post("/notification-callback", (req, res) => {
  const update = req.body;
  console.log(
    `[service-4-payments-api] Received notification callback from Service 5 (Cloud Run):`,
    JSON.stringify(update)
  );
  res.json({
    service: "service-4-payments-api",
    message: "Notification callback received successfully",
    received: update,
    callback_path:
      "Cloud Run (Service 5) → VPC Egress → Internal Nginx → GKE Pod (Service 4)",
  });
});

app.listen(PORT, () => {
  console.log(`[service-4-payments-api] Listening on port ${PORT}`);
  console.log(
    `[service-4-payments-api] NOTIFICATIONS_CLOUDRUN_URL=${NOTIFICATIONS_CLOUDRUN_URL}`
  );
});
