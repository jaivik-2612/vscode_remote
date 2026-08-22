# Google Play submission runbook

Written for a **brand-new personal developer account on a Windows machine**,
starting from nothing. Signing mechanics live in
[`../SIGNING-WINDOWS.md`](../SIGNING-WINDOWS.md); listing copy and graphics
live in [`LISTING.md`](LISTING.md).

Everything here was checked against Google's live documentation on
**22 August 2026**. Play's rules move; re-read anything dated before acting
on it months from now.

---

## The shape of the timeline

The calendar, not the code, is what stands between you and a public listing.

```
register + ID verify   a few days      ─┐
device verification    a minute         │  can overlap
app entry + listing    an afternoon    ─┘
        ↓
closed test            14 days MINIMUM  ← the hard gate, cannot be shortened
        ↓
apply for production   up to 7 days
        ↓
first app review       up to 7 days, longer for new accounts
```

**Realistically 4–6 weeks from account creation to a live public listing.**
The 14 days is a floor, not the total.

The single highest-value thing you can do today is start the account and get
the closed test running, because that clock cannot be compressed by any
amount of later effort. Everything else can happen alongside it.

---

## The app is technically ready

Verified against the current bundle requirements, so you can skip worrying
about these:

| Requirement | Status |
|---|---|
| Target API 36 (mandatory for new apps from **31 Aug 2026**) | ✅ `targetSdkVersion = 36` |
| AAB format (APKs not accepted for new apps) | ✅ `bundleRelease` |
| 16 KB memory page size (enforced 1 Feb 2027) | ✅ no native `.so` libraries at all |
| Edge-to-edge, mandatory and un-opt-out-able at API 36 | ✅ `viewport-fit=cover` + `env(safe-area-inset-*)` |
| Signed release bundle | ✅ Gradle `signingConfig`, verified in CI on every push |
| Unique increasing versionCode | ✅ from the workflow run number |

The remaining work is entirely Play Console paperwork.

---

## Step 1 — Register the developer account

**play.google.com/console** → US$25, one time, non-refundable.

- Pay with a **real credit card, not a prepaid one**, whose billing name
  matches the government ID you will upload. A name mismatch is the single
  most common cause of a failed registration, and the $25 is not returned.
- Set the Google Payments profile legal name and address to **exactly** match
  your documents *before* submitting. Fixing it afterwards costs a whole
  review cycle.

### Identity verification

You will be asked for two things:

1. **Government photo ID** — passport, driving licence, or provincial ID.
   Valid (not expired), in colour, clear, and a photo of the real document
   rather than a photocopy.
2. **Proof of address** — utility bill, bank or credit-card statement, or
   insurance statement, showing the same name and address as the payments
   profile.

Google's own note: *"Submitting unsupported documents is the primary reason
for developer verification failures."* Review takes "a few days"; there is no
published SLA.

### Device verification — easy to miss

New personal accounts must also verify they have a **real, non-rooted
physical Android phone running Android 10 or later**, by signing in to the
**Play Console mobile app** as the account owner. Emulators do not count. It
takes under a minute, and it is a separate task on the Play Console home page
from ID verification.

### Developer email

You must provide a developer email that is **shown publicly on every
listing**, verified by a 6-digit code. Use the durable alias, not a
throwaway, and not your main personal address — it attracts spam forever.
Once you have created it, put it in `docs/store/PRIVACY.md` too, or set
`FAIRSHARE_CONTACT_EMAIL` when building the Pages site so the hosted privacy
policy names it directly.

---

## Step 2 — Create the app and enrol in Play App Signing

Play Console → **Create app**.

- **App name:** `FairShare: Option Fair Value` (28/30 characters)
- **Default language:** English
- **App or game:** App
- **Free or paid:** Free
- Accept the declarations.

**Enrol in Play App Signing when prompted.** It is mandatory, and it is also
what makes the app auto-register for Android developer verification (see the
September deadline below) and what makes a lost upload key recoverable.

