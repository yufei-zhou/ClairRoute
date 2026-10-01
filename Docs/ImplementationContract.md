# ClairRoute implementation contract

Current scope: milestones 1–4, macOS 26+, Apple Silicon, Swift 6 / SwiftUI. This describes the delivered source and its boundaries, not completed network acceptance. Default rules are ChatGPT-only (`^/Applications/ChatGPT\.app/` → `PROXY`, final `MATCH,DIRECT`). Both network switches start off.

## Development and acceptance boundary

Development may compile/package code, check static syntax, and run pure offline tests using synthetic input, temporary files and an in-memory secret vault. It must not create signing identities, install/start services, launch mihomo, access real subscriptions/credentials, or change DNS, proxies or routes without an explicit live-acceptance action.

Offline coverage includes URI/YAML parsing, golden configuration output, rule ordering, malicious provider rejection, library secret isolation/transaction recovery, legacy migration, subscription headers and pure recovery deadline/process identity logic. These checks do not establish TUN correctness, XPC admission, real provider compatibility or network recovery. Real signing/install, proxy traffic, LAN exposure, GUI kill, 30-minute sleep and Wi-Fi/hotspot transitions have not been accepted. Do not describe those as verified.

## Components and trust boundaries

| Component | Privilege and responsibility |
| --- | --- |
| `App/` | Login user. Menu bar, settings, editors, connections, Keychain and App lifecycle. `AppLibraryModel` is MainActor; library edits are saved before the user chooses Apply. |
| `Helper/` | Root LaunchDaemon. Authenticated typed XPC, serial sessions, core lifecycle, proxy/DNS ownership, GUI watchdog, sleep/network reconciliation. |
| Pinned mihomo | Root process started only from the fixed root-owned verified copy. No root subscription downloads or automatic updates. |
| `ClairRouteRecoveryGuard` | Separate root LaunchDaemon for independent, timed trial rollback. No TCP/XPC administration interface. |
| `Shared/` | Codable/Sendable models, bounded parsers and deterministic configuration builder. |

Identifiers are `local.nano.ClairRoute`, `.Helper` and `.RecoveryGuard`; Mach service is `local.nano.ClairRoute.Helper`. Mixed proxy is `127.0.0.1:17890`; TUN DNS is `127.0.0.1:53`; reserved interface is `utun197`. Listener collisions fail activation. `allow-lan` is false. No TCP management listener exists.

Both XPC peers set `setCodeSigningRequirement` before resuming. Local builds pin identifier and exact certificate fingerprint. Helper derives UID/PID from XPC and verifies current console/session ownership; a client cannot supply its trusted identity. Missing signing requirements disable privileged activation. Helper never reads the user's Keychain.

The core's Unix controller remains in a root-owned private runtime directory. GUI receives bounded typed results through Helper, keeping broader controller operations inaccessible to ordinary user processes. No raw socket, generic HTTP forwarding, arbitrary command, file path or YAML write is exposed.

## XPC, configuration and rules

Objective-C methods are `apply`, `stop`, `readStatus`, `heartbeat`, and `inspect`. Messages are bounded to 1 MiB. Apply carries session UUID, advancing generation, independent TUN/system-proxy flags, typed `RuntimeProfile` and optional trial flag. Inspect permits only connections, proxy inventory, selecting an already-validated node in PROXY, and delay tests of validated nodes against a fixed HTTPS probe; it accepts no URL/method/path/command.

`RuntimeProfile` includes nodes, mode (rule/global/direct), ordered rules, fallback, selected node and typed advanced options. Protocols are SS, VMess and VLESS including Reality/Vision. SS2022 Base64/key lengths are checked. Plugins are restricted to supported core built-ins, never external executables.

The builder emits deterministic JSON (valid YAML) in memory. Full credentials travel through bounded XPC, pipes for core config checking/startup, and private controller reload bodies. No credential-bearing config file, argv, provider cache or persistent core selection cache is written. Before activation/reload, Helper validates the model and runs the fixed core's `-t` check; health and selected node are confirmed before accepting the transaction. Failure attempts the prior configuration/state; unconfirmed rollback stops proxying and restores owned settings.

Template defaults include `find-process-mode: strict`, mixed TUN stack, auto-route, auto-detect-interface, UDP/TCP port-53 hijack and fake-IP DNS. The highlighted advanced editor accepts only `ipv6`, `log-level`, `tcp-concurrent`, `tun.stack`, `tun.mtu`, DNS upstreams and fake-IP filter. It is a safe YAML fragment editor, not an unrestricted privileged configuration editor. DNS URLs cannot embed credentials, query tokens or local paths.

