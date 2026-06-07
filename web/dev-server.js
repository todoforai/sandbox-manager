// Dev server: serves web/ and proxies API paths to the Go service.
// Usage:  bun web/dev-server.js   (from sandbox-manager/)
//
// Two dev servers (mirror prod's two-socket pattern — see packages/shared-web/README.md):
//   :8250  user UI    → /sandbox, /templates, /stats, /health   → 127.0.0.1:8200
//   :8280  admin UI   → /admin/api/*                            → 127.0.0.1:8200
//
// The Go service has no separate admin socket: admin scope is role-based on the
// same :8200 API (an admin bearer token widens /sandbox + /stats to all users,
// and the /admin/api/* aliases gate on that role). In dev there is no shared
// cookie (different origin), so paste a session token / admin API key into the
// panel's "advanced" field; it is sent as `Authorization: Bearer …`.
import { makeDevServer } from "../../packages/shared-web/dev-server.js";

const root = new URL("./", import.meta.url);

makeDevServer({
  port: 8250,
  api: "http://127.0.0.1:8200",
  apiPrefixes: ["/sandbox", "/templates", "/stats", "/health"],
  root,
  label: "sandbox-manager dev (user)",
});

makeDevServer({
  port: 8280,
  api: "http://127.0.0.1:8200",
  apiPrefixes: ["/admin/api/"],
  pages: { "/": "/admin/index.html", "/admin": "/admin/index.html", "/admin/": "/admin/index.html" },
  root,
  label: "sandbox-manager dev (admin)",
});
