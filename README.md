# LifeOS — Universal Life Administration Platform

The world is administratively fragmented. One life event — moving, starting a
business, immigrating — fans out into obligations across a dozen unrelated
institutions, each with its own forms, documents and deadlines. The problem is
not lack of information; it is coordination.

LifeOS is a mobile app (Android + iOS, one React Native codebase) where you
say what happened, and the app builds the coordinated plan:

- **"I moved."** → driver's licence, insurance, government records, banks,
  employer, utilities, tax records — with legal deadlines resolved to real dates.
- **"I started a business."** → registration, tax accounts, insurance,
  licences, payroll, accounting, compliance — sequenced by dependency
  (you can't get a tax ID before the entity exists).
- **"I want to immigrate to Canada."** → eligibility analysis, document
  checklist, timeline, deadlines, application package, status monitoring.

Also in the catalog: *I got married*, *We had a baby*. Adding an event is one
declarative template file.

## How it works

```
free text ──► intent matcher ──► event template ──► intake questions
                                                      │
                                       planner (offsets → dates,
                                       answers gate tasks in/out,
                                       dependency graph → blocked states)
                                                      │
                            plan: tasks grouped by domain + document
                            checklists + unified cross-plan timeline
```

### Layout

| Path | What it is |
|---|---|
| `src/core/` | The engine — pure TypeScript, zero React Native dependencies |
| `src/core/types.ts` | Domain model: events, tasks, plans, domains, priorities |
| `src/core/intent.ts` | Offline intent matcher ("I moved" → template), explainable matches |
| `src/core/templates/` | The event catalog (5 events, ~50 task templates) |
| `src/core/planner.ts` | Template + answers + date → concrete plan; dependency reconciliation |
| `src/core/progress.ts` | Progress, per-domain grouping, cross-plan deadline timeline |
| `src/state/` | React context store with AsyncStorage persistence |
| `src/screens/` | Home ("What happened?"), Intake, Plan, Task detail, Timeline |
| `__tests__/` | Jest tests for the engine (intent, planner, progress) |

Key engine behaviors:

- **Task gating** — intake answers (e.g. "Do you own a vehicle?") include or
  exclude optional tasks; dependencies on excluded tasks are dropped cleanly.
- **Dependency graph** — tasks whose prerequisites aren't done show as
  blocked and unblock automatically when you complete (or skip) the
  prerequisite; un-completing re-blocks dependents.
- **Real deadlines** — templates carry day offsets relative to the event date
  (negative = before), so "update licence within 14 days of the move" becomes
  an actual date, and the Timeline tab merges every plan into one
  soonest-first deadline feed with overdue highlighting.
- **Step checklists** — every task in the catalog breaks down into checkable
  sub-steps ("Flight tickets booked", "Hotel stay confirmed"), instantiated
  per plan and persisted; task rows show step progress.
- **Focused intake** — every event asks at most 5 questions, and answers gate
  tasks in or out rather than just collecting data.
- **Document checklists** — each task instantiates its required documents as
  a per-task checklist.
- **Country-aware resources** — every task has a "How & where to do this"
  section: official links for the user's country (US/CA/GB/AU/IN today),
  the domain's national portal, and a search localized to their region.
  Driven by the profile (name, country, state/region, city) collected on the
  Profile tab and stored on-device.

Everything runs on-device and offline; plans persist in AsyncStorage.

## Accounts & cloud backup (Supabase)

Sign-up/sign-in gates the app: email + password (8+ chars with letters,
numbers and a special character), a confirmation email before first sign-in,
and a Terms & Disclaimer page accepted once per account. Plans and profile
auto-back up to a row-level-secured `user_backups` table and restore on
sign-in to an empty device.

Setup (one time):

1. Create a project at [supabase.com](https://supabase.com) (free tier is fine).
2. SQL Editor → run `supabase/schema.sql`.
3. Follow the dashboard checklist in that file (email confirmation is on by
   default; set the Site URL; optionally set min password length to 8).
4. Copy `.env.example` to `.env` and fill in the Project URL and anon key
   from Project Settings → API.

Without credentials the app runs in **local-only mode** — no gate, no
backups, everything else works. The web bench simulates the full auth flow
(including the confirmation link) so the UX is testable without a backend.

## Monetization: affiliate product suggestions

No charges, no ads. Life events come with shopping lists as well as paperwork,
so plans show a "Things you might need" section (baby → newborn clothes,
diapers, monitor; new job → work clothes, laptop) and some tasks carry
anchored products (language test → IELTS prep book). The product database
lives in `src/core/products.ts` — per-event packs following the user's
profile country storefront. The required disclosure is shown wherever
products appear.

The link ladder (each tier converts better than the last):

1. **Tagged search links** — set `AFFILIATE_TAG` once your Associates
   account is approved and every link earns. Amazon pays commission on
   anything bought within 24h of a tagged click, so search links do earn.
2. **Curated ASINs** — add `asin: { US: '…', CA: '…' }` to any product for
   direct product-page links (much higher conversion). ASINs are
   marketplace-specific; countries without one automatically fall back to
   the search link, so stale ASINs never dead-end.
3. **PA-API product cards** (future) — after 3 qualifying sales unlock
   Amazon's Product Advertising API, real cards with image/price/rating
   become possible via a small backend proxy.

## Web test bench

No emulator needed to try the product: `web-bench/lifeos-test-bench.html` is a
self-contained page with a phone simulator running the **exact engine code**
(transpiled from `src/core/`) plus an inspector showing intent-match scores,
plan statistics, gated-out tasks and an action log. A "simulated today" control
lets you fast-forward time to test overdue states. Open the file in any
browser, or rebuild it after engine changes with:

```bash
npm run bench   # transpiles src/core → injects into web-bench/shell.html
```

## Running it

```bash
npm install

npm test          # engine unit tests (no emulator needed)
npm run typecheck # full TypeScript check

npm run android   # Expo on an Android emulator/device
npm run ios       # Expo on an iOS simulator/device
npm start         # Expo dev server + QR code for Expo Go
```

Production builds ship through [EAS](https://docs.expo.dev/build/introduction/):
`eas build --platform android` / `--platform ios` (bundle ids are configured
in `app.json`).

## Roadmap

- Push/local notifications for approaching deadlines
- Jurisdiction packs (per-country authorities, deadlines and forms)
- Regenerate a plan when intake answers change, preserving completed work
- LLM-backed intent matching and Q&A on top of the deterministic planner
- Direct integrations (change-of-address APIs, government portals) where they exist

## Disclaimer

Task lists and deadlines are general guidance, not legal advice; requirements
vary by jurisdiction. Verify deadlines with the relevant authority.
