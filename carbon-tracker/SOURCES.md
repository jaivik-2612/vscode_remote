# Data sources & assumptions

Every number the app uses lives in [`factors.js`](factors.js) and is rendered,
with its source, in the app's **Data** tab. This file is the long-form record:
where each value comes from, and the assumptions behind every derived estimate.

Two kinds of values:

- **Published** — read directly from a cited dataset.
- **Derived estimate** (marked `≈` in the app) — computed from published data
  plus stated assumptions (a serving size, a lifetime, a power rating).

All values are kg CO₂-equivalent (GWP-100). Retrieved July 2026.

---

## 1. Transport — operation (per passenger-km)

**Source:** Our World in Data, *“Carbon footprint of travel per kilometer”*
(2022 values), built from the UK Government/DEFRA greenhouse-gas conversion
factors. <https://ourworldindata.org/travel-carbon-footprint>

| Mode | g CO₂e/pkm (source) | Used as kg/km |
|---|---|---|
| Petrol car | 170.48 | 0.170 |
| Diesel car | 170.82 | 0.171 |
| Motorbike | 113.55 | 0.114 |
| Bus (average) | 96.5 | 0.097 |
| National rail | 35.49 | 0.035 |
| London Underground (used for metro) | 27.81 | 0.028 |
| Domestic flight | 245.87 | 0.246 |
| Long-haul flight | 147.87 | 0.148 |

Estimates: **electric car** 0.17 kWh/km × user grid (typical mid-size EV
consumption). Walking and cycling operation = 0 (food energy not counted).

## 2. Transport — embodied (manufacturing, amortised per km)

**Source basis:** ICCT (Hall & Lutsey 2018) and IVL Swedish Environmental
Research Institute (2019 revision, 61–106 kg CO₂e per kWh of battery), both
via Carbon Brief's EV factcheck.
<https://www.carbonbrief.org/factcheck-how-electric-vehicles-help-to-tackle-climate-change/>

All rows are **derived estimates**:

| Mode | Assumption | kg CO₂e/km |
|---|---|---|
| Petrol/diesel car | ≈6 t to manufacture a mid-size car ÷ 200,000 km lifetime | 0.030 |
| Electric car | ≈6 t car + ≈4 t battery (50 kWh × ~85 kg/kWh) ÷ 200,000 km | 0.050 |
| Motorbike | ≈1.2 t ÷ 100,000 km | 0.012 |
| Bus | vehicle mfg over ~1 M km ÷ passengers | 0.006 |
| Metro / intercity train | rolling stock only, per passenger-km | 0.004 / 0.005 |
| Aircraft | ~25-year service life, per passenger-km | 0.002 |
| Bicycle | ≈150 kg ÷ ~30,000 km | 0.005 |

Infrastructure (roads, rails, airports) is excluded throughout.

## 3. Food — production & supply chain (per serving)

**Source:** Poore & Nemecek (2018), *Reducing food's environmental impacts
through producers and consumers*, Science 360 — global average kg CO₂e per kg
of product, including land-use change, via Our World in Data.
<https://ourworldindata.org/grapher/ghg-per-kg-poore>

| Item | Source kg CO₂e/kg | Serving | Per-serving |
|---|---|---|---|
| Beef (beef herd) | 99.48 | 125 g | 12.44 |
| Lamb & mutton | 39.72 | 125 g | 4.97 |
| Pig meat | 12.31 | 125 g | 1.54 |
| Poultry | 9.87 | 125 g | 1.23 |
| Farmed fish | 13.63 | 125 g | 1.70 |
| Eggs | 4.67 | 2 eggs (120 g) | 0.56 |
| Rice | 4.45 | 75 g dry | 0.33 |
| Milk | 3.15 | 250 ml | 0.79 |
| Cheese | 23.88 | 30 g | 0.72 |
| Tofu | 3.16 | 100 g | 0.32 |
| Coffee | 28.53 | 12 g beans/cup | 0.34 |
| Dark chocolate | 46.65 | 20 g | 0.93 |

Notes: beef from dairy herds is ~⅓ of beef-herd beef (33.3 kg/kg) — the app
uses the global beef-herd average, so if your beef is dairy-herd, the value
overstates. Serving sizes are the app's own assumption.

