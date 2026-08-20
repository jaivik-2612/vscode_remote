#!/usr/bin/env node
/**
 * Command line front end, for when a terminal is closer to hand than a
 * browser.
 *
 *   optprice --spot 100 --strike 105 --days 90 --vol 25 --rate 4.5
 *   optprice --spot 100 --strike 105 --days 90 --price 6.20   # implied vol
 */

import { valuation, impliedVol, yearsFromDays } from '../src/index.js';

const USAGE = `
Fair value for a stock option.

  optprice [options]

Contract
  --spot <n>        underlying price                     (required)
  --strike <n>      strike price                         (required)
  --days <n>        calendar days to expiry              (required)
  --type <call|put>                                      (default call)
  --style <european|american>                            (default european)

Market
  --vol <pct>       annualised volatility, in percent
  --rate <pct>      risk-free rate, in percent           (default 4.5)
  --yield <pct>     continuous dividend yield, in percent (default 0)

Give --vol to price the option. Give --price instead to solve for the
implied volatility of a quote.

  --price <n>       traded price, to imply volatility from
  --json            emit raw JSON instead of a formatted report
`.trim();

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) throw new Error(`unexpected argument: ${token}`);
    const key = token.slice(2);
    if (key === 'json' || key === 'help') {
      out[key] = true;
      continue;
    }
    const value = argv[++i];
    if (value === undefined) throw new Error(`--${key} needs a value`);
    out[key] = value;
  }
  return out;
}

function requireNumber(args, name) {
  const value = Number(args[name]);
  if (args[name] === undefined) throw new Error(`--${name} is required`);
  if (!Number.isFinite(value)) throw new Error(`--${name} must be a number`);
  return value;
}

function optionalNumber(args, name, fallback) {
  if (args[name] === undefined) return fallback;
  const value = Number(args[name]);
  if (!Number.isFinite(value)) throw new Error(`--${name} must be a number`);
  return value;
}

const pad = (label) => label.padEnd(30);
const money = (n) => n.toFixed(4).padStart(12);

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || process.argv.length === 2) {
    console.log(USAGE);
    return;
  }

  const type = args.type ?? 'call';
  const style = args.style ?? 'european';
  const inputs = {
    spot: requireNumber(args, 'spot'),
    strike: requireNumber(args, 'strike'),
    time: yearsFromDays(requireNumber(args, 'days')),
    rate: optionalNumber(args, 'rate', 4.5) / 100,
    yield: optionalNumber(args, 'yield', 0) / 100,
    type,
  };

  if (args.price !== undefined) {
    const solved = impliedVol({
      ...inputs,
      price: requireNumber(args, 'price'),
      american: style === 'american',
      steps: 300,
    });
    if (args.json) {
      console.log(JSON.stringify(solved, null, 2));
      return;
    }
    if (solved.identifiable === false) {
      console.log('No volatility can be implied: this price does not respond to volatility.');
      console.log(style === 'american'
        ? 'The quote sits at intrinsic, below the early-exercise boundary.'
        : 'The option is so far in or out of the money that its price is flat in volatility.');
      return;
    }
    console.log(`${pad('Implied volatility')}${(solved.vol * 100).toFixed(2).padStart(11)}%`);
    console.log(`${pad('Reprices to')}${money(solved.priceAtVol)}`);
    console.log(`${pad('Solver iterations')}${String(solved.iterations).padStart(12)}`);
    return;
  }

  if (args.vol === undefined) throw new Error('give either --vol to price, or --price to imply');
  const result = valuation({ ...inputs, vol: requireNumber(args, 'vol') / 100, style, steps: 400 });

  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  const label = `${style} ${type}`;
  console.log(`${label[0].toUpperCase()}${label.slice(1)}  ` +
    `spot ${inputs.spot}  strike ${inputs.strike}  ${args.days} days\n`);
  console.log(`${pad('Fair value')}${money(result.fairValue)}`);
  console.log(`${pad('  intrinsic')}${money(result.intrinsic)}`);
  console.log(`${pad('  time value')}${money(result.timeValue)}`);
  console.log(`${pad('Break-even at expiry')}${money(result.breakEven)}`);
  console.log('');
  console.log(`${pad('Delta')}${money(result.greeks.delta)}`);
  console.log(`${pad('Gamma')}${money(result.greeks.gamma)}`);
  console.log(`${pad('Vega  (per vol point)')}${money(result.greeks.vega)}`);
  console.log(`${pad('Theta (per day)')}${money(result.greeks.theta)}`);
  console.log(`${pad('Rho   (per 1% of rates)')}${money(result.greeks.rho)}`);
  console.log('');
  console.log(`${pad('Chance of finishing ITM')}${(result.probabilities.itm * 100).toFixed(1).padStart(11)}%`);
  console.log(`${pad('Chance of touching strike')}${(result.probabilities.touch * 100).toFixed(1).padStart(11)}%`);

  if (style === 'american') {
    console.log('');
    console.log(`${pad('Value if European only')}${money(result.europeanValue)}`);
    console.log(`${pad('Early-exercise premium')}${money(result.earlyExercisePremium)}`);
    console.log(`${pad('Exercise becomes optimal')}` + (result.earlyExerciseBoundary === null
      ? '       never'
      : `${type === 'put' ? 'below' : 'above'} ${result.earlyExerciseBoundary.toFixed(2)}`));
  }
}

try {
  main();
} catch (error) {
  console.error(`optprice: ${error.message}`);
  process.exitCode = 1;
}
