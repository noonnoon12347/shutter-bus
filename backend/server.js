require("dotenv").config();
const http = require("http");
const express = require("express");
const cors = require("cors");
const { Pool } = require("pg");
const { Server } = require("socket.io");

const PORT = process.env.PORT || 3000;
const DRIVER_KEY = process.env.DRIVER_KEY || "";

if (!process.env.DATABASE_URL) {
  console.error("ไม่พบ DATABASE_URL ในไฟล์ .env");
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false }, // Supabase ต้องใช้ SSL
});

const app = express();
app.use(cors());
app.use(express.json());

const server = http.createServer(app);
const io = new Server(server, { cors: { origin: "*" } });

// ตำแหน่งรถล่าสุด เก็บในหน่วยความจำ (vehicleId -> ข้อมูล)
const positions = new Map();

// ---------- REST API ----------

// รายการสายรถ
app.get("/api/routes", async (req, res) => {
  try {
    const onlyActive = req.query.isActive === "true";
    const { rows } = await pool.query(
      `SELECT id, code, name, description, color, "isActive"
       FROM routes
       ${onlyActive ? 'WHERE "isActive" = true' : ""}
       ORDER BY id`,
    );
    res.json({ data: rows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "server error" });
  }
});

// รายละเอียดสาย + ป้ายตามลำดับ
app.get("/api/routes/:id", async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isInteger(id)) return res.status(400).json({ error: "bad id" });

    const r = await pool.query(
      `SELECT id, code, name, description, color, "isActive", geometry
       FROM routes WHERE id = $1`,
      [id],
    );
    if (r.rowCount === 0) return res.status(404).json({ error: "not found" });

    const s = await pool.query(
      `SELECT rs.sequence AS "stopOrder",
              s.id, s.code, s.name, s.latitude, s.longitude
       FROM route_stops rs
       JOIN stops s ON s.id = rs."stopId"
       WHERE rs."routeId" = $1
       ORDER BY rs.sequence`,
      [id],
    );

    const routeStops = s.rows.map((x) => ({
      stopOrder: x.stopOrder,
      stop: {
        id: x.id,
        code: x.code,
        name: x.name,
        latitude: x.latitude,
        longitude: x.longitude,
      },
    }));

    res.json({ data: { ...r.rows[0], routeStops } });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "server error" });
  }
});

// รถส่งตำแหน่งเข้ามา (ใช้ทดสอบ หรือให้แอปคนขับเรียก)
// body: { "vehicleCode": "BUS-01", "latitude": 13.96, "longitude": 100.58 }
// header: x-driver-key: <DRIVER_KEY>
app.post("/api/location", async (req, res) => {
  try {
    if (!DRIVER_KEY || req.get("x-driver-key") !== DRIVER_KEY) {
      return res.status(401).json({ error: "unauthorized" });
    }
    const { vehicleCode, latitude, longitude } = req.body || {};
    if (
      !vehicleCode ||
      typeof latitude !== "number" ||
      typeof longitude !== "number"
    ) {
      return res
        .status(400)
        .json({ error: "vehicleCode, latitude, longitude required" });
    }

    const v = await pool.query(
      `SELECT id, code, "routeId" FROM vehicles WHERE code = $1`,
      [vehicleCode],
    );
    if (v.rowCount === 0)
      return res.status(404).json({ error: "vehicle not found" });
    if (v.rows[0].routeId == null)
      return res.status(400).json({ error: "vehicle has no route" });

    const pos = {
      vehicleId: v.rows[0].id,
      vehicleCode: v.rows[0].code,
      routeId: v.rows[0].routeId,
      latitude,
      longitude,
      at: new Date().toISOString(),
    };
    positions.set(pos.vehicleId, pos);
    io.emit("vehicle:location", pos);
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "server error" });
  }
});

// จบการเดินรถ: ลบรถออกจากแผนที่
// body: { "vehicleCode": "BUS-01" }
app.post("/api/trip/end", async (req, res) => {
  if (!DRIVER_KEY || req.get("x-driver-key") !== DRIVER_KEY) {
    return res.status(401).json({ error: "unauthorized" });
  }
  const { vehicleCode } = req.body || {};
  for (const [id, p] of positions) {
    if (p.vehicleCode === vehicleCode) {
      positions.delete(id);
      io.emit("trip:ended", { vehicleId: id });
    }
  }
  res.json({ ok: true });
});

app.get("/", (_req, res) => res.send("Shutter Bus backend is running"));

// ---------- Socket.IO ----------
io.on("connection", (socket) => {
  socket.emit("snapshot", { positions: [...positions.values()] });
});

server.listen(PORT, () => {
  console.log(`backend รันที่ http://localhost:${PORT}`);
  pool
    .query("SELECT 1")
    .then(() => console.log("เชื่อมต่อ Supabase สำเร็จ"))
    .catch((e) => console.error("เชื่อมต่อฐานข้อมูลไม่ได้:", e.message));
});
