const express = require("express");
const axios = require("axios");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// ClusterIP DNS — works because Service A and B are in the same cluster
// Kubernetes automatically creates this DNS name when a Service is created
const SERVICE_B_URL =
  process.env.SERVICE_B_URL || "http://service-b.default.svc.cluster.local:8080";

// Cloud Run URL for Service C — injected via Kubernetes secret at deploy time
const SERVICE_C_URL = process.env.SERVICE_C_URL;

app.get("/health", (req, res) =>
  res.json({ status: "ok", service: "service-a" })
);

// Standard request — routed to Service B inside the cluster
app.post("/api/process", async (req, res) => {
  try {
    const result = await axios.post(`${SERVICE_B_URL}/process`, req.body, {
      headers: { "x-internal-call": "true" },
    });
    res.json({ source: "service-a", downstream: result.data });
  } catch (err) {
    console.error("Error calling service-b:", err.message);
    res.status(502).json({ error: "service-b unavailable", detail: err.message });
  }
});

// Heavy task — dispatched to Service C on Cloud Run
app.post("/api/heavy", async (req, res) => {
  if (!SERVICE_C_URL) {
    return res.status(503).json({ error: "SERVICE_C_URL not configured" });
  }
  try {
    // Fetch a GCP identity token so Cloud Run accepts the request
    const tokenRes = await axios
      .get(
        `http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${SERVICE_C_URL}`,
        { headers: { "Metadata-Flavor": "Google" } }
      )
      .catch(() => ({ data: null })); // graceful fallback for local dev

    const headers = { "x-internal-call": "true" };
    if (tokenRes.data) headers["Authorization"] = `Bearer ${tokenRes.data}`;

    const result = await axios.post(`${SERVICE_C_URL}/heavy`, req.body, {
      headers,
    });
    res.json({ source: "service-a", downstream: result.data });
  } catch (err) {
    console.error("Error calling service-c:", err.message);
    res.status(502).json({ error: "service-c unavailable", detail: err.message });
  }
});

// Receives callbacks FROM Service C after a heavy job finishes
app.post("/api/callback", (req, res) => {
  console.log("Callback received from service-c:", JSON.stringify(req.body));
  res.json({ received: true, service: "service-a", payload: req.body });
});

app.listen(PORT, () =>
  console.log(`Service A (Gateway) running on port ${PORT}`)
);
