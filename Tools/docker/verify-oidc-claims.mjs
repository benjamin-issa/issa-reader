// Checks that the Keycloak realm issues the claims Storyteller's OIDC sign-in
// is given: email_verified, true, in the ID token, the access token and
// userinfo alike, and the reader's group in `groups`.
//
// A realm file that lists its own client scopes gets none of Keycloak's
// defaults, so every claim comes from a mapper written by hand in
// keycloak/realm-issa.json — and a mapper of the wrong kind fails silently:
// the email_verified mapper was once an attribute mapper, issued no claim
// at all, and nothing noticed because neither pinned Storyteller reads it.
// This is the check that would have. Plain fetch, no browser: a password
// grant as the fixture user is enough to see what a sign-in would carry.
//
// Keycloak only imports a realm it does not already have, so an edited realm
// file needs the container recreated before this can see it, and only that
// container: without --no-deps, Compose run from a worktree recreates
// Storyteller as well, on the worktree's empty data directory (README).
//
//   docker compose up -d --no-deps --force-recreate keycloak
//   PUBLIC_HOST=$(ipconfig getifaddr en0) node verify-oidc-claims.mjs

const HOST = process.env.PUBLIC_HOST ?? "localhost"
const KEYCLOAK = process.env.KEYCLOAK_URL ?? `http://${HOST}:8080`
const REALM = `${KEYCLOAK}/realms/issa/protocol/openid-connect`
// The realm's own fixtures: the client Storyteller is configured with, and
// the user approve-device.mjs signs in as in OIDC mode.
const CLIENT = { id: "storyteller", secret: "storyteller-dev-secret" }
const OIDC_USER = { username: "reader", password: "reader" }
// What Storyteller asks for, so the grant is shaped like a real sign-in.
const SCOPE = "openid profile email groups"
// The group setup.mjs maps to library permissions, and the one the realm
// puts `reader` in.
const GROUP = "librarians"
const log = (...a) => console.log("[claims]", ...a)

/** The payload of a JWT. Not verified: this reads what was issued, it does not trust it. */
function claimsOf(jwt) {
  const payload = jwt.split(".")[1]
  return JSON.parse(Buffer.from(payload, "base64url").toString("utf8"))
}

/** One line per source, and whether that source passes. */
function check(source, claims) {
  const verified = claims.email_verified
  const groups = Array.isArray(claims.groups) ? claims.groups : []
  const ok = verified === true && groups.includes(GROUP)
  // `JSON.stringify` so a missing claim prints as undefined and a string
  // "true" as "true" — both of which are failures, and must look different
  // from the boolean.
  log(
    `${ok ? "PASS" : "FAIL"} ${source}: email_verified=${JSON.stringify(verified)}`,
    `groups=${JSON.stringify(claims.groups)}`,
  )
  return ok
}

async function main() {
  const res = await fetch(`${REALM}/token`, {
    method: "POST",
    body: new URLSearchParams({
      grant_type: "password",
      client_id: CLIENT.id,
      client_secret: CLIENT.secret,
      username: OIDC_USER.username,
      password: OIDC_USER.password,
      scope: SCOPE,
    }),
  })
  if (!res.ok) throw new Error(`token request -> ${res.status} ${await res.text()}`)
  const tokens = await res.json()

  const info = await fetch(`${REALM}/userinfo`, {
    headers: { Authorization: `Bearer ${tokens.access_token}` },
  })
  if (!info.ok) throw new Error(`userinfo -> ${info.status} ${await info.text()}`)

  // Every source checked and printed before deciding, so a failing run says
  // which of the three is wrong rather than stopping at the first.
  const results = [
    check("id_token", claimsOf(tokens.id_token)),
    check("access_token", claimsOf(tokens.access_token)),
    check("userinfo", await info.json()),
  ]
  if (results.includes(false)) process.exit(1)
}

main().catch((e) => { console.error("[claims] FAILED:", e.message); process.exit(1) })
