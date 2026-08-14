// Read-only probe: connect to DSH host/mux WS streams, print frame types + a
// truncated sample of each distinct type, then exit.
import WebSocket from "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/ws/index.js";

const BASE = process.env.DSH_URL ?? "http://127.0.0.1:3080";
const seen = new Map();
const started = Date.now();

function note(name, payload) {
  const key = name;
  if (!seen.has(key)) {
    seen.set(key, JSON.stringify(payload).slice(0, 900));
    console.log(`\n[${name}]\n${seen.get(key)}`);
  }
}

function connect(path, label) {
  const ws = new WebSocket(`${BASE.replace(/^http/, "ws")}${path}`);
  ws.on("open", () => console.log(`[${label}] connected ${path}`));
  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      const type = msg?.payload?.type ?? msg?.type ?? "?";
      const ev = msg?.payload?.event;
      const evType = ev?.type ? `${type}<${ev.type}>` : type;
      note(`${label}:${evType}`, msg.payload);
      if (type === "session/event" && ev?.type && ev?.data) {
        note(`${label}:${ev.type}.data`, ev.data);
      }
    } catch {}
  });
  ws.on("error", (e) => console.log(`[${label}] error: ${e.message}`));
  ws.on("close", () => console.log(`[${label}] closed`));
  return ws;
}

const host = connect("/api/events.host", "host");
const mux = connect("/api/events.mux", "mux");

setTimeout(() => {
  host.close();
  mux.close();
  console.log("\n-- done --");
  process.exit(0);
}, Number(process.env.PROBE_MS ?? 20000));
