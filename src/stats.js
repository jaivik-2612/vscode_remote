/**
 * Normal distribution helpers.
 *
 * `normCdf` uses Hart's (1968) rational approximation, as popularised by
 * Graeme West. It is accurate to roughly double precision (~1e-15), which
 * matters because implied-volatility solvers differentiate the pricing
 * function and amplify any noise in the CDF.
 */

const SQRT_2PI = 2.5066282746310002;

/** Standard normal probability density function. */
export function normPdf(x) {
  return Math.exp(-0.5 * x * x) / SQRT_2PI;
}

/** Standard normal cumulative distribution function. */
export function normCdf(x) {
  const ax = Math.abs(x);
  let tail;

  if (ax > 37) {
    tail = 0;
  } else {
    const e = Math.exp(-0.5 * ax * ax);
    if (ax < 7.07106781186547) {
      let num = 3.52624965998911e-2 * ax + 0.700383064443688;
      num = num * ax + 6.37396220353165;
      num = num * ax + 33.912866078383;
      num = num * ax + 112.079291497871;
      num = num * ax + 221.213596169931;
      num = num * ax + 220.206867912376;

      let den = 8.83883476483184e-2 * ax + 1.75566716318264;
      den = den * ax + 16.064177579207;
      den = den * ax + 86.7807322029461;
      den = den * ax + 296.564248779674;
      den = den * ax + 637.333633378831;
      den = den * ax + 793.826512519948;
      den = den * ax + 440.413735824752;

      tail = (e * num) / den;
    } else {
      // Continued-fraction expansion for the far tail.
      let cf = ax + 0.65;
      cf = ax + 4 / cf;
      cf = ax + 3 / cf;
      cf = ax + 2 / cf;
      cf = ax + 1 / cf;
      tail = e / (cf * SQRT_2PI);
    }
  }

  return x > 0 ? 1 - tail : tail;
}

/**
 * Inverse standard normal CDF (Acklam's algorithm, ~1.15e-9 relative error).
 * Used to seed volatility searches and to build spot grids by probability.
 */
export function normInv(p) {
  if (!(p > 0 && p < 1)) {
    if (p === 0) return -Infinity;
    if (p === 1) return Infinity;
    return NaN;
  }

  const a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2,
    1.383577518672690e2, -3.066479806614716e1, 2.506628277459239];
  const b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2,
    6.680131188771972e1, -1.328068155288572e1];
  const c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838,
    -2.549732539343734, 4.374664141464968, 2.938163982698783];
  const d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996,
    3.754408661907416];

  const pLow = 0.02425;
  const pHigh = 1 - pLow;
  let x;

  if (p < pLow) {
    const q = Math.sqrt(-2 * Math.log(p));
    x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  } else if (p <= pHigh) {
    const q = p - 0.5;
    const r = q * q;
    x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
      (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
  } else {
    const q = Math.sqrt(-2 * Math.log(1 - p));
    x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
      ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
  }

  // One Halley refinement step to reach near machine precision.
  const e = normCdf(x) - p;
  const u = e * SQRT_2PI * Math.exp(0.5 * x * x);
  return x - u / (1 + 0.5 * x * u);
}
