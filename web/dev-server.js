// Dev server: serves web/ and proxies API paths to the Rust service.
// Usage:  bun web/dev-server.js   (from sandbox-manager/)
//
// Routes:
//   /                                                          → web/index.html (user panel)
//   /admin/                                                    → web/admin.html (legacy admin UI)
//   /sandbox, /templates, /stats, /health, /recovery-ca.pub      → 127.0.0.1:8200 (public REST)
//   /admin/api/*                                                 → 127.0.0.1:8210 (admin REST, separate socket)
//
// In dev there is no shared cookie (different origin), so paste a session
// token / API key into the panel's "advanced" field; it will be sent as
// `Authorization: Bearer …`.
import { makeDevServer } from "../../packages/shared-web/dev-server.js";

makeDevServer({
  port: 8250,
  api: "http://127.0.0.1:8200",
  apiPrefixes: ["/sandbox", "/templates", "/stats", "/health", "/recovery-ca.pub"],
  apiRoutes: { "/admin/api/": "http://127.0.0.1:8210" },
  pages: { "/admin": "/admin.html", "/admin/": "/admin.html" },
  root: new URL("./", import.meta.url),
  label: "sandbox-manager dev (user + admin)",
});
