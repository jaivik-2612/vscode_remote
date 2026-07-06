/*
 * Emission factors, in kg CO2-equivalent per unit of activity.
 *
 * Values are rounded averages assembled from public sources:
 *  - UK DEFRA/BEIS greenhouse-gas conversion factors (transport, fuels)
 *  - Poore & Nemecek 2018 (food, via Our World in Data)
 *  - Typical appliance power ratings; electricity is converted with the
 *    user's grid intensity setting (kg CO2/kWh)
 *
 * Two kinds of activity:
 *  - direct:   { per } kg CO2e per unit (km, serving, hour, ...)
 *  - electric: { kwhPerUnit } kWh per unit; emissions = kWh x grid intensity
 *
 * `split` is the approximate share of the CO2e that comes from each gas
 * (CO2, CH4, N2O), expressed on a GWP-100 CO2e basis.
 */

const GAS_SPLITS = {
  electricity: { co2: 0.985, ch4: 0.005, n2o: 0.010 },
  fuel:        { co2: 0.960, ch4: 0.010, n2o: 0.030 },
  lpg:         { co2: 0.990, ch4: 0.005, n2o: 0.005 },
  ruminant:    { co2: 0.300, ch4: 0.550, n2o: 0.150 },
  poultry:     { co2: 0.600, ch4: 0.150, n2o: 0.250 },
  plant:       { co2: 0.550, ch4: 0.200, n2o: 0.250 },
  rice:        { co2: 0.250, ch4: 0.700, n2o: 0.050 },
  dairy:       { co2: 0.350, ch4: 0.500, n2o: 0.150 },
  waste:       { co2: 0.100, ch4: 0.850, n2o: 0.050 },
};

/* Categorical palette: validated slot order (see dashboard charts). */
const CATEGORIES = [
  { id: 'transport', label: 'Transport',        icon: '🚗', colorLight: '#2a78d6', colorDark: '#3987e5' },
  { id: 'food',      label: 'Food & drink',     icon: '🍛', colorLight: '#1baf7a', colorDark: '#199e70' },
  { id: 'home',      label: 'Home appliances',  icon: '🔌', colorLight: '#eda100', colorDark: '#c98500' },
  { id: 'water',     label: 'Cooking & water',  icon: '🚿', colorLight: '#008300', colorDark: '#008300' },
  { id: 'other',     label: 'Other',            icon: '📦', colorLight: '#4a3aa7', colorDark: '#9085e9' },
];

