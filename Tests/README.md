# Offline validation

## Signed build preflight

After a signed local build, run `python3 Tests/signature-preflight.py <expected certificate SHA1>` in an ordinary Terminal with Keychain trust access. It runs `codesign` verification only, never packaged code. On 2026-10-01 it accepted all four components, rejected all eight wrong identifier/certificate combinations, and verified the sealed bundle and packaged core digest (exit 0). The `=` prefix belongs only to codesign CLI inline requirements, not XPC/Security API expressions. This does not prove root service startup or network restoration.

## Model and library suite

Run from the project directory:

```sh
zsh Tests/run.sh
```

This runner compiles only shared models/parsers/configuration and the App's injectable library persistence components. It **does not launch the GUI, Helper, Guard or mihomo**, open network sockets, change proxy/DNS/routes, or call the real Keychain. Library tests use a trap vault for ordinary plaintext operations, a memory vault for explicit legacy migration, mocked subscription responses, and a temporary directory removed at completion. Build products go to the workspace `work/clairroute-offline-tests` directory.

Coverage includes SS SIP002/legacy/IPv6 and SS2022 keys, VMess, VLESS Reality/Vision, Base64 URI lists, YAML/JSON import, safe full-template extraction, malicious provider/plugin/field rejection, deterministic config golden comparison, stable user-before-subscription rule order, default ChatGPT-only policy, selected-node persistence in generated config, monotonic 120-second trial expiry and PID-generation matching. Persistence checks cover v3 plaintext password/UUID/URL roundtrips, private file/directory permissions, restart and edits without Keychain access, mocked subscription replacement, pre-rename filesystem rejection without a partial commit, explicit legacy migration, source preservation on missing credentials, and deferred Keychain cleanup without automatic launch-time retries. Fake credentials in fixtures are not usable credentials.

These are source-level offline checks, **not proof of mihomo protocol interoperability or actual macOS route/DNS recovery**. On-device connectivity, sleep/network changes, LAN isolation and kill-recovery acceptance require the separately authorized controlled trial.

## Optional fixed-core parser preflight

`zsh Tests/core-preflight.sh` is a separate opt-in check. It verifies the original bundled mihomo binary and public GEOSITE file SHA256, compiles `CorePreflight.swift`, and pipes generated fake-credential configuration into `Vendor/mihomo -t -f - -d <workspace-directory>` as the ordinary user. TUN, DNS serving and IPv6 probing are disabled in this fixture; all geodata download URLs are empty and the pinned `geosite.dat` is already present. The subprocess receives a clean environment so `CLASH_*` overrides cannot replace the fixture. This script does **not** start normal core mode, the Helper, an outbound delay test or a UI session.

