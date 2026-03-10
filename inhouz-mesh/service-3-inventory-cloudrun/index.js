// =============================================================================
// Service 3: Inventory
// Role: Cloud Run — manages inventory data
// Communicates with:
//   - Service 2 (Orders API, GKE) via internal Nginx:
//     http://service-2-orders-api.k8s.api.internal/inventory-callback
// Receives calls from:
//   - Service 2 (Orders API, GKE) via Internal ALB
// =============================================================================

const express = require("express");
const axios = require("axios");

const app = express();
const PORT = process.env.PORT || 8080;

// Internal Nginx DNS — resolves to 10.10.1.51 inside the VPC
// Cloud Run reaches this via Direct VPC Egress
const ORDERS_API_CALLBACK_URL =
  process.env.ORDERS_API_CALLBACK_URL ||
  "http://service-2-orders-api.k8s.api.internal";

app.use(express.json());

// Health check
app.get("/healthz", (req, res) => {
  res.json({ status: "ok", service: "service-3-inventory-cloudrun" });
});

// Returns inventory data and fires a callback to Service 2 (GKE)
app.get("/inventory", async (req, res) => {
  const inventory = [
    { sku: "WIDGET-A", stock: 142, warehouse: "us-central" },
    { sku: "WIDGET-B", stock: 37, warehouse: "us-central" },
    { sku: "WIDGET-C", stock: 0, warehouse: "us-central", status: "out_of_stock" },
  ];

  // Fire async callback to Service 2 (GKE) to confirm inventory was checked
  // This goes: Cloud Run → VPC Egress → DNS → Internal Nginx → GKE Pod
  setImmediate(async () => {
    try {
      await axios.post(
        `${ORDERS_API_CALLBACK_URL}/inventory-callback`,
        {
          source: "service-3-inventory-cloudrun",
          event: "inventory_checked",
          timestamp: new Date().toISOString(),
          items_checked: inventory.map((i) => i.sku),
        },
        { timeout: 5000 }
      );
      console.log(
        `[service-3-inventory-cloudrun] Callback to Service 2 (Orders GKE) successful`
      );
    } catch (err) {
      console.error(
        `[service-3-inventory-cloudrun] Callback to Service 2 failed: ${err.message}`
      );
    }
  });

  res.json({
    service: "service-3-inventory-cloudrun",
    location: "Cloud Run",
    inventory,
    callback_fired_to: `${ORDERS_API_CALLBACK_URL}/inventory-callback`,
    communication_path:
      "Cloud Run (Service 3) → VPC Egress → Internal Nginx → GKE Pod (Service 2)",
  });
});

app.listen(PORT, () => {
  console.log(`[service-3-inventory-cloudrun] Listening on port ${PORT}`);
  console.log(
    `[service-3-inventory-cloudrun] ORDERS_API_CALLBACK_URL=${ORDERS_API_CALLBACK_URL}`
  );
});
