# Privacy Policy — Issa Reader for Android

**Effective 25 October 2026.**

## The short version

**Issa Reader sends no data to its developer. There is no account to create, no
analytics, no crash reporting, no advertising, and no tracking of any kind.**

The app is a client for [Storyteller](https://storyteller-platform.dev/), a
server you or somebody you know runs. Your books, your reading position and your
sign-in all travel between your device and *that* server. The developer of Issa
Reader operates no server, receives no copy of any of it, and has no technical
means of obtaining it.

Issa Reader can also open EPUB books you choose from your own files, with no
server at all. Those books, and your place in them, stay on your device.

If you turn on "Ask AI about this book", Google's ML Kit library, which runs the
on-device model that answers, sends Google diagnostics about its own use. It
never sends your questions, the answers or your books. It is off unless you
turn it on.

The rest of this document says exactly what that means, because Google Play's
[User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311)
requires a policy to identify what is collected, name every third party that
receives data, and explain retention and deletion. All three are answered below.

## Three parties, and which is which

Confusing these is the single easiest mistake to make about an app of this shape,
so they are named up front.

| | |
| --- | --- |
| **Issa Reader** (this app) | Software that runs on your Android device. Published by the developer named at the end of this policy. Collects nothing. |
| **Your Storyteller server** | A computer you or somebody you know operates, at an address you type into the app. It holds your library and your reading position. **It is not operated by the developer of Issa Reader.** |
| **Google** | Distributes the app through Google Play, and provides system features the app uses. Google's own privacy policy governs anything Google receives. |

This policy covers the first only. What your server does with your data is
governed by whoever runs it — which, for most people using Issa Reader, is
themselves.

## What the app collects

**Nothing is collected by, transmitted to, or accessible by the developer.**

There is no telemetry, no usage measurement, no identifier for advertisers, no
fingerprinting, no attribution SDK, and no crash reporting service. The app
contains these third-party software libraries:

- Google's [AndroidX](https://developer.android.com/jetpack/androidx) libraries,
  including Media3, which plays audio, and SQLite, which stores data in a
  database file on your own device. They perform no networking of their own.
- [OkHttp](https://square.github.io/okhttp/), which carries the app's requests to
  your server and to no one else.
- Google's [ML Kit](https://developers.google.com/ml-kit), used only by "Ask AI
  about this book", and not started at all until you turn that feature on. What
  it sends Google is described below.

Because nothing is collected, there is nothing for the developer to sell, share,
disclose, retain, or lose.

## What stays on your device

The app stores the following locally. None of it leaves your device except as
described in the next section.

- **A sign-in token for your server**, encrypted with a key held in the Android
  Keystore. This is a credential for your server, not an account with the
  developer.
- **The address of your server**, as you typed it.
- **A cached copy of your library** — titles, authors, cover images, chapters and
  reading progress — in a local database, so the app works offline.
- **Books and audio you download**, stored in the app's own storage and
  deliberately excluded from Android's backup to your Google account so that a
  large audiobook library does not consume your Google storage.
- **Your reading preferences** — typeface, text size, page colour, playback speed
  and control mappings.
- **A small snapshot for the home-screen widget** — the current book's title,
  author, chapter, progress and cover — in the app's private storage, readable
  only by Issa Reader and its own widget.
- **Recent book titles as launcher shortcuts**, so you can open a book by
  pressing and holding the app's icon. These are kept by your device's launcher,
  on your device, and are removed when you sign out.
- **A diagnostics log**, kept for six hours and then discarded, and likewise
  excluded from backup. Credentials are removed as each line is written
  rather than when the log is read, so a token never reaches the file at all.
  This log stays on your device unless you deliberately export and send it (see
  below).
- **A text index of a book you ask questions about** — one small database per
  book, holding that book's own words so the app can search what you have
  already read. It is built on your device the first time you ask a question
  about that book, is excluded from backup, and is deleted when you delete the
  download, remove a book you added from your files, or sign out (books from
  your server). Your questions and the answers are never written down: they
  exist while the sheet is open and are gone when you close it.
- **Books you add from your files** — a copy of each EPUB you choose, its cover
  and any narration extracted from it, kept in the app's own storage and
  excluded from backup (the original stays where you chose it from). Your
  reading position, highlights and bookmarks for these books are kept in the
  app's local database, which is backed up with the app's preferences. Removing
  a book deletes the copy, its position and its highlights; the original file is
  not touched. Signing out of a server does not remove them.

Uninstalling the app deletes all of the above.

## What the app sends, and to whom

Exactly two destinations. There are no others.

**1. The Storyteller server you configured.** The app sends your sign-in, and
thereafter an authentication token, in order to list your library, download books
and audio, and record how far through a book you are. It contacts no server other
than the address you enter. What that server logs or retains is determined by its
operator and by the Storyteller software, not by this app.

**2. Google, only if you turn on "Ask AI about this book".** The model that
answers runs on your device, through Google's ML Kit library, and ML Kit reports
diagnostics about its own use to Google. According to Google's
[ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure),
these are device information (manufacturer, model, OS version and build, available
ML hardware), the app's package name and version, device and per-installation
identifiers, performance metrics such as latency, the API's configuration, the
size of its input and output, the feature's version, event types and error codes.
Google uses them for diagnostics and usage analytics, sends them over HTTPS, and
says it does not pass them to third parties. They do not include your questions,
the answers or your books, and the developer receives none of it. Until you turn
the feature on, the app does not start ML Kit at all, not even to check whether
your device can run the model. If the model is not yet on your device, turning
the feature on asks Android to download it from Google. This is governed by
[Google's Privacy Policy](https://policies.google.com/privacy), and stops when
you turn the feature off.

**Books you add from your files are never sent anywhere** — not to your server,
not to the widget or the launcher's shortcuts. They are read from the copy on
your device, and nothing about them leaves it.

**"Ask AI about this book" sends your questions nowhere.** It is answered by
Gemini Nano, the on-device model behind Android's AICore, running on the device
in your hand. Your question, and the excerpts from your own book that it is
answered from, are processed there and sent to no one: not to the developer, not
to Google, and not to your server. The feature is off unless you turn it on in
Settings, and it needs a device that can run Gemini Nano; where the hardware
cannot run the model, the feature is simply not offered rather than being
answered somewhere else.

**If you choose to share a diagnostics log**, the export goes wherever *you* send
it — mail, messages, a file. Credentials are redacted before they are written, but
the log does describe your activity in the app and may contain your server's
address and book titles. Read it before sending it to anyone, including the
developer.

## Third parties

Google Play's policy requires that any third party receiving user data offer
equivalent protection. **The only third party that receives anything from this
app is Google, and only the ML Kit diagnostics described above, once you turn on
"Ask AI about this book".** Google's own privacy policy governs them. For
completeness:

- **AndroidX and OkHttp** — libraries that run on your device. OkHttp talks only
  to your server; the others send nothing.
- **Google** — distributes the app and provides the Keystore, the backup
  service, the launcher's shortcuts, the widget system, Android Auto, and ML Kit
  with the on-device model. Governed by Google's own privacy policy.
- **Your server operator** — receives the data described above because you
  directed the app to talk to them. If that is you, you are your own operator.
- **The Storyteller project** — publishes the server software under the MIT
  licence. It is a separate project. Installing or running it is not this app's
  doing, and the Storyteller project receives nothing from this app.

No data is sold or shared for advertising or any other purpose. Issa Reader does
not engage in "sharing" or "sale" as those terms are defined by the California
Consumer Privacy Act, and does not track users across apps or websites.

## Retention and deletion

**By the developer:** nothing is retained, because nothing is received. There is
no database to delete you from and no request to make.

**On your device:** everything listed above is retained until you remove it. You
can:

- sign out in **Settings**, which discards the stored token and, at your option,
  the books you have downloaded;
- delete individual downloads under **Downloads & storage**;
- remove a book you added from your files under **On this phone**;
- uninstall the app, which removes all of its storage — token, cache, downloads,
  preferences, widget snapshot and log;
- the diagnostics log discards itself after six hours regardless.

**At Google:** the ML Kit diagnostics are kept by Google under its own
practices. The developer holds none of them and cannot delete them; turning
"Ask AI about this book" off stops any more being sent.

**On your server:** deleting your account or your data there is a matter for its
operator and for Storyteller's own controls. The developer of Issa Reader cannot
reach it.

**Withdrawing consent** is therefore simply turning Ask off, signing out or
uninstalling the app; there is no separate consent held by the developer to
withdraw.

## Your rights under GDPR, UK GDPR and CCPA

If you are in the European Economic Area, the United Kingdom, California or a
jurisdiction with comparable law, you have rights of access, correction, erasure,
portability and objection over personal data held about you.

The developer of Issa Reader is **not a data controller or data processor of any
personal data** in connection with this app, holding none. Those rights are
therefore exercised against the operator of the Storyteller server you use — which
is very often yourself. If somebody else runs your server, direct your request to
them. For the ML Kit diagnostics, Google is the controller, and requests go to
Google.

## Children

Issa Reader is not directed at children and knowingly collects no information
from anyone, of any age. It contains no advertising, no in-app purchases, no
social features and no messaging. The books shown are whatever the server you
connect to provides; the app itself supplies none.

## Security

Your sign-in token is encrypted with a key held in the Android Keystore rather
than kept in ordinary app storage. Network requests to your server use HTTPS
wherever your server offers it; if you deliberately enter an `http://` address
for a server on your own network, the app honours that choice, and that traffic
is unencrypted. Data on your device is protected by your screen lock and
Android's file-based encryption.

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
