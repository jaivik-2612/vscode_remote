# Product policy: staying outside adviser registration

FairShare prices securities and charges (or will charge) money for it. That
puts it near a regulatory line in every market it ships to. This document is
the set of rules that keep it on the safe side, written down so the
constraint survives future feature work — and so a lawyer can be asked to
opine on *a specific set of rules* rather than an open-ended "is my app OK",
which is far cheaper.

**Read this before designing any new feature.** If a feature breaks a rule in
the "must stay true" list, it is not a small change.

Researched against primary sources in August 2026. Not legal advice — the
open questions at the bottom are the agenda for an actual lawyer.

---

## Why a disclaimer is not the answer

The education-only modal is good and must stay. But every regulator surveyed
says, in terms, that it does not decide the question:

- **Canada** — the CSA says a disclaimer does not defeat registration; what
  matters is whether the advice is tailored.
- **India** — SEBI looks at substance. Its December 2025 order against a
  business marketed as "educational" found unregistered advisory activity and
  ordered ₹546 crore disgorged. "Education-only" framing collapsed because
  the product gave stock-specific output for a fee.
- **United States** — the publisher's exclusion turns on the *character* of
  the publication, not on what it says about itself.

The protection comes from what the software actually does.

---

## Rules that must stay true

Every one of these is currently true. Keeping them true is what keeps the app
out of scope.

- **No account is required to price an option.** The calculator works
  offline, for anyone, with no sign-in.
- **The user supplies every input.** The app computes; it does not observe.
- **Outputs are values and model statistics, never actions.** A fair price, a
  probability, a break-even, a regime label. Never a suggestion to do
  something.
- **No buy / sell / hold / target / entry / exit vocabulary anywhere** — UI,
  marketing, store listing, or release notes.
- **No ranking, sorting or filtering of securities by attractiveness.** No
  "top opportunities", no "best trades", no "our picks", no "for you" feed.
- **Identical inputs produce identical outputs for every user.** There is no
  per-person branch anywhere in the pricing path.
- **No questionnaire** about objectives, risk tolerance, income, time horizon
  or experience. Asking those questions is the definition of tailoring.
- **No brokerage linkage**, no position import, no reading of real holdings.
- **No revenue that varies with whether users trade.** No rebates, no
  order-flow payment, no affiliate commission on brokerage sign-ups.
- **No claim of past or expected performance** for the models.

## Changes that need a lawyer before they ship

These are not forbidden. They are the ones where the answer is genuinely
uncertain and the downside is large.

| Feature | Why it is different in kind |
|---|---|
| Portfolio-level regime view **computed server-side over stored holdings** | The input becomes the user's own book and the output is generated from it. That is the fact pattern the tailoring test is aimed at. |
| Watchlist or position-triggered alerts | Same reason, plus in the US the publisher's exclusion requires publication "of general and regular circulation rather than issued from time to time in response to episodic market activity" — which is what an event-driven alert is. |
| Any onboarding questionnaire touching circumstances | Straightforwardly tailoring. |
| Brokerage or account linkage | Same. |
| A strategy builder that **proposes** a structure rather than pricing one the user specifies | Proposing is recommending. |
| Publishing or sharing user-specific outputs | Turns private computation into circulated advice. |

### The design that probably preserves both risky features

The trick is to make the personalisation happen **in the user's browser** and
the analysis happen **to a security, not to a person**:

1. **Compute the portfolio view entirely client-side**, from data the user
   typed, with positions never leaving the device and never reaching the
   server. The app is then a spreadsheet the user is operating, not a service
   that has been told about them.
2. **Make alerts subscribe to a security, not to a person.** Broadcast
   *"AAPL entered the turbulent regime"* identically to everyone who ticked
   AAPL — rather than *"your position is at risk"*. The alert is then a
   published observation about a security, and the fact that this user cares
   about AAPL stays on their device.
3. **If a watchlist must sync**, sync an encrypted blob the server cannot
   read, and keep the regime computation over it on the client.

This is an architectural decision that must be made **before** the database
schema exists. Retrofitting "the server never sees positions" after shipping
a `holdings` table is expensive — and a regulator reading a schema where
`user_id` joins to `holdings` joins to `alerts_sent` sees tailoring, however
the marketing is worded.