const ACTIVITIES = [
  /* ---------- Transport (per passenger-km) ---------- */
  { id: 'car_petrol',   cat: 'transport', label: 'Car — petrol',            unit: 'km',      per: 0.192, split: 'fuel' },
  { id: 'car_diesel',   cat: 'transport', label: 'Car — diesel',            unit: 'km',      per: 0.171, split: 'fuel' },
  { id: 'car_ev',       cat: 'transport', label: 'Car — electric',          unit: 'km',      kwhPerUnit: 0.17, split: 'electricity' },
  { id: 'motorbike',    cat: 'transport', label: 'Motorbike / scooter',     unit: 'km',      per: 0.114, split: 'fuel' },
  { id: 'auto',         cat: 'transport', label: 'Auto-rickshaw / tuk-tuk', unit: 'km',      per: 0.065, split: 'fuel' },
  { id: 'bus',          cat: 'transport', label: 'City bus',                unit: 'km',      per: 0.105, split: 'fuel' },
  { id: 'metro',        cat: 'transport', label: 'Metro / local train',     unit: 'km',      per: 0.035, split: 'electricity' },
  { id: 'train',        cat: 'transport', label: 'Intercity train',         unit: 'km',      per: 0.041, split: 'fuel' },
  { id: 'flight_dom',   cat: 'transport', label: 'Flight — domestic',       unit: 'km',      per: 0.246, split: 'fuel' },
  { id: 'flight_int',   cat: 'transport', label: 'Flight — long haul',      unit: 'km',      per: 0.150, split: 'fuel' },
  { id: 'cycle',        cat: 'transport', label: 'Bicycle',                 unit: 'km',      per: 0.0,   split: 'fuel' },
  { id: 'walk',         cat: 'transport', label: 'Walking',                 unit: 'km',      per: 0.0,   split: 'fuel' },

  /* ---------- Food & drink (per serving) ---------- */
  { id: 'meal_redmeat', cat: 'food', label: 'Meal with beef / mutton',   unit: 'meals',    per: 5.5,  split: 'ruminant' },
  { id: 'meal_chicken', cat: 'food', label: 'Meal with chicken',         unit: 'meals',    per: 1.8,  split: 'poultry' },
  { id: 'meal_fish',    cat: 'food', label: 'Meal with fish',            unit: 'meals',    per: 1.7,  split: 'poultry' },
  { id: 'meal_egg',     cat: 'food', label: 'Egg dish (2 eggs)',         unit: 'servings', per: 0.5,  split: 'poultry' },
  { id: 'meal_veg',     cat: 'food', label: 'Vegetarian meal',           unit: 'meals',    per: 1.2,  split: 'plant' },
  { id: 'meal_vegan',   cat: 'food', label: 'Vegan meal',                unit: 'meals',    per: 0.8,  split: 'plant' },
  { id: 'rice',         cat: 'food', label: 'Rice (extra serving)',      unit: 'servings', per: 0.35, split: 'rice' },
  { id: 'milk',         cat: 'food', label: 'Milk (1 glass)',            unit: 'glasses',  per: 0.55, split: 'dairy' },
  { id: 'cheese',       cat: 'food', label: 'Cheese / paneer serving',   unit: 'servings', per: 1.4,  split: 'dairy' },
  { id: 'coffee',       cat: 'food', label: 'Coffee (1 cup)',            unit: 'cups',     per: 0.28, split: 'dairy' },
  { id: 'tea',          cat: 'food', label: 'Tea (1 cup)',               unit: 'cups',     per: 0.05, split: 'plant' },

  /* ---------- Home appliances (electric; kWh per hour = kW rating) ---------- */
  { id: 'ac',           cat: 'home', label: 'Air conditioner (1.5 T split)', unit: 'hours',   kwhPerUnit: 1.50,  split: 'electricity' },
  { id: 'fan',          cat: 'home', label: 'Ceiling fan',                   unit: 'hours',   kwhPerUnit: 0.075, split: 'electricity' },
  { id: 'heater',       cat: 'home', label: 'Space heater',                  unit: 'hours',   kwhPerUnit: 1.80,  split: 'electricity' },
  { id: 'fridge',       cat: 'home', label: 'Refrigerator',                  unit: 'hours',   kwhPerUnit: 0.06,  split: 'electricity' },
  { id: 'tv',           cat: 'home', label: 'Television',                    unit: 'hours',   kwhPerUnit: 0.10,  split: 'electricity' },
  { id: 'desktop',      cat: 'home', label: 'Desktop computer',              unit: 'hours',   kwhPerUnit: 0.15,  split: 'electricity' },
  { id: 'laptop',       cat: 'home', label: 'Laptop / tablet',               unit: 'hours',   kwhPerUnit: 0.05,  split: 'electricity' },
  { id: 'lights',       cat: 'home', label: 'Room lighting (4 LED bulbs)',   unit: 'hours',   kwhPerUnit: 0.04,  split: 'electricity' },
  { id: 'washer',       cat: 'home', label: 'Washing machine',               unit: 'loads',   kwhPerUnit: 0.80,  split: 'electricity' },
  { id: 'iron',         cat: 'home', label: 'Clothes iron',                  unit: 'hours',   kwhPerUnit: 1.10,  split: 'electricity' },
  { id: 'microwave',    cat: 'home', label: 'Microwave oven',                unit: 'hours',   kwhPerUnit: 1.20,  split: 'electricity' },
  { id: 'kettle',       cat: 'home', label: 'Electric kettle',               unit: 'boils',   kwhPerUnit: 0.11,  split: 'electricity' },
  { id: 'phone',        cat: 'home', label: 'Phone charging',                unit: 'charges', kwhPerUnit: 0.015, split: 'electricity' },

  /* ---------- Cooking & water ---------- */
  { id: 'lpg',          cat: 'water', label: 'LPG stove cooking',             unit: 'hours',   per: 0.66, split: 'lpg' },
  { id: 'geyser',       cat: 'water', label: 'Electric water heater (geyser)',unit: 'hours',   kwhPerUnit: 2.0, split: 'electricity' },
  { id: 'shower_hot',   cat: 'water', label: 'Hot shower (10 min)',           unit: 'showers', kwhPerUnit: 0.5, split: 'electricity' },
  { id: 'shower_cold',  cat: 'water', label: 'Cold shower',                   unit: 'showers', per: 0.01, split: 'electricity' },

  /* ---------- Other ---------- */
  { id: 'stream',       cat: 'other', label: 'Video streaming',            unit: 'hours', per: 0.055, split: 'electricity' },
  { id: 'waste',        cat: 'other', label: 'Mixed waste to landfill',    unit: 'kg',    per: 0.70,  split: 'waste' },
  { id: 'shopping',     cat: 'other', label: 'Online order delivered',     unit: 'parcels', per: 0.50, split: 'fuel' },
];