Derived composites: **vegetarian meal** ≈1.0 (75 g dry grains 0.12 + 60 g dry
pulses 0.11 + 250 g vegetables 0.13 + 30 g paneer/cheese 0.72 ≈ 1.08, rounded
down for pulse-only variants); **vegan meal** ≈0.7 (same minus dairy, plus
extra pulses/tofu); **tea** ≈0.03 (2 g dry leaves, brewed black).

## 4. Electricity grid intensity (kg CO₂/kWh)

Three levels, all listed in the app's Data tab and in `factors.js`:

- **Countries (~180)**: Ember yearly electricity data (latest year, mostly
  2024/2025) via Our World in Data,
  <https://ourworldindata.org/grapher/carbon-intensity-electricity>.
  Values are the published national figures rounded to 3 decimals
  (e.g. Canada 190.7 g → 0.191; US 384.4 g → 0.384). "Other / not listed"
  falls back to ~0.47, the world average from Ember's Global Electricity
  Review 2025 (2024 data).
- **Canadian provinces & territories**: approximate values from Environment
  and Climate Change Canada's National Inventory Report (~2022 data), from
  Quebec/Manitoba ≈ 0.002 to Alberta 0.54, Saskatchewan 0.69 and
  diesel-powered Nunavut 0.9.
- **US states**: approximate values from EPA eGRID 2022, from Vermont 0.01
  and Washington 0.09 to West Virginia 0.85 and Wyoming 0.9.

The provincial/state figures are marked *approximate*: they are assembled
from the cited government datasets but rounded and not fetched from a live
table — verify against the current NIR/eGRID release before any formal use.

At sign-up the user picks a country of residence (and a province/state for
Canada/US); this sets their grid intensity. It can be changed any time in
Settings, including a custom value. The app is regionally centred on
Canada/US: the default is Canada, and the activity list includes
North-American staples such as gas-furnace home heating.

## 5. Home appliances

**Operation** = power rating × hours × grid intensity. Power ratings are
typical nameplate/average values (derived estimates): AC 1.5-ton split 1.5 kW ·
space heater 1.8 kW · geyser 2.0 kW · microwave 1.2 kW · iron 1.1 kW ·
washing machine 0.8 kWh/load · desktop 0.15 kW · TV 0.10 kW · ceiling fan
0.075 kW · fridge 0.06 kW averaged over 24 h · laptop 0.05 kW · 4 LED bulbs
0.04 kW · kettle 0.11 kWh/boil · phone 0.015 kWh/charge.

**Embodied** (all derived estimates from manufacturer product environmental
reports and LCA literature; manufacturing footprint ÷ typical lifetime usage):

| Appliance | Mfg footprint | Lifetime | kg CO₂e/unit |
|---|---|---|---|
| Air conditioner | ≈500 kg | 15,000 h (10 yr) | 0.033/h |
| Refrigerator | ≈400 kg | 105,000 h (12 yr, always on) | 0.004/h |
| Television 43″ | ≈300 kg | 12,500 h (7 yr) | 0.024/h |
| Desktop + monitor | ≈400 kg | 13,000 h (6 yr) | 0.030/h |
| Laptop | ≈200 kg | 10,000 h (5 yr) | 0.020/h |
| Smartphone | ≈55 kg | 1,100 charges (3 yr) | 0.050/charge |
| Washing machine | ≈350 kg | 2,200 loads (10 yr) | 0.16/load |
| Ceiling fan | ≈35 kg | 37,000 h (15 yr) | 0.001/h |
| Space heater | ≈50 kg | 10,000 h | 0.005/h |
| Geyser | ≈100 kg | 10,000 h | 0.010/h |
| Microwave | ≈100 kg | 2,000 h | 0.050/h |
| Iron | ≈20 kg | 1,000 h | 0.020/h |
| Kettle | ≈15 kg | 2,000 boils | 0.008/boil |

