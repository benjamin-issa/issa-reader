// Approves a pending device authorization by entering its user code, the way a
// person would on their phone. Signs in through Keycloak so the whole
// third-party OIDC path is exercised.
//
//   node approve-device.mjs BS53-YLNP

import { chromium } from "playwright"

const HOST = process.env.PUBLIC_HOST ?? "localhost"
const BASE = process.env.STORYTELLER_URL ?? `http://${HOST}:8001`
const MODE = process.env.MODE ?? "oidc"
const OIDC_USER = { username: "reader", password: "reader" }
const ADMIN = { username: "admin", password: "issareader" }
const userCode = process.argv[2]

if (!userCode) { console.error("usage: node approve-device.mjs <USER-CODE>"); process.exit(1) }

const browser = await chromium.launch()
const page = await browser.newPage()
try {
  await page.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" })
  if (MODE === "oidc") {
    await page.click('button:has-text("Continue with Keycloak")')
    await page.waitForURL(/\/realms\/issa\/protocol\/openid-connect\/auth/, { timeout: 30000 })
    await page.fill("#username", OIDC_USER.username)
    await page.fill("#password", OIDC_USER.password)
    await page.click('input[type="submit"], button[type="submit"]')
  } else {
    await page.fill('input[name="usernameOrEmail"]', ADMIN.username)
    await page.fill('input[name="password"]', ADMIN.password)
    await page.click('button:has-text("Login")')
  }
  await page.waitForURL(u => !u.pathname.startsWith("/login") && !u.href.includes("/realms/"), { timeout: 45000 })
  console.log(`[approve] signed in via ${MODE}`)

  // Enter the code by hand, exactly as someone reading it off a TV would.
  await page.goto(`${BASE}/device`, { waitUntil: "domcontentloaded" })
  await page.fill('input[name="user_code"]', userCode)
  await page.click('button:has-text("Approve device")')
  await page.waitForTimeout(1200)

  const approve = page.getByRole("button", { name: "Approve", exact: true })
  if (await approve.count()) {
    await approve.click()
    await page.waitForTimeout(1200)
  }
  console.log(`[approve] approved ${userCode}`)
} catch (e) {
  console.error("[approve] FAILED:", e.message)
  await page.screenshot({ path: "/tmp/approve-failure.png", fullPage: true })
  process.exitCode = 1
} finally {
  await browser.close()
}
