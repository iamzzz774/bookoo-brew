# Read-only website config contract — verified 2026-10-31

Public served asset inspection only, using HTTPS GET. No website runtime was
executed; no browser/device/profile, persisted user data, cloud endpoints or
credentials were accessed. Static assets were inspected in memory, not copied
from any retired application source. This is the **currently served website**
(build gitSha `f6d45c38`, buildTime `2026-10-31T05:43:39.529Z`), not a guessed
localStorage schema or the wrapper application's independent Settings class.

## Primary evidence

Base: `https://coffee.chu3.top/` (Next build `zVVj9VTVPfKaxBb5sl5sG`).

1. `https://coffee.chu3.top/_next/static/chunks/f9f34f8f1e8e5795.js`
   SHA-256 `592bb9ca8a0f0f1e376d90dfaebd8c7517dd9cbc34b4345a3d295237ed4230c0`
   - Dexie database constructor names `BrewGuideDB`.
   - `appSettings` is keyed by `id`; the repository uses `I="main"`,
     `get(){let t=await e.get(I);return t?.data}`.
   - Save persists `{id:I,data:t}`. Thus the authoritative record is
     `BrewGuideDB / appSettings / main / data`, not the legacy `settings` store.
   - Migration can read localStorage `brewGuideSettings` (direct object or
     `state.settings`) into this record only when it does not already exist.
     Consequently that localStorage item may be stale and is deliberately NOT
     used by this reader. An unmigrated website must finish its own migration;
     this bridge never runs migration or attempts to bootstrap a DB.
2. `https://coffee.chu3.top/_next/static/chunks/d760961e2f93aaf3.js`
   SHA-256 `5973ef89264b4cfaba544bfc53e1feb738f7fd7aa2852aa653cd3555445d7d82`
   - Default connection settings are `supabaseSync:{enabled:!1,url:"",anonKey:""}`.
   - Current provider is `activeSyncType`; valid values include `none`,
     `supabase`, `s3`, `webdav`. Normalization for records without the field
     infers the provider from enabled connection settings. The reader treats
     explicitly disabled Supabase or an explicitly different provider as
     disabled, instead of accidentally importing a dormant connection.
3. `https://coffee.chu3.top/_next/static/chunks/4545bfceefc6f145.js`
   SHA-256 `03dfc53ad145b55ac88cb0316c9f4297c17060bea147456f113f34314ee71785`
   - Sync module defines `let y="default_user"` and uses
     `.eq("user_id",y)` for cloud reads and `user_id:y` for payloads.
   - This is **fixed upstream identity**, not a configurable `userId` field and
     not a fallback inferred from wrapper settings. Username or hypothetical
     userId properties in saved settings must not override the identity used
     by this deployed website. The bridge emits exactly `default_user`.
   - The Dart protocol still preserves any validated incoming userId byte-for-
     byte/code-unit-for-code-unit: no trim, case folding or invented default.

The website's normal web runtime resolves storage to Dexie; its native
SQLite backend is not applicable to an HTTPS remote page. Only the two lazy
Dexie chunks referenced by the initial HTML/module graph were fetched beyond
the initial page scripts; this was a bounded asset inspection, not a crawl.

## Integration contract

- Channel: `kWebCloudConfigChannel = 'BookooCloudConfigBridge'`.
- Generator: `webCloudConfigReadScript(origin:, token:, requestId:)`.
- Parser: `parseWebCloudConfigMessage(raw, origin:, token:, requestId:)`.
- Status enum: `WebCloudConfigStatus.ready/missing/disabled/unsupported`.
- `result.config` is non-null only for ready; its fields are `url/key/userId`.
- Envelope has exactly `type/origin/token/requestId/status`, plus `config`
  only for ready. Type is `bookoo.webCloudConfig.v1`. Token is the per-document
  nonce. Request IDs/tokens must match `[A-Za-z0-9_-]{1,128}`. Origin must be a
  canonical HTTPS origin without trailing slash, path, query or credentials.
- No error text is ever emitted. Nonready messages contain no connection data.
- Endpoint is credential-free HTTPS, without whitespace, backslash, query or
  fragment. URL/key/userId bounds are 2048/8192/256 code units; messages are
  bounded at 24576 code units. Values are not normalized.
- Reads only one key from one store in a readonly transaction; never enumerates
  records, calls a cloud service, creates an object store, writes or migrates.
  Database discovery is used where available; `onupgradeneeded` always aborts,
  including deletion races and old WebViews without `databases()` support.
- Three-second static unsupported timeout; closed DB handles; no page watcher.
- Parent must check current HTTPS URL, document generation, nonce/request ID,
  and single consumption. Channel messages alone are not document provenance;
  a compromised trusted same-origin page remains within the trust boundary.

## Local fixture execution

```
dart test/web_cloud_config_protocol_test.dart
node test/web_cloud_config_reader_test.cjs
dart analyze lib/web_cloud_config.dart test/web_cloud_config_emit.dart test/web_cloud_config_protocol_test.dart
```

Tests use synthetic settings only. Node uses built-in vm and a strict
asynchronous fake-IDB double; its assertions permit only appSettings.get(main)
in readonly mode. The script is generated by Dart at runtime, so the tests do
not exercise a separately maintained JS copy. No third-party Node dependency,
real IndexedDB, webpage execution or cloud access is needed. These are local
protocol/fixture tests, not Android WebView end-to-end certification.