Laptop/phone figures are consistent with manufacturer product carbon
footprints (e.g. a ~1.5 kg laptop ≈ 200–300 kg CO₂e, ~75–85% of it
manufacturing; a flagship phone ≈ 55–80 kg CO₂e, ~80% manufacturing).
AC embodied excludes refrigerant leakage, which can rival manufacturing —
a known simplification.

## 6. Other factors

- **Gas stove cooking** ≈0.50 kg/h: DEFRA LPG/propane combustion factor
  (~1.56 kg CO₂e per litre) × typical domestic burner consumption
  (~0.32 l/h). Natural-gas stoves are similar. Derived estimate.
- **Gas furnace heating** ≈3.2 kg/h of burner runtime: 60,000 BTU-input
  furnace ≈ 17.6 kWh(th) × DEFRA natural-gas factor ~0.18 kg CO₂e/kWh.
  Furnaces cycle on and off — log actual burner runtime, not thermostat-on
  hours. Derived estimate.
- **Video streaming** 0.036 kg/h: IEA (Kamiya, 2020), *The carbon footprint of
  streaming video* — data centres + network only, world-average grid; the
  viewing device is logged separately.
  <https://www.iea.org/commentaries/the-carbon-footprint-of-streaming-video-fact-checking-the-headlines>
- **Mixed waste to landfill** ≈0.50 kg/kg: DEFRA waste-disposal factors for
  mixed municipal waste (~450–590 kg CO₂e/tonne depending on composition).
  Derived estimate.
- **Online order delivered** ≈0.50 kg/parcel: last-mile van delivery +
  packaging; the purchased product itself is not included. Derived estimate.

## 7. Benchmarks

- **Sustainable target** 5.5 kg CO₂e/day ≈ 2 t/person/year — a widely used
  Paris-aligned personal budget for ~2030–2040.
- **World average** 12.9 kg/day ≈ 4.7 t fossil CO₂/person/year, Global Carbon
  Budget per-capita CO₂ (all-GHG per-capita is higher, ~6.5 t).
- **Canada / US average** 38 kg/day ≈ 14 t fossil CO₂/person/year — both
  countries sit near this figure in Global Carbon Budget per-capita data.

## 8. Gas splits (CO₂ / CH₄ / N₂O)

The per-gas shares in `GAS_SPLITS` are **approximate allocations**, not
published factors. They reflect how each activity's emissions physically arise
(IPCC/FAO source categories): combustion is nearly pure CO₂; ruminant meat and
dairy are dominated by enteric-fermentation methane; rice by paddy methane;
landfill waste by decomposition methane; fertilised crops carry N₂O. Treat the
gas-mix chart as indicative.

## 9. Product savings estimates (Tips tab)

The affiliate product cards show personalised money/CO₂ savings computed
from the user's own last-7-days logs:

    weekly $ saved = (units of affected activities logged that week)
                   × (operating cost per unit) × (product's reduction share)

- **Energy prices** (CAD estimates in `PRICES`): electricity $0.15/kWh,
  petrol ≈ $0.13/km (8 L/100 km × ~$1.60/L), gas furnace ≈ $0.30 per
  burner-hour, gas stove ≈ $0.10/h. These are typical Canadian rates, not
  the user's bill; the in-app disclosure says so.
- **Reduction shares** (per product, derived from public guidance):
  smart thermostat 12% of heating/cooling (ENERGY STAR cites ~8–15%);
  draft sealing 10% of heating; water-heater timer 25% of heater runtime;
  smart plug 10% of scheduled appliances; LED refresh 15% of lighting;
  e-bike 40% of logged car km. Marked as estimates.
- **Prices & lifespans**: typical retail CAD prices and service lives,
  hard-coded per product. Payback = price ÷ yearly savings; if payback
  exceeds the product's lifespan the card says it may not pay for itself.

## Known limitations

- Global/UK averages stand in for local values everywhere.
- Serving sizes, power ratings and lifetimes are fixed assumptions.
- No radiative-forcing multiplier is applied to aviation (would roughly
  double flight numbers).
- AC refrigerant leakage is excluded.
- Embodied amortisation assigns manufacturing linearly per use — using a
  device less doesn't reduce past manufacturing, it extends its life; the
  Tips tab's savings therefore count only the operation phase.
