import { chromium } from "playwright"
const BASE = process.env.STORYTELLER_URL
const b = await chromium.launch()
const p = await b.newPage()
await p.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" })
await p.fill('input[name="usernameOrEmail"]', "admin")
await p.fill('input[name="password"]', "issareader")
await p.click('button:has-text("Login")')
await p.waitForURL(u => !u.pathname.startsWith("/login"), { timeout: 30000 })
console.log("signed in at", p.url())

const start = await fetch(`${BASE}/api/v2/device/start`, { method: "POST", headers: { Origin: BASE } })
const d = await start.json()
console.log("verification_uri_complete:", d.verification_uri_complete)

await p.goto(d.verification_uri_complete, { waitUntil: "networkidle" })
const info = await p.evaluate(() => ({
  url: location.href,
  heading: document.querySelector("h1,h2,h3")?.innerText?.trim(),
  bodyText: document.body.innerText.replace(/\s+/g, " ").trim().slice(0, 400),
  buttons: [...document.querySelectorAll("button")].map(x => ({ text: x.innerText.trim().slice(0,40), type: x.type })),
  inputs: [...document.querySelectorAll("input")].map(i => ({ name: i.name, type: i.type, placeholder: i.placeholder })),
}))
console.log(JSON.stringify(info, null, 2))
await p.screenshot({ path: "/tmp/device-page.png", fullPage: true })
await b.close()
