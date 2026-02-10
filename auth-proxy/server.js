const express = require("express");
const session = require("express-session");
const { createProxyMiddleware } = require("http-proxy-middleware");
const { Issuer, generators } = require("openid-client");
const path = require("path");

const app = express();
const PORT = 3000;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const TENANT_ID = process.env.AZURE_AD_TENANT_ID;
const CLIENT_ID = process.env.AZURE_AD_CLIENT_ID;
const CLIENT_SECRET = process.env.AZURE_AD_CLIENT_SECRET;
const SESSION_SECRET = process.env.SESSION_SECRET || "change-me-in-production";
const CALLBACK_URL = process.env.CALLBACK_URL || "https://localhost/auth/callback";
const API_BACKEND_URL = process.env.API_BACKEND_URL || "http://nginx-api:80";
const DEFAULT_ADMIN_UPN = (process.env.DEFAULT_ADMIN_UPN || "").toLowerCase();
// Base URL derived from CALLBACK_URL (e.g., https://cipp.example.com)
const BASE_URL = CALLBACK_URL.replace("/auth/callback", "");

let oidcClient = null;

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------
// "trust proxy" is required when running behind a reverse proxy (Pangolin,
// Caddy, nginx, etc.) that terminates TLS. The proxy sets X-Forwarded-Proto
// and X-Forwarded-For headers. With trust proxy enabled, Express uses these
// to correctly determine the original protocol, so secure cookies work even
// though this server listens on plain HTTP.
app.set("trust proxy", 1);
app.use(
  session({
    secret: SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: {
      secure: true,
      httpOnly: true,
      sameSite: "lax",
      maxAge: 8 * 60 * 60 * 1000, // 8 hours
    },
  })
);

// ---------------------------------------------------------------------------
// Health check (for Docker, Pangolin, or other monitoring)
// ---------------------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.json({ status: "ok", oidc: oidcClient !== null });
});

// ---------------------------------------------------------------------------
// OIDC Client Initialization
// ---------------------------------------------------------------------------
async function initOidc() {
  const issuer = await Issuer.discover(
    `https://login.microsoftonline.com/${TENANT_ID}/v2.0`
  );
  oidcClient = new issuer.Client({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    redirect_uris: [CALLBACK_URL],
    response_types: ["code"],
  });
  console.log("OIDC client initialized for tenant: " + TENANT_ID);
}

// ---------------------------------------------------------------------------
// Helper: Build clientPrincipal from session user
// ---------------------------------------------------------------------------
function buildClientPrincipal(user) {
  if (!user) return null;

  const roles = ["authenticated", "anonymous"];

  // Grant admin role to the default admin user
  if (DEFAULT_ADMIN_UPN && user.email.toLowerCase() === DEFAULT_ADMIN_UPN) {
    roles.push("admin");
  }

  return {
    identityProvider: "aad",
    userId: user.oid,
    userDetails: user.email,
    userRoles: roles,
  };
}

// ---------------------------------------------------------------------------
// Auth Endpoints (SWA-compatible)
// ---------------------------------------------------------------------------

// GET /.auth/me - Return current user session in SWA format
app.get("/.auth/me", (req, res) => {
  const principal = buildClientPrincipal(req.session.user);
  res.json({ clientPrincipal: principal });
});

// GET /.auth/login/aad - Initiate Azure AD login
app.get("/.auth/login/aad", (req, res) => {
  if (!oidcClient) {
    return res.status(503).send("Auth service not ready");
  }

  const postLoginRedirect = req.query.post_login_redirect_uri || "/";
  const nonce = generators.nonce();
  const state = generators.state();

  req.session.oidcNonce = nonce;
  req.session.oidcState = state;
  req.session.postLoginRedirect = postLoginRedirect;

  const authUrl = oidcClient.authorizationUrl({
    scope: "openid profile email",
    nonce: nonce,
    state: state,
  });

  res.redirect(authUrl);
});

// GET /auth/callback - Handle OAuth2 callback
app.get("/auth/callback", async (req, res) => {
  if (!oidcClient) {
    return res.status(503).send("Auth service not ready");
  }

  try {
    const params = oidcClient.callbackParams(req);
    const tokenSet = await oidcClient.callback(CALLBACK_URL, params, {
      nonce: req.session.oidcNonce,
      state: req.session.oidcState,
    });

    const claims = tokenSet.claims();

    req.session.user = {
      oid: claims.oid || claims.sub,
      email: claims.preferred_username || claims.email || claims.upn || "",
      name: claims.name || "",
    };

    // Clean up OIDC state
    delete req.session.oidcNonce;
    delete req.session.oidcState;

    const redirect = req.session.postLoginRedirect || "/";
    delete req.session.postLoginRedirect;

    res.redirect(redirect);
  } catch (err) {
    console.error("Auth callback error:", err.message);
    res.status(500).send("Authentication failed. Please try again.");
  }
});

