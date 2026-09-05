// Exercises Storyteller's RFC 8628 device authorization grant end to end,
// approving in a real browser the way a phone would.
//
// This is the flow tvOS signs in with, and it is also how iOS/macOS sign in
// when the app-token path is unavailable.

import { chromium } from "playwright"

const STORYTELLER = process.env.STORYTELLER_URL ?? "http://localhost:8001"
const ADMIN = { username: "admin", password: "issareader" }
// The Keycloak realm user, used to prove the third-party OIDC path.
const OIDC_USER = { username: "reader", password: "reader" }
// "password" signs in with local credentials; "oidc" goes out to Keycloak.
const MODE = process.env.MODE ?? "password"
const log = (...a) => console.log("[device]", ...a)

async function start() {
  const res = await fetch(`${STORYTELLER}/api/v2/device/start`, {
    method: "POST",
    // The server derives the verification URLs from Origin when webUrl is unset,
    // and rewrites a localhost origin to what it believes its LAN address is.
    headers: { Origin: STORYTELLER },
  })
  const json = await res.json()
  log("start ->", res.status)
  log("  user_code:", json.user_code)
  log("  verification_uri_complete:", json.verification_uri_complete)
  log("  interval:", json.interval, "expires_in:", json.expires_in)
  return json
}

async function poll(deviceCode) {
  const res = await fetch(`${STORYTELLER}/api/v2/device/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_code: deviceCode }),
  })
  return { status: res.status, body: await res.json() }
}

async function approveInBrowser(url) {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  try {
    await page.goto(`${STORYTELLER}/login`, { waitUntil: "domcontentloaded" })

    if (MODE === "oidc") {
      // The login page renders one submit button per configured provider BEFORE
      // the credentials form, so target it by its label, never by type.
      await page.click('button:has-text("Continue with Keycloak")')
      await page.waitForURL(/\/realms\/issa\/protocol\/openid-connect\/auth/, { timeout: 30_000 })
      log("redirected to Keycloak")
      await page.fill("#username", OIDC_USER.username)
      await page.fill("#password", OIDC_USER.password)
      await page.click('input[type="submit"], button[type="submit"]')
    } else {
      await page.fill('input[name="usernameOrEmail"]', ADMIN.username)
      await page.fill('input[name="password"]', ADMIN.password)
      await page.click('button:has-text("Login")')
    }

    await page.waitForURL((u) => !u.pathname.startsWith("/login") && !u.href.includes("/realms/"), { timeout: 45_000 })
    log(`signed in via ${MODE}; landed on ${page.url()}`)

    await page.goto(url, { waitUntil: "domcontentloaded" })
    await page.waitForTimeout(500)
    const heading = await page.locator("h1,h2,h3").first().textContent()
    log("approval page:", heading?.trim())

    // The page offers "Approve device" (the manual user-code form), "Deny", and
    // "Approve" (this pre-identified request). Match the exact label — a loose
    // selector picks up the manual-entry form or a provider button instead.
    await page.getByRole("button", { name: "Approve", exact: true }).click()
    await page.waitForTimeout(1500)
    log("after approval:", (await page.textContent("body")).replace(/\s+/g, " ").trim().slice(0, 160))
    await page.screenshot({ path: "/tmp/device-approval.png" })
  } finally {
    await browser.close()
  }
}

async function main() {
  const device = await start()

  // Before approval the server must say authorization_pending.
  const pending = await poll(device.device_code)
  log(`poll before approval -> ${pending.status} ${JSON.stringify(pending.body)}`)

  // Polling again immediately exercises the rate limiter. Note this server
  // returns slow_down for ANY poll inside the interval and does not advance
  // lastPolledAt, so a client must NOT ratchet its interval upward per RFC 8628.
  const tooSoon = await poll(device.device_code)
  log(`immediate re-poll -> ${tooSoon.status} ${JSON.stringify(tooSoon.body)}`)

  await approveInBrowser(device.verification_uri_complete)

  // Poll to completion, honouring the interval.
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, device.interval * 1000))
    const { status, body } = await poll(device.device_code)
    if (status === 200 && body.access_token) {
      log("GRANTED. token:", body.access_token.slice(0, 8) + "…")
      const me = await fetch(`${STORYTELLER}/api/v2/user`, {
        headers: { Authorization: `Bearer ${body.access_token}` },
      })
      log(`token works: GET /api/v2/user -> ${me.status}`, (await me.json()).username)

      // The grant is single-use: a second exchange must fail.
      const replay = await poll(device.device_code)
      log(`replay of consumed device_code -> ${replay.status} ${JSON.stringify(replay.body)}`)
      return
    }
    log(`poll -> ${status} ${JSON.stringify(body)}`)
    if (body.error && !["authorization_pending", "slow_down"].includes(body.error)) {
      throw new Error(`terminal error: ${body.error}`)
    }
  }
  throw new Error("timed out waiting for approval")
}

main().catch((e) => { console.error("[device] FAILED:", e.message); process.exit(1) })
