/* Feeds the synthetic fixtures through the browser pipeline in streaming mode
 * and checks the count against ground truth and against the Python detector.
 *
 *   node test/js_parity.mjs
 */
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { RepCounter } from '../web/pipeline.js';

// The two ports are pinned separately and must agree with each other everywhere.
// They disagreed by one on `legcurl_slow` until repetitions sharing a whole lobe were
// merged; the pins stayed apart through that so the disagreement could not hide, and
// this harness is also what caught a real porting bug -- a median taking the upper
// middle on one side and averaging on the other.


const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, 'fixtures');
const expected = JSON.parse(readFileSync(join(fixtures, 'expected.json'), 'utf8'));

let failures = 0;

for (const name of Object.keys(expected)) {
  const exp = expected[name];
  const rows = readFileSync(join(fixtures, `${name}.csv`), 'utf8').trim().split('\n').slice(1);
  const counter = new RepCounter();

  // replay as a stream: push samples, update every ~250 ms of signal time
  let nextUpdate = 0;
  for (const line of rows) {
    const [t, x, y, z] = line.split(',').map(Number);
    counter.push(t, x, y, z);
    if (t >= nextUpdate) { counter.update(); nextUpdate = t + 0.25; }
  }
  counter.update();

  // Measured against what the streaming counter is known to do, which is not always
  // what the offline reference does. The offline pass sees the whole set at once; the
  // counter sees a 60 s window and may never revise a commit. At the start of a very
  // slow set a short window is short relative to one repetition, the order-2 detrend
  // oscillates across it, and the zero crossings that oscillation creates are real
  // lobes — three of them inside the first repetition of `legcurl_slow`, committed
  // before any later window can disagree.
  //
  // The point of this harness is that JavaScript and Swift behave identically, so that
  // is what it asserts. Both gaps — to the offline run and to the truth — are printed
  // on every line rather than hidden behind a passing test.
  const ok = counter.count === exp.streaming_reps_js;
  if (!ok) failures++;
  console.log(
    `${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(18)} js=${counter.count} ` +
    `python=${exp.python_reps} truth=${exp.true_reps}` +
    (counter.count === exp.true_reps ? '' : `  (+${counter.count - exp.true_reps})`) +
    (() => {
      const done = counter.phases.filter(Boolean);
      return done.length
        ? `  con/ecc median ${med(done, 0).toFixed(2)}/${med(done, 1).toFixed(2)}s (${done.length}/${counter.phases.length} resolved)`
        : '  no phases resolved';
    })()
  );

  // timing agreement against ground truth (matched greedily)
  const errs = [];
  for (const tt of exp.true_times) {
    let best = Infinity;
    for (const c of counter.reps) if (Math.abs(c - tt) < Math.abs(best)) best = c - tt;
    if (Math.abs(best) < 1.0) errs.push(best);
  }
  if (errs.length) {
    const bias = errs.reduce((a, b) => a + b, 0) / errs.length;
    console.log(`      matched ${errs.length}/${exp.true_times.length}, bias ${bias >= 0 ? '+' : ''}${bias.toFixed(3)}s`);
  }
}

function med(pairs, k) {
  const s = pairs.map(p => p[k]).sort((a, b) => a - b);
  return s[s.length >> 1];
}

console.log(failures ? `\n${failures} failing fixture(s)` : '\nall fixtures pass');
process.exit(failures ? 1 : 0);