User rules precede subscription rules, retaining order within each part; the first match wins and final MATCH is separately managed. Kinds are PROCESS-PATH-REGEX, PROCESS-NAME, DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD and GEOSITE. Process path patterns accept escaped literal absolute prefixes/exact paths, not general regex. Bundle prefixes include helpers inside the bundle; separately installed/shared helpers need separate rules. Actual process attribution depends on macOS/core and requires connection-panel acceptance.

## Library and subscriptions

Version-2 user Application Support `ClairRoute/profile.json` contains node/subscription metadata, rules, selection, fallback, typed advanced options, pending-secret references and optional legacy migration metadata. File/directory permissions are 0600/0700. Authentication UUIDs, passwords and subscription URLs are absent.

Keychain service `local.nano.ClairRoute.NodeSecrets` stores complete node JSON and subscription URL/raw payload under fresh app-generated UUID references. Write-ahead pending references, fresh Keychain items, atomic metadata replacement and deferred deletion retain the previous committed profile on failure. Cleanup survives restart and legacy single-node/password metadata migrates transactionally. Unfinished Keychain deletion blocks complete uninstall.

Downloads use ephemeral URLSession without disk cache, cookies or credential storage. URLs/redirects must be HTTPS; URL userinfo/fragments are rejected. Streaming is limited to 1 MiB with timeouts and five redirects. `subscription-userinfo` counters/expiry are parsed locally. Automatic refresh runs while GUI is open, at intervals from five minutes to thirty days; it saves library data without silently applying a running session.

Clash/Mihomo YAML, Base64 URI lists and ss/vmess/vless URIs are parsed locally without online converters. Typed nodes generate **inline proxy-providers**, so secret subscription URLs never reach root files. Provider/group names are generated locally, with stable internal node IDs separate from display names. Safe full-template fields may be ignored; executable providers, foreign paths, unsafe directives, YAML tags/aliases and unsupported transports are rejected instead of copied. Remote rule-provider fetching is unsupported; GEOSITE uses the bundled hash-checked asset.

The connection panel shows process/path, destination, matching rule and outbound chains, and drafts rules from rows. Polling uses bounded snapshots. Delay tests and actual connection observations are live network operations requiring an authenticated active session.

## Restore-first lifecycle

States are idle → preparing → starting → active, with reconfiguring, restoring and needsAttention branches. Installation/login never auto-enable networking. Library editing does not activate the network.

`NetworkSettingsManager` serial API: `init(stateDirectory:)`, `recoverIfNeeded()`, `prepare(sessionID:)`, `apply(tunEnabled:systemProxyEnabled:)`, `restoreAll()`, `recoveryPending`, `conflictDescription()`, `startObserving(onChange:)`, `stopObserving()`. It uses native SystemConfiguration and physical-service UUIDs, with independent DNS/proxy leases. Journal precedes settings commit. Related enable/endpoint fields are compared/restored together; externally changed values are preserved and reported rather than overwritten by a full historical snapshot.

Start checks pending recovery and competing VPN/default routes, journals before takeover, starts/health-checks core, then redirects owned DNS/proxy. Stop restores DNS/proxy while core is alive, terminates only the recorded core identity, then verifies its TUN disappears. PID, birth time and fixed executable prevent PID-reuse mistakes. Kernel removal of the owned interface handles its routes; there is no route-table restore, global route flush or blind utun deletion.

Core exit, GUI XPC invalidation, console-owner loss and expired heartbeat trigger restoration. Ordinary watchdog ticks every five seconds with a 25-second lease; actual sleep pauses expiry and wake grants 30 seconds. Network/settings events are coalesced to avoid self-trigger loops. Wake/interface change causes egress redetection and reconciliation; two failures restore and stop. Incomplete restoration leaves recovery records/needsAttention and blocks activation.

First live acceptance can use the fixed **120-second trial**. Helper requires a fresh independent Guard before takeover and durably writes a lease using a continuous clock including sleep plus a boot identifier. Reconfiguration cannot extend it. Guard independently detects expiry, reboot or death of the recorded Helper, writes a recovery marker, stops only its matching process identity, and restores journals under a cross-process lock. This protects timed trials; ordinary sessions do not have a two-minute timeout. It cannot guarantee repair of physical connectivity or a failing OS networking API.