The package name `io.github.jaivik2612.fairshare` is fixed by the first
upload and can never be changed.

### A dated item worth knowing about

From **30 September 2026**, apps must be registered by a verified developer
to install on certified devices in Brazil, Indonesia, Singapore and Thailand,
with global rollout following in 2027. Enrolling in Play App Signing claims
the app automatically. After your first upload, glance at the Play Console
home page and clear any "unregistered package" task.

---

## Step 3 — Work the App content page *in this order*

Play Console → **Policy and programs → App content**. The order matters:
the Target audience screen is blocked until the three before it are done.

**1. Privacy policy**

```
https://jaivik-2612.github.io/vscode_remote/privacy.html
```

This is generated from `docs/store/PRIVACY.md` and deployed by the Pages
workflow. Confirm it returns 200 in a browser before pasting it in —
Google requires an active, public, non-geofenced, non-editable URL, and a
404 blocks both the listing and the Data safety form.

**2. Ads** — No. There are no ad SDKs in the app.

**3. App access** — *All functionality is available without special access*.
There is no sign-in. Paste the reviewer notes from `LISTING.md` here.

**4. Target audience** — **18 and over only.** Selecting any band that
includes children pulls the app into the Families programme, which brings
a pile of extra requirements you do not want.

**5. Content ratings** — category **Utility, Productivity, Communication, or
Other** (Google's own definition of that category literally names
calculators). Answer **No** to violence, sexuality, language, controlled
substances, and horror.

Answer **No** to gambling too: IARC's gambling questions are about real or
simulated wagering with stakes and payouts. A probability gauge is a model
output, not a wager. Interactive elements: Users Interact — No; Shares
Location — No; Digital Purchases — No; Unrestricted Internet — No.

Expected result: ESRB Everyone, PEGI 3, IARC 3+.

**6. Data safety** — the whole form collapses to a single answer. To *"Does
your app collect or share any of the required user data types?"* answer
**No**. The encryption and deletion follow-ups are gated behind Yes and never
appear. Leave both optional badges unticked.

This is accurate, and verified in the code rather than merely asserted: in
the shipped build the symbol directory and rate curves are bundled into the
app, the one `fetch` call is unreachable, and the only outbound URLs are
links the user taps, which open the system browser. The declared
`INTERNET` permission is not data collection — Google is explicit that
permissions and the Data safety section are different things.

> If a future release ever ships a live backend, this form must be
> resubmitted **before** that release. Google enforces on the discrepancy
> between declared and actual behaviour.

**7. Financial features** — mandatory for **every** app, including apps with
none. Select the single opt-out: **"My app doesn't provide any financial
features."**

Do **not** tick "Stock trading and portfolio management" (the app places no
orders and holds no positions) or "Financial advice" (it gives none). Over-
declaring here is expensive: ticking a financial feature implies you should
hold an *organization* account, which requires a D-U-N-S number.

The Financial Services policy itself does not reach FairShare — its only
substantive sections are binary options, personal loans and earned wage
access. The India/Japan/Indonesia licensing declarations are personal-loan
rules and do not apply, so the Indian and Japanese tickers create no
obligation.

---

## Step 4 — Store listing

Paste from [`LISTING.md`](LISTING.md). Two things to remember:

- The full description field is **plain text** — no Markdown, no HTML. The
  copy in `LISTING.md` is already flattened.
- **Category: Education**, not Finance. Finance puts the listing in the
  bucket Google's financial-services tooling watches and invites questions
  the "no financial features" declaration then has to rebut.

Upload the graphics from `docs/store/assets/` (regenerate any time the UI
changes with `node tools/store-assets.mjs`). Add the alt text from
`LISTING.md` beside each image — it is entered by hand, one field per upload.

---

## Step 5 — The closed test: the 14-day gate

This is the part that takes real calendar time and real people.