---

## Per-jurisdiction notes

### Canada — the exemption we rely on

`NI 31-103 s.8.25` ("advising generally") disapplies the adviser registration
requirement where the advice "does not purport to be tailored to the needs of
the person or company receiving the advice." It is self-executing: no filing,
no fee.

But `s.8.25(3)` attaches a condition: where a specified security is
recommended and the adviser (or its officers/insiders) has a financial or
other interest in it, that interest must be disclosed. **The app should carry
a standing disclosure that it holds no position in, and takes no compensation
referable to, any security it prices** — and that must remain true.

Note also that securities regulation is provincial, and an app-store listing
reaches all thirteen jurisdictions at once. Quebec is genuinely different:
exchange-traded options fall under the *Derivatives Act*, not the *Securities
Act*, and the equivalent exemption could not be confirmed.

### United States — the harder jurisdiction

The Advisers Act definition is *broader* than Canada's: it reaches advice "as
to the value of securities", which is literally what a fair-value calculator
produces. The publisher's exclusion (*Lowe v. SEC*) is the defence, and its
third prong — general and regular circulation, "rather than issued from time
to time in response to episodic market activity" — is the one that
event-driven regime alerts strain hardest.

### India — the sharpest risk, and the one with precedent

SEBI draws the line at a security-specific recommendation for consideration.
A calculator that prices from user-entered inputs and names no security sits
outside both the Investment Adviser and Research Analyst regimes. A push
notification naming a security is a much harder argument.

Two further constraints if the app targets India:

- **A 30-day price-data lag applies to educational use of market price data**
  from 1 July 2026, with an audit-trail requirement.
- **Displaying NSE/BSE price or option-chain data needs an exchange data
  licence.** Lot sizes and STT rates do not — those are published reference
  data, and they are the genuinely useful part.

SEBI's jurisdiction follows the Indian resident, not the developer's
location. Being a Canadian sole proprietor is not a shield.

---

## Where platform policy actually bites

Worth separating from the securities analysis above, because it is easy to
over-read the app stores' rules and under-read the regulators'.

- **Google Play is a disclosure step, not a gate, for a Canadian developer.**
  Neither "Stock trading and portfolio management" nor "Financial advice"
  carries a published licensing requirement on the Financial features
  declaration, and Canada is absent from Google's country-specific list
  (US, India, Indonesia, Philippines, Nigeria, Kenya, Pakistan, Thailand).
  India's presence on that list is the part that matters if India is
  targeted.
- **Apple Guideline 5.1.1(ix)** — in the *Data Collection and Storage*
  section — is the provision that can block an individual developer, and it
  fires on apps in highly regulated fields *or that require sensitive user
  information*. It is enforced as a rejection with a stated cure (enrol as
  an organization), not as removal. Guideline 3.2.1(viii) is often cited
  here and should not be: it is a condition on apps submitted by financial
  institutions, and it sits in that section's *Acceptable* list.
- **Consequently the trigger to plan around is cloud storage of user
  financial data, not the paid tier.** Collecting nothing is this app's
  strongest position with both stores and both regulators. Incorporating
  before adding that storage is the sequencing that matters; charging money
  changes neither store's answer.

## Open questions for the lawyer

In priority order. The first is the whole engagement:

1. Does "tailored to the needs of the person receiving the advice" in
   `NI 31-103 s.8.25(2)` reach output computed from a user's positions where
   the provider knows nothing of their objectives or circumstances? Canada
   says "needs"; the US and CFTC analogues say "accounts" and "positions".
   There appears to be no Canadian authority directly on point.
2. The statute says "does not **purport** to be tailored" — arguably an
   objective test about presentation — while the CSA/CIRO finfluencer notice
   restates it substantively as "is not tailored". Which governs?
3. Does the Quebec *Derivatives Act* carry an equivalent to s.8.25 for
   exchange-traded options?
4. Does the US publisher's exclusion survive event-driven alerts if the alert
   is about a security and is broadcast identically to all subscribers?

Hand this document to the lawyer as the thing to opine on.