## Fixed paths and maintenance

| Path | Contract |
| --- | --- |
| `/Applications/ClairRoute.app` | Root-owned verified bundle with GUI, Helper and Guard. |
| `/Library/LaunchDaemons/local.nano.ClairRoute.{Helper,RecoveryGuard}.plist` | Local no-account deployment, initially idle. |
| `/Library/Application Support/ClairRoute/bin/mihomo` | Fixed verified root-owned core; never a GUI-supplied path. |
| `CoreManifest.json`, `GeoManifest.json`, `state/geosite.dat` under support | Sealed provenance/hash manifests and GEOSITE. No root auto-update. |
| `state/network-recovery.json` | Atomic owned DNS/proxy journal. Empty `leases` is clean; file may remain. |
| `state/core-process.json` | Only absence means no pending core recovery. |
| `state/trial-lease.json`, `state/recovery-in-progress.json` | Any remaining record blocks maintenance/activation. |
| `state/recovery.lock` | Empty owned lock file is not pending recovery. |
| `run/recovery-guard.json`, `run/helper-ready.json` | Fresh process-bound readiness stamps; stale stamps alone are not pending recovery. |
| `.maintenance` under support | Transaction lock, record and backups; preserve incomplete transactions. |

Official v1.19.31 darwin-arm64 archive SHA256 is `d131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963`. Archive, extracted original binary and re-signed runtime binary digests are distinct. The signed outer App seals final manifests; installer/Helper verify the fixed copies. Version updates require reviewed official release/digest changes and rebuilding. GEOSITE has its own version-1 hash manifest.

Maintenance checks ownership/types/symlinks/hardlinks, GUI/core processes, reserved TUN and journals. Installation stages/verifies the bundle in a root-private directory, backs up App/core/assets/manifests/both plists, stops Helper then Guard and rechecks inactivity. It starts Guard before Helper. Successful completion requires real process identities and fresh readiness, not merely launchctl loaded state. Failure triggers rollback; incomplete rollback preserves backups. Uninstall stops both daemons, rechecks recovery, deletes only fixed owned paths, and rejects node/subscription/pending-Keychain metadata. Signing identity and source project remain.

## User-run local installation without a developer account

Double-click `Scripts/Install ClairRoute.command` from the source folder in Finder, or run its quoted absolute path in Terminal. It requires normal login user, macOS 26+, Apple Silicon, selected full Xcode with SDK 26+, and an existing login Keychain.

The entry creates/reuses exactly one valid `ClairRoute Local Development` identity, builds/verifies the bundle, then invokes interactive Terminal sudo only for installation. Password input is handled by sudo, never captured by the script or passed in argv; Keychain prompts are handled by macOS. It does not reset, unlock or replace login Keychain, change its search list, grant broad private-key permissions or modify TLS trust. Only the new certificate's code-signing trust is added. An invalid/conflicting existing identity stops and remains for inspection. Installation leaves network switches off; it performs no live connectivity tests.

Component commands remain `create-local-identity.sh [--print-hash]`, `build-local.sh <identity SHA1>`, then `sudo install-local.sh <identity SHA1>`. Native build directly uses selected Xcode's compiler, avoiding IDE plug-in loading. It neither runs tests nor launches App/core. A failed build retains the signing identity for retry.

This is self-signed local/manual-LaunchDaemon deployment, not Developer ID notarized distribution. A paid-account release still needs Developer ID signing/notarization, Apple/Team-ID production XPC requirements and separately validated SMAppService.daemon registration/approval. Embedded daemon plists exist; self-signed/ad-hoc SMAppService deployment is not represented as accepted. No SMJobBless, SIP change or Gatekeeper disable is used.

## Remaining live acceptance

Record these separately before declaring operation verified: signed installation and readiness; safe GUI interactions; real node import; timed-trial expiry/recovery before extended activation; raw terminal curl without proxy environment; clean DNS/routes after stop; ChatGPT/Telegram proxy and WeChat direct hits; independent system-proxy mode; LAN management-interface inaccessibility; GUI kill -9; core failure; sleep/wake and Wi-Fi/hotspot changes. Retain the existing working proxy/configuration during acceptance. A compiled binary, passing fixture, ready daemon or successful delay probe alone does not establish this full matrix.
