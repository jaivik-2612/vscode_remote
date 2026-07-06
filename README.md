# vscode_remote
This repository is for using vscode on my ipad

## 🌱 Carbon Footprint Tracker

A dependency-free web app (in [`carbon-tracker/`](carbon-tracker/)) that tracks
the carbon footprint of your day-to-day life — from the morning commute to the
fan running while you sleep.

### Features

- **Log daily activities** — transport, meals & drinks, home appliances
  (AC, fan, heater, geyser, fridge, TV, …), cooking, showers, waste and more,
  for today or any past date.
- **Emissions engine** — every activity is converted to kg CO₂-equivalent,
  with a breakdown into CO₂, CH₄ (methane) and N₂O (nitrous oxide).
  Electric appliances use a configurable grid carbon intensity
  (presets for India, world average, US, EU, UK, renewables).
- **Dashboard** — daily/weekly/monthly totals compared against the
  sustainable target (~5.5 kg CO₂e/day) and the world average (~12.9 kg/day),
  a category donut, greenhouse-gas mix, a 14-day trend chart and your
  biggest contributors.
- **Personal suggestions** — rule-based tips computed from your own last
  7 days of logs, each with an estimated weekly saving, plus a
  **minimal-usage guide** showing a comfortable-but-frugal baseline for every
  appliance you actually use and what trimming to it would save per day.
- **Private by design** — all data stays in your browser (localStorage),
  with JSON export/import for backups. Works offline, light & dark mode,
  touch-friendly (iPad-ready).

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
