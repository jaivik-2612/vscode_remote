/*
 * Cloud backend configuration.
 *
 * Leave both values empty to run in device-accounts mode (data stays in the
 * browser). To turn on cloud accounts with backup/restore — mandatory
 * email+password sign-up — create a free Supabase project and paste its URL
 * and anon (public) key here. Step-by-step instructions: SETUP-CLOUD.md.
 *
 * The anon key is safe to publish: it only allows what the database's
 * row-level-security policies permit (each user can touch only their own row).
 */
const CLOUD_CONFIG = {
  supabaseUrl: 'https://cljkprrtnmydroalzycw.supabase.co',
  supabaseAnonKey: 'sb_publishable_MnE-xOMeBF5iiQHD3zX9_Q_jDO0V4nn',
};

/*
 * Monetization & contact (all optional — leave a value empty to hide that
 * feature in the app).
 *
 * donateUrl:    your Ko-fi / Buy Me a Coffee / GitHub Sponsors page.
 * contactEmail: shown in the privacy policy for data/account requests.
 * affiliates:   product links shown under matching tips, clearly labelled
 *               as affiliate links. Paste your tagged URLs from Amazon
 *               Associates / retailer programs as you join them.
 */
const MONETIZE = {
  donateUrl: '',
  contactEmail: '',
  affiliates: {
    thermostat: '',    // smart thermostat (AC / heater / furnace tips)
    smart_plug: '',    // smart plug with timer (AC tip)
    weatherstrip: '',  // draft-sealing kit (heater / furnace tips)
    timer_plug: '',    // water-heater timer (water-heater tip)
    led_bulbs: '',     // LED bulbs
    ebike: '',         // e-bike (car tip)
  },
};