// GET /.auth/logout - Logout and redirect
app.get("/.auth/logout", (req, res) => {
  const postLogoutRedirect =
    req.query.post_logout_redirect_uri || req.query.post_logout_redirect_url || "/";

  req.session.destroy(() => {
    // Build the full post-logout URL from the relative path
    const fullRedirect = postLogoutRedirect.startsWith("http")
      ? postLogoutRedirect
      : BASE_URL + postLogoutRedirect;

    const logoutUrl =
      `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/logout` +
      `?post_logout_redirect_uri=${encodeURIComponent(fullRedirect)}`;
    res.redirect(logoutUrl);
  });
});

// ---------------------------------------------------------------------------
// /api/me: Return clientPrincipal directly for unauthenticated users
// ---------------------------------------------------------------------------
// The CIPP frontend calls /api/me to check user roles. When unauthenticated,
// the backend returns 403 (Test-CIPPAccess throws on null Roles), which causes
// the frontend to get stuck in a loading loop. Instead, we intercept /api/me
// here: if the user has no session, return { clientPrincipal: null } directly
// (matching Azure SWA behavior). If authenticated, fall through to the proxy.
app.get("/api/me", (req, res, next) => {
  if (req.session && req.session.user) {
    // Authenticated: let it fall through to the proxy middleware below
    return next();
  }
  // Not authenticated: return null clientPrincipal (SWA behavior)
  res.json({ clientPrincipal: null });
});

// ---------------------------------------------------------------------------
// API Proxy: /api/* -> backend with SWA-compatible headers
// ---------------------------------------------------------------------------
app.use(
  "/api",
  (req, _res, next) => {
    // SECURITY: Strip any incoming SWA headers to prevent spoofing
    delete req.headers["x-ms-client-principal"];
    delete req.headers["x-ms-client-principal-name"];
    delete req.headers["x-ms-client-principal-idp"];

    // Inject SWA-compatible headers if user is authenticated
    if (req.session && req.session.user) {
      const principal = buildClientPrincipal(req.session.user);
      const principalJson = JSON.stringify(principal);
      const principalBase64 = Buffer.from(principalJson, "utf8").toString(
        "base64"
      );

      req.headers["x-ms-client-principal"] = principalBase64;
      req.headers["x-ms-client-principal-name"] = req.session.user.email;
      req.headers["x-ms-client-principal-idp"] = "aad";
    }

    next();
  },
  createProxyMiddleware({
    target: API_BACKEND_URL,
    changeOrigin: true,
    ws: false,
    // Express strips the mount path ("/api") before forwarding to the proxy.
    // Azure Functions expects the full path (e.g., /api/me, /api/ExecSAMSetup),
    // so we re-prepend "/api" to restore the original path.
    pathRewrite: (p) => "/api" + p,
    on: {
      error: (err, _req, res) => {
        console.error("API proxy error:", err.message);
        if (res.writeHead) {
          res.writeHead(502, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "API backend unavailable" }));
        }
      },
    },
  })
);

// ---------------------------------------------------------------------------
// Static Frontend: Serve the Next.js static export
// ---------------------------------------------------------------------------
const FRONTEND_DIR = process.env.FRONTEND_DIR || "/app/frontend";

app.use(express.static(FRONTEND_DIR));

// SPA fallback: any unmatched route serves index.html
// (replicates SWA's navigationFallback)
app.get("*", (req, res) => {
  res.sendFile(path.join(FRONTEND_DIR, "index.html"));
});

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------
async function start() {
  try {
    await initOidc();
  } catch (err) {
    console.error("Failed to initialize OIDC:", err.message);
    console.error("Auth endpoints will return 503 until OIDC is available.");
  }

  app.listen(PORT, "0.0.0.0", () => {
    console.log("CIPP Auth Proxy listening on port " + PORT);
    console.log("API backend: " + API_BACKEND_URL);
    console.log("Default admin: " + (DEFAULT_ADMIN_UPN || "(none)"));
  });
}

start();
