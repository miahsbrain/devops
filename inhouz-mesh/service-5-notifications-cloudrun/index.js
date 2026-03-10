// =============================================================================
// Service 5: Notifications
// Role: Cloud Run — handles notification delivery
// Communicates with:
//   - Service 4 (Payments API, GKE) via internal Nginx:
//     http://service-4-payments-api.k8s.api.internal/notification-callback
// Receives calls from:
//   - Service 4 (Payments API, GKE) via Internal ALB
// =============================================================================

const express = require("express");
const axios = require("axios");

const app = express();
const PORT = process.env.PORT || 8080;

// Internal Nginx DNS — resolves to 10.10.1.51 inside the VPC
// Cloud Run reaches this via Direct VPC Egress
const PAYMENTS_API_CALLBACK_URL =
  process.env.PAYMENTS_API_CALLBACK_URL ||
  "http://service-4-payments-api.k8s.api.internal";

app.use(express.json());

// Health check
app.get("/healthz", (req, res) => {
  res.json({ status: "ok", service: "service-5-notifications-cloudrun" });
});

// Receives notification request from Service 4 (GKE) and fires callback
app.post("/notify", async (req, res) => {
  const payload = req.body;
  console.log(
    `[service-5-notifications-cloudrun] Received notification request:`,
    JSON.stringify(payload)
  );

  const notificationResult = {
    service: "service-5-notifications-cloudrun",
    location: "Cloud Run",
    notification_id: `NOTIF-${Date.now()}`,
    event_received: payload.event,
    channels_notified: ["email", "slack", "webhook"],
    status: "delivered",
    timestamp: new Date().toISOString(),
  };

  // Fire async callback to Service 4 (GKE) to confirm notification was delivered
  // This goes: Cloud Run → VPC Egress → DNS → Internal Nginx → GKE Pod
  setImmediate(async () => {
    try {
      await axios.post(
        `${PAYMENTS_API_CALLBACK_URL}/notification-callback`,
        {
          source: "service-5-notifications-cloudrun",
          event: "notification_delivered",
          notification_id: notificationResult.notification_id,
          timestamp: new Date().toISOString(),
        },
        { timeout: 5000 }
      );
      console.log(
        `[service-5-notifications-cloudrun] Callback to Service 4 (Payments GKE) successful`
      );
    } catch (err) {
      console.error(
        `[service-5-notifications-cloudrun] Callback to Service 4 failed: ${err.message}`
      );
    }
  });

  res.json({
    ...notificationResult,
    callback_fired_to: `${PAYMENTS_API_CALLBACK_URL}/notification-callback`,
    communication_path:
      "Cloud Run (Service 5) → VPC Egress → Internal Nginx → GKE Pod (Service 4)",
  });
});

app.listen(PORT, () => {
  console.log(`[service-5-notifications-cloudrun] Listening on port ${PORT}`);
  console.log(
    `[service-5-notifications-cloudrun] PAYMENTS_API_CALLBACK_URL=${PAYMENTS_API_CALLBACK_URL}`
  );
});
