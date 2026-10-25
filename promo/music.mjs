// music.mjs — 96 BPM, A minor pentatonic. Same beat table as film.html: every event sits on that grid.
// Writes bgm.wav (music only) and sfx.wav (hits, peak-aligned to beats).
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const SR = 48000, BEAT = 0.5;
// --- beat table (keep in sync with film.html) ---
const NB = 60 / 96;
const SKIP = new Set([25, 26, 27, 28]);
const DOUBLE = new Set([13, 14, 19, 23, 24, 29, 30, 31, 32, 34, 35, 36, 40, 42, 47, 48]);
const SEG = []; { let acc = 0; for (let b = 1; b <= 48; b++) { if (SKIP.has(b)) continue; const n = DOUBLE.has(b) ? 2 : 1; SEG.push({ b, o: (b - 1) * BEAT, t: acc, d: n * NB }); acc += n * NB; } }
const FILM = SEG[SEG.length - 1].t + SEG[SEG.length - 1].d;
const BEATS = Math.round(FILM / NB);                      // 60
const filmT = o => { const g = SEG.find(x => o >= x.o && o < x.o + BEAT) || SEG[SEG.length - 1]; return g.t + (o - g.o) / BEAT * g.d; };
const oldBeat = b => SEG.find(x => x.b === b).t;          // film time of an old (scene) beat
const DUR = Math.ceil(FILM) + 2, N = SR * DUR;
const L = new Float32Array(N), R = new Float32Array(N);
const SL = new Float32Array(N), SRr = new Float32Array(N);

// deterministic noise
let seed = 1234567;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1;
const mtof = m => 440 * Math.pow(2, (m - 69) / 12);
const at = s => Math.round(s * SR);

function add(buf, start, data, gain = 1) {
  for (let i = 0; i < data.length; i++) { const j = start + i; if (j >= 0 && j < N) buf[j] += data[i] * gain; }
}
function addSt(start, data, g, pan = 0) {
  add(L, start, data, g * Math.cos((pan + 1) * Math.PI / 4) * 1.414);
  add(R, start, data, g * Math.sin((pan + 1) * Math.PI / 4) * 1.414);
}

// ---------- voices ----------
function pluck(freq, len = 0.9, bright = 0.5) {           // Karplus-Strong
  const n = at(len), p = Math.max(2, Math.round(SR / freq)), d = new Float32Array(p), out = new Float32Array(n);
  for (let i = 0; i < p; i++) d[i] = rnd() * (0.6 + 0.4 * bright);
  let idx = 0, prev = 0;
  for (let i = 0; i < n; i++) {
    const cur = d[idx]; const v = 0.5 * (cur + prev) * 0.996; prev = cur; d[idx] = v; idx = (idx + 1) % p;
    out[i] = cur * Math.min(1, i / 40);
  }
  return out;
}
function pad(freqs, len) {                                // detuned saws through a slow one-pole LPF
  const n = at(len), out = new Float32Array(n); let lp = 0;
  const ph = freqs.flatMap(f => [0, 0.3, 0.6]);
  for (let i = 0; i < n; i++) {
    const t = i / SR; let s = 0;
    freqs.forEach((f, k) => { for (let d = 0; d < 3; d++) { const ff = f * (1 + (d - 1) * 0.004); s += ((t * ff + ph[k * 3 + d]) % 1) * 2 - 1; } });
    const env = Math.min(1, t / 0.35) * Math.min(1, (len - t) / 0.4);
    lp += (s - lp) * 0.035; out[i] = lp * env / (freqs.length * 3);
  }
  return out;
}
function bass(freq, len) {
  const n = at(len), out = new Float32Array(n);
  for (let i = 0; i < n; i++) { const t = i / SR; const env = Math.min(1, t / 0.008) * Math.exp(-t * 3.2);
    out[i] = (Math.sin(2 * Math.PI * freq * t) + 0.25 * Math.sin(4 * Math.PI * freq * t)) * env; }
  return out;
}
function kick(g = 1) {                                    // soft, short: under the picture, not over it
  const n = at(0.35), out = new Float32Array(n); let ph = 0;
  for (let i = 0; i < n; i++) { const t = i / SR; const f = 48 + 90 * Math.exp(-t * 38); ph += 2 * Math.PI * f / SR;
    out[i] = Math.sin(ph) * Math.exp(-t * 11) * g; }
  return out;
}
function hat(len = 0.05) {
  const n = at(len), out = new Float32Array(n); let hp = 0, last = 0;
  for (let i = 0; i < n; i++) { const x = rnd(); hp = 0.85 * (hp + x - last); last = x; out[i] = hp * Math.exp(-i / SR * 70); }
  return out;
}
function lead(freq, len) {                                // soft triangle with vibrato
  const n = at(len), out = new Float32Array(n); let ph = 0;
  for (let i = 0; i < n; i++) { const t = i / SR; ph += freq * (1 + 0.003 * Math.sin(2 * Math.PI * 5 * t)) / SR;
    const tri = 1 - 4 * Math.abs((ph % 1) - 0.5); const env = Math.min(1, t / 0.02) * Math.exp(-t * 2.2);
    out[i] = tri * env; }
  return out;
}

