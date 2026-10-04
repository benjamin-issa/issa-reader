// Approves a pending device authorization by entering its user code, the way a
// person would on their phone. Signs in through Keycloak so the whole
// third-party OIDC path is exercised.
//
//   node approve-device.mjs BS53-YLNP
//
// Prints `[approve] approved <code> (<route>)` only once the server has shown
// that it took the approval, and exits non-zero otherwise: live-check.sh
// records PASS on that line, so it must never be printed for a code the
// server refused, or one it never got to see.
//
// Storyteller has had two device pages, and this handles both, because the
// servers it is tested against include both:
//   - 2.x and 3.x up to beta.40: the code goes in and "Approve device" is
//     pressed; some versions then ask once more with "Approve".
//   - 3.x from beta.41: the code goes in and "Find request" looks it up; the
//     request found is approved with "Approve".

import { chromium } from "playwright"

const HOST = process.env.PUBLIC_HOST ?? "localhost"
const BASE = process.env.STORYTELLER_URL ?? `http://${HOST}:8001`
const MODE = process.env.MODE ?? "oidc"
const OIDC_USER = { username: "reader", password: "reader" }
const ADMIN = { username: "admin", password: "issareader" }
const userCode = process.argv[2]

// Exact labels, matched whole: "Approve" must not find "Approve device".
const LEGACY = /^\s*approve device\s*$/i
const FIND = /^\s*find request\s*$/i
const APPROVE = /^\s*approve\s*$/i
// What the page says once the approval took. Every server tested so far —
// 2.14.21, 2.14.23, beta.40 and beta.46 — says "This device is approved.
// Return to the app to finish pairing."; a code that matched nothing leaves
// the form's instructions in place (up to beta.40) or says "No pairing request
// matches that code" (beta.41 on). The refusals are checked as well, so a page
// that says both is not taken for a success.
const APPROVED = /\bdevice (is )?approved\b/i
const REFUSED = /no pairing request matches|invalid|expired|not found|could not|couldn't|unable to|denied/i

if (!userCode) { console.error("usage: node approve-device.mjs <USER-CODE>"); process.exit(1) }

const browser = await chromium.launch()
const page = await browser.newPage()
// What the page shows, not its source: `textContent` also returns the text
// of the <style> elements Storyteller's pages inline.
const bodyText = async () => ((await page.innerText("body")) ?? "").replace(/\s+/g, " ").trim()
try {
  await page.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" })
  if (MODE === "oidc") {
    // 2.x labels the button "Continue with Keycloak"; 3.x shows only the
    // provider's name beside an "Or continue with" caption.
    await page.getByRole("button", { name: /keycloak/i }).first().click()
    await page.waitForURL(/\/realms\/issa\/protocol\/openid-connect\/auth/, { timeout: 30000 })
    await page.fill("#username", OIDC_USER.username)
    await page.fill("#password", OIDC_USER.password)
    await page.click('input[type="submit"], button[type="submit"]')
  } else {
    await page.fill('input[name="usernameOrEmail"]', ADMIN.username)
    await page.fill('input[name="password"]', ADMIN.password)
    // The credentials form's own submit button, not its wording ("Login"
    // on 2.x): the provider buttons sit in forms of their own, and a label
    // is the first thing a release rewords.
    await page.locator('form:has(input[name="password"]) button[type="submit"]').first().click()
  }
  await page.waitForURL(u => !u.pathname.startsWith("/login") && !u.href.includes("/realms/"), { timeout: 45000 })
  console.log(`[approve] signed in via ${MODE}`)

  // Enter the code by hand, exactly as someone reading it off a TV would.
  await page.goto(`${BASE}/device`, { waitUntil: "domcontentloaded" })
  await page.fill('input[name="user_code"]', userCode)

  const legacy = page.getByRole("button", { name: LEGACY })
  const find = page.getByRole("button", { name: FIND })
  const approve = page.getByRole("button", { name: APPROVE })
  await legacy.or(find).first().waitFor({ timeout: 30000 })

  let route
  if (await find.count()) {
    route = "lookup"
    await find.first().click()
    // Required: a lookup that finds no request shows no Approve, and that
    // is the refusal, not something to step past.
    try {
      await approve.first().waitFor({ timeout: 30000 })
    } catch {
      throw new Error(`no request found for ${userCode}: ${(await bodyText()).slice(0, 200)}`)
    }
    await approve.first().click()
  } else {
    route = "direct page"
    await legacy.first().click()
    // Some versions confirm on a second step; others approve at once.
    try {
      await approve.first().waitFor({ timeout: 5000 })
      await approve.first().click()
    } catch { /* approved by the first button */ }
  }

  // The server's answer. The Approve button leaving is the first half; the
  // page then has to say it worked and not say it failed.
  await approve.first().waitFor({ state: "detached", timeout: 30000 })
    .catch(() => { throw new Error("the Approve button never went away") })
  await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {})
  const text = await bodyText()
  console.log(`[approve] the page says: ${text.slice(0, 200)}`)
  if (REFUSED.test(text) || !APPROVED.test(text)) {
    throw new Error(`the server did not confirm the approval of ${userCode}`)
  }
  console.log(`[approve] approved ${userCode} (${route})`)
} catch (e) {
  console.error("[approve] FAILED:", e.message)
  await page.screenshot({ path: "/tmp/approve-failure.png", fullPage: true }).catch(() => {})
  process.exitCode = 1
} finally {
  await browser.close()
}
