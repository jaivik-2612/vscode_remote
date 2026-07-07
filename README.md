# vscode_remote
This repository is for using vscode on my ipad

## 🌱 Carbon Footprint Tracker

A dependency-free web app (in [`carbon-tracker/`](carbon-tracker/)) that tracks
the carbon footprint of your day-to-day life — from the morning commute to the
fan running while you sleep.

### Features

- **Log daily activities** — transport, meals & drinks, home appliances
  (AC, fan, heater, geyser, fridge, TV, …), cooking, showers, waste and more,
  for today or any past date. Tap any logged entry to expand the detailed
  footprint: the factor math, operation vs. manufacturing split, per-gas
  breakdown and the data source.
- **Emissions engine** — every activity is converted to kg CO₂-equivalent,
  with a breakdown into CO₂, CH₄ (methane) and N₂O (nitrous oxide), and
  split into two phases: **operation** (the fuel/electricity used) and
  **embodied** (manufacturing of the equipment amortised over its lifetime,
  or the farm-to-shop production footprint of food). Electric appliances use
  a configurable grid carbon intensity (default: Canada; presets for the US,
  world average, UK, EU, India, renewables — Ember 2025 data). The activity
  list is centred on Canada/US life, including gas-furnace home heating.
- **Citable data** — factors come from published datasets (UK DEFRA
  conversion factors via Our World in Data, Poore & Nemecek 2018 for food,
  Ember for grids, ICCT/IVL for vehicle manufacturing, IEA for streaming);
  derived estimates are explicitly marked. See
  [`carbon-tracker/SOURCES.md`](carbon-tracker/SOURCES.md) for every
  assumption, and the in-app **Data** tab for the live factor matrix.
- **Dashboard** — daily/weekly/monthly totals compared against the
  sustainable target (~5.5 kg CO₂e/day) and the world average (~12.9 kg/day),
  a category donut, greenhouse-gas mix, an operation-vs-manufacturing split,
  a 14-day trend chart and your biggest contributors.
- **Personal suggestions** — rule-based tips computed from your own last
  7 days of logs, each with an estimated weekly saving, plus a
  **minimal-usage guide** showing a comfortable-but-frugal baseline for every
  appliance you actually use and what trimming to it would save per day.
- **Quick logging** — one-tap favorite chips learned from your habits,
  "copy yesterday", reusable day templates, and in-place editing of any
  entry. A first-run welcome card can load a sample day to explore.
- **Mandatory accounts** — sign-up with name, email and password before
  using the app. Without a cloud backend configured, accounts live on the
  device (several people can share it, fully isolated). With Supabase
  configured (see [`carbon-tracker/SETUP-CLOUD.md`](carbon-tracker/SETUP-CLOUD.md),
  ~5 minutes, free), accounts become real email+password cloud accounts:
  every change is backed up automatically, and signing in on a new device
  restores everything. Settings shows backup status plus manual
  "Back up now" / "Restore from cloud".
- **Installable PWA** — web-app manifest, icons and a service worker:
  "Add to Home Screen" gives a real app icon, full-screen launch and
  offline use.
- **Private by design** — data lives in your browser per account (plus your
  own Supabase project when cloud mode is on), with JSON export/import for
  manual backups. Works offline, light & dark mode, touch-friendly
  (iPad-ready).

### Run it

No build step, no dependencies:

```sh
cd carbon-tracker
python3 -m http.server 8000   # then open http://localhost:8000
```

…or just open `carbon-tracker/index.html` directly in a browser, or serve the
folder with GitHub Pages.

### About the numbers

Emission factors are rounded averages from public sources (UK DEFRA/BEIS
conversion factors, Poore & Nemecek 2018 via Our World in Data, national grid
intensity data). They are intended for habit tracking and comparison, not for
formal carbon accounting. CH₄ and N₂O are expressed as CO₂-equivalent
(GWP-100).