// ---------- arrangement (in 96 BPM beats; one bar = 4 beats) ----------
const CH = [[57, 60, 64, 67], [60, 64, 67, 69], [62, 67, 69, 72], [64, 67, 69, 74]]; // Am7, C6, Dsus/7, Em7(11)
const ROOT = [45, 48, 50, 52];
const BAR = 4 * NB;
const sec = b => b * NB;
// section boundaries from the picture: timeline (breathes), spread (builds), drop, ending
const bTime = b => Math.round(oldBeat(b) / NB);
const B_SPARSE = bTime(29), B_SPREAD = bTime(33), B_DROP = bTime(37), B_END = bTime(45);
const bars = Math.ceil(BEATS / 4);
for (let bar = 0; bar < bars; bar++) {
  const b0 = bar * 4, t0 = sec(b0), c = CH[bar % 4];
  if (b0 >= B_END) break;
  for (let k = 0; k < 4; k++) {
    const beat = b0 + k, t = sec(beat);
    if (beat >= B_END) break;
    const sparse = beat >= B_SPARSE && beat < B_SPREAD;
    const dense = beat >= B_SPREAD && beat < B_END;
    const drop = beat >= B_DROP;
    if (k === 0 || (beat === B_SPARSE || beat === B_SPREAD || beat === B_DROP)) addSt(at(t), pad(c.map(mtof), BAR + 0.2), dense ? 0.17 : 0.13);
    // pluck arp: 8ths normally, 16ths in the drop, quarters while the timeline reads
    const div = drop ? 4 : sparse ? 1 : 2;
    for (let j = 0; j < div; j++) {
      const n = c[(beat * div + j + bar) % 4] + ((beat * div + j) % 4 === 3 ? 12 : 0);
      addSt(at(t + j * NB / div), pluck(mtof(n + 12), 0.8, drop ? 0.8 : 0.5), drop ? 0.10 : 0.12, (((beat * div + j) % 2) * 2 - 1) * 0.35);
    }
    if (beat >= 8 && !sparse && (k === 0 || k === 2)) addSt(at(t), bass(mtof(ROOT[bar % 4]), NB * 1.6), k === 0 ? 0.32 : 0.22);
    if (sparse && k === 0) addSt(at(t), bass(mtof(ROOT[bar % 4]), BAR), 0.26);
    if (!sparse && (drop || k % 2 === 0)) addSt(at(t), kick(), 0.42);
    if (!sparse) { addSt(at(t + NB / 2), hat(), 0.07, 0.3); if (drop) { addSt(at(t + NB / 4), hat(), 0.045, 0.3); addSt(at(t + 3 * NB / 4), hat(), 0.045, 0.3); } }
  }
}
// lead over the drop: one note per beat, a few eighths
const MEL = [76, 74, 72, 69, 72, 74, 76, 79, 76, 74];
MEL.forEach((m, i) => addSt(at(sec(B_DROP + i)), lead(mtof(m), NB + 0.6), 0.13, 0.1));
// final chord at the ending, rings into the silence and decays
for (const m of [45, 57, 60, 64, 67, 69]) addSt(at(sec(B_END)), pluck(mtof(m), 5.0, 0.3), 0.11);
addSt(at(sec(B_END)), lead(mtof(69), 2.4), 0.12, 0.1);
// riser into the drop
{ const n = at(3 * NB), out = new Float32Array(n); let lp = 0;
  for (let i = 0; i < n; i++) { const p = i / n; lp += (rnd() - lp) * (0.02 + 0.3 * p); out[i] = lp * p * p; }
  addSt(at(sec(B_DROP - 3)), out, 0.22); }

