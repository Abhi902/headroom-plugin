// spawn-probe.mjs — CI-only. Spawns an MCP stdio server WITHOUT a shell (the way
// Claude Code's MCP client does), sends `initialize`, and exits 0 only when a
// JSON-RPC result comes back. Usage: node spawn-probe.mjs <command> [args...]
// Exit: 0 handshake ok · 2 process exited early · 3 spawn error · 4 timeout
import { spawn } from "node:child_process";

const [cmd, ...args] = process.argv.slice(2);
if (!cmd) { console.error("usage: spawn-probe.mjs <command> [args...]"); process.exit(1); }

const child = spawn(cmd, args, {
  shell: false,
  stdio: ["pipe", "pipe", "inherit"],
  env: { ...process.env, HEADROOM_UPDATE_CHECK: "off", HF_HUB_OFFLINE: "1" },
});
const done = (code, msg) => { if (msg) console.error(msg); try { child.kill(); } catch {} process.exit(code); };
child.on("error", (e) => done(3, `spawn error: ${e.code || e.message}`));
child.on("exit", (code) => done(2, `server exited early (code ${code})`));
let buf = "";
child.stdout.on("data", (d) => {
  buf += d.toString();
  if (buf.includes('"result"')) { console.log("initialize ok"); done(0); }
});
const init = { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "spawn-probe", version: "0" } } };
child.stdin.write(JSON.stringify(init) + "\n");
setTimeout(() => done(4, "timeout waiting for initialize result"), 20000);
