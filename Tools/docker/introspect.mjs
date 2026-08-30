import { chromium } from "playwright"
const b = await chromium.launch()
const p = await b.newPage()
await p.goto("http://localhost:8001/login", { waitUntil: "networkidle" })
const info = await p.evaluate(() => ({
  inputs: [...document.querySelectorAll("input")].map(i => ({
    type: i.type, name: i.name, id: i.id, placeholder: i.placeholder, ariaLabel: i.getAttribute("aria-label"),
  })),
  buttons: [...document.querySelectorAll("button")].map(x => ({
    text: x.innerText.trim().slice(0, 40), type: x.type,
  })),
  labels: [...document.querySelectorAll("label")].map(l => l.innerText.trim().slice(0, 40)),
  links: [...document.querySelectorAll("a")].map(a => ({ text: a.innerText.trim().slice(0,40), href: a.getAttribute("href") })).slice(0,10),
}))
console.log(JSON.stringify(info, null, 2))
await p.screenshot({ path: "/tmp/login.png" })
await b.close()
