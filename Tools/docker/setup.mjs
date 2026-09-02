// Provisions the local Storyteller + Keycloak stack for Issa Reader development.
//
// Idempotent: safe to re-run. Storyteller's first-run screen is a Next.js server
// action with no REST equivalent, so that one step is driven with Playwright;
// everything after it goes through the v2 REST API.
//
// Usage: npm run setup   (from Tools/docker)

import { chromium } from "playwright"

// Everything must agree on ONE host. Auth.js sets the PKCE `state` cookie on
// the origin that starts the OIDC redirect and reads it back on the callback,
// so mixing localhost and the LAN address fails with "state value could not be
// parsed". The LAN address is also the only one a phone or Apple TV can reach.
const HOST = process.env.PUBLIC_HOST ?? "localhost"
const STORYTELLER = process.env.STORYTELLER_URL ?? `http://${HOST}:8001`
const KEYCLOAK = process.env.KEYCLOAK_URL ?? `http://${HOST}:8080`

const ADMIN = {
  username: "admin",
  email: "admin@issa.test",
  fullName: "Issa Admin",
  password: "issareader",
}

// Provider display name "Keycloak" => provider id "keycloak" via the server's
// customProviderId(): lowercase, spaces to dashes, non-alphanumerics stripped.
// That id is what the callback URL in the realm import must match.
const OIDC_PROVIDER = {
  kind: "custom",
  name: "Keycloak",
  type: "oidc",
  clientId: "storyteller",
  clientSecret: "storyteller-dev-secret",
  issuer: `${KEYCLOAK}/realms/issa`,
  allowRegistration: true,
  groupPermissions: {
    librarians: [
      "bookRead", "bookList", "bookDownload", "bookCreate",
      "bookUpdate", "bookProcess", "collectionCreate",
    ],
    readers: ["bookRead", "bookList", "bookDownload"],
  },
}

const log = (...a) => console.log("[setup]", ...a)

async function waitForHealthy(name, url, predicate, tries = 60) {
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(url)
      if (await predicate(res)) return
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 2000))
  }
  throw new Error(`${name} did not become ready at ${url} — is the stack up? (docker compose up -d)`)
}

async function isInitialised() {
  const res = await fetch(`${STORYTELLER}/`, { redirect: "follow" })
  return !res.url.endsWith("/init")
}

async function runInitScreen() {
  const browser = await chromium.launch()
  try {
    const page = await browser.newPage()
    await page.goto(`${STORYTELLER}/init`, { waitUntil: "domcontentloaded" })
    await page.fill('input[name="email"]', ADMIN.email)
    await page.fill('input[name="fullName"]', ADMIN.fullName)
    await page.fill('input[name="username"]', ADMIN.username)
    await page.fill('input[name="password"]', ADMIN.password)
    await Promise.all([
      page.waitForURL((u) => !u.pathname.startsWith("/init"), { timeout: 60_000 }),
      page.click('button[type="submit"]'),
    ])
    log("admin account created:", ADMIN.username)
  } finally {
    await browser.close()
  }
}

async function getToken() {
  const body = new URLSearchParams({
    usernameOrEmail: ADMIN.username,
    password: ADMIN.password,
  })
  const res = await fetch(`${STORYTELLER}/api/v2/token`, { method: "POST", body })
  if (!res.ok) throw new Error(`token request failed: ${res.status}`)
  const json = await res.json()
  // NOTE: `expires_in` from this server is `epochMillis * 1000` — a broken value,
  // not a duration. Never trust it; validate with GET /api/v2/validate instead.
  return json.access_token
}

async function configureOIDC(token) {
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }

  const res = await fetch(`${STORYTELLER}/api/v2/settings`, { headers })
  if (!res.ok) throw new Error(`GET settings failed: ${res.status}`)
  const settings = await res.json()

  const providers = (settings.authProviders ?? []).filter(
    (p) => !(p.kind === "custom" && p.name === OIDC_PROVIDER.name),
  )
  providers.push(OIDC_PROVIDER)

  const put = await fetch(`${STORYTELLER}/api/v2/settings`, {
    method: "PUT",
    headers,
    body: JSON.stringify({ ...settings, authProviders: providers }),
  })
  if (!put.ok) throw new Error(`PUT settings failed: ${put.status} ${await put.text()}`)
  log("Keycloak configured as an OIDC provider")
}

async function verify(token) {
  const auth = { Authorization: `Bearer ${token}` }

  const validate = await fetch(`${STORYTELLER}/api/v2/validate`, { headers: auth })
  log(`GET /api/v2/validate -> ${validate.status}`)

  const books = await fetch(`${STORYTELLER}/api/v2/books`, { headers: auth })
  const list = books.ok ? await books.json() : []
  log(`GET /api/v2/books -> ${books.status} (${Array.isArray(list) ? list.length : "?"} books)`)

  // The device-authorization grant is what tvOS signs in with.
  const start = await fetch(`${STORYTELLER}/api/v2/device/start`, { method: "POST" })
  const device = await start.json()
  log(`POST /api/v2/device/start -> ${start.status}`)
  log(`  user_code=${device.user_code} interval=${device.interval}s expires_in=${device.expires_in}s`)
  log(`  verification_uri=${device.verification_uri}`)

  // Confirm the login page actually renders the provider button.
  const login = await fetch(`${STORYTELLER}/login`)
  const html = await login.text()
  log(`login page advertises Keycloak: ${/keycloak/i.test(html)}`)
}

async function main() {
  await waitForHealthy("storyteller", `${STORYTELLER}/api/health`, (r) => r.ok)
  await waitForHealthy(
    "keycloak",
    `${KEYCLOAK}/realms/issa/.well-known/openid-configuration`,
    (r) => r.ok,
  )
  log("both services healthy")

  if (await isInitialised()) log("storyteller already initialised, skipping /init")
  else await runInitScreen()

  const token = await getToken()
  log("obtained admin bearer token")

  await configureOIDC(token)
  await verify(token)

  console.log("\n" + JSON.stringify({ storyteller: STORYTELLER, keycloak: KEYCLOAK, adminToken: token }, null, 2))
}

main().catch((e) => { console.error("[setup] FAILED:", e.message); process.exit(1) })
