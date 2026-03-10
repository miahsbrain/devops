// =============================================================================
// Service 1: Frontend
// Role: Public-facing UI served from GKE
// Communicates with:
//   - Service 2 (Orders API) via internal DNS: http://service-2-orders-api.k8s.api.internal
//   - Service 4 (Payments API) via internal DNS: http://service-4-payments-api.k8s.api.internal
// =============================================================================

const express = require("express");
const axios = require("axios");

const app = express();
const PORT = process.env.PORT || 3000;

// Internal DNS URLs injected via Kubernetes env vars
const ORDERS_API_URL =
  process.env.ORDERS_API_URL || "http://service-2-orders-api.k8s.api.internal";
const PAYMENTS_API_URL =
  process.env.PAYMENTS_API_URL ||
  "http://service-4-payments-api.k8s.api.internal";

app.use(express.json());

// Health check
app.get("/healthz", (req, res) => {
  res.json({ status: "ok", service: "service-1-frontend" });
});

// Main UI — fetches data from Service 2 (Orders) and Service 4 (Payments)
app.get("/", async (req, res) => {
  let orders = null;
  let payments = null;
  let ordersError = null;
  let paymentsError = null;

  try {
    const ordersResponse = await axios.get(`${ORDERS_API_URL}/orders`, {
      timeout: 5000,
    });
    orders = ordersResponse.data;
  } catch (err) {
    ordersError = err.message;
  }

  try {
    const paymentsResponse = await axios.get(`${PAYMENTS_API_URL}/payments`, {
      timeout: 5000,
    });
    payments = paymentsResponse.data;
  } catch (err) {
    paymentsError = err.message;
  }

  res.send(`
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
      <title>Service Mesh Demo</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: 'Courier New', monospace;
          background: #0a0a0a;
          color: #e2e2e2;
          min-height: 100vh;
          padding: 40px;
        }
        h1 {
          font-size: 2rem;
          color: #00ff88;
          margin-bottom: 8px;
          letter-spacing: -1px;
        }
        .subtitle {
          color: #666;
          margin-bottom: 40px;
          font-size: 0.85rem;
        }
        .grid {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 24px;
          max-width: 960px;
        }
        .card {
          background: #111;
          border: 1px solid #222;
          border-radius: 8px;
          padding: 24px;
        }
        .card h2 {
          font-size: 0.75rem;
          text-transform: uppercase;
          letter-spacing: 2px;
          color: #00ff88;
          margin-bottom: 16px;
        }
        .card .source {
          font-size: 0.7rem;
          color: #444;
          margin-bottom: 12px;
        }
        .data {
          background: #0d0d0d;
          border: 1px solid #1a1a1a;
          border-radius: 4px;
          padding: 16px;
          font-size: 0.8rem;
          line-height: 1.6;
          white-space: pre-wrap;
          word-break: break-all;
        }
        .error { color: #ff4444; }
        .ok { color: #00ff88; }
        .mesh-diagram {
          max-width: 960px;
          margin-top: 40px;
          background: #111;
          border: 1px solid #222;
          border-radius: 8px;
          padding: 24px;
        }
        .mesh-diagram h2 {
          font-size: 0.75rem;
          text-transform: uppercase;
          letter-spacing: 2px;
          color: #00ff88;
          margin-bottom: 16px;
        }
        .flow {
          font-size: 0.75rem;
          color: #888;
          line-height: 2;
        }
        .flow span { color: #00ff88; }
      </style>
    </head>
    <body>
      <h1>⬡ Internal Service Mesh</h1>
      <p class="subtitle">Service 1 — Frontend (GKE) — All communication over private VPC</p>

      <div class="grid">
        <div class="card">
          <h2>Orders Data</h2>
          <p class="source">← Service 2 (Orders API, GKE) via ${ORDERS_API_URL}</p>
          <div class="data ${ordersError ? "error" : "ok"}">
${ordersError ? "ERROR: " + ordersError : JSON.stringify(orders, null, 2)}
          </div>
        </div>

        <div class="card">
          <h2>Payments Data</h2>
          <p class="source">← Service 4 (Payments API, GKE) via ${PAYMENTS_API_URL}</p>
          <div class="data ${paymentsError ? "error" : "ok"}">
${paymentsError ? "ERROR: " + paymentsError : JSON.stringify(payments, null, 2)}
          </div>
        </div>
      </div>

      <div class="mesh-diagram">
        <h2>Live Communication Map</h2>
        <div class="flow">
          <span>[Browser]</span> → Public Nginx → <span>[Service 1: Frontend GKE]</span><br/>
          &nbsp;&nbsp;↓ http://service-2-orders-api.k8s.api.internal<br/>
          &nbsp;&nbsp;<span>[Service 2: Orders API GKE]</span> → ALB → <span>[Service 3: Inventory Cloud Run]</span><br/>
          &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;↓ http://service-2-orders-api.k8s.api.internal (callback)<br/>
          &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span>[Service 3]</span> calls back to <span>[Service 2]</span> via internal Nginx<br/>
          <br/>
          &nbsp;&nbsp;↓ http://service-4-payments-api.k8s.api.internal<br/>
          &nbsp;&nbsp;<span>[Service 4: Payments API GKE]</span> → ALB → <span>[Service 5: Notifications Cloud Run]</span><br/>
          &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;↓ http://service-4-payments-api.k8s.api.internal (callback)<br/>
          &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span>[Service 5]</span> calls back to <span>[Service 4]</span> via internal Nginx<br/>
        </div>
      </div>
    </body>
    </html>
  `);
});

app.listen(PORT, () => {
  console.log(
    `[service-1-frontend] Listening on port ${PORT}`
  );
  console.log(`[service-1-frontend] ORDERS_API_URL=${ORDERS_API_URL}`);
  console.log(`[service-1-frontend] PAYMENTS_API_URL=${PAYMENTS_API_URL}`);
});
