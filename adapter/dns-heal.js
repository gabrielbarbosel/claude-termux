#!/usr/bin/env node
// dns-heal.js — Heals the glibc DNS environment on Termux.
//
// The glibc runtime resolves via $PREFIX/etc/{resolv.conf,hosts}. Android
// manages DNS in the framework, so that resolv.conf easily rots (e.g. a
// stray `nameserver 127.0.0.1` kills every glibc lookup). Node's resolver
// on Termux reads the same file, and dns.lookup() also consults the hosts
// file — so asking either for "the system DNS" just reflects the breakage
// back. That circularity is how stale pins used to survive forever.
//
// Strategy — network-only, nothing read back from the files being healed:
//   1. Probe candidate resolvers (current file's + public) with dns.Resolver.
//   2. First one that answers wins; rewrite resolv.conf only if the file's
//      own servers all failed.
//   3. Re-resolve the target hosts through the working resolver and refresh
//      their /etc/hosts pins with live addresses.
//   4. If port 53 is blocked everywhere (Private DNS), fall back to DoH by
//      literal IP (no name resolution needed) and let hosts pins carry it.
//   5. Fully offline: change nothing — stale pins beat empty files.
//
// Usage: node dns-heal.js <hostsFile> <resolvConf> <host> [host...]

'use strict';
const fs = require('fs');
const path = require('path');
const dns = require('dns');
const https = require('https');

const [hostsFile, resolvConf, ...targets] = process.argv.slice(2);
if (!hostsFile || !resolvConf || targets.length === 0) process.exit(0);

const PUBLIC_DNS = ['1.1.1.1', '8.8.8.8', '9.9.9.9'];
const PROBE_TIMEOUT_MS = 1500;
const DOH_TIMEOUT_MS = 4000;

function isLoopback(ip) {
  return ip.startsWith('127.') || ip === '::1' || ip.startsWith('[::1]');
}

function fileNameservers() {
  try {
    return fs.readFileSync(resolvConf, 'utf8')
      .split('\n')
      .map(l => l.trim())
      .filter(l => l.startsWith('nameserver '))
      .map(l => l.slice('nameserver '.length).trim())
      .filter(Boolean);
  } catch (e) {
    return [];
  }
}

function probe(server, name) {
  return new Promise(resolve => {
    let done = false;
    const finish = ok => { if (!done) { done = true; resolve(ok); } };
    const t = setTimeout(() => finish(false), PROBE_TIMEOUT_MS);
    t.unref();
    try {
      const r = new dns.Resolver({ timeout: PROBE_TIMEOUT_MS, tries: 1 });
      r.setServers([server]);
      r.resolve4(name, (err, addrs) => {
        clearTimeout(t);
        finish(!err && addrs && addrs.length > 0);
      });
    } catch (e) {
      clearTimeout(t);
      finish(false);
    }
  });
}

function resolveVia(server, name, rrtype) {
  return new Promise(resolve => {
    let done = false;
    const finish = v => { if (!done) { done = true; resolve(v); } };
    const t = setTimeout(() => finish([]), PROBE_TIMEOUT_MS * 2);
    t.unref();
    try {
      const r = new dns.Resolver({ timeout: PROBE_TIMEOUT_MS, tries: 2 });
      r.setServers([server]);
      const fn = rrtype === 'AAAA' ? r.resolve6.bind(r) : r.resolve4.bind(r);
      fn(name, (err, addrs) => {
        clearTimeout(t);
        finish(!err && addrs ? addrs : []);
      });
    } catch (e) {
      clearTimeout(t);
      finish([]);
    }
  });
}

