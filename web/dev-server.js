// Dev server: serves web/ and proxies API paths to the Rust service.
// Usage:  bun web/dev-server.js   (from sandbox-manager/)
//
// Two dev servers (mirror prod's two-socket pattern — see packages/shared-web/README.md):
//   :8250  user UI    → /sandbox, /templates, /stats, /health   → 127.0.0.1:8200 (public REST)
//   :8280  admin UI   → /admin/api/*                            → 127.0.0.1:8210 (admin REST)
//
// In dev there is no shared cookie (different origin), so paste a session
// token / API key into the panel's "advanced" field; it will be sent as
// `Authorization: Bearer …`.
import { makeDevServer } from "../../packages/shared-web/dev-server.js";

const root = new URL("./", import.meta.url);

makeDevServer({
  port: 8250,
  api: "http://127.0.0.1:8200",
  apiPrefixes: ["/sandbox", "/templates", "/stats", "/health", "/recovery-ca.pub"],
  root,
  label: "sandbox-manager dev (user)",
});

makeDevServer({
  port: 8280,
  api: "http://127.0.0.1:8210",
  apiPrefixes: ["/admin/api/"],
  pages: { "/": "/admin/index.html", "/admin": "/admin/index.html", "/admin/": "/admin/index.html" },
  root,
  label: "sandbox-manager dev (admin)",
});
