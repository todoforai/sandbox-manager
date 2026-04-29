// Dev server: serves web/ and proxies /admin/api/* → http://127.0.0.1:9000
// Usage:  bun web/dev-server.js   (from sandbox-manager/)
import { serve } from "bun";

const ROOT = new URL("./", import.meta.url);
const API = "http://127.0.0.1:9000";

serve({
  port: 8190,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/admin/api/")) {
      return fetch(API + url.pathname + url.search, { method: req.method, headers: req.headers, body: req.body });
    }
    const path = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(new URL("." + path, ROOT).pathname);
    return (await file.exists()) ? new Response(file) : new Response("Not found", { status: 404 });
  },
});
console.log("→ http://127.0.0.1:8190/  (proxying /admin/api/* to " + API + ")");