The v1.19.31 source check confirms [`main.go`'s test branch](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/main.go#L162-L178) returns after parsing; [`ParseWithBytes`](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/executor/executor.go#L74-L103) does not call `ApplyConfig`, which installs listeners, DNS and TUN. Inline provider construction parses the payload without starting health checks. `CorePreflight.swift` exercises SS, all three SS2022 ciphers, built-in obfs/v2ray-plugin, VMess TCP/WebSocket, VLESS Reality/Vision, inline source providers, an explicit selected node, default ChatGPT path routing and GEOSITE Telegram. This adds actual core **configuration acceptance** evidence; it still does not test authentication, remote protocol behavior, routing or recovery.

On 2026-09-30, the pinned original binary SHA256 `fae1f37e28ee53fcf5be7a8bb121099db1fe442e44205734ed49c62579364090` returned exit 0 with `configuration file config.yaml test is successful`. The dedicated runtime directory contained only the copied public `geosite.dat` afterward; no config/provider cache/controller socket was created.

Final repeat regression at 2026-09-30 21:48 UTC: `Tests/run.sh` returned exit 0 for every parser, YAML, golden/order/selection, recovery and injected Library suite; `Tests/core-preflight.sh` returned exit 0 after checksum verification and accepted the generated configuration in 132 ms (GEOSITE Telegram: 21 records). The dedicated runtime directory again contained only public `geosite.dat`. No packaged binary, signing resource or application configuration was modified by this regression. Static review and the existing roundtrip check confirmed `AdvancedOptions.yamlString` emits valid JSON-as-YAML and includes all eight model fields: DNS servers, proxy DNS, fake-IP filter, IPv6, TUN stack, MTU, log level and TCP concurrency.

# YAML import contract

`SafeYAML` accepts UTF-8 up to 4 MiB, one document, indentation-based maps/sequences (including standard indentless list values), flow arrays/maps, JSON, single/double quoted strings and comments. Double-quoted escapes use JSON string syntax. Leading zeroes in plain credential strings are preserved. Limits: depth 20, lines 30,000, per-line 64 KiB, accumulated flow collection 256 KiB, scalar 16 KiB, collection/node limits. Aliases, anchors, tags, merge keys, directives, block scalars and multiple documents are rejected. Unknown node/transport/plugin fields produce a redacted error, not silent truncation.

Subscription input permits `proxies`, `rules`, `proxy-groups` and `proxy-providers` only when each provider has `type: inline` and `payload`. Standard full-template listener, DNS, TUN, profile and mode fields are discarded with a warning. Scripts, rule providers, external controllers/UI and arbitrary provider URL/path fields are rejected. At most 512 nodes, 2048 rules and 256 groups may be imported. Original provider subscriptions are downloaded by the unprivileged GUI, retained in the private v3 plaintext profile and normalized in memory; the root core receives regenerated inline providers only.

SS supports listed AEAD/SS2022 ciphers and built-in `obfs`/`v2ray-plugin` options. No executable plugins or disabled certificate verification. VMess/VLESS support TCP, WebSocket and gRPC with the fields present in `ProxyNode`; other transports, multiplexing, ALPN customizations and unsupported URI parameters are rejected explicitly. VMess URI imports use the conventional Base64 JSON form. Proxy-group declarations are normalized into one source group; their automatic test URLs/behavior are not imported. Subscription MATCH is ignored because the user's fallback policy is authoritative. Supported rule types are PROCESS-PATH-REGEX, PROCESS-NAME, DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, GEOSITE. Process path regex accepts only escaped, anchored literal absolute path prefixes or exact paths, not arbitrary regex programs.

VLESS YAML additionally accepts `encryption: ""` and `encryption: none`, normalized to the omitted default. The fixed v1.19.31 [`encryption.NewClient` implementation](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/transport/vless/encryption/factory.go#L10-L15) returns the identical no-additional-encryption result for those two strings. Other strings, null, numbers, booleans and structured values remain rejected; the importer does not discard a requested encryption mode.

Unsupported schema fields now throw a typed `SubscriptionFieldDiagnostic`. Its context uses only fixed labels, protocol enum and node index. It retains at most eight sorted field identifiers of up to 48 ASCII letters/digits/hyphens/underscores; URL-like, UUID-like, control-character, long or excess names are hidden as a count. The rejected mapping and field values are never retained in this error. Focused offline tests verify missing value disclosure, name bounds, control/URL redaction, root/URI diagnostics and VLESS empty/none equivalence. The full offline suite passed again on 2026-10-01 with these checks; no actual subscription, credential, Keychain item or proxy service was accessed by these tests.

Advanced YAML is a separate allowlist: `ipv6`, `log-level`, `tcp-concurrent`, `tun.stack`, `tun.mtu`, and `dns.nameserver`, `dns.proxy-server-nameserver`, `dns.fake-ip-filter`. It cannot modify listeners, paths, controller, providers, binaries or scripts. Use `AdvancedOptions.exampleYAML` / `.yamlString` to obtain valid content.
# PKCS#12 签名兼容性回归

运行 `bash Tests/signing-compatibility.sh`。使用临时生成的虚构证书与私钥，经 Apple `SecKeychainItemImport` 在内存中解析（`importKeychain=NULL`），不会写入 login Keychain 或改变信任/网络。macOS 27 上确认空密码重现 -25264，随机非空密码成功返回一份 identity，显式 PKCS#12 格式也通过。需要系统 Security 模块可用的普通终端环境；沙箱阻止 CSSM 模块时返回 -67711，不应当作密码错误。
