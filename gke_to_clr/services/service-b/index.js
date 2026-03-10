const express = require("express");
const axios = require("axios");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// ClusterIP DNS — both A and B are in the same cluster, so this resolves natively
const SERVICE_A_URL =
  process.env.SERVICE_A_URL || "http://service-a.default.svc.cluster.local:8080";

app.get("/health", (req, res) =>
  res.json({ status: "ok", service: "service-b" })
);

// Core processing — called by Service A
app.post("/process", async (req, res) => {
  try {
    const { payload } = req.body;

    const result = {
      processed: true,
      service: "service-b",
      input: payload,
      output: `Processed: ${JSON.stringify(payload)}`,
      timestamp: new Date().toISOString(),
    };

    // Optionally call back to Service A (still ClusterIP — stays inside cluster)
    if (req.body.requiresCallback) {
      await axios.post(
        `${SERVICE_A_URL}/api/callback`,
        { origin: "service-b", result },
        { headers: { "x-internal-call": "true" } }
      );
    }

    res.json(result);
  } catch (err) {
    console.error("Processing error:", err.message);
    res.status(500).json({ error: "processing failed", detail: err.message });
  }
});

// Data endpoint — also called by Service C via the internal ingress
// Cloud Run hits: http://internal.myapp.com/service-b/data
// Ingress routes /service-b → this service → /data
app.get("/data", (req, res) => {
  res.json({
    service: "service-b",
    data: {
      records: [
        { id: 1, value: "alpha" },
        { id: 2, value: "beta" },
        { id: 3, value: "gamma" },
      ],
      fetchedAt: new Date().toISOString(),
    },
  });
});

app.listen(PORT, () =>
  console.log(`Service B (Business Logic) running on port ${PORT}`)
);
