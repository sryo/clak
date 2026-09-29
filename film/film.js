/* Clak "Macro" hero: a scroll-scrubbed 150-frame film, a live 2D FX layer on top of it
 * (dust, spark and trail, galaxy, caret), and two live DOM screens that take over from
 * the locked frames 138–149.
 *
 * Site build, forked from lab/macro/film/film.js (scripts/sync-film.sh --merge-player
 * 3-way merges later lab changes). Site differences: namespaced .film__ classes, URLs
 * relative to data-base, the title as the first beat, a portrait set from
 * frames/mobile/beats.json when the render ships one, the clean plate at the lock, frames
 * fetched only after the page has loaded, Save-Data treated like reduced motion, and
 * window.clakFilm.ownsKeys() so the page's other demo knows when to stand back.
 *
 * Coordinates: frames/track.json and meta.json are in frame pixels (1600×900, origin
 * top-left). `view` is the cover fit that maps frame pixels to stage CSS pixels; the
 * frame canvas, the FX canvas and the screen homographies all go through it.
 *
 * Memory model (from shot1): every frame's compressed bytes are kept, but only a window
 * of decoded ImageBitmaps around the scroll position, since 150 decoded frames would be
 * ~860 MB of RGBA. */
(() => {
  'use strict';

  const hero = document.getElementById('film');
  if (!hero) return;
  const BASE = hero.dataset.base || '';
  const url = (p) => BASE + p;
  const stage = hero.querySelector('.film__stage');
  const canvas = hero.querySelector('canvas.film__frames');
  const ctx = canvas.getContext('2d', { alpha: false });
  const fxCanvas = hero.querySelector('canvas.film__fx');
  const fx = fxCanvas.getContext('2d');
  const lines = [...hero.querySelectorAll('.film__line, .film__title, .film__cue')];
  const loadingEl = hero.querySelector('.film__loading');
  const pillEl = hero.querySelector('.film__screen--pill');
  const phoneEl = hero.querySelector('.film__screen--phone');
  const hudText = pillEl.querySelector('.film__hud');
  const fieldText = phoneEl.querySelector('.film__fieldtext');
  const tapInput = hero.querySelector('.film__tap input');
  const announceEl = document.getElementById('filmAnnounce');

  const params = new URLSearchParams(location.search);
  const DEV = params.has('dev');                          // allows the synthetic track
  const DEBUG_SCREENS = params.has('screens');

  const LINE_FADE = 2.5;            // storyboard % over which a copy line fades
  const FETCH_CONCURRENCY = 6;
  const DECODE_CONCURRENCY = 4;
  const AHEAD = 14, BEHIND = 5;
  const DECODED_BUDGET = { desktop: 200e6, mobile: 110e6 };
  const LOADING_DELAY_MS = 450;
  const DEMO = 'lak';               // typed after the landed "C" (storyboard §9)
  const LANDED = 'C';

  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const portrait = matchMedia('(max-aspect-ratio: 4/5)');
  const coarse = matchMedia('(pointer: coarse)');

  const stats = window.__hero = {
    firstFrameMs: null, allFetchedMs: null,
    set: null, format: null, bytes: 0, draws: 0, misses: 0, decodes: 0, evictions: 0,
    trackSource: null,
    tickMs: [], fxMs: [],
  };

  let meta, set, N, track;
  let NI = 0;                       // images in the active set (N story frames map onto them)
  let spec = null, plate = null, plateFor = '';
  let assets = null;                // film/assets.json from scripts/sync-film.sh: which optional files exist
  let format = 'avif';
  let generation = 0;
  let blobs = [];
  const bitmaps = new Map();
  const decoding = new Set();
  let decodeQueue = [];
  let capacity = 32;
  let target = 0, lastTarget = 0, direction = 1;
  let drawnIndex = -1, drawnKey = '';
  let pf = 0;                       // film progress in storyboard % (100 = film end)
  let f = 0;                        // fractional frame
  let visible = true;
  let tickPending = false;
  let view = { cw: 0, ch: 0, dpr: 1, s: 1, ox: 0, oy: 0 };
  let screensKey = '';
  const saveData = !!(navigator.connection && navigator.connection.saveData);
  let staticMode = reduceMotion.matches || saveData || params.has('static');   // ?static previews it

  // ---------- math ----------

  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  const smooth01 = (x) => { const c = clamp(x, 0, 1); return c * c * (3 - 2 * c); };
  const hash = (n) => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };

  function solve(A, b) {
    const n = b.length;
    const M = A.map((row, i) => [...row, b[i]]);
    for (let c = 0; c < n; c++) {
      let p = c;
      for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
      [M[c], M[p]] = [M[p], M[c]];
      for (let r = c + 1; r < n; r++) {
        const k = M[r][c] / M[c][c];
        for (let q = c; q <= n; q++) M[r][q] -= k * M[c][q];
      }
    }
    const x = new Array(n);
    for (let r = n - 1; r >= 0; r--) {
      let s = M[r][n];
      for (let q = r + 1; q < n; q++) s -= M[r][q] * x[q];
      x[r] = s / M[r][r];
    }
    return x;
  }

  // Projective map (row-major 3×3, h33 = 1) taking src[i] → dst[i] for four point pairs.
  function homography(src, dst) {
    const A = [], b = [];
    for (let i = 0; i < 4; i++) {
      const [x, y] = src[i], [u, v] = dst[i];
      A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u);
      A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v);
    }
    return [...solve(A, b), 1];
  }
  // CSS matrix3d is column-major; z passes through, w carries the projective row.
  const toMatrix3d = ([a, b, c, d, e, g, h, i, j]) => `matrix3d(${a},${d},0,${h},${b},${e},0,${i},0,0,1,0,${c},${g},0,${j})`;

  const project = ([x, y]) => [view.ox + x * view.s, view.oy + y * view.s];

  // Pull each corner 1 px toward the centroid, so sub-pixel error falls on the dark bezel.
  function inset(quad, px) {
    const cx = quad.reduce((s, p) => s + p[0], 0) / 4, cy = quad.reduce((s, p) => s + p[1], 0) / 4;
    return quad.map(([x, y]) => { const d = Math.hypot(x - cx, y - cy) || 1; return [x + (cx - x) / d * px, y + (cy - y) / d * px]; });
  }

  // ---------- scroll map ----------

  // Piecewise-linear storyboard % → frame, with plateaus (meta.scrollMap: [[%, frame], ...]).
  function frameAt(pct) {
    const m = meta.scrollMap;
    if (pct <= m[0][0]) return m[0][1];
    for (let k = 1; k < m.length; k++) {
      const [p0, f0] = m[k - 1], [p1, f1] = m[k];
      if (pct <= p1) return p1 === p0 ? f1 : f0 + (f1 - f0) * (pct - p0) / (p1 - p0);
    }
    return m[m.length - 1][1];
  }

  function scrollProgress() {
    const r = hero.getBoundingClientRect();
    const span = r.height - stage.clientHeight;
    return span > 0 ? clamp(-r.top / span, 0, 1) : 1;
  }

  // ---------- track ----------

  // ?dev only: a stand-in with the same shape, for when frames/track.json is missing.
  function syntheticTrack() {
    const frames = [];
    const quad = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
    for (let i = 0; i < 150; i++) {
      const e = { i, spark: null, galaxy: null, caret: null, hud: null, hudPill: null };
      if (i >= 36 && i <= 73) e.spark = [780, lerp(430, 180, smooth(36, 66, i)), lerp(120, 12, smooth(36, 60, i))];
      if (i >= 96 && i <= 99) e.spark = [lerp(250, 860, (i - 96) / 3), 360, 10];
      if (i >= 100 && i <= 114) e.galaxy = { x: lerp(860, 1040, smooth(100, 108, i)), y: 360, scale: 36, radius: 140 };
      if (i >= 97) e.caret = [1190, 392, 17];
      if (i >= 65) { e.hud = [622, 167]; e.hudPill = quad(585, 143, 182, 47); }
      frames.push(e);
    }
    return {
      width: 1600, height: 900, frames,
      screens: { macWindow: quad(300, 45, 755, 475), phone: quad(1150, 200, 205, 440), hudPill: quad(585, 143, 182, 47) },
    };
  }

  // Portrait set: mobile image m shows story frame story[m] (frames/mobile/beats.json). The
  // player keeps working in story frames; only image lookups go through this inverse.
  function imageAt(t) {
    const st = set && set.story;
    if (!st) return t;
    if (t <= st[0]) return 0;
    for (let m = 1; m < st.length; m++) {
      if (t <= st[m]) return st[m] === st[m - 1] ? m : m - 1 + (t - st[m - 1]) / (st[m] - st[m - 1]);
    }
    return st.length - 1;
  }

  // The mobile track is per mobile image; resample it onto the story frames the FX code uses.
  function resampleToStory(raw, n) {
    const byI = [];
    for (const e of raw.frames || []) if (e) byI[e.i] = e;
    const mix = (A, B, u) => {
      if (A == null || B == null) return u < 0.5 ? A ?? null : B ?? null;
      if (Array.isArray(A)) return A.map((a, k) => (Array.isArray(a) ? a.map((c, q) => lerp(c, B[k][q], u)) : lerp(a, B[k], u)));
      const o = {};
      for (const k of Object.keys(A)) o[k] = typeof A[k] === 'number' && typeof B[k] === 'number' ? lerp(A[k], B[k], u) : A[k];
      return o;
    };
    const frames = [];
    for (let s = 0; s < n; s++) {
      const m = imageAt(s), m0 = Math.floor(m), m1 = Math.min(set.story.length - 1, m0 + 1), u = m - m0;
      const A = byI[m0] || {}, B = byI[m1] || {};
      const e = { i: s };
      for (const k of ['spark', 'galaxy', 'caret', 'hud', 'hudPill']) e[k] = mix(A[k], B[k], u);
      frames.push(e);
    }
    return { width: raw.width, height: raw.height, screens: raw.screens, frames };
  }

  function buildTrack(raw) {
    let source = 'real';
    if (!raw || !Array.isArray(raw.frames)) {
      if (!DEV) return null;
      raw = syntheticTrack(); source = 'synthetic';
    }
    const sx = set.width / (raw.width || 1600), sy = set.height / (raw.height || 900);
    const sp = (p) => p && [p[0] * sx, p[1] * sy, ...(p.length > 2 ? [p[2] * sy] : [])];
    const sq = (q) => q && q.map(sp);
    const frames = new Array(N);
    for (const e of raw.frames) if (e && e.i >= 0 && e.i < N) frames[e.i] = e;
    const out = [];
    for (let i = 0; i < N; i++) {
      const e = frames[i] || {};
      out.push({
        spark: sp(e.spark), caret: sp(e.caret), hud: sp(e.hud), hudPill: sq(e.hudPill),
        galaxy: e.galaxy ? { x: e.galaxy.x * sx, y: e.galaxy.y * sy, scale: e.galaxy.scale * sy, radius: e.galaxy.radius != null ? e.galaxy.radius * sy : null } : null,
      });
    }
    const runs = (key) => {
      const r = [];
      out.forEach((e, i) => { if (e[key]) { if (r.length && r[r.length - 1][1] === i - 1) r[r.length - 1][1] = i; else r.push([i, i]); } });
      return r;
    };
    const range = (key) => { const r = runs(key); return r.length ? [r[0][0], r[r.length - 1][1]] : null; };
    const sc = raw.screens || {};
    return {
      source, frames: out,
      screens: { macWindow: sq(sc.macWindow), phone: sq(sc.phone), hudPill: sq(sc.hudPill), radius: sc.radius || {} },
      sparkRuns: runs('spark'), galaxy: range('galaxy'), caret: range('caret'), hud: range('hud'),
    };
  }

  // Value of a track field at a fractional frame, and how present it is (fades at the ends).
  function sample(key, t) {
    if (!track || t < 0 || t > N - 1) return null;
    const i0 = Math.floor(t), i1 = Math.min(N - 1, i0 + 1), u = t - i0;
    const A = track.frames[i0][key], B = track.frames[i1][key];
    if (A && B) {
      if (Array.isArray(A)) return { v: A.map((a, k) => lerp(a, B[k], u)), a: 1 };
      return { v: { x: lerp(A.x, B.x, u), y: lerp(A.y, B.y, u), scale: lerp(A.scale, B.scale, u), radius: A.radius != null && B.radius != null ? lerp(A.radius, B.radius, u) : A.radius }, a: 1 };
    }
    if (A) return { v: A, a: 1 - u };
    if (B) return { v: B, a: u };
    return null;
  }

  // ---------- layout ----------

  // "follow": after the fixed keys, crop so the subject (spark, galaxy, caret, then the phone at
  // the lock) sits mid-frame. Keys every few frames, smoothstepped between, so the crop glides.
  function followKeys() {
    const keys = [...(set.focusFrom || [[0, 0.5, 0.5]])];
    const last = keys[keys.length - 1][0];
    const phone = track.screens.phone, px = phone ? phone.reduce((a, p) => a + p[0], 0) / 4 : set.width / 2;
    const cw = stage.clientWidth || 390, ch = stage.clientHeight || 844;
    const s = Math.max(cw / set.width, ch / set.height), slack = cw - set.width * s;
    for (let i = last + 6; i < N; i += 6) {
      const e = track.frames[i];
      const x = e.spark ? e.spark[0] : e.galaxy ? e.galaxy.x : e.caret ? e.caret[0] : e.hud ? e.hud[0] : px;
      keys.push([i, slack < 0 ? clamp((cw / 2 - x * s) / slack, 0, 1) : 0.5, keys[keys.length - 1][2]]);
    }
    keys.push([N - 1, slack < 0 ? clamp((cw / 2 - px * s) / slack, 0, 1) : 0.5, keys[keys.length - 1][2]]);
    return keys;
  }

  function focusAt(t) {
    const k = set.focusKeys || [[0, 0.5, 0.5]];
    if (t <= k[0][0]) return [k[0][1], k[0][2]];
    for (let n = 1; n < k.length; n++) {
      if (t <= k[n][0]) {
        const u = smooth(k[n - 1][0], k[n][0], t);
        return [lerp(k[n - 1][1], k[n][1], u), lerp(k[n - 1][2], k[n][2], u)];
      }
    }
    const last = k[k.length - 1];
    return [last[1], last[2]];
  }

  function updateView() {
    const cw = stage.clientWidth, ch = stage.clientHeight;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const s = Math.max(cw / set.width, ch / set.height);
    const [fxr, fyr] = focusAt(f);
    view = { cw, ch, dpr, s, ox: (cw - set.width * s) * fxr, oy: (ch - set.height * s) * fyr };
  }

  function layout() {
    if (!set) return;
    set.focusKeys = set.focus === 'follow' && track ? followKeys() : set.focusFrom || set.focus;
    updateView();
    const bw = Math.round(view.cw * view.dpr), bh = Math.round(view.ch * view.dpr);
    for (const c of [canvas, fxCanvas]) if (c.width !== bw || c.height !== bh) { c.width = bw; c.height = bh; }
    drawnKey = ''; screensKey = '';
    requestTick();
  }

  // ---------- loading & decoding ----------

  const pad = (i) => String(i).padStart(3, '0');
  const fill = (path, fmt, i) => path.replaceAll('{format}', fmt).replace('{index}', pad(i));
  const frameURL = (i, fmt = format) => url(fill(set.path, fmt, i));
  function loadOrder(n, step) {
    const seen = new Set(), order = [];
    const push = (i) => { if (i >= 0 && i < n && !seen.has(i)) { seen.add(i); order.push(i); } };
    push(0); push(n - 1);
    for (let s = step; s >= 1; s >>= 1) for (let i = 0; i < n; i += s) push(i);
    return order;
  }

  async function fetchWithRetry(url, tries = 3) {
    for (let k = 0; ; k++) {
      try {
        const res = await fetch(url);
        if (res.ok || res.status === 404) return res;
        if (res.status < 500 || k >= tries - 1) throw new Error(`${res.status} ${url}`);
      } catch (e) {
        if (k >= tries - 1) throw e;
      }
      await new Promise((r) => setTimeout(r, 250 * 2 ** k));
    }
  }

  async function fetchFrame(i, fmt = format) {
    const res = await fetchWithRetry(frameURL(i, fmt));
    if (!res.ok) throw new Error(`${res.status} frame ${i}`);
    return res.blob();
  }

  async function fetchBlob(i, gen) {
    const blob = await fetchFrame(i);
    if (gen !== generation) return;
    blobs[i] = blob;
    stats.bytes += blob.size;
    if (i === 0 || i === NI - 1 || Math.abs(i - target) <= AHEAD) enqueueDecode(i);
  }

  async function decodeBlob(blob) {
    if ('createImageBitmap' in window) return createImageBitmap(blob);
    const img = new Image();
    img.src = URL.createObjectURL(blob);
    await img.decode();
    return img;
  }

  // AVIF is tried on one frame; a decode failure drops the whole set to WebP.
  async function pickFormat(gen, i) {
    for (const fmt of meta.formats) {
      try {
        const blob = await fetchFrame(i, fmt);
        const bmp = await decodeBlob(blob);
        if (gen !== generation) return false;
        format = fmt;
        blobs[i] = blob; stats.bytes += blob.size;
        bitmaps.set(i, bmp);
        return true;
      } catch (_) { /* next format */ }
    }
    return false;
  }

  function enqueueDecode(i) {
    if (!blobs[i] || bitmaps.has(i) || decoding.has(i) || decodeQueue.includes(i)) return;
    decodeQueue.push(i);
    pumpDecodes();
  }

  function pumpDecodes() {
    const gen = generation;
    while (decoding.size < DECODE_CONCURRENCY && decodeQueue.length) {
      decodeQueue.sort((a, b) => Math.abs(a - target) - Math.abs(b - target));
      const i = decodeQueue.shift();
      if (!blobs[i] || bitmaps.has(i)) continue;
      decoding.add(i);
      decodeBlob(blobs[i]).then((bmp) => {
        decoding.delete(i);
        if (gen !== generation) { bmp.close?.(); return; }
        bitmaps.set(i, bmp);
        stats.decodes++;
        evict();
        requestTick();
        pumpDecodes();
      }, (err) => { decoding.delete(i); console.warn('decode failed', i, err); pumpDecodes(); });
    }
  }

  function evict() {
    while (bitmaps.size > capacity) {
      let worst = -1, dist = -1;
      for (const i of bitmaps.keys()) {
        if (i === NI - 1 || i === drawnIndex) continue;
        const d = Math.abs(i - target) * (Math.sign(i - target) === direction ? 1 : 2.5);
        if (d > dist) { dist = d; worst = i; }
      }
      if (worst < 0) return;
      bitmaps.get(worst).close?.();
      bitmaps.delete(worst);
      stats.evictions++;
    }
  }

  function refreshWindow() {
    decodeQueue = decodeQueue.filter((i) => Math.abs(i - target) <= AHEAD + BEHIND);
    const lo = direction > 0 ? target - BEHIND : target - AHEAD;
    const hi = direction > 0 ? target + AHEAD : target + BEHIND;
    for (let i = Math.max(0, lo); i <= Math.min(NI - 1, hi); i++) enqueueDecode(i);
  }

  async function loadJSON(path) {
    try {
      const res = await fetch(url(path));
      return res.ok ? await res.json() : null;
    } catch (_) { return null; }
  }

  // Clean plate: the locked frame with no baked text, shown once the live screens are fully on.
  async function loadPlate(gen, key) {
    if (plateFor === key || (assets && !(assets.plate && assets.plate[key]))) return;
    plateFor = key;
    const path = `frames/${key}/plate/${pad(NI - 1)}_clean.{format}`;
    try {
      const res = await fetch(url(path.replaceAll('{format}', format)));
      if (!res.ok) return;
      const bmp = await decodeBlob(await res.blob());
      if (gen !== generation) { bmp.close?.(); return; }
      plate = bmp; drawnKey = ''; requestTick();
    } catch (_) { /* no plate: the last frame stays */ }
  }

  // Frame sizes and measured colours from the render; without it the CSS defaults stand.
  function applySpec(key) {
    if (!spec || !spec.hudPill || !spec.hudPill.texture) return;
    const [w, h] = spec.hudPill.texture;
    NATIVE.hudPill = [w, h];
    pillEl.style.width = w + 'px'; pillEl.style.height = h + 'px';
    const pt = spec.hudPill.ptPx || h / 46;
    HUD_MAX = w - (spec.hudPill.textLeftPx || 29 * pt) - 16 * pt;
    const c = spec[key] && spec[key].renderedColors;
    if (!c) return;
    const put = (name, v) => { if (v) hero.style.setProperty(name, v); else hero.style.removeProperty(name); };
    put('--film-pill-bg', c.hudPill && c.hudPill.background);
    put('--film-pill-text', c.hudPill && c.hudPill.text && c.hudPill.text.color);
    put('--film-field-bg', c.phone && c.phone.fieldFill);
    put('--film-field-text', c.phone && c.phone.text && c.phone.text.color);
    put('--film-caret', c.phone && c.phone.caret && c.phone.caret.color);
  }

  // Frames wait for the page to finish loading and for the film to be on screen.
  const pageLoaded = new Promise((r) => (document.readyState === 'complete' ? r() : addEventListener('load', r, { once: true })));
  let onScreen;
  const filmOnScreen = new Promise((r) => { onScreen = r; });

  async function start() {
    const gen = ++generation;
    for (const b of bitmaps.values()) b.close?.();
    bitmaps.clear(); decoding.clear(); decodeQueue = []; blobs = [];
    plate?.close?.(); plate = null; plateFor = '';
    drawnIndex = -1; drawnKey = ''; screensKey = ''; screensOpacity = -1; track = null;
    const key = portrait.matches ? 'mobile' : 'desktop';
    N = meta.frames;
    set = { ...meta.sets[key] };
    let raw = null, imagesKey = 'desktop';
    if (key === 'mobile' && (!assets || assets.mobile)) {
      // A rendered portrait set replaces the desktop crop when it's there.
      const [beats, tm] = await Promise.all([loadJSON('frames/mobile/beats.json'), loadJSON('frames/track_mobile.json')]);
      if (beats && Array.isArray(beats.story) && tm && Array.isArray(tm.frames)) {
        set = {
          width: tm.width, height: tm.height, path: 'frames/mobile/{format}/{index}.{format}', focus: [[0, 0.5, 0.5]], story: beats.story,
          // The portrait camera's key light, in its frame pixels (read off mobile/png/000); meta.json can override it.
          beam: (meta.sets.mobile && meta.sets.mobile.beam) || { a: [-100, 170], b: [850, 1030], w0: 150, w1: 260 },
        };
        raw = resampleToStory(tm, N);
        imagesKey = 'mobile';
      }
    }
    if (!raw) raw = await loadJSON('frames/track.json');
    NI = set.story ? set.story.length : N;
    hero.classList.toggle('has-portrait-set', imagesKey === 'mobile');
    // Still portrait: the phone panel fills the bottom of the frame, so the title moves below it.
    if (staticMode) {
      const title = hero.querySelector('.film__title');
      if (imagesKey === 'mobile') hero.appendChild(title); else hero.querySelector('.film__copy').prepend(title);
    }
    capacity = Math.max(12, Math.floor(DECODED_BUDGET[key] / (set.width * set.height * 4)));
    stats.set = imagesKey === key ? key : `${key} (desktop crop)`;
    track = buildTrack(raw);
    stats.trackSource = track ? track.source : 'missing';
    if (track && track.source !== 'real') console.info('film: using the synthetic track (?dev)');
    if (gen !== generation) return;
    applySpec(imagesKey);
    layout();

    const loadingTimer = setTimeout(() => { if (stats.firstFrameMs == null) loadingEl.hidden = false; }, LOADING_DELAY_MS);
    const first = staticMode ? NI - 1 : 0;
    target = lastTarget = first;
    if (!(await pickFormat(gen, first))) { console.error('no decodable frame format'); return; }
    stats.format = format;
    requestTick();
    if (staticMode) { clearTimeout(loadingTimer); loadPlate(gen, imagesKey); return; }

    await pageLoaded;
    await filmOnScreen;
    if (gen !== generation) return;
    const order = loadOrder(NI, meta.keyframeStep).filter((i) => !blobs[i]);
    let next = 0;
    const worker = async () => {
      while (next < order.length && gen === generation) {
        const i = order[next++];
        try { await fetchBlob(i, gen); } catch (e) { console.warn(e); }
      }
    };
    await Promise.all(Array.from({ length: FETCH_CONCURRENCY }, worker));
    if (gen === generation) { stats.allFetchedMs = Math.round(performance.now()); loadPlate(gen, imagesKey); }
    clearTimeout(loadingTimer);
  }

  // ---------- FX: dust ----------

  const TAU = Math.PI * 2;
  let sprite = null;

  // One soft dot, drawn scaled for every glow: white core → link blue → transparent.
  function makeSprite(stops) {
    const c = document.createElement('canvas');
    c.width = c.height = 64;
    const g = c.getContext('2d');
    const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    for (const [o, col] of stops) grad.addColorStop(o, col);
    g.fillStyle = grad;
    g.fillRect(0, 0, 64, 64);
    return c;
  }
  const blueGlow = () => sprite.blue;

  let motes = null;
  function makeMotes(n) {
    const out = [];
    for (let k = 0; k < n; k++) {
      const z = hash(k * 3.1);                 // 0 = in the focal plane, 1 = far out of focus
      out.push({
        u: hash(k * 7.7), v: hash(k * 5.3) * 2 - 1, z,
        r: z > 0.78 ? 5 + hash(k * 2.2) * 7 : 0.7 + hash(k * 2.2) * 1.1,
        ph: hash(k * 9.1) * TAU, w: 0.25 + hash(k * 4.4) * 0.35,
        speed: 0.004 + hash(k * 6.6) * 0.008,
      });
    }
    return out;
  }

  function drawDust(t, alpha) {
    const { a, b, w0, w1 } = set.beam || meta.beam;
    const ax = b[0] - a[0], ay = b[1] - a[1], len = Math.hypot(ax, ay);
    const nx = -ay / len, ny = ax / len;
    const warm = sprite.warm;
    for (const m of motes) {
      // Drifting down the beam, slowly, with a lazy sideways sway; wraps at the ends.
      const u = (m.u + t * m.speed) % 1;
      const v = m.v + 0.18 * Math.sin(t * m.w + m.ph) + 0.06 * Math.sin(t * m.w * 2.3 + m.ph * 1.7);
      const half = lerp(w0, w1, u) / 2;
      const x = a[0] + ax * u + nx * v * half + 6 * Math.sin(t * 0.21 + m.ph);
      const y = a[1] + ay * u + ny * v * half - f * 1.1;          // a hint of parallax with the push-in
      const inBeam = 1 - smooth(0.55, 1.05, Math.abs(v));
      const edge = smooth(0, 0.08, u) * (1 - smooth(0.92, 1, u));
      const twinkle = 0.65 + 0.35 * Math.sin(t * (0.9 + m.w) + m.ph * 3);
      const area = m.r > 3 ? 0.16 * (3 / m.r) : 1;                // defocused motes dim like bokeh
      const o = alpha * inBeam * edge * twinkle * area * 0.85;
      if (o < 0.01) continue;
      fx.globalAlpha = o;
      const d = m.r * (m.r > 3 ? 2.2 : 3.2);
      fx.drawImage(warm, x - d, y - d, d * 2, d * 2);
    }
    fx.globalAlpha = 1;
  }

  // ---------- FX: spark and trail ----------

  const TRAIL = 9, TRAIL_STEP = 0.25, SHED_EVERY = 0.5, SHED_LIFE = 7;

  // The spark flies in runs (key → pill, then pill → galaxy); each fades in and out on its own.
  const sparkRun = (t) => track.sparkRuns.find(([a, b]) => t >= a - 1 && t <= b + 1);

  function sparkPresence(t) {
    const run = sparkRun(t);
    const s = run && sample('spark', t);
    if (!s) return null;
    const [ra, rb] = run, edge = Math.min(4, (rb - ra) / 2);
    const a = s.a * smooth(ra, ra + edge, t) * (1 - smooth(rb - edge, rb + 0.5, t));
    return a > 0.003 ? { p: s.v, a, run } : null;
  }

  function drawSpark() {
    const head = sparkPresence(f);
    if (!head) return false;
    const pts = [];
    for (let k = 0; k <= TRAIL / TRAIL_STEP; k++) {
      const t = f - k * TRAIL_STEP;
      const s = t >= head.run[0] ? sample('spark', t) : null;
      if (!s) break;
      pts.push(s.v);
    }
    const r = head.p[2] || 6;
    const core = Math.min(r, 7), spread = clamp(7 / r, 0.12, 1);
    fx.lineCap = 'round';
    // Halo then core, tail to head: sharp at the head, fading at the tail.
    for (const [col, width, ak] of [['#0A84FF', Math.min(r * 2.4, 60), 0.22 * spread], ['#3EA0FF', core * 0.7, 0.9]]) {
      fx.strokeStyle = col;
      for (let k = pts.length - 1; k > 0; k--) {
        const u = k / (TRAIL / TRAIL_STEP);
        fx.globalAlpha = head.a * ak * (1 - u) ** 2;
        fx.lineWidth = Math.max(0.4, width * (1 - u) ** 1.3);
        fx.beginPath();
        fx.moveTo(pts[k][0], pts[k][1]);
        fx.lineTo(pts[k - 1][0], pts[k - 1][1]);
        fx.stroke();
      }
    }
    // The tail sheds dots: seeded per spawn time, so a scrub replays them exactly.
    const glow = blueGlow();
    for (let s = Math.floor(f / SHED_EVERY) * SHED_EVERY, n = 0; n < SHED_LIFE / SHED_EVERY; s -= SHED_EVERY, n++) {
      const age = f - s;
      if (s < head.run[0] + 2) break;
      const at = sample('spark', s);
      if (!at) continue;
      const hx = hash(s * 13.3) - 0.5, hy = hash(s * 17.9) - 0.5;
      const x = at.v[0] + hx * 5 * age, y = at.v[1] + hy * 3 * age + 0.5 * age * age;
      const o = head.a * (1 - age / SHED_LIFE) ** 2 * 0.9;
      const d = 3.2 + hash(s * 3.3) * 2;
      fx.globalAlpha = o;
      fx.drawImage(glow, x - d, y - d, d * 2, d * 2);
    }
    // Head: a wide soft halo, then a small hot core.
    const halo = Math.max(core * 7, r * 2.2);
    fx.globalAlpha = head.a * 0.55 * Math.sqrt(spread);
    fx.drawImage(glow, head.p[0] - halo, head.p[1] - halo, halo * 2, halo * 2);
    fx.globalAlpha = head.a * spread;
    const d = Math.max(core * 1.6, r);
    fx.drawImage(sprite.core, head.p[0] - d, head.p[1] - d, d * 2, d * 2);
    fx.globalAlpha = 1;
    return true;
  }

  // ---------- FX: galaxy (port of ClakRemote/ConnectingGalaxyView.swift) ----------

  const G = {
    count: 96, extent: 80, dotRadius: 2.8,
    fallTime: 0.45, landed: 0.7, squeezeEnd: 0.82, burstStart: 0.9, burstTime: 0.6, fadeStart: 1.4, fadeEnd: 1.75,
  };
  // Same seeded scatter as the app: a 64-bit LCG, rejection at 8 pt spacing.
  G.homes = (() => {
    const MASK = (1n << 64n) - 1n;
    let seed = 0x9E3779B97F4A7C15n;
    const next = () => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & MASK; return Number(seed >> 11n) / 2 ** 53; };
    const pts = [];
    while (pts.length < G.count) {
      const r = G.extent * Math.sqrt(next()), a = next() * TAU;
      const p = [r * Math.cos(a), r * Math.sin(a)];
      if (pts.every((q) => Math.hypot(q[0] - p[0], q[1] - p[1]) > 8)) pts.push(p);
    }
    return pts.map(([x, y]) => ({ r: Math.hypot(x, y), a: Math.atan2(y, x) }));
  })();
  G.sizes = G.homes.map((h) => G.dotRadius * (1.05 - 0.45 * h.r / G.extent));
  G.totalArea = G.sizes.reduce((s, r) => s + r * r, 0);
  const fallStart = (i) => 0.25 * (G.homes[i].r / G.extent) ** 0.7;

  function waiting(i, home, t) {
    const edge = home.r / G.extent;
    const gather = 1 - 0.08 * (0.5 + 0.5 * Math.sin(t * TAU / 5.5));
    const a = home.a + t * (0.32 - 0.14 * edge);
    const r = home.r * gather;
    return [
      r * Math.cos(a) + 1.5 * Math.sin(t * TAU / (4.1 + 0.09 * i) + i * 1.9),
      r * Math.sin(a) + 1.5 * Math.cos(t * TAU / (5.3 + 0.07 * i) + i * 2.7),
    ];
  }

  function infall([x, y], p) {
    const fall = p * p * p, spin = 2.2 * fall, k = 1 - fall;
    const cx = x * k, cy = y * k;
    return [cx * Math.cos(spin) - cy * Math.sin(spin), cx * Math.sin(spin) + cy * Math.cos(spin)];
  }

  function coreRadius(since, m, cover) {
    const accreted = 14 * Math.sqrt(m) * (1 - 0.6 * m * m);
    if (since < G.landed) return accreted;
    if (since < G.squeezeEnd) { const x = (since - G.landed) / (G.squeezeEnd - G.landed); return 5.6 - 2.6 * x * x * x; }
    if (since < G.burstStart) return 3;
    const x = Math.min((since - G.burstStart) / G.burstTime, 1);
    const eased = x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2;
    return 3 + (cover - 3) * eased;
  }

  // Frame → seconds since the app's `connectedAt`, piecewise from meta.galaxyClock, which pins
  // the app's beats to the render's: fall from 91, landed on the caret at 104 (SP.land), burst
  // at 108 (SP.burst), gone by 114 (SP.end). Before the first key the galaxy is still waiting.
  function galaxySince(t) {
    const m = meta.galaxyClock;
    if (t < m[0][0]) return -1;
    for (let n = 1; n < m.length; n++) if (t <= m[n][0]) return lerp(m[n - 1][1], m[n][1], (t - m[n - 1][0]) / (m[n][0] - m[n - 1][0]));
    const [fa, sa] = m[m.length - 2], [fb, sb] = m[m.length - 1];
    return sb + (t - fb) * (sb - sa) / (fb - fa);
  }

  // Galaxy extent in frame px: the track's `radius` while it waits, then held from the moment
  // it starts falling, because the infall itself does the shrinking.
  function galaxyExtentPx(g, t) {
    const at = (u) => { const s = sample('galaxy', u); return s ? (s.v.radius || s.v.scale * 4) : null; };
    const start = meta.galaxyClock[0][0];
    return (t < start ? at(t) : at(start)) || g.v.radius || g.v.scale * 4;
  }

  function ellipse(x, y, rx, ry, angle) {
    if (rx <= 0.05) return;
    fx.beginPath();
    fx.ellipse(x, y, rx, ry, angle, 0, TAU);
    fx.fill();
  }

  function drawGalaxy(now) {
    if (!track.galaxy) return false;
    const g = sample('galaxy', f);
    if (!g) return false;
    const since = galaxySince(f);
    const k = galaxyExtentPx(g, f) / G.extent;            // app points → frame px
    const t = now / 1000 * 0.9 + f * 0.12;                // turns on its own, and with the scroll
    const opacity = g.a * (since < 0 ? 1 : 1 - smooth01((since - G.fadeStart) / 0.35));
    if (opacity <= 0.003) return true;
    // It forms out of the spark over its first frames, rim last.
    const form = clamp((f - track.galaxy[0]) / 4, 0, 1);
    const cx = g.v.x, cy = g.v.y;
    const glow = blueGlow();

    fx.fillStyle = '#3EA0FF';
    let absorbed = 0, jiggle = 0;
    if (since < G.burstStart) {
      for (let i = 0; i < G.count; i++) {
        const home = G.homes[i];
        const appear = smooth01(form * 1.7 - (home.r / G.extent) * 0.7);
        if (appear <= 0) continue;
        const r = G.sizes[i] * k * appear;
        let p = waiting(i, home, t);
        p = [p[0] * appear, p[1] * appear];
        let rx = r, ry = r, angle = 0;
        if (since >= 0) {
          const x = (since - fallStart(i)) / G.fallTime;
          if (x >= 1) {
            absorbed += G.sizes[i] ** 2;
            const tau = since - fallStart(i) - G.fallTime;
            jiggle += G.sizes[i] ** 2 / G.totalArea * 4 * Math.exp(-9 * tau) * Math.sin(26 * tau);
            continue;
          }
          const xc = Math.max(x, 0);
          const here = infall(p, xc), nxt = infall(p, Math.min(xc + 0.02, 1));
          const squash = 1 - 0.5 * xc, stretch = 1 + 0.8 * xc;
          rx = r * squash * stretch; ry = r * squash / stretch;
          angle = Math.atan2(nxt[1] - here[1], nxt[0] - here[0]);
          p = here;
        }
        const x = cx + p[0] * k, y = cy + p[1] * k;
        fx.globalAlpha = opacity * 0.35;
        const d = r * 4.5;
        fx.drawImage(glow, x - d, y - d, d * 2, d * 2);
        fx.globalAlpha = opacity;
        ellipse(x, y, rx, ry, angle);
      }
    }
    if (since >= 0) {
      const jig = clamp(jiggle, -0.05, 0.05);
      const cover = g.v.scale * 3 / k;                     // 3 cm, the render's burst radius, in app points
      const rc = coreRadius(since, absorbed / G.totalArea, cover) * k;
      const shiver = since > G.squeezeEnd && since < G.burstStart ? 0.1 * Math.sin(since * 190) : 0;
      if (since < G.burstStart) {
        fx.globalAlpha = opacity * 0.6;
        const d = Math.max(rc, 1) * 5;
        fx.drawImage(glow, cx - d, cy - d, d * 2, d * 2);
        fx.globalAlpha = opacity;
        ellipse(cx, cy, rc * (1 + jig + shiver), rc * (1 - jig - shiver), 0);
      } else {
        // The burst: a disc of light that thins as it opens, brightest at its rim.
        const x = Math.min((since - G.burstStart) / G.burstTime, 1);
        const grad = fx.createRadialGradient(cx, cy, 0, cx, cy, Math.max(rc, 0.5));
        grad.addColorStop(0, 'rgba(62,160,255,0.22)');
        grad.addColorStop(0.7, 'rgba(62,160,255,0.26)');
        grad.addColorStop(0.95, 'rgba(120,190,255,0.38)');
        grad.addColorStop(1, 'rgba(10,132,255,0)');
        fx.fillStyle = grad;
        fx.globalAlpha = opacity * (1 - 0.55 * x);
        fx.beginPath(); fx.arc(cx, cy, Math.max(rc, 0.5), 0, TAU); fx.fill();
        fx.globalAlpha = opacity * (1 - x);
        fx.fillStyle = '#EAF4FF';
        ellipse(cx, cy, 3 * k * (1 - x), 3 * k * (1 - x), 0);
      }
    }
    fx.globalAlpha = 1;
    return since < G.burstStart;                           // the dots turn on their own until the burst
  }

  // ---------- FX: caret and the landed letter ----------

  // The render bakes the caret and the letter into the phone panel, so this stays off
  // (meta.drawCaretLetter). If it's turned on, track.caret is the caret itself (centre and
  // height); from letterFrame on it already sits after the "C", laid out like the render's
  // phoneContent: caret = 1.05 × font size, 0.08 em gap after the letter.
  let letterWidthCache = { key: '', w: 0 };
  function drawCaret(lockX) {
    if (!meta.drawCaretLetter || !track.caret) return;
    const c = sample('caret', f);
    if (!c) return;
    const begin = track.galaxy ? meta.galaxyClock[2][0] : track.caret[0];
    const a = c.a * smooth(begin, begin + 1.5, f) * (1 - lockX);
    if (a <= 0.003) return;
    const [x, y, h] = c.v;
    const size = h / 1.05;
    const font = `500 ${size.toFixed(2)}px Inter, sans-serif`;
    fx.font = font;
    if (letterWidthCache.key !== font) letterWidthCache = { key: font, w: fx.measureText(LANDED).width };
    const cw = Math.max(1, size * 0.084);
    const letter = smooth(meta.letterFrame - 1, meta.letterFrame, f);
    if (f >= meta.letterFrame - 1) {
      fx.globalAlpha = a * letter;
      fx.fillStyle = '#F5F5F7';
      fx.textBaseline = 'middle';
      fx.fillText(LANDED, x - cw / 2 - size * 0.08 - letterWidthCache.w, y + size * 0.03);
    }
    fx.globalAlpha = a;
    fx.fillStyle = '#3EA0FF';
    fx.fillRect(x - cw / 2, y - h / 2, cw, h);
    fx.globalAlpha = 1;
  }

  function drawDebugScreens() {
    fx.lineWidth = 1.5;
    fx.strokeStyle = '#ff375f';
    const pill = track.frames[Math.round(f)].hudPill;
    for (const q of [track.screens.macWindow, track.screens.phone, pill]) {
      if (!q) continue;
      fx.beginPath();
      q.forEach(([x, y], k) => (k ? fx.lineTo(x, y) : fx.moveTo(x, y)));
      fx.closePath(); fx.stroke();
    }
  }

  // Returns true while something on this layer moves without the scroll moving.
  function drawFx(now, lockX) {
    const t0 = performance.now();
    const { dpr, s, ox, oy } = view;
    fx.setTransform(1, 0, 0, 1, 0, 0);
    fx.clearRect(0, 0, fxCanvas.width, fxCanvas.height);
    if (!track) return false;
    if (staticMode) { if (DEBUG_SCREENS) { fx.setTransform(dpr * s, 0, 0, dpr * s, dpr * ox, dpr * oy); drawDebugScreens(); } return false; }
    fx.setTransform(dpr * s, 0, 0, dpr * s, dpr * ox, dpr * oy);
    let alive = false;
    fx.globalCompositeOperation = 'lighter';
    const dustA = 1 - smooth(meta.dust.until[0], meta.dust.until[1], f);
    if (dustA > 0) { drawDust(now / 1000, dustA); alive = true; }
    drawSpark();
    if (drawGalaxy(now)) alive = true;
    fx.globalCompositeOperation = 'source-over';
    drawCaret(lockX);
    if (DEBUG_SCREENS) drawDebugScreens();
    stats.fxMs.push(performance.now() - t0);
    if (stats.fxMs.length > 600) stats.fxMs.shift();
    return alive;
  }

  // ---------- live screens ----------

  // Native CSS sizes of the overlays = the render's content textures (calib/film.js
  // pillContent 1260×323, phoneContent 800×1686), mapped onto track.screens.hudPill / .phone.
  // The Mac-window wallpaper and both glass panels stay baked; only the pill's text strip and
  // the phone's text field are live.
  const NATIVE = { hudPill: [1260, 323], phone: [800, 1686] };
  const liveScreens = () => [[pillEl, 'hudPill'], [phoneEl, 'phone']].filter(([, name]) => track && track.screens[name]);

  function placeScreens() {
    const key = `${view.s}|${view.ox}|${view.oy}`;
    if (key === screensKey) return;
    screensKey = key;
    for (const [el, name] of liveScreens()) {
      const [w, h] = NATIVE[name];
      el.style.transform = toMatrix3d(homography([[0, 0], [w, 0], [w, h], [0, h]], track.screens[name].map(project)));
    }
  }

  let screensOpacity = -1;
  function setScreens(o) {
    if (!track || o === screensOpacity) return;         // no track yet: nothing to show, nothing to cache
    screensOpacity = o;
    for (const [el] of liveScreens()) {
      el.style.opacity = o.toFixed(3);
      el.classList.toggle('is-on', o > 0);
    }
    // The caret doesn't blink until the overlay is fully on (storyboard §5.4).
    phoneEl.classList.toggle('is-blinking', o >= 1);
    phoneEl.style.pointerEvents = o >= 1 && coarse.matches ? 'auto' : 'none';
  }

  // ---------- live typing ----------

  let note = LANDED, typed = LANDED;
  let demoState = 'idle';                                  // idle → running → done
  let demoK = 0;
  let demoTimer = 0, typingTimer = 0, announceTimer = 0;
  let lastTypedAt = -Infinity;

  // Keep the tail of a string within `max` px in `font`, with a leading ellipsis, the way the
  // real HUD keeps the latest keystrokes in view.
  const measurer = document.createElement('canvas').getContext('2d');
  function fitTail(text, font, max) {
    measurer.font = font;
    if (measurer.measureText(text).width <= max) return text;
    let lo = 1, hi = text.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (measurer.measureText('…' + text.slice(mid)).width <= max) hi = mid; else lo = mid + 1;
    }
    return '…' + text.slice(lo);
  }
  // Text area inside the pill texture: from x = 29 pt to 16 pt short of the right edge (pt = 323/46).
  const PT = 323 / 46;
  const HUD_FONT = `${(24 * PT).toFixed(2)}px Menlo, "SF Mono", ui-monospace, monospace`;
  let HUD_MAX = 1260 - 29 * PT - 16 * PT;
  // Field text: 500 weight, 0.5 × the 126.45 px field height, room for the caret at the end.
  const FIELD_FONT = '500 63.23px Inter, sans-serif';
  const FIELD_MAX = 672 * 0.94 - 40.32 - 20;

  // The HUD echoes; the real one fades after 2 s idle and shows a hint that wouldn't fit this
  // pill, so the echo simply stays.
  function paintHud() {
    hudText.textContent = fitTail(typed, HUD_FONT, HUD_MAX);
  }

  function paintNote() {
    fieldText.textContent = fitTail(note, FIELD_FONT, FIELD_MAX);
    phoneEl.classList.add('is-typing');
    clearTimeout(typingTimer);
    typingTimer = setTimeout(() => phoneEl.classList.remove('is-typing'), 500);
  }

  function announce() {
    clearTimeout(announceTimer);
    announceTimer = setTimeout(() => { announceEl.textContent = `The iPhone shows: ${note.slice(-80) || 'nothing'}`; }, 700);
  }

  function typeKey(key) {
    let op;
    if (key === 'Backspace') { typed = typed.slice(0, -1); op = 'del'; }
    else if (key.length === 1) { typed += key; op = key; }
    else return false;
    if (typed.length > 500) typed = typed.slice(-500);
    paintHud();
    // The phone lands a beat after the HUD echoes, like the real link.
    setTimeout(() => {
      note = op === 'del' ? note.slice(0, -1) : note + op;
      if (note.length > 140) note = note.slice(-140);
      paintNote();
      announce();
    }, 40);
    return true;
  }

  // "C" is already there; "lak" follows with a human rhythm (~105 ms a key, seeded jitter).
  function startDemo() {
    if (demoState !== 'idle') return;
    demoState = 'running';
    let seed = 11;
    const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    const step = () => {
      if (demoState !== 'running') return;
      if (!visible || document.hidden) { demoTimer = setTimeout(step, 250); return; }
      if (demoK >= DEMO.length) { demoState = 'done'; return; }
      typeKey(DEMO[demoK++]);
      demoTimer = setTimeout(step, 105 + (rnd() + rnd() - 1) * 30);
    };
    demoTimer = setTimeout(step, 900);
  }

  function finishDemoNow() {
    if (demoState === 'done') return;
    clearTimeout(demoTimer);
    const rest = DEMO.slice(demoK);
    demoK = DEMO.length;
    demoState = 'done';
    // Keystrokes already echoed but not yet landed land with the rest.
    setTimeout(() => { note += rest; paintNote(); }, 40);
    typed += rest;
    paintHud();
  }

  let liveReady = false;
  function inView() {
    const r = stage.getBoundingClientRect();
    return r.top < innerHeight * 0.5 && r.bottom > innerHeight * 0.5;
  }
  const editable = (el) => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));

  // The film's live screens own the keyboard only once they're live and the stage covers the
  // middle of the viewport; the page's other demo asks before it takes a key.
  const ownsKeys = () => liveReady && inView();
  window.clakFilm = { ownsKeys };

  addEventListener('keydown', (e) => {
    if (!liveReady || e.defaultPrevented || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (editable(e.target) || !inView()) return;
    // Space and Enter on a focused control belong to that control.
    if (e.target.closest && e.target.closest('a, button, summary, [role="button"], #demo')) return;
    const k = e.key;
    if (!(k.length === 1 || k === 'Backspace')) return;
    // Space scrolls the page unless the visitor is in the middle of typing.
    if (k === ' ' && performance.now() - lastTypedAt > 4000) return;
    finishDemoNow();
    if (typeKey(k)) { lastTypedAt = performance.now(); if (k === ' ' || k === 'Backspace') e.preventDefault(); }
  });

  // Touch: tapping the live phone asks for the soft keyboard via a hidden input.
  phoneEl.addEventListener('click', () => { if (liveReady) { tapInput.focus({ preventScroll: true }); } });
  tapInput.addEventListener('beforeinput', (e) => {
    e.preventDefault();
    finishDemoNow();
    if (e.inputType === 'deleteContentBackward') typeKey('Backspace');
    else if (e.data) for (const ch of e.data) typeKey(ch);
  });

  // ---------- tick ----------

  function nearestDecoded(t) {
    if (bitmaps.has(t)) return t;
    for (let d = 1; d < NI; d++) {
      const a = t - d * direction, b = t + d * direction;
      if (bitmaps.has(a)) return a;
      if (bitmaps.has(b)) return b;
    }
    return -1;
  }

  function requestTick() {
    if (tickPending) return;
    tickPending = true;
    requestAnimationFrame(tick);
  }

  function tick(now) {
    tickPending = false;
    if (!set) return;
    const t0 = performance.now();

    if (staticMode) { pf = 100; f = N - 1; }
    else {
      pf = scrollProgress() / meta.filmEnd * 100;
      f = clamp(frameAt(pf), 0, N - 1);
    }
    target = Math.round(imageAt(f));
    if (target !== lastTarget) { direction = target > lastTarget ? 1 : -1; lastTarget = target; refreshWindow(); }
    updateView();

    // Live screens crossfade in over the locked frames; once they're fully on, the clean plate
    // (no baked text) replaces the last frame so nothing can ghost through the overlays.
    const [l0, l1] = meta.lock;
    const lockX = staticMode ? 1 : clamp((f - l0) / (l1 - l0), 0, 1);
    const usePlate = !!plate && lockX >= 1;

    const idx = usePlate ? NI - 1 : nearestDecoded(target);
    const key = `${usePlate ? 'plate' : idx}|${canvas.width}x${canvas.height}|${view.ox.toFixed(2)},${view.oy.toFixed(2)}`;
    if (idx >= 0 && key !== drawnKey) {
      const { dpr, s, ox, oy } = view;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.fillStyle = '#0B0B0D';
      ctx.fillRect(0, 0, view.cw, view.ch);
      ctx.drawImage(usePlate ? plate : bitmaps.get(idx), ox, oy, set.width * s, set.height * s);
      drawnIndex = idx; drawnKey = key; stats.drawnIndex = idx; stats.plate = usePlate;
      stats.draws++;
      if (idx !== target) stats.misses++;
      if (stats.firstFrameMs == null) { stats.firstFrameMs = Math.round(performance.now()); loadingEl.hidden = true; hero.classList.add('is-drawn'); }
    }

    if (lockX > 0 && track) placeScreens();
    setScreens(lockX);
    liveReady = !!track && lockX >= 1 && pf >= 100;
    if (liveReady && demoState === 'idle') { if (staticMode) finishDemoNow(); else startDemo(); }

    const alive = drawFx(now || performance.now(), lockX);
    stats.f = f; stats.pf = pf;

    if (!staticMode) {
      for (const el of lines) {
        const a = +el.dataset.in, b = +el.dataset.out;
        const o = (a <= 0 ? 1 : smooth(a, a + LINE_FADE, pf)) * (1 - smooth(b - LINE_FADE, b, pf));
        el.style.opacity = o.toFixed(3);
        el.style.visibility = o > 0.005 ? '' : 'hidden';
        el.style.transform = `translate3d(0, ${((1 - o) * 10).toFixed(1)}px, 0)`;
      }
    }

    stats.tickMs.push(performance.now() - t0);
    if (stats.tickMs.length > 600) stats.tickMs.shift();
    stats.alive = alive;
    if (alive && visible && !document.hidden) requestTick();
  }

  // ---------- wiring ----------

  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    phoneEl.querySelector('.film__caret').style.animationPlayState = visible ? 'running' : 'paused';
    if (visible) { onScreen(); requestTick(); }
  }).observe(hero);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) requestTick(); });
  addEventListener('scroll', () => { if (visible) requestTick(); }, { passive: true });
  new ResizeObserver(layout).observe(stage);
  portrait.addEventListener('change', () => meta && start());
  reduceMotion.addEventListener('change', () => location.reload());

  if (staticMode) hero.classList.add('is-static');

  sprite = {
    blue: makeSprite([[0, 'rgba(62,160,255,1)'], [0.25, 'rgba(62,160,255,0.55)'], [0.6, 'rgba(10,132,255,0.14)'], [1, 'rgba(10,132,255,0)']]),
    core: makeSprite([[0, 'rgba(255,255,255,1)'], [0.3, 'rgba(200,228,255,0.95)'], [0.55, 'rgba(62,160,255,0.6)'], [1, 'rgba(10,132,255,0)']]),
    warm: makeSprite([[0, 'rgba(242,230,208,1)'], [0.35, 'rgba(242,230,208,0.5)'], [1, 'rgba(242,230,208,0)']]),
  };

  fetch(url('meta.json'))
    .then((r) => r.json())
    .then(async (m) => {
      meta = m; motes = makeMotes(m.dust.count);
      assets = await loadJSON('assets.json');
      if (!assets || assets.overlaySpec) spec = await loadJSON('frames/overlay_spec.json');
      return start();
    })
    .catch((e) => console.error('hero failed to start', e));

  // ---------- measurement hooks ----------

  // Scroll to a storyboard % and resolve once the target frame is on screen.
  stats.seek = (pct) => new Promise((resolve) => {
    const span = hero.offsetHeight - stage.clientHeight;
    window.scrollTo(0, hero.offsetTop + span * clamp(pct / 100 * meta.filmEnd, 0, 1));
    const t0 = performance.now();
    const check = () => {
      requestTick();
      if ((drawnIndex === Math.round(imageAt(frameAt(pct))) && !decoding.size) || performance.now() - t0 > 4000) requestAnimationFrame(() => requestAnimationFrame(() => resolve({ f, drawnIndex, pf })));
      else setTimeout(check, 30);
    };
    check();
  });

  // Scripted scrub: scrolls through the hero over `ms`, reports rAF deltas and fallbacks.
  stats.bench = (ms = 3000) => new Promise((resolve) => {
    const top = hero.offsetTop, span = hero.offsetHeight - stage.clientHeight;
    const before = { draws: stats.draws, misses: stats.misses };
    const deltas = [];
    let t0 = 0, last = 0;
    stats.tickMs.length = 0; stats.fxMs.length = 0;
    const step = (now) => {
      if (!t0) { t0 = now; last = now; } else { deltas.push(now - last); last = now; }
      const p = Math.min(1, (now - t0) / ms);
      window.scrollTo(0, top + span * p);
      if (p < 1) return requestAnimationFrame(step);
      const sorted = [...deltas].sort((a, b) => a - b);
      const med = sorted[sorted.length >> 1];
      const pct = (arr, q) => { const s = [...arr].sort((a, b) => a - b); return +(s[Math.floor(s.length * q)] || 0).toFixed(2); };
      resolve({
        frames: deltas.length,
        medianDeltaMs: +med.toFixed(2),
        p95DeltaMs: +sorted[Math.floor(sorted.length * 0.95)].toFixed(2),
        maxDeltaMs: +sorted[sorted.length - 1].toFixed(2),
        dropped: deltas.filter((d) => d > med * 1.5).length,
        draws: stats.draws - before.draws,
        neighbourFallbacks: stats.misses - before.misses,
        tickP95Ms: pct(stats.tickMs, 0.95),
        fxP95Ms: pct(stats.fxMs, 0.95),
        decodedHeld: bitmaps.size,
      });
    };
    window.scrollTo(0, top);
    requestAnimationFrame(step);
  });

  stats.geometry = () => ({
    view, screens: { hudPill: track.screens.hudPill.map(project), phone: track.screens.phone.map(project) },
  });
  stats.live = () => ({ note, typed, hud: hudText.textContent, demoState, liveReady, screensOpacity, announce: announceEl.textContent });
})();