/* Grid carbon intensity presets, kg CO2 per kWh. */
const GRID_PRESETS = [
  { id: 'india',  label: 'India (≈0.71)',          value: 0.71 },
  { id: 'world',  label: 'World average (≈0.48)',  value: 0.48 },
  { id: 'us',     label: 'United States (≈0.37)',  value: 0.37 },
  { id: 'eu',     label: 'European Union (≈0.25)', value: 0.25 },
  { id: 'uk',     label: 'United Kingdom (≈0.20)', value: 0.20 },
  { id: 'renew',  label: 'Mostly renewables (≈0.05)', value: 0.05 },
  { id: 'custom', label: 'Custom…',                value: null },
];

/* Daily benchmarks in kg CO2e per person per day. */
const BENCHMARKS = {
  sustainable: 5.5,   // ~2 t/yr, a widely used 2030-ish personal target
  worldAvg:    12.9,  // ~4.7 t/yr world average per capita
};

/* Comfortable-but-frugal daily baselines for the minimal-usage guide.
 * qty = suggested units/day; note = the habit that gets you there. */
const MINIMAL_BASELINES = {
  ac:        { qty: 4,    note: 'Run it at 26 °C for the hottest hours only; a fan covers the rest.' },
  heater:    { qty: 2,    note: 'Heat the room you are in, layer up, and switch off overnight.' },
  fan:       { qty: 10,   note: 'Fans are cheap to run — prefer them over AC whenever bearable.' },
  geyser:    { qty: 0.25, note: '15 minutes heats enough water for one person’s bath.' },
  tv:        { qty: 2,    note: 'Switch off at the wall — standby still draws power.' },
  desktop:   { qty: 8,    note: 'Enable sleep mode; a laptop uses about a third of the power.' },
  lights:    { qty: 5,    note: 'Daylight first; switch rooms off as you leave them.' },
  iron:      { qty: 0.25, note: 'Iron clothes in one weekly batch instead of daily.' },
  microwave: { qty: 0.3,  note: 'Fine as-is — microwaving is usually the efficient choice.' },
  stream:    { qty: 2,    note: 'Stream over Wi-Fi at 720p on small screens; download repeats.' },
  shower_hot:{ qty: 1,    note: 'One hot shower a day; shorter and cooler both help.' },
};
