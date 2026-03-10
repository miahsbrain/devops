// =============================================================================
// Service 2: Orders API
// Role: GKE — handles order data
// Communicates with:
//   - Service 3 (Inventory, Cloud Run) via internal ALB:
//     http://service-3-inventory-cloudrun.api.internal
// Receives callbacks from:
//   - Service 3 (Inventory, Cloud Run) via internal Nginx:
//     http://service-2-orders-api.k8s.api.internal/inventory-callback
// =============================================================================

const express = require("express");
const axios = require("axios");

const app = express();
const PORT = process.env.PORT || 3001;

// Internal ALB DNS — resolves to 10.10.1.50 inside the VPC
const INVENTORY_CLOUDRUN_URL =
  process.env.INVENTORY_CLOUDRUN_URL ||
  "http://service-3-inventory-cloudrun.api.internal";

app.use(express.json());

// Health check
app.get("/healthz", (req, res) => {
  res.json({ status: "ok", service: "service-2-orders-api" });
});

// Returns orders and fetches live inventory from Service 3 (Cloud Run)
app.get("/orders", async (req, res) => {
  const orders = [
    { id: "ORD-001", product: "Widget A", quantity: 3, status: "pending" },
    { id: "ORD-002", product: "Widget B", quantity: 1, status: "confirmed" },
  ];

  let inventory = null;
  let inventoryError = null;

  try {
    // Calling Service 3 (Cloud Run) via Internal ALB
    const response = await axios.get(`${INVENTORY_CLOUDRUN_URL}/inventory`, {
      timeout: 5000,
    });
    inventory = response.data;
  } catch (err) {
    inventoryError = `Failed to reach Service 3 (Inventory Cloud Run): ${err.message}`;
  }

  res.json({
    service: "service-2-orders-api",
    location: "GKE",
    orders,
    inventory_from_service_3: inventory || { error: inventoryError },
    communication_path: `GKE Pod → ${INVENTORY_CLOUDRUN_URL} → Internal ALB → Cloud Run`,
  });
});

// Callback endpoint — Service 3 (Cloud Run) calls this to push inventory updates
app.post("/inventory-callback", (req, res) => {
  const update = req.body;
  console.log(
    `[service-2-orders-api] Received inventory callback from Service 3 (Cloud Run):`,
    JSON.stringify(update)
  );
  res.json({
    service: "service-2-orders-api",
    message: "Inventory callback received successfully",
    received: update,
    callback_path:
      "Cloud Run (Service 3) → VPC Egress → Internal Nginx → GKE Pod (Service 2)",
  });
});

app.listen(PORT, () => {
  console.log(`[service-2-orders-api] Listening on port ${PORT}`);
  console.log(
    `[service-2-orders-api] INVENTORY_CLOUDRUN_URL=${INVENTORY_CLOUDRUN_URL}`
  );
});
