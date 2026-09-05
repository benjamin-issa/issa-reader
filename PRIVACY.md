# Privacy Policy — Issa Reader

**Effective 5 September 2026.**

## The short version

**Issa Reader sends no data to its developer. There is no account to create, no
analytics, no crash reporting, no advertising, and no tracking of any kind.**

The app is a client for [Storyteller](https://storyteller-platform.dev/), a
server you or somebody you know runs. Your books, your reading position and your
sign-in all travel between your device and *that* server. The developer of Issa
Reader operates no server, receives no copy of any of it, and has no technical
means of obtaining it.

The rest of this document says exactly what that means, because Apple's
[App Store Review Guideline 5.1.1(i)](https://developer.apple.com/app-store/review/guidelines/#privacy)
requires a policy to identify what is collected, name every third party that
receives data, and explain retention and deletion. All three are answered below.

## Three parties, and which is which

Confusing these is the single easiest mistake to make about an app of this shape,
so they are named up front.

| | |
| --- | --- |
| **Issa Reader** (this app) | Software that runs on your Apple devices. Published by the developer named at the end of this policy. Collects nothing. |
| **Your Storyteller server** | A computer you or somebody you know operates, at an address you type into the app. It holds your library and your reading position. **It is not operated by the developer of Issa Reader.** |
| **Apple** | Distributes the app, and provides system features the app uses. Apple's own privacy policy governs anything Apple receives. |

This policy covers the first only. What your server does with your data is
governed by whoever runs it — which, for most people using Issa Reader, is
themselves.

## What the app collects

**Nothing is collected by, transmitted to, or accessible by the developer.**

There is no telemetry, no usage measurement, no identifier for advertisers, no
fingerprinting, no attribution SDK, and no crash reporting service. The app
contains one third-party software library,
[GRDB](https://github.com/groue/GRDB.swift), which stores data in a database file
on your own device and performs no networking whatsoever.

Because nothing is collected, there is nothing for the developer to sell, share,
disclose, retain, or lose.

## What stays on your device

The app stores the following locally. None of it leaves your device except as
described in the next section.

- **A sign-in token for your server**, held in the iOS/macOS Keychain. This is a
  credential for your server, not an account with the developer.
- **The address of your server**, as you typed it.
- **A cached copy of your library** — titles, authors, cover images, chapters and
  reading progress — in a local database, so the app works offline.
- **Books and audio you download**, stored in the app's own container and
  deliberately excluded from iCloud backup so that a large audiobook library does
  not consume your iCloud storage.
- **Your reading preferences** — typeface, text size, page colour, playback speed
  and control mappings.
- **A small snapshot for the home-screen widget** — the current book's title,
  author, chapter, progress and cover — in a shared App Group container readable
  only by Issa Reader and its own widget.
- **Book titles and authors in the on-device Spotlight index**, so you can find a
  book from system search. This index is local to your device and is not
  submitted to Apple for public search.
- **A diagnostics log**, kept for six hours and then discarded, and likewise
  excluded from iCloud backup. Credentials are removed as each line is written
  rather than when the log is read, so a token never reaches the file at all.
  This log stays on your device unless you deliberately export and send it (see
  below).

Deleting the app deletes all of the above.

## What the app sends, and to whom

Exactly two destinations. There are no others.

**1. The Storyteller server you configured.** The app sends your sign-in, and
thereafter an authentication token, in order to list your library, download books
and audio, and record how far through a book you are. It contacts no server other
than the address you enter. What that server logs or retains is determined by its
operator and by the Storyteller software, not by this app.

**2. Apple's Handoff, between your own devices.** If you have Handoff enabled in
system settings, the app publishes the book and position you are currently
reading so you can continue on another of your Apple devices. This is carried by
Apple between devices signed into your Apple Account, is governed by
[Apple's Privacy Policy](https://www.apple.com/legal/privacy/), and can be turned
off in system settings. The developer receives nothing from it.

**If you choose to share a diagnostics log**, the export goes wherever *you* send
it — mail, messages, a file. Credentials are redacted before they are written, but
the log does describe your activity in the app and may contain your server's
address and book titles. Read it before sending it to anyone, including the
developer.

## Third parties

Apple's guideline requires that any third party receiving user data offer
equivalent protection. **No third party receives user data from this app**, so
the requirement is satisfied by there being nothing to pass on. For completeness:

- **GRDB** — a database library. Runs entirely on your device; sends nothing.
- **Apple** — distributes the app and provides Handoff, Keychain, Spotlight and
  the widget system. Governed by Apple's own privacy policy.
- **Your server operator** — receives the data described above because you
  directed the app to talk to them. If that is you, you are your own operator.
- **The Storyteller project** — publishes the server software under the MIT
  licence. It is a separate project. Installing or running it is not this app's
  doing, and the Storyteller project receives nothing from this app.

No data is sold or shared for advertising or any other purpose, because none is
gathered. Issa Reader does not engage in "sharing" or "sale" as those terms are
defined by the California Consumer Privacy Act, and does not track users across
apps or websites as defined by Apple's App Tracking Transparency.

## Retention and deletion

**By the developer:** nothing is retained, because nothing is received. There is
no database to delete you from and no request to make.

**On your device:** everything listed above is retained until you remove it. You
can:

- sign out in **Settings**, which discards the stored token and, at your option,
  the books you have downloaded;
- delete individual downloads under **Downloads & storage**;
- delete the app, which removes the entire container — token, cache, downloads,
  preferences, widget snapshot and log;
- the diagnostics log discards itself after six hours regardless.

**On your server:** deleting your account or your data there is a matter for its
operator and for Storyteller's own controls. The developer of Issa Reader cannot
reach it.

**Withdrawing consent** is therefore simply signing out or deleting the app; there
is no separate consent held by the developer to withdraw.

## Your rights under GDPR, UK GDPR and CCPA

If you are in the European Economic Area, the United Kingdom, California or a
jurisdiction with comparable law, you have rights of access, correction, erasure,
portability and objection over personal data held about you.

The developer of Issa Reader is **not a data controller or data processor of any
personal data** in connection with this app, holding none. Those rights are
therefore exercised against the operator of the Storyteller server you use — which
is very often yourself. If somebody else runs your server, direct your request to
them.

## Children

Issa Reader is not directed at children and knowingly collects no information
from anyone, of any age. It contains no advertising, no in-app purchases, no
social features and no messaging. The books shown are whatever the server you
connect to provides; the app itself supplies none.

## Security

Your sign-in token is stored in the system Keychain rather than in ordinary app
storage. Network requests to your server use HTTPS wherever your server offers it;
if you deliberately enter an `http://` address for a server on your own network,
the app honours that choice, and that traffic is unencrypted. Data on your device
is protected by your device passcode and Apple's file protection.

No system is perfectly secure, and no assurance of absolute security is given.

## Disclaimer

Issa Reader is free, open-source software published under the MIT licence and
provided **"as is", without warranty of any kind**, as set out in the
[LICENSE](LICENSE) file. To the fullest extent permitted by law, the developer
accepts no liability for the practices, security, availability or content of any
Storyteller server, for the Storyteller software itself, or for any loss arising
from use of this app.

Nothing in this policy limits any right you have that cannot lawfully be limited.

## Changes

This policy will be updated if the app's behaviour changes. The effective date at
the top will change with it, and the full revision history is public in the
repository this file lives in. Material changes will be noted in the release
notes of the version that introduces them.

## Contact

Questions about this policy, or about the app's handling of data, can be sent to:

**issa-reader@protonmail.com**

Issa Reader is developed by **Benjamin Issa** in the **United States**.

Please note that a question about the contents of a particular library, or a
request to access or delete data held there, has to go to whoever runs that
Storyteller server — see *Your rights* above. The developer has no access to any
server and cannot act on such a request.

---

*This document describes the behaviour of Issa Reader as published. It is not
legal advice. If you need certainty about your obligations in a particular
jurisdiction, have it reviewed by a lawyer.*
