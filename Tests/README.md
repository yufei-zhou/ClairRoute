# Offline validation

## Signed build preflight

After a signed local build, run `python3 Tests/signature-preflight.py <expected certificate SHA1>` in an ordinary Terminal with Keychain trust access. It runs `codesign` verification only, never packaged code. The `=` prefix belongs only to codesign CLI inline requirements, not XPC/Security API expressions. This does not prove root service startup or network restoration.

## Model and library suite

Run from the project directory:

```sh
zsh Tests/run.sh
```

This runner compiles shared models/parsers/configuration and injectable library/AppModel components. It **does not launch the GUI, Helper, Guard or mihomo**, open network sockets, change proxy/DNS/routes, or call the real Keychain. Library tests use a trap vault for ordinary plaintext operations, a memory vault for explicit legacy migration, mocked subscription responses, and a temporary directory removed at completion. AppModel tests inject a recording Helper and in-memory preferences; they never instantiate the App delegate or real HelperClient. Build products go to the git-ignored `.build/offline-tests` directory inside the project.

Lifecycle regressions cover manual default despite a legacy auto-connect flag, persisted automatic-launch opt-in, readiness checks, all three remembered takeover combinations, cancellation during a delayed Helper reply, recovery/existing-session guards, offline timeout, unsigned builds, single-attempt failure, and preserving the mode across trials/stops/failures. Startup tests inject a fake network monitor; no real path monitor is started. Further cases cover idle editing without connection, explicit TUN activation, automatic-to-manual node selection, failure before touching the core, atomic rollback after a rejected Apply, and a second persistence failure that requests Stop. Both confirmed and failed recovery are checked. Configuration tests also cover moving the PROXY link between subscription groups.

Refresh-message regressions cover HTTP failure, a successful automatic retry clearing the prior error, routine template normalization without a warning, and skipped unsupported rules remaining visible after the success notice expires.

Coverage includes SS SIP002/legacy/IPv6 and SS2022 keys, VMess, VLESS Reality/Vision, Base64 URI lists, YAML/JSON import, safe full-template extraction, malicious provider/plugin/field rejection, deterministic config golden comparison, stable user-before-subscription rule order, default ChatGPT-only policy, selected-node persistence in generated config, monotonic 120-second trial expiry and PID-generation matching. Persistence checks cover v3 plaintext password/UUID/URL roundtrips, private file/directory permissions, restart and edits without Keychain access, mocked subscription replacement, pre-rename filesystem rejection without a partial commit, explicit legacy migration, source preservation on missing credentials, and deferred Keychain cleanup without automatic launch-time retries. Fake credentials in fixtures are not usable credentials.

These are source-level offline checks, **not proof of mihomo protocol interoperability or actual macOS route/DNS recovery**. On-device connectivity, sleep/network changes, LAN isolation and kill-recovery acceptance need a separate controlled trial on a real Mac.

## Isolated interface preview

`python3 Scripts/build-ui-preview.py` builds `.build/ui-preview/ClairRoute UI Preview.app` without opening it. Open that bundle for layout checks; do not install it in Applications. It uses synthetic nodes, a temporary fixture profile, a trap credential store, in-memory preferences and a mock Helper. It does not open the real user profile, contact a subscription, call XPC or start a proxy. After its initial fixture load, consecutive Refresh clicks produce success, HTTP 503, and a partial-import warning. These cases exercise footer layout and dismissal without changing the network. Quit the preview before rebuilding it; its disposable profiles remain under `.build/ui-preview/fixtures`.

## Optional fixed-core parser preflight

`zsh Tests/core-preflight.sh` is a separate opt-in check. It verifies the original bundled mihomo binary and public GEOSITE file SHA256, compiles `CorePreflight.swift`, and pipes both manual and automatic-selection fake-credential configurations into `Vendor/mihomo -t -f - -d <workspace-directory>` as the ordinary user. TUN, DNS serving and IPv6 probing are disabled in these fixtures; all geodata download URLs are empty and the pinned `geosite.dat` is already present. A separate macOS sandbox denies all network operations, and a clean environment prevents `CLASH_*` overrides. This script does **not** start normal core mode, the Helper or a UI session. If the host cannot create the network-denying sandbox, the script fails rather than running the parser without it.

