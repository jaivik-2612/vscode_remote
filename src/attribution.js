/**
 * Premium attribution: where an option's price actually comes from.
 *
 * Every options tool shows Greeks, which are rates of change. This answers a
 * different question — why does this contract cost what it costs? — by
 * building the price up from the floor in named, additive steps, each one
 * the difference between two full revaluations that differ in exactly one
 * assumption. That is the same sequential-revaluation idea desks use for
 * P&L explain, pointed at the price level instead of a change in it.
 *
 * The ladder, in order:
 *
 *   intrinsic       what exercising right now would collect
 * + time value      the textbook option value at plain trailing volatility
 * + regime          what changes when the fitted regime volatility replaces
 *                   the trailing estimate — the piece no other tool isolates
 * + path            what the simulation sees that the closed form averages
 *                   away: volatility that itself moves, skew, fat tails
 * + early exercise  the right to exercise before expiry (American only)
 * + reconciliation  the models do not fully agree; this names the gap rather
 *                   than hiding it
 * = the consensus price on screen
 *
 * The last step matters for honesty. Attribution ladders are path-dependent:
 * re-order the steps and the individual numbers shift, because each is
 * measured against the state left by the one before. Rather than pretend
 * otherwise, the ladder is fixed, documented, and its residual is shown.
 */

/**
 * Builds the attribution ladder.
 *
 * @param {object} result the value returned by `ensembleValuation`
 * @returns {{steps: Array, total: number, note: string}}
 */
export function attributePremium(result) {
  const { blackScholes, monteCarlo, consensus, volatility, style } = result;
  const onTrailing = blackScholes.onTrailing;
  const onRegime = blackScholes.onRegime;

  const intrinsic = onTrailing.intrinsic;

  // Each rung is a difference of two prices that differ in one assumption,
  // so the label really does describe what the number measures.
  const timeValue = onTrailing.europeanValue - intrinsic;
  const regime = onRegime.europeanValue - onTrailing.europeanValue;
  const path = monteCarlo.european.price - onRegime.europeanValue;
  const earlyExercise = style === 'american'
    ? monteCarlo.value - monteCarlo.european.price
    : 0;

  const built = intrinsic + timeValue + regime + path + earlyExercise;
  const reconciliation = consensus.value - built;

  const steps = [
    {
      key: 'intrinsic',
      label: 'Intrinsic value',
      amount: intrinsic,
      detail: intrinsic > 0
        ? 'What exercising today would collect: the gap between the stock price and the strike.'
        : 'Nothing — the strike is on the wrong side of the stock price, so exercising today collects nothing.',
    },
    {
      key: 'time',
      label: 'Time value',
      amount: timeValue,
      detail: `The textbook value of the remaining ${formatDays(result.days)}, priced at ` +
        `the plain trailing volatility of ${percent(volatility.trailing)}. This is what a ` +
        'Black-Scholes calculator with no regime model would tell you.',
    },
    {
      key: 'regime',
      label: 'Regime adjustment',
      amount: regime,
      detail: describeRegime(volatility, regime),
    },
    {
      key: 'path',
      label: 'Path effects',
      amount: path,
      detail: 'What the simulation sees and the closed form cannot: volatility that ' +
        'moves during the option’s life, and a return distribution with skew and ' +
        'fatter tails than the bell curve Black-Scholes assumes.',
    },
  ];

  if (style === 'american') {
    steps.push({
      key: 'early',
      label: 'Early exercise',
      amount: earlyExercise,
      detail: earlyExercise > 0
        ? 'The extra worth of being able to exercise before expiry rather than only at it.'
        : 'Effectively nothing — on these numbers there is no advantage to exercising early.',
    });
  }

  steps.push({
    key: 'reconciliation',
    label: 'Model disagreement',
    amount: reconciliation,
    detail: 'The headline price averages three models, and this ladder walks up one ' +
      'of the three. This is the difference between them — shown rather than ' +
      'absorbed silently.',
  });

  return {
    steps,
    total: consensus.value,
    note: 'Each step is the difference between two full valuations that differ in one ' +
      'assumption, taken in the order shown. A different order would split the same ' +
      'total differently.',
  };
}

function describeRegime({ trailing, regime }, amount) {
  const direction = regime > trailing ? 'above' : 'below';
  // Below a cent the sign is noise, and claiming a direction it cannot
  // support would be exactly the kind of false precision this panel exists
  // to avoid.
  const effect = Math.abs(amount) < 0.005
    ? 'barely moves the price at all — this contract is not very sensitive to volatility'
    : amount > 0 ? 'adds to the price' : 'takes off the price';
  return `The regimes fitted to this history imply ${percent(regime)} volatility over ` +
    `the option’s life — ${direction} the ${percent(trailing)} trailing ` +
    `estimate — which ${effect}. No other input changed.`;
}

const percent = (v) => `${(v * 100).toFixed(1)}%`;
const formatDays = (d) => `${Math.round(d).toLocaleString('en-US')} days`;
