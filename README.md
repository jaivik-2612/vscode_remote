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
- **Document checklists** — each task instantiates its required documents as
  a per-task checklist.

Everything runs on-device and offline; plans persist in AsyncStorage.

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