The v1.19.31 source check confirms [`main.go`'s test branch](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/main.go#L162-L178) returns after parsing; [`ParseWithBytes`](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/executor/executor.go#L74-L103) does not call `ApplyConfig`, which installs listeners, DNS and TUN. Inline provider construction parses the payload without starting health checks. `CorePreflight.swift` exercises SS, all three SS2022 ciphers, built-in obfs/v2ray-plugin, VMess TCP/WebSocket, VLESS Reality/Vision, inline source providers, an explicit selected node, default ChatGPT path routing and GEOSITE Telegram. This adds actual core **configuration acceptance** evidence; it still does not test authentication, remote protocol behavior, routing or recovery.


# YAML import contract

`SafeYAML` accepts UTF-8 up to 4 MiB, one document, indentation-based maps/sequences (including standard indentless list values), flow arrays/maps, JSON, single/double quoted strings and comments. Double-quoted escapes use JSON string syntax. Leading zeroes in plain credential strings are preserved. Limits: depth 20, lines 30,000, per-line 64 KiB, accumulated flow collection 256 KiB, scalar 16 KiB, collection/node limits. Aliases, anchors, tags, merge keys, directives, block scalars and multiple documents are rejected. Unknown node/transport/plugin fields produce a redacted error, not silent truncation.

Subscription input permits `proxies`, `rules`, `proxy-groups` and `proxy-providers` only when each provider has `type: inline` and `payload`. Standard full-template listener, DNS, TUN, profile and mode fields are discarded as routine parser notes, without a persistent warning. Scripts, rule providers, external controllers/UI and arbitrary provider URL/path fields are rejected. At most 512 nodes, 2048 rules and 256 groups may be imported. Original provider subscriptions are downloaded by the unprivileged GUI, retained in the private v3 plaintext profile and normalized in memory; the root core receives regenerated inline providers only.

SS supports listed AEAD/SS2022 ciphers and built-in `obfs`/`v2ray-plugin` options. No executable plugins or disabled certificate verification. VMess/VLESS support TCP, WebSocket and gRPC with the fields present in `ProxyNode`; other transports, multiplexing, ALPN customizations and unsupported URI parameters are rejected explicitly. VMess URI imports use the conventional Base64 JSON form. Proxy-group declarations are normalized into one source group; their automatic test URLs/behavior are not imported. Subscription MATCH is ignored because the user's fallback policy is authoritative. Other rule types (GEOIP, IP-CIDR, RULE-SET, …) are skipped with a visible warning instead of rejecting the whole subscription; likewise, URI lists skip links of unsupported schemes (trojan://, hysteria2://, …) with a warning. VLESS share links may carry `headerType`, `allowInsecure` and `alpn`, and VMess links `alpn`, only at their default values. Supported rule types are PROCESS-PATH-REGEX, PROCESS-NAME, DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, GEOSITE. Process path regex accepts only escaped, anchored literal absolute path prefixes or exact paths, not arbitrary regex programs.

VLESS YAML additionally accepts `encryption: ""` and `encryption: none`, normalized to the omitted default. The fixed v1.19.31 [`encryption.NewClient` implementation](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/transport/vless/encryption/factory.go#L10-L15) returns the identical no-additional-encryption result for those two strings. Other strings, null, numbers, booleans and structured values remain rejected; the importer does not discard a requested encryption mode.

Unsupported schema fields throw a typed `SubscriptionFieldDiagnostic`. Its context uses only fixed labels, protocol enum and node index. It retains at most eight sorted field identifiers of up to 48 ASCII letters/digits/hyphens/underscores; URL-like, UUID-like, control-character, long or excess names are hidden as a count. The rejected mapping and field values are never retained in this error. Focused offline tests verify missing value disclosure, name bounds, control/URL redaction, root/URI diagnostics and VLESS empty/none equivalence.

Advanced YAML is a separate allowlist: `ipv6`, `log-level`, `tcp-concurrent`, `tun.stack`, `tun.mtu`, and `dns.nameserver`, `dns.proxy-server-nameserver`, `dns.fake-ip-filter`. It cannot modify listeners, paths, controller, providers, binaries or scripts. Use `AdvancedOptions.exampleYAML` / `.yamlString` to obtain valid content.
# PKCS#12 签名兼容性回归

运行 `bash Tests/signing-compatibility.sh`。使用临时生成的虚构证书与私钥，经 Apple `SecKeychainItemImport` 在内存中解析（`importKeychain=NULL`），不会写入 login Keychain 或改变信任/网络。空密码会触发 -25264，随机非空密码应成功返回一份 identity，显式 PKCS#12 格式同样应通过。需要系统 Security 模块可用的普通终端环境；沙箱阻止 CSSM 模块时返回 -67711，不应当作密码错误。
