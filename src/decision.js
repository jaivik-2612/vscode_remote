/**
 * Position decisions: where a trade breaks even, and whether an in-the-money
 * option is better sold or exercised. Pure arithmetic — the UI turns the
 * returned facts into prose.
 */

/** Terminal price at which a bought option exactly repays its premium. */
export function breakEvenPrice(type, strike, premium) {
  return type === 'put' ? strike - premium : strike + premium;
}

/** What immediate exercise collects per share; zero when out of the money. */
export function intrinsicValue(type, spot, strike) {
  return Math.max(0, type === 'put' ? strike - spot : spot - strike);
}

/**
 * Sell or exercise?
 *
 * The core fact: exercising collects only intrinsic value, while selling
 * collects intrinsic plus whatever time value is left, so exercise is only
 * defensible once time value has decayed to (or below) nothing — which does
 * happen for deep in-the-money puts, where waiting costs interest on the
 * strike.
 *
 * States:
 *   'short'           the writer holds no exercise right; exit = buy back
 *   'otm'             no intrinsic value — exercising trades at a worse price
 *                     than the market, so selling is the only way out
 *   'european-locked' in the money, but European style: exercise exists only
 *                     at expiry, so before then selling is the only exit
 *   'sell'            in the money, American, meaningful time value left —
 *                     exercising would forfeit it
 *   'exercise-ok'     in the money, American, time value ≈ 0 or negative —
 *                     selling and exercising come out about level
 */
export function exerciseAdvice({ type, style, direction, spot, strike, fair }) {
  const intrinsic = intrinsicValue(type, spot, strike);
  const timeValue = fair - intrinsic;
  if (direction === 'short') return { state: 'short', intrinsic, timeValue };
  if (intrinsic === 0) return { state: 'otm', intrinsic, timeValue };
  if (style !== 'american') return { state: 'european-locked', intrinsic, timeValue };
  // Below this, the "forfeited" time value is inside the models' own noise
  // (and bid-ask spread), so calling it a toss-up is the honest answer.
  const threshold = Math.max(0.01, fair * 0.01);
  return timeValue > threshold
    ? { state: 'sell', intrinsic, timeValue }
    : { state: 'exercise-ok', intrinsic, timeValue };
}