// ---------- SFX, peak-aligned ----------
function click() { const n = at(0.06), o = new Float32Array(n);
  for (let i = 0; i < n; i++) { const t = i / SR; o[i] = (Math.sin(2 * Math.PI * 2100 * t) * 0.6 + rnd() * 0.4) * Math.exp(-t * 90) * Math.min(1, i / 24); } return o; }
function thump() { const n = at(0.4), o = new Float32Array(n); let ph = 0;
  for (let i = 0; i < n; i++) { const t = i / SR; ph += 2 * Math.PI * (40 + 60 * Math.exp(-t * 25)) / SR; o[i] = Math.sin(ph) * Math.min(1, t / 0.006) * Math.exp(-t * 9); } return o; }
function whoosh() { const n = at(0.45), o = new Float32Array(n); let a = 0, b = 0;
  for (let i = 0; i < n; i++) { const p = i / n; const env = Math.sin(Math.PI * Math.pow(p, 0.6)); const x = rnd();
    const k = 0.05 + 0.5 * env; a += (x - a) * k; b += (a - b) * k; o[i] = (a - b) * env * 2.2; } return o; }
const peak = d => { let m = 0, k = 0; for (let i = 0; i < d.length; i++) if (Math.abs(d[i]) > m) { m = Math.abs(d[i]); k = i; } return k; };
function hitAt(beat, data, g) { const t = oldBeat(beat); const s = at(t) - peak(data);
  add(SL, s, data, g); add(SRr, s, data, g); }
const C = click(), T = thump(), W = whoosh();
for (const b of [4, 17, 20, 24, 37, 42]) hitAt(b, C, 0.32);
for (const b of [3, 21, 37]) hitAt(b, T, 0.55);
hitAt(21, W, 0.35);
// small ticks for the typed password dots (beat 24 offbeats, beat 41 eighths)
for (let i = 0; i < 8; i++) { const s = at(filmT(11.5 + 0.06 + i * 0.03)); add(SL, s, C, 0.07); add(SRr, s, C, 0.07); }
hitAt(41, C, 0.18);                                 // padlock appears

// ---------- reverb (Schroeder) on music ----------
function reverb(x) {
  const out = new Float32Array(x.length);
  const combs = [1557, 1617, 1491, 1422].map(n => ({ b: new Float32Array(n), i: 0 }));
  const aps = [225, 556].map(n => ({ b: new Float32Array(n), i: 0 }));
  for (let i = 0; i < x.length; i++) {
    let s = 0;
    for (const c of combs) { const y = c.b[c.i]; c.b[c.i] = x[i] + y * 0.80; c.i = (c.i + 1) % c.b.length; s += y; }
    s /= 4;
    for (const a of aps) { const y = a.b[a.i]; const v = s + y * 0.5; a.b[a.i] = v; a.i = (a.i + 1) % a.b.length; s = y - v * 0.5; }
    out[i] = s;
  }
  return out;
}
const rl = reverb(L), rr = reverb(R);
for (let i = 0; i < N; i++) { L[i] += rl[i] * 0.28; R[i] += rr[i] * 0.28; }
// half beat of quiet at 23.5: duck everything except the decaying tail
{ const q = at(filmT(23.5)); for (let i = q; i < N; i++) { const g = Math.exp(-(i - q) / SR * 3); L[i] *= g; R[i] *= g; } }

function writeWav(path, a, b, gain) {
  let m = 0; for (let i = 0; i < N; i++) m = Math.max(m, Math.abs(a[i]), Math.abs(b[i]));
  const g = gain ?? (m > 0 ? 0.89 / m : 1), buf = Buffer.alloc(44 + N * 4);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write('WAVEfmt ', 8); buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22); buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28);
  buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(N * 4, 40);
  for (let i = 0; i < N; i++) { buf.writeInt16LE(Math.round(a[i] * g * 32767), 44 + i * 4); buf.writeInt16LE(Math.round(b[i] * g * 32767), 46 + i * 4); }
  fs.writeFileSync(path, buf); return g;
}
const gm = writeWav(fileURLToPath(new URL('./out/bgm.wav', import.meta.url)), L, R);
// sfx share the music's gain so their balance is what's written above
writeWav(fileURLToPath(new URL('./out/sfx.wav', import.meta.url)), SL, SRr, gm);
console.log('ok', { film: FILM.toFixed(3), beats: BEATS, musicGain: gm.toFixed(3), blackAt: filmT(23.75).toFixed(3) });
