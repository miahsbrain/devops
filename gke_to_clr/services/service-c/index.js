const express = require("express");
const axios = require("axios");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// The single URL that reaches the internal ingress inside the GKE VPC.
// Cloud Run calls this over VPC egress — no public internet involved.
// All services in GKE are reachable via paths on this base URL.
const INTERNAL_GATEWAY_URL = process.env.INTERNAL_GATEWAY_URL;

app.get("/health", (req, res) =>
  res.json({ status: "ok", service: "service-c" })
);

// Heavy task endpoint — triggered by Service A
app.post("/heavy", async (req, res) => {
  if (!INTERNAL_GATEWAY_URL) {
    return res
      .status(503)
      .json({ error: "INTERNAL_GATEWAY_URL not configured" });
  }

  try {
    const { jobType, payload } = req.body;
    console.log(`Starting heavy job: ${jobType}`);

    // Fetch supporting data from Service B
    // Note: we reach Service B through the internal ingress — NOT via ClusterIP
    // ClusterIPs are cluster-internal only; Cloud Run lives outside the cluster
    const dataRes = await axios.get(
      `${INTERNAL_GATEWAY_URL}/service-b/data`,
      { headers: { "x-internal-call": "true" } }
    );

    // Simulate heavy work (replace with real logic: image resize, ML, bulk export, etc.)
    await simulateHeavyWork(jobType);

    const result = {
      jobType,
      status: "completed",
      service: "service-c",
      inputPayload: payload,
      enrichedWith: dataRes.data,
      completedAt: new Date().toISOString(),
    };

    // Call back to Service A to signal job completion
    await axios.post(
      `${INTERNAL_GATEWAY_URL}/api/callback`,
      { origin: "service-c", result },
      { headers: { "x-internal-call": "true" } }
    );

    res.json(result);
  } catch (err) {
    console.error("Heavy task error:", err.message);
    res
      .status(500)
      .json({ error: "heavy task failed", detail: err.message });
  }
});

function simulateHeavyWork(jobType) {
  return new Promise((resolve) => {
    const duration = jobType === "image-processing" ? 3000 : 1500;
    setTimeout(resolve, duration);
  });
}

app.listen(PORT, () =>
  console.log(`Service C (Heavy Processor) running on port ${PORT}`)
);
