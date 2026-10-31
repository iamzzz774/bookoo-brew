// Run: node test/web_cloud_config_reader_test.cjs
// Executes the actual Dart-generated script, using only Node built-ins and an
// intentionally narrow asynchronous IDB double. No website, cloud or real DB.
'use strict';
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {execFileSync} = require('node:child_process');
const path = require('node:path');
const script = execFileSync('dart', [path.join(__dirname, 'web_cloud_config_emit.dart')], {encoding: 'utf8'});
const ORIGIN = 'https://coffee.chu3.top';
const SECRET = 'FAKE_SECRET_not_real';
const URL_VALUE = 'https://fixture.invalid/project';
const record = () => ({id: 'main', data: {activeSyncType: 'supabase', supabaseSync: {enabled: true, url: URL_VALUE, anonKey: SECRET}, private: {neverExport: 'PRIVATE_SENTINEL'}}});

async function run(options = {}) {
  const messages = [], operations = [], timers = new Set();
  let closes = 0, aborts = 0, created = false;
  const later = f => queueMicrotask(f);
  const db = {
    objectStoreNames: {contains(name) {assert.equal(name, 'appSettings'); return !options.noStore;}},
    close() {closes++;},
    transaction(stores, mode) {
      assert.deepEqual(Array.from(stores), ['appSettings']);
      assert.equal(mode, 'readonly');
      operations.push('readonly');
      if (options.txThrow) throw Error(SECRET + URL_VALUE);
      const tx = {abort() {aborts++; later(() => tx.onabort?.());}, objectStore(name) {
        assert.equal(name, 'appSettings');
        return {get(key) {
          assert.equal(key, 'main'); operations.push('get:main');
          const get = {};
          later(() => {
            if (options.getError) {get.onerror?.(); return;}
            get.result = Object.hasOwn(options, 'record') ? options.record : record();
            get.onsuccess?.();
            later(() => options.txAbort ? tx.onabort?.() : tx.oncomplete?.());
          });
          return get;
        }};
      }};
      return tx;
    },
  };
  const idb = {open(...args) {
    operations.push('open'); assert.deepEqual(args, ['BrewGuideDB']);
    if (options.openThrow) throw Error(SECRET + URL_VALUE);
    const req = {transaction: {abort() {aborts++; created = false;}}};
    later(() => {
      if (options.stallOpen) return;
      if (options.creation) {
        created = true; req.onupgradeneeded(); req.onerror?.(); return;
      }
      if (options.blocked) {req.onblocked?.(); return;}
      req.result = db;
      if (options.navigate) context.location.origin = 'https://untrusted.invalid';
      req.onsuccess?.();
    });
    return req;
  }};
  if (!options.oldWebView) idb.databases = async () => {
    operations.push('databases');
    if (options.discoveryThrow) throw Error(SECRET + URL_VALUE);
    return options.noDB ? [{name: 'unrelated'}] : [{name: 'BrewGuideDB'}];
  };
  const context = {
    URL, queueMicrotask,
    location: {origin: options.wrongOrigin ? 'https://wrong.invalid' : ORIGIN, protocol: options.http ? 'http:' : 'https:'},
    setTimeout(fn) { const id = {fn}; timers.add(id); return id; },
    clearTimeout(id) {timers.delete(id);},
    indexedDB: options.noIDB ? undefined : idb,
    BookooCloudConfigBridge: {postMessage(raw) {messages.push(JSON.parse(raw));}},
    // Any broader/legacy read or networking would fail the test.
    localStorage: new Proxy({}, {get() {throw Error('forbidden localStorage read');}}),
    fetch() {throw Error('forbidden network');},
    console: new Proxy({}, {get() {throw Error('forbidden logging');}}),
  };
  context.window = context;
  context.top = options.iframe ? {} : context;
  const actual = options.badNonce ? script.replace(/document_nonce_123/g, '') : script;
  await vm.runInNewContext(actual, context, {timeout: 1000});
  for (let i = 0; i < 10; i++) await Promise.resolve();
  if (options.timeout) for (const t of [...timers]) t.fn();
  assert.equal(created, false, 'must not create a database');
  assert.ok(messages.length <= 1, 'at most one reply');
  for (const m of messages) {
    assert.equal(m.type, 'bookoo.webCloudConfig.v1');
    assert.equal(m.origin, ORIGIN);
    assert.equal(m.token, 'document_nonce_123');
    assert.equal(m.requestId, 'request_456');
    assert.deepEqual(Object.keys(m).sort(), ['type', 'origin', 'token', 'requestId', 'status', ...(m.status === 'ready' ? ['config'] : [])].sort());
    if (m.status === 'ready') assert.deepEqual(Object.keys(m.config).sort(), ['key', 'url', 'userId']);
    else {
      assert.ok(!JSON.stringify(m).includes(SECRET));
      assert.ok(!JSON.stringify(m).includes(URL_VALUE));
    }
    assert.ok(!JSON.stringify(m).includes('PRIVATE_SENTINEL'));
  }
  return {messages, operations, closes, aborts, status: messages[0]?.status};
}
let count = 0;
async function test(name, fn) {await fn(); count++; process.stdout.write(`ok ${count} - ${name}\n`);}
(async () => {
  await test('current appSettings/main/data schema; projected keys only; closes DB', async () => {
    const r = await run(); assert.equal(r.status, 'ready');
    assert.deepEqual(r.messages[0].config, {url: URL_VALUE, key: SECRET, userId: 'default_user'});
    assert.deepEqual(r.operations, ['databases', 'open', 'readonly', 'get:main']); assert.ok(r.closes > 0);
  });
  await test('upstream identity is fixed, not settings username/userId', async () => {
    const r = record(); r.data.userId = '  DifferentCase  '; r.data.supabaseSync.userId = 'other';
    assert.equal((await run({record: r})).messages[0].config.userId, 'default_user');
  });
  await test('disabled never exports credentials', async () => {const r = record(); r.data.supabaseSync.enabled = false; assert.equal((await run({record: r})).status, 'disabled');});
  await test('inactive provider disabled; absent activeSyncType uses enabled', async () => {
    const r = record(); r.data.activeSyncType = 's3'; assert.equal((await run({record: r})).status, 'disabled');
    delete r.data.activeSyncType; assert.equal((await run({record: r})).status, 'ready');
  });
  await test('missing record/config/URL/key', async () => {
    for (const r of [undefined, {id: 'main', data: {}}, {id: 'main', data: {supabaseSync: {enabled: true, url: ''}}}]) assert.equal((await run({record: r})).status, 'missing');
  });
  await test('databases noDB does not call open', async () => {const r = await run({noDB: true}); assert.equal(r.status, 'missing'); assert.deepEqual(r.operations, ['databases']);});
  await test('old WebView absent DB creation is aborted', async () => {const r = await run({oldWebView: true, creation: true}); assert.equal(r.status, 'missing'); assert.equal(r.aborts, 1); assert.ok(!r.operations.includes('readonly'));});
  await test('deletion race after databases still aborts creation', async () => {const r = await run({creation: true}); assert.equal(r.status, 'missing'); assert.equal(r.aborts, 1);});
  await test('old WebView existing DB works', async () => {assert.equal((await run({oldWebView: true})).status, 'ready');});
  await test('wrong origin/HTTP/iframe/invalid nonce silent and no DB access', async () => {
    for (const o of [{wrongOrigin: true}, {http: true}, {iframe: true}, {badNonce: true}]) {const r = await run(o); assert.deepEqual(r.messages, []); assert.deepEqual(r.operations, []);}
  });
  await test('navigation during async read cannot emit', async () => {const r = await run({navigate: true}); assert.deepEqual(r.messages, []); assert.ok(r.closes > 0);});
  await test('invalid endpoints and bounded key reject without secrets', async () => {
    for (const value of ['http://fixture.invalid', 'https://user:pass@fixture.invalid', 'https://@fixture.invalid', 'https://fixture.invalid?secret=x', 'https://fixture.invalid/#x', ' https://fixture.invalid', 'https://fixture.invalid\\evil', 'https://', 'https://fixture.invalid:0', 'https://fixture.invalid:99999']) {
      const r = record(); r.data.supabaseSync.url = value; assert.equal((await run({record: r})).status, 'unsupported', value);
    }
    for (const value of [' ', ' bad ', 'x\n', 'x'.repeat(8193), 42]) {const r = record(); r.data.supabaseSync.anonKey = value; assert.equal((await run({record: r})).status, 'unsupported');}
  });
  await test('invalid records/types are unsupported', async () => {
    for (const r of [{id: 'other', data: {}}, {id: 'main', data: []}, {id: 'main', data: {supabaseSync: []}}, {id: 'main', data: {supabaseSync: {enabled: 'true'}}}]) assert.equal((await run({record: r})).status, 'unsupported');
  });
  await test('stalled open times out with static unsupported only', async () => {assert.equal((await run({stallOpen: true, timeout: true})).status, 'unsupported');});
  await test('static unsupported errors never reveal exception secrets', async () => {
    for (const o of [{noIDB: true}, {noStore: true}, {discoveryThrow: true}, {openThrow: true}, {txThrow: true}, {getError: true}, {txAbort: true}, {blocked: true}]) assert.equal((await run(o)).status, 'unsupported');
  });
  process.stdout.write(`PASS: ${count} reader fixture tests (no network or real storage)\n`);
})().catch(error => {console.error(error); process.exitCode = 1;});