// DoH by literal IP — works even when every port-53 resolver is blocked.
function dohQuery(endpoint, name, rrtype) {
  return new Promise(resolve => {
    const req = https.get({
      host: endpoint.host,
      path: endpoint.path(name, rrtype),
      headers: { accept: 'application/dns-json' },
      timeout: DOH_TIMEOUT_MS,
    }, res => {
      let body = '';
      res.on('data', c => { body += c; });
      res.on('end', () => {
        try {
          const wanted = rrtype === 'AAAA' ? 28 : 1;
          const answers = (JSON.parse(body).Answer || [])
            .filter(a => a.type === wanted)
            .map(a => a.data);
          resolve(answers);
        } catch (e) { resolve([]); }
      });
    });
    req.on('timeout', () => { req.destroy(); resolve([]); });
    req.on('error', () => resolve([]));
  });
}

const DOH_ENDPOINTS = [
  { host: '1.1.1.1', path: (n, t) => `/dns-query?name=${encodeURIComponent(n)}&type=${t}` },
  { host: '8.8.8.8', path: (n, t) => `/resolve?name=${encodeURIComponent(n)}&type=${t}` },
];

function writeAtomic(file, content) {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp${process.pid}`);
  fs.writeFileSync(tmp, content, 'utf8');
  fs.renameSync(tmp, file);
}

function rewriteResolvConf(servers) {
  const lines = servers.slice(0, 3).map(s => `nameserver ${s}`);
  lines.push('options timeout:2 attempts:2');
  writeAtomic(resolvConf, lines.join('\n') + '\n');
}

// Replace the pins of every target we managed to resolve; leave everything
// else (user entries, localhost, unresolved targets' stale pins) untouched.
function updateHosts(resolved) {
  const done = Object.keys(resolved).filter(h => resolved[h].length > 0);
  if (done.length === 0) return;
  let content = '';
  try { content = fs.readFileSync(hostsFile, 'utf8'); } catch (e) {}
  const kept = content.split('\n').filter(line => {
    const t = line.trim();
    if (!t || t.startsWith('#')) return t.length > 0 || false;
    const fields = t.split(/\s+/).slice(1);
    return !fields.some(f => done.includes(f.toLowerCase()));
  });
  const added = [];
  for (const h of done) for (const ip of resolved[h]) added.push(`${ip} ${h}`);
  writeAtomic(hostsFile, kept.concat(added).join('\n') + '\n');
}

(async () => {
  const fromFile = fileNameservers();
  const candidates = [...new Set([
    ...fromFile.filter(s => !isLoopback(s)),
    ...PUBLIC_DNS,
  ])];

  let working = null;
  for (const server of candidates) {
    if (await probe(server, targets[0])) { working = server; break; }
  }

  const resolved = {};
  for (const t of targets) resolved[t.toLowerCase()] = [];

  if (working) {
    // The file is only rewritten when none of its own servers answer —
    // a healthy, Android-managed config is left alone.
    let fileWorks = false;
    for (const s of fromFile) {
      if (!isLoopback(s) && (s === working || await probe(s, targets[0]))) { fileWorks = true; break; }
    }
    if (!fileWorks) {
      try { rewriteResolvConf([working, ...PUBLIC_DNS.filter(s => s !== working)]); } catch (e) {}
    }
    for (const t of targets) {
      const h = t.toLowerCase();
      const [v4, v6] = await Promise.all([
        resolveVia(working, h, 'A'),
        resolveVia(working, h, 'AAAA'),
      ]);
      resolved[h] = [...v4, ...v6];
    }
  } else {
    // Port 53 blocked everywhere → DoH. resolv.conf still gets public
    // servers (anything beats a lone loopback entry); pins do the work.
    if (fromFile.every(isLoopback)) {
      try { rewriteResolvConf(PUBLIC_DNS); } catch (e) {}
    }
    for (const t of targets) {
      const h = t.toLowerCase();
      for (const ep of DOH_ENDPOINTS) {
        const [v4, v6] = await Promise.all([
          dohQuery(ep, h, 'A'),
          dohQuery(ep, h, 'AAAA'),
        ]);
        if (v4.length + v6.length > 0) { resolved[h] = [...v4, ...v6]; break; }
      }
    }
  }

  try { updateHosts(resolved); } catch (e) {}
  process.exit(0);
})().catch(() => process.exit(0));
