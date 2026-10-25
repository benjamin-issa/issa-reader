# Privacy Policy — Issa Reader for Android

**Effective 25 October 2026.**

This policy covers the Android app. The apps for iPhone, iPad, Mac and Apple TV
have their own, in [PRIVACY.md](PRIVACY.md).

## The short version

**Issa Reader sends no data to its developer. There is no account to create, no
analytics, no crash reporting, no advertising, and no tracking of any kind.**

The app is a client for [Storyteller](https://storyteller-platform.dev/), a
server you or somebody you know runs. Your books, your reading position and your
sign-in all travel between your phone and *that* server. The developer of Issa
Reader operates no server, receives no copy of any of it, and has no technical
means of obtaining it.

Issa Reader can also open EPUB books you choose from your own files, with no
server at all. Those books, and your place in them, stay on your phone.

One optional feature involves Google. "Ask AI about this book" is answered on
your phone by Gemini Nano, and the Google library that runs it, ML Kit, reports
diagnostics to Google once you turn the feature on. It never reports your
questions, the answers or your books. With Ask off, which is how the app
starts, the app never uses ML Kit at all. The details are under *What the app
sends*.

The rest of this document says exactly what that means, because Google Play's
[User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311)
requires a policy to identify what is collected, name every third party that
receives data, and explain retention and deletion. All three are answered below.

## Three parties, and which is which

Confusing these is the single easiest mistake to make about an app of this shape,
so they are named up front.

| | |
| --- | --- |
| **Issa Reader** (this app) | Software that runs on your Android phone. Published by the developer named at the end of this policy. Collects nothing. |
| **Your Storyteller server** | A computer you or somebody you know operates, at an address you type into the app. It holds your library and your reading position. **It is not operated by the developer of Issa Reader.** |
| **Google** | Makes Android and distributes the app through Google Play. It provides the system features the app uses, and, if you turn Ask on, the on-device model and the library that runs it. Google's own privacy policy governs anything Google receives. |

This policy covers the first only. What your server does with your data is
governed by whoever runs it — which, for most people using Issa Reader, is
themselves.

## What the app collects

**Nothing is collected by, transmitted to, or accessible by the developer.**

There is no telemetry, no usage measurement, no advertising identifier, no
fingerprinting, no attribution SDK, and no crash reporting service.

The app is built from:

- Google's AndroidX libraries, including Media3, which plays audio, and a bundled
  SQLite database;
- [OkHttp](https://square.github.io/okhttp/), which carries the app's requests to
  your server and nowhere else;
- Google's ML Kit, used only by "Ask AI about this book".

None of them sends anything on its own except ML Kit, and ML Kit does so only
once you turn Ask on. Until then the app does not start it.

Because nothing is collected, there is nothing for the developer to sell, share,
disclose, retain, or lose.

## What stays on your phone

The app stores the following on your phone. None of it leaves your phone except
as described in the next section.

- **A sign-in token for your server.** It is a credential for your server, not
  an account with the developer. It is encrypted with a key held in the Android
  Keystore, which never leaves it, and is never backed up.
- **The address of your server**, as you typed it.
- **A cached copy of your library** — titles, authors, cover images, chapters and
  reading progress — in a local database, so the app works offline.
- **Books and audio you download**, stored in the app's own storage. They are
  never backed up, so that a large audiobook library does not fill your backup
  storage.
- **Your reading preferences** — typeface, text size, page colour, playback speed
  and control mappings.
- **A small snapshot for the home-screen widget** — the current book's title,
  author, chapter, progress and cover — in the app's private storage, which its
  widget reads.
- **Your recent books' titles as launcher shortcuts.** Pressing and holding the
  app's icon offers them, beside a "Continue reading" shortcut. Your phone's
  launcher keeps them on your phone, and some launchers also offer them in their
  own on-device search. They are removed when you sign out.
- **A diagnostics log**, kept for six hours and then discarded, and never backed
  up. Credentials are removed as each line is written rather than when the log
  is read, so a token never reaches the file at all. This log stays on your
  phone unless you deliberately export and send it (see below).
- **A text index of a book you ask questions about** — one small database per
  book, holding that book's own words so the app can search what you have
  already read. It is built on your phone the first time you ask a question
  about that book and is never backed up. It is deleted when you delete the
  download, remove a book you added from your files, or sign out (for books
  from your server). Your questions and the answers are never written down:
  they exist while the sheet is open and are gone when you close it. A question
  you leave mid-answer is held in memory until you come back to the app, and is
  gone if the app is closed.
- **Books you add from your files** — a copy of each EPUB you choose, its cover
  and any narration extracted from it, in the app's own storage and never backed
  up; the original stays where you chose it from. Your reading position,
  highlights and bookmarks for these books are kept in the app's local
  database, which is backed up with the rest of it (see *Backups*). Removing a
  book deletes the copy, its position and its highlights; the original file is
  not touched. Signing out of a server does not remove them.

**Backups.** The app lets Android back up only two things: its preferences and
its library database. They go to your Google account backup, or to a new phone
when you transfer to one, as your phone's backup settings allow, and Android
encrypts that backup with your screen lock where the phone supports it. The
sign-in token, downloads, books you added from your files, Ask indexes and the
diagnostics log are never backed up.

Uninstalling the app deletes all of the above from your phone.

## What the app sends, and to whom

**1. The Storyteller server you configured.** The app sends your sign-in, and
thereafter an authentication token, in order to list your library, download books
and audio, and record how far through a book you are. It contacts no server other
than the address you enter. What that server logs or retains is determined by its
operator and by the Storyteller software, not by this app.

Signing in through the browser opens your server's own sign-in page in a Chrome
Auth Tab, and the browser keeps that page's cookies as it would for any site.
That page, and any identity provider it sends you to, are your server's, not
this app's. Signing in with a pairing code involves no browser on the phone.

**2. Google's ML Kit, only if you turn on "Ask AI about this book".** Ask is off
unless you turn it on. Until you do, the app does not start ML Kit or call it in
any way, not even to check whether your phone could run it. Once you turn it on:

- **Your questions and your book stay on your phone.** They are answered by
  Gemini Nano, Google's on-device model, running in Android's AICore system
  service. Google states that ML Kit's GenAI features process "input, inference,
  and output data" locally. Neither your question, nor the excerpts it is
  answered from, nor the answer goes to the developer, to Google or to your
  server.
- **ML Kit reports diagnostics to Google**, as all ML Kit features do. According
  to Google's
  [ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure),
  these are:
  - device information (manufacturer, model, OS version and build, available ML
    hardware);
  - the app's package name and version;
  - device and per-installation identifiers;
  - performance metrics such as latency;
  - the API's configuration, the size of its input and output, and the
    feature's version;
  - event types and error codes.

  Google uses these for diagnostics and usage analytics, sends them over HTTPS,
  and says it does not pass them to third parties. They do not include the text
  of your questions, the answers or your books. The developer receives none of
  it. Turning Ask off stops the app from using ML Kit again.
- **If Gemini Nano is not yet on your phone**, turning Ask on asks Android to
  download it. AICore downloads the model from Google, as it would for any app
  that uses it.
- **If you allow notifications**, the app can tell you an answer is ready while
  you are in another app. On the lock screen that notification says only that;
  it never shows your question or the answer.

A phone that cannot run Gemini Nano says so and does not offer the feature. Your
question is never answered somewhere else instead. The
[Google Privacy Policy](https://policies.google.com/privacy) governs what Google
receives.

**3. In the car, through Android Auto.** Android Auto shows the titles,
authors and covers of your server's books, your progress and the chapter you are
on. It runs on your phone and shows it on the car's screen. If you search by
voice ("play … on Issa Reader"), Google Assistant hears the request under
Google's own privacy policy and passes the app only the words of the search,
which the app looks up in your library on your phone.

**Books you add from your files are never sent anywhere** — not to your server,
not to the widget, the launcher's shortcuts or the car. They are read from the
copy on your phone, and nothing about them leaves it. Asking about one involves
ML Kit exactly as described above, and so sends no part of the book.

**If you choose to share a diagnostics log**, the export goes wherever *you* send
it — email, a message, a file. Credentials are redacted before they are written,
but the log does describe your activity in the app and may contain your server's
address and book titles. Read it before sending it to anyone, including the
developer.

There are no other destinations.

## Third parties

Google Play's policy requires that any third party receiving user data offer
equivalent protection. The app sends data to one third party, and only if you
turn on Ask: the ML Kit diagnostics described above go to Google, whose privacy
policy and published ML Kit commitments govern them. For completeness:

- **AndroidX, Media3 and OkHttp** — libraries that run on your phone. OkHttp
  talks only to your server; the others send nothing.
- **Google ML Kit and AICore** (only with Ask on) — run Gemini Nano on your phone
  and send Google the diagnostics described above, never your questions or your
  books.
- **Google** — distributes the app through Google Play and provides the
  Keystore, the backup service, the launcher's shortcuts, Android Auto, Google
  Assistant and the Chrome Auth Tab used to sign in. Governed by Google's own
  privacy policy.
- **Your server operator** — receives the data described above because you
  directed the app to talk to them. If that is you, you are your own operator.
- **The Storyteller project** — publishes the server software under the MIT
  licence. It is a separate project. Installing or running it is not this app's
  doing, and the Storyteller project receives nothing from this app.

No data is sold or shared for advertising or any other purpose. Issa Reader does
not engage in "sharing" or "sale" as the California Consumer Privacy Act defines
those terms, contains no advertising identifier, and does not track you across
apps or websites.

## Retention and deletion

**By the developer:** nothing is retained, because nothing is received. There is
no database to delete you from and no request to make.

**On your phone:** everything listed above is retained until you remove it. You
can:

- sign out in **Settings**, which discards the stored token and, at your option,
  the books you have downloaded;
- delete individual downloads under **Downloads & storage**;
- remove a book you added from your files under **On this phone**;
- uninstall the app, which removes all of its storage — token, cache, downloads,
  preferences, widget snapshot and log;
- the diagnostics log discards itself after six hours regardless.

**At Google, for Ask:** ML Kit's diagnostics are kept by Google under its own
retention practices; the developer holds none of them and cannot delete them.
Turning Ask off stops any more from being sent.

**On your server:** deleting your account or your data there is a matter for its
operator and for Storyteller's own controls. The developer of Issa Reader cannot
reach it.

**Withdrawing consent** is therefore simply turning Ask off, signing out or
uninstalling the app. There is no separate consent held by the developer to
withdraw.

## Your rights under GDPR, UK GDPR and CCPA

If you are in the European Economic Area, the United Kingdom, California or a
jurisdiction with comparable law, you have rights of access, correction, erasure,
portability and objection over personal data held about you.

The developer of Issa Reader is **not a data controller or data processor of any
personal data** in connection with this app, holding none. Those rights are
therefore exercised against the operator of the Storyteller server you use, which
is very often yourself. If somebody else runs your server, direct your request to
them. For the diagnostics ML Kit sends Google, Google is the controller, and
requests go to Google.

## Children

Issa Reader is not directed at children and knowingly collects no information
from anyone, of any age. It contains no advertising, no in-app purchases, no
social features and no messaging. The books shown are whatever the server you
connect to provides; the app itself supplies none.

## Security

Your sign-in token is encrypted with a key that never leaves the Android
Keystore, rather than kept in ordinary app storage. Network requests to your
server use HTTPS wherever your server offers it. If you deliberately enter an
`http://` address for a server on your own network, the app honours that choice,
and that traffic is unencrypted. Data on your phone is protected by your screen
lock and Android's file-based encryption.

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

*This document describes the behaviour of Issa Reader for Android as published.
It is not legal advice. If you need certainty about your obligations in a
particular jurisdiction, have it reviewed by a lawyer.*
