// Sample service for the playground: Express endpoints with varied latency, one that fails, and a loop calling them.
const express = require("express");
const { setTimeout: sleep } = require("node:timers/promises");

class OrderError extends Error {}

async function loadOrder(id) {
  await sleep(5 + Math.random() * 120);
  return { id };
}

async function checkout() {
  await sleep(200 + Math.random() * 600);
  if (Math.random() < 0.3) {
    throw new OrderError("payment declined");
  }
  return { ok: true };
}

const app = express();
app.get("/orders/:id", async (req, res) => res.json(await loadOrder(req.params.id)));
app.post("/checkout", async (req, res, next) => {
  try {
    res.json(await checkout());
  } catch (err) {
    next(err);
  }
});

// Express answers with a 500 either way; this only keeps the expected failures out of the console.
app.use((err, req, res, next) => res.status(500).json({ error: err.message }));

const server = app.listen(0, async () => {
  const base = `http://localhost:${server.address().port}`;
  console.log(`sample app on ${base}`);
  for (;;) {
    await Promise.all([
      fetch(`${base}/orders/${Math.floor(Math.random() * 100)}`),
      fetch(`${base}/checkout`, { method: "POST" }),
    ]).catch((err) => console.error(err.message));
    await sleep(200);
  }
});
