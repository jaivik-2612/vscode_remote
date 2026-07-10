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
  /* Standard Amazon.ca search links for now — swap each for your tagged
   * affiliate URL when your Amazon Associates account is approved. */
  affiliates: {
    thermostat: 'https://www.amazon.ca/s?k=smart+thermostat',
    smart_plug: 'https://www.amazon.ca/s?k=smart+plug+with+timer',
    weatherstrip: 'https://www.amazon.ca/s?k=door+window+draft+seal+kit',
    timer_plug: 'https://www.amazon.ca/s?k=water+heater+timer',
    led_bulbs: 'https://www.amazon.ca/s?k=led+light+bulbs+pack',
    ebike: 'https://www.amazon.ca/s?k=electric+bike+adult',
  },
};