> Personal accounts created after 13 November 2023 must run a closed test
> with **at least 12 testers opted in continuously for at least 14 days**
> before production access is granted.

Still in force as of August 2026. Open testing does not get you around it —
its own access requirement is "gain access to production".

### How the count actually works

Evaluated **at the moment you apply**, looking back 14 days. You need 12
people each holding an unbroken 14-day opt-in ending now. If someone opts out
and rejoins, their clock restarts. **Uninstalling the app is the usual
accidental opt-out.**

So:

- **Recruit 15–18, not 12.** You need slack for drop-outs.
- Tell every tester explicitly: stay opted in, don't uninstall, for two weeks.
- Prefer a **Google Group** over an email list — you can add and remove
  members without editing the Play Console track and disturbing opt-in state.
- Make sure nobody is sitting in the *internal* testing track; that blocks
  closed-test eligibility for their account.
- Publish the release and **click your own opt-in link first**. The link can
  take several hours to go live after the first release, and a broken link on
  day one costs the whole group a restart.

### Engagement is judged, not just headcount

"Insufficient tester engagement" is an explicit rejection reason. Twelve
dormant installs is a known failure mode. Ask people to actually use the
thing across several days, and **keep a written log of the feedback and what
you changed** — you have to summarise it in the application.

For FairShare specifically, recruit people who hold or have been granted
equity. The application asks whether tester usage matched expected production
behaviour, and a finance-literate group answers that far better than a rented
pool. The paid "12 testers in 14 days" services that dominate search results
are unendorsed and carry real risk, since Google evaluates authenticity.

---

## Step 6 — Apply for production

Dashboard → **Apply for production**. Three parts, six free-text answers:

1. **About your closed test** — how easy recruiting was; tester engagement,
   including whether testers used all features and whether their usage
   matched expected production behaviour; a summary of feedback and how you
   collected it.
2. **About your app** — target audience, value proposition, estimated
   first-year install range.
3. **About your production readiness** — what you changed based on the test,
   and how you decided it was ready.

**Draft all six in a document first and paste them in.** The form has no
autosave and warns on every part that leaving the page discards your answers.

Review takes "seven days or less, but can occasionally take longer". A
brand-new personal account is exactly the profile that draws the longer
review, and the first app review can take another seven days on top.

---

## Every release, afterwards

```powershell
# Actions → Android build → Run workflow, setting versionName and versionCode
# then download fairshare-release-aab-v<n> and upload it to Play Console
```

Bump `versionCode` every single time — Play rejects a repeat. The workflow
defaults it to the run number, which always increases.

Re-run `node tools/store-assets.mjs` whenever the UI changes so the
screenshots do not drift from the app; misleading listing imagery is a real
policy violation, not just untidiness.

Retake the content-rating questionnaire if you change features in a way that
affects the answers.

---

## iOS, later

Needs a Mac with Xcode (or a macOS CI runner) and the Apple Developer
Program at $99/year. The Capacitor scaffold in `ios/` is already renamed to
the same bundle identifier. `LISTING.md` keeps the App Store's
primary/secondary category pair separate from Play's single-category model.

---

## Things that do **not** apply, so you can stop worrying about them

- **Tablet screenshots are not mandatory.** The widely repeated claim that
  they are required for store visibility is false. They are uploaded anyway
  because missing them costs eligibility for large-format placements.
- **No news declaration** — the app has no feed and says "news" nowhere.
  Keep it that way: the scope test keys on your title, icon and description.
- **No country restrictions.** Shipping global tickers creates no
  availability or licensing obligation. Ship worldwide.
- **No prediction-markets enrolment.** That pilot is scoped to real-money
  transactions; a probability gauge has no stake, counterparty or settlement.
- **No generic financial-disclaimer rule exists** on Play. The app's
  education-only modal is already stronger than anything required — and it is
  the evidence that answers a reviewer asking why "Financial advice" was not
  declared. Do not let a future UI cleanup remove the acknowledgement gate.
