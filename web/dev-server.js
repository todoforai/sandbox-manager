// Dev server: serves web/ and proxies API paths to the Rust service.
// Usage:  bun web/dev-server.js   (from sandbox-manager/)
//
// Routes:
//   /                 → web/index.html (user panel)
//   /admin/           → web/admin.html (legacy admin UI)
//   /sandbox, /templates, /stats, /health, /admin/api/*  → 127.0.0.1:9000
//
// In dev there is no shared cookie (different origin), so paste a session
// token / API key into the panel's "advanced" field; it will be sent as
// `Authorization: Bearer …`.
import { serve } from "bun";

const ROOT = new URL("./", import.meta.url);
const API = "http://127.0.0.1:9000";
const API_PREFIXES = ["/admin/api/", "/sandbox", "/templates", "/stats", "/health", "/recovery-ca.pub"];

serve({
  port: 8190,
  async fetch(req) {
    const url = new URL(req.url);
    if (API_PREFIXES.some(p => url.pathname === p || url.pathname.startsWith(p.endsWith("/") ? p : p + "/") || url.pathname === p)) {
      return fetch(API + url.pathname + url.search, { method: req.method, headers: req.headers, body: req.body });
    }
    let path = url.pathname;
    if (path === "/") path = "/index.html";
    else if (path === "/admin" || path === "/admin/") path = "/admin.html";
    const file = Bun.file(new URL("." + path, ROOT).pathname);
    return (await file.exists()) ? new Response(file) : new Response("Not found", { status: 404 });
  },
});
console.log("→ http://127.0.0.1:8190/        (user panel)");
console.log("→ http://127.0.0.1:8190/admin/  (legacy admin)");
console.log("   proxying API paths to " + API);
