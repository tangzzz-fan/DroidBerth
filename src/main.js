const invoke = window.__TAURI__.core.invoke;
const $ = (id) => document.getElementById(id);

const state = {
  doctor: null,
  adb: null,
  wifi: { probes: [], matrix: [] },
  console: [],
};

const MATRIX = [
  { key: 'screen-off', scenario: 'Screen off for 5 minutes', expected: 'Port stays 5555, reconnect succeeds' },
  { key: 'wifi-switch', scenario: 'Switch to another WiFi network', expected: 'New IP needed, port stays 5555' },
  { key: 'battery-saver', scenario: 'Enable battery saver', expected: 'May drop; reconnect should still work' },
  { key: 'reboot', scenario: 'Reboot the phone', expected: 'Port lost - USB re-arm required (known limit)' },
  { key: 'ap-isolation', scenario: 'Router AP isolation on', expected: 'Cannot connect at all' },
];

function pill(text, kind) {
  return `<span class="pill ${kind}">${text}</span>`;
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function fillKv(id, pairs) {
  $(id).innerHTML = pairs
    .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v ?? '-')}</dd>`)
    .join('');
}

function logWifi(message, kind = '') {
  const box = $('wifi-log');
  const now = new Date().toLocaleTimeString();
  const line = document.createElement('div');
  line.innerHTML = `<span class="t">${now}</span><span class="${kind}">${esc(message)}</span>`;
  box.prepend(line);
  while (box.childElementCount > 200) box.lastElementChild.remove();
}

function target() {
  const host = $('wifi-host').value.trim();
  const port = $('wifi-port').value.trim() || '5555';
  return host ? `${host}:${port}` : '';
}

async function callAdb(args, timeoutSecs = 30) {
  const res = await invoke('adb_run', { args, timeoutSecs });
  return res;
}

function describe(res) {
  if (!res) return 'no response';
  if (res.spawn_error) return `spawn error: ${res.spawn_error}`;
  if (res.timed_out) return `timed out after ${res.duration_ms} ms`;
  const p = res.parsed;
  if (!p) return `exit ${res.code}`;
  if (p.error) return p.error;
  const text = (p.stdout || p.stderr || '').trim();
  return text || `exit ${p.code}`;
}

document.querySelectorAll('nav button').forEach((btn) => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('nav button').forEach((b) => b.classList.remove('active'));
    document.querySelectorAll('main > section').forEach((s) => s.classList.remove('active'));
    btn.classList.add('active');
    $(`tab-${btn.dataset.tab}`).classList.add('active');
  });
});

async function runDoctor() {
  const btn = $('btn-doctor');
  btn.disabled = true;
  btn.innerHTML = '<span class="spin"></span> running';
  try {
    const res = await invoke('doctor');
    const d = res.parsed;
    if (!d) {
      $('verdict').textContent = 'error';
      $('verdict').className = 'verdict fail';
      $('tally').textContent = describe(res);
      return;
    }
    state.doctor = d;
    renderDoctor(d);
  } catch (e) {
    $('verdict').textContent = 'error';
    $('verdict').className = 'verdict fail';
    $('tally').textContent = String(e);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Run doctor';
  }
}

function renderDoctor(d) {
  const s = d.summary || {};
  const verdict = $('verdict');
  verdict.textContent = s.verdict || 'unknown';
  verdict.className = `verdict ${s.verdict || ''}`;
  $('tally').innerHTML =
    `<b>${s.pass ?? 0}</b> pass &nbsp; <b>${s.fail ?? 0}</b> fail &nbsp; ` +
    `<b>${s.manual ?? 0}</b> manual &nbsp; <b>${s.skip ?? 0}</b> skipped &nbsp; of ${s.total ?? 0}`;

  $('checks').innerHTML = `
    <thead><tr><th style="width:34px">#</th><th style="width:52%">Check</th><th style="width:70px">Level</th><th style="width:74px">Status</th></tr></thead>
    <tbody>${(d.checks || [])
      .map(
        (c) => `<tr>
          <td class="mono">${c.id}</td>
          <td>${esc(c.name)}<div class="small muted">${esc(c.detail)}</div>${
            c.evidence ? `<div class="mono-sm muted" style="margin-top:3px">${esc(c.evidence)}</div>` : ''
          }</div></td>
          <td>${pill(c.level, c.level)}</td>
          <td>${pill(c.status, c.status)}</td>
        </tr>`
      )
      .join('')}</tbody>`;

  const host = d.host || {};
  fillKv('host-kv', [
    ['macOS', `${host.macOSVersion || '-'} (${host.macOSBuild || '-'})`],
    ['arch', host.arch || '-'],
    ['Sequoia+', host.isSequoiaOrLater ? 'yes' : 'no'],
    ['tool', d.tool || '-'],
  ]);

  const b = d.bundle || {};
  fillKv('bundle-kv', [
    ['app', b.appPath || '(not running from a bundle)'],
    ['in /Applications', b.installedInApplications ? 'yes' : 'no'],
    ['main exe', b.mainExecutable || '-'],
    ['archs', (b.archs || []).join(' ') || '-'],
    ['app size', b.appSizeMb ? `${b.appSizeMb.toFixed(1)} MB` : '-'],
    ['dmg size', b.dmgSizeMb ? `${b.dmgSizeMb.toFixed(1)} MB` : 'not built'],
    ['xattrs', (b.quarantineAttributes || []).join(' ') || '(none)'],
  ]);

  const nested = (d.nestedMachO && d.nestedMachO.items) || [];
  $('nested').innerHTML = nested.length
    ? `<thead><tr><th style="width:34%">File</th><th>Authority</th><th style="width:74px">Team</th><th style="width:88px">Runtime</th><th style="width:96px">Timestamp</th></tr></thead>
       <tbody>${nested
         .map(
           (n) => `<tr>
             <td class="mono-sm">${esc(n.path.split('/').slice(-2).join('/'))}</td>
             <td class="mono-sm">${esc((n.authorities || [])[0] || n.note || '(unsigned)')}</td>
             <td class="mono-sm">${esc(n.teamId || n.certKind || '-')}</td>
             <td>${pill(n.hardenedRuntime ? 'yes' : 'no', n.hardenedRuntime ? 'pass' : 'fail')}</td>
             <td>${pill(n.hasTimestamp ? 'yes' : 'no', n.hasTimestamp ? 'pass' : 'fail')}</td>
           </tr>`
         )
         .join('')}</tbody>`
    : '<tbody><tr><td class="muted">No nested Mach-O files.</td></tr></tbody>';

  const g = d.gatekeeper || {};
  $('spctl').textContent = g.spctlOutput || '(no output)';
  $('doctor-raw').textContent = JSON.stringify(d, null, 2);
}

$('btn-doctor').addEventListener('click', runDoctor);

async function resolveAdb() {
  const res = await invoke('sidecar_run', { args: ['resolve'], timeoutSecs: 30 });
  const r = res.parsed || {};
  state.adb = { resolution: r };
  fillKv('adb-kv', [
    ['found', r.found ? 'yes' : 'no'],
    ['path', r.path || '-'],
    ['source', r.source || '-'],
  ]);
  $('adb-probes').innerHTML = `
    <thead><tr><th>Probe path</th><th style="width:210px">Source</th><th style="width:70px">Exists</th></tr></thead>
    <tbody>${(r.probes || [])
      .map(
        (p) => `<tr><td class="mono-sm">${esc(p.path)}</td><td class="mono-sm muted">${esc(p.source)}</td>
        <td>${pill(p.exists ? 'yes' : 'no', p.exists ? 'pass' : 'skip')}</td></tr>`
      )
      .join('')}</tbody>`;
  return r;
}

$('btn-resolve').addEventListener('click', async () => {
  const r = await resolveAdb();
  if (!r.found) logWifi('adb not found - bundle one at Contents/Resources/adb or set DROIDDOCK_ADB', 'warn');
});

$('btn-adb-inspect').addEventListener('click', async () => {
  const res = await invoke('sidecar_run', { args: ['doctor', '--compact'], timeoutSecs: 120 });
  const d = res.parsed;
  const bin = d && d.adb && d.adb.binary;
  if (!bin) {
    $('adb-deps').textContent = 'No adb binary resolved.';
    return;
  }
  state.adb = { ...(state.adb || {}), binary: bin };
  fillKv('adb-kv', [
    ['path', bin.path],
    ['size', `${(bin.sizeBytes / 1048576).toFixed(2)} MB`],
    ['archs', (bin.archs || []).join(' ') || '-'],
    ['universal', bin.universal ? 'yes' : 'no'],
    ['system-only deps', bin.systemOnlyDependencies ? 'yes' : 'no'],
    ['cert', (bin.signature || {}).certKind || '-'],
    ['version', (bin.versionOutput || '').split('\n')[0] || '-'],
  ]);
  $('adb-deps').textContent =
    (bin.dependencies || []).join('\n') +
    (bin.foreignDependencies && bin.foreignDependencies.length
      ? `\n\nforeign (must be bundled or statically linked):\n${bin.foreignDependencies.join('\n')}`
      : '\n\nno foreign dependencies');
});

$('btn-devices').addEventListener('click', async () => {
  const res = await invoke('adb_devices');
  $('devices').textContent = describe(res);
  logWifi(`adb devices -l -> ${describe(res).split('\n').pop()}`, res.parsed && res.parsed.ok ? 'ok' : 'err');
});

async function adbSimple(args, label) {
  const res = await callAdb(args, 25);
  logWifi(`${label} -> ${describe(res).split('\n').slice(0, 2).join(' / ')}`, res.parsed && res.parsed.ok ? 'ok' : 'err');
  return res;
}

$('btn-tcpip').addEventListener('click', () => adbSimple(['tcpip', '5555'], 'adb tcpip 5555'));
$('btn-connect').addEventListener('click', () => {
  const t = target();
  if (!t) return logWifi('Enter the device IP first', 'warn');
  return adbSimple(['connect', t], `adb connect ${t}`);
});
$('btn-disconnect').addEventListener('click', () => {
  const t = target();
  if (!t) return logWifi('Enter the device IP first', 'warn');
  return adbSimple(['disconnect', t], `adb disconnect ${t}`);
});
$('btn-pair').addEventListener('click', () => {
  const t = target();
  const code = $('wifi-code').value.trim();
  if (!t || !code) return logWifi('Pairing needs both the IP:port and the code', 'warn');
  return adbSimple(['pair', t, code], `adb pair ${t}`);
});

function deviceState(text, t) {
  for (const line of String(text || '').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith(t)) continue;
    const rest = trimmed.slice(t.length).trim();
    return rest.split(/\s+/)[0] || 'unknown';
  }
  return null;
}

async function reconnectProbe(t) {
  const attempts = [];
  for (let i = 1; i <= 3; i += 1) {
    const started = performance.now();
    const connect = await callAdb(['connect', t], 15);
    const devices = await invoke('adb_devices');
    const devicesText = (devices.parsed && devices.parsed.stdout) || '';
    const st = deviceState(devicesText, t);
    attempts.push({
      attempt: i,
      connectOk: !!(connect.parsed && connect.parsed.ok),
      connectOutput: describe(connect),
      state: st,
      durationMs: Math.round(performance.now() - started),
    });
    if (st === 'device') break;
  }
  return attempts;
}

function renderProbe(attempts, label) {
  $('probe').innerHTML = `
    <thead><tr><th style="width:34px">#</th><th style="width:64px">Connect</th><th style="width:96px">State</th><th style="width:78px">ms</th><th>Output</th></tr></thead>
    <tbody>${attempts
      .map(
        (a) => `<tr>
          <td class="mono">${a.attempt}</td>
          <td>${pill(a.connectOk ? 'ok' : 'fail', a.connectOk ? 'pass' : 'fail')}</td>
          <td>${pill(a.state || 'absent', a.state === 'device' ? 'pass' : a.state ? 'manual' : 'fail')}</td>
          <td class="mono-sm">${a.durationMs}</td>
          <td class="mono-sm">${esc(a.connectOutput.split('\n')[0])}</td>
        </tr>`
      )
      .join('')}</tbody>`;
  const ok = attempts.some((a) => a.state === 'device');
  logWifi(`${label}: ${ok ? 'connected' : 'not connected'} after ${attempts.length} attempt(s)`, ok ? 'ok' : 'err');
  return ok;
}

async function probeAndRecord(row) {
  const t = target();
  if (!t) return logWifi('Enter the device IP first', 'warn');
  const attempts = await reconnectProbe(t);
  const ok = renderProbe(attempts, `probe [${row.scenario}]`);
  state.wifi.probes.push({ scenario: row.key, target: t, at: new Date().toISOString(), ok, attempts });
  const record = state.wifi.matrix.find((m) => m.key === row.key);
  if (record) {
    record.outcome = ok ? 'pass' : 'fail';
    record.note = ok ? `connected after ${attempts.length} attempt(s)` : `failed after ${attempts.length} attempt(s)`;
    const sel = document.querySelector(`select[data-key="${row.key}"]`);
    if (sel) sel.value = record.outcome;
    const note = document.querySelector(`input[data-note="${row.key}"]`);
    if (note) note.value = record.note;
  }
}

function renderMatrix() {
  state.wifi.matrix = MATRIX.map((m) => ({ ...m, outcome: 'unset', note: '' }));
  $('matrix-body').innerHTML = state.wifi.matrix
    .map(
      (m) => `<tr>
        <td>${esc(m.scenario)}</td>
        <td class="muted small">${esc(m.expected)}</td>
        <td>
          <select data-key="${m.key}">
            <option value="unset">unset</option>
            <option value="pass">pass</option>
            <option value="fail">fail</option>
            <option value="n/a">n/a</option>
          </select>
          <div style="margin-top:5px"><button class="ghost small" data-probe="${m.key}">Probe</button></div>
        </td>
        <td><input type="text" data-note="${m.key}" placeholder="note" style="width:100%" /></td>
      </tr>`
    )
    .join('');

  $('matrix-body').querySelectorAll('select').forEach((sel) => {
    sel.addEventListener('change', () => {
      const rec = state.wifi.matrix.find((m) => m.key === sel.dataset.key);
      if (rec) rec.outcome = sel.value;
    });
  });
  $('matrix-body').querySelectorAll('input').forEach((inp) => {
    inp.addEventListener('input', () => {
      const rec = state.wifi.matrix.find((m) => m.key === inp.dataset.note);
      if (rec) rec.note = inp.value;
    });
  });
  $('matrix-body').querySelectorAll('button[data-probe]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const row = MATRIX.find((m) => m.key === btn.dataset.probe);
      btn.disabled = true;
      btn.innerHTML = '<span class="spin"></span>';
      try {
        await probeAndRecord(row);
      } finally {
        btn.disabled = false;
        btn.textContent = 'Probe';
      }
    });
  });
}

$('btn-probe').addEventListener('click', async () => {
  const t = target();
  if (!t) return logWifi('Enter the device IP first', 'warn');
  $('btn-probe').disabled = true;
  try {
    const attempts = await reconnectProbe(t);
    const ok = renderProbe(attempts, 'reconnect probe');
    state.wifi.probes.push({ scenario: 'manual', target: t, at: new Date().toISOString(), ok, attempts });
  } finally {
    $('btn-probe').disabled = false;
  }
});

$('btn-run-adb').addEventListener('click', async () => {
  const raw = $('console-args').value.trim();
  if (!raw) return;
  const args = raw.split(/\s+/);
  const res = await callAdb(args, 60);
  state.console.push({ args, res });
  $('console-out').textContent = describe(res) + (res.parsed && res.parsed.stderr ? `\n\nstderr:\n${res.parsed.stderr}` : '');
});

$('btn-run-sidecar').addEventListener('click', async () => {
  const raw = $('console-args').value.trim();
  if (!raw) return;
  const args = raw.split(/\s+/);
  const res = await invoke('sidecar_run', { args, timeoutSecs: 60 });
  state.console.push({ args, res });
  $('console-out').textContent = res.parsed ? JSON.stringify(res.parsed, null, 2) : describe(res);
});

$('btn-export').addEventListener('click', async () => {
  const report = {
    generatedAt: new Date().toISOString(),
    doctor: state.doctor,
    adb: state.adb,
    wifi: state.wifi,
    console: state.console.map((c) => ({ args: c.args, code: c.res && c.res.code })),
  };
  try {
    const path = await invoke('save_report', { contents: JSON.stringify(report, null, 2) });
    logWifi(`report written to ${path}`, 'ok');
    $('console-out').textContent = `report written to ${path}`;
  } catch (e) {
    logWifi(`export failed: ${e}`, 'err');
  }
});

(async function init() {
  renderMatrix();
  try {
    const probe = await invoke('sidecar_probe');
    $('sidecar-badge').textContent = probe.resolved ? `sidecar: ${probe.resolved}` : 'sidecar: NOT FOUND';
    if (!probe.resolved) {
      logWifi('sidecar binary not found. Build it with scripts/build.sh', 'err');
    }
  } catch (e) {
    $('sidecar-badge').textContent = `sidecar: error (${e})`;
  }
  await runDoctor();
  await resolveAdb();
})();
