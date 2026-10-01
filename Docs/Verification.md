# 验证记录

本记录区分代码验证、界面验证和真实联网验收。未执行的项目不能按通过计。

## 已完成

- macOS 27 / Apple Silicon / Xcode 27 Swift 编译器直接构建 GUI、Helper、RecoveryGuard 成功。
- 2026-10-01 完成本机证书签名构建，四个组件通过正向校验，错误 identifier / certificate 的八项反向校验均被拒绝；整个 bundle strict/deep 校验和内核摘要匹配通过。随后用户完成 root 安装，见下方安装后观察。
- Helper/Guard 最新就绪记录实现分别 typecheck 通过。
- 离线测试通过：SS、VMess、VLESS Reality URI；不可信 YAML；配置 golden；规则排序；Keychain 抽象事务；订阅响应头；连续时钟期限与 PID 复用判定。
- 固定官方 mihomo v1.19.31 的 `-t` 配置预检通过，使用虚构节点、禁用 TUN/DNS，未启动代理服务。
- 安装/卸载 shell 语法、Python 与内嵌 Python AST 检查通过。
- computer use 实际打开设置窗口并检查五个页面。首次启动不展示窗口的问题已修复。
- computer use 确认默认 ChatGPT bundle 路径规则、DIRECT 兜底；无效 `ss://invalid` 在导入 sheet 内显示错误，未写入节点。
- computer use 检查规则类型菜单、运行中 App 列表、关闭状态连接面板、高级编辑器语法高亮。
- 界面构建网络开关禁用，测试未改变系统代理、DNS 或路由。
- 2026-10-01 活跃 TUN 会话期间强杀 GUI 后，约 5 秒后开始采集的快照显示可观察网络状态恢复直连基线；见下方运行中强杀记录。

## 待本机完成

- 长时间会话的服务健康和恢复观察；基本启动、限时恢复、活跃 GUI 强杀恢复已通过。
- 强制无效配置时的实时回滚（离线失败路径已测）。双模式同时开启、独立关闭、规则热切换和 GUI 内置节点测速已通过，见下方。
- 微信 DIRECT / Telegram PROXY 命中观察。
- 局域网远端管理接口不可达检查。
- 合盖 30 分钟、切换 Wi-Fi / 热点后的恢复。

首次联网必须先确认独立 RecoveryGuard 新鲜心跳、保存基线状态，使用固定期限验收。不能把编译或 `-t` 的成功当作联网可用性证明。当前尚不能宣称完成全部验收。

## 安装签名包兼容性修复

用户首次安装在 `security import` 报 PKCS#12 MAC verification failed，未进入构建或服务安装。通过 `Tests/signing-compatibility.sh` 使用临时证书和 `SecKeychainItemImport` 的 NULL importKeychain（只内存）复现：空密码在格式推断与显式 PKCS#12 下均返回 -25264；随机非空密码的两种格式均返回 0，获得一份 identity。

安装器现改为 256-bit 随机临时包密码，显式 `-f pkcs12`，导入前验证包 MAC。测试不写入用户钥匙串、不改信任、不启动服务。该修复验证通过不代表完整安装或联网验收已通过。

## codesign CLI 参数修复（2026-10-01）

`codesign -R` 将普通参数视为文件路径；内联签名要求必须带 `=` 前缀。修复内核准备、App/Helper/Guard 构建、安装与卸载的全部调用。`CoreManifest` 与 XPC/Security API 仍保存原始表达式，不添加 CLI 专用前缀。

实际执行 `Scripts/build-local.sh` exit 0，输出 `.build/Local/Build/Products/Release/ClairRoute.app`。`Tests/signature-preflight.py` exit 0，检查正确证书与四个 bundle identifier、八个错误值、封装完整性及摘要。临时无副作用 Bundle.main 探针还确认 Helper 读取自己的内嵌 Info.plist。没有启动 App、Helper、Guard 或内核，未改动网络。尝试只读 `sudo -n codesign` 因需要用户密码未执行，因此管理员环境和服务就绪仍待安装验证。

## 已安装后的观察（2026-10-01，以下按时间追加）

用户执行修复后的安装器成功。后续只读确认 `/Applications/ClairRoute.app` strict/deep 验签通过；Helper PID 3801 与 RecoveryGuard PID 3797 均由固定 LaunchDaemon 路径运行，runs=1、never exited。安装器本身在提交前已执行双服务就绪检查。computer use 打开安装版 App，界面显示“Helper 已连接并验签 / 未启动 / 无待恢复修改”，TUN 与系统代理均关闭。至此安装与双向 XPC 的基本验收已完成，原上方待办中的这些项目已更新为通过；持续心跳、内核启动与网络恢复仍需实测。

现有 ClashX Pro 仍通过 utun6 与 198.18.0.2 DNS 接管网络，系统代理 HTTP/HTTPS/SOCKS 均为 127.0.0.1:7890。当前 ChatGPT/Codex 部分连接依赖 Clash 的 fake-IP / TUN。未关闭 Clash，未启动 ClairRoute TUN；两者不得同时接管。ClairRoute 的自动恢复只负责自身修改，不会重新开启 Clash 的增强模式。Safari JustMySocks 页面仍报服务器意外断开，尚未获取或导入订阅。首次迁移前基线保存在工作目录私有 `work/clairroute-verification-2026-10-01/before-migration.json`。

同日补充了“开始 120 秒系统代理验收”GUI 入口，复用既有 Helper/Guard 的 trialMode；仅将 tun=false、systemProxy=true 发给同一固定期限逻辑。完整签名构建成功。computer use 先退出空闲安装版，再打开工作目录 `.build/Local/.../ClairRoute.app`，确认新按钮和说明可见、与现有安装 Helper 双向验签成功、内核未启动、两开关关闭。没有替换系统安装组件；当前打开的是新版签名 GUI 构建。系统代理试验仍会依赖现有 Clash DNS/TUN，不能据此证明独立 TUN 已可用。用户选择先自行恢复 Safari 订阅页面，未授权或执行 Clash 配置迁移。

用户随后自行退出 ClashX Pro，Safari 已能打开 JustMySocks 服务器与订阅页面。新的只读基线 `work/clairroute-verification-2026-10-01/before-clairroute-trial.json`（0600）记录：系统 HTTP/HTTPS/SOCKS/PAC 关闭，DNS 为 192.168.0.1，IPv4 默认路由为 192.168.0.1 / en0，无 utun6 或 utun197，无 mihomo 进程。后续验收恢复以此直连基线为准，不恢复先前 Clash 接管状态。旧基线仍保留。

computer use 从官方页面读取 Mihomo YAML 订阅并通过 GUI 保存到 Keychain；本地 profile.json 仅含订阅引用，权限 0600，无订阅 URL 或密码。真实下载已成功，但首次解析拒绝 VLESS 节点的 `encryption: ""`；正在修复该格式兼容性。此前没有启动 ClairRoute 内核或改变网络。

## 实际订阅与联网验收（2026-10-01）

- 核对固定 mihomo v1.19.31 的 VLESS encryption 实现后，严格接受 YAML `encryption: ""` / `none`，其他值仍拒绝。新增安全字段名诊断、真实格式的虚构凭据回归测试；全套离线测试通过。官方订阅经 GUI 刷新成功，导入 1 个 SS + 5 个 VLESS Reality 节点，凭据进入 Keychain。
- 系统代理限时验收：HTTP/HTTPS/SOCKS 指向 127.0.0.1:17890；DNS、默认路由不变，无 utun197。SS 和 VLESS Reality s2 分别通过本地 HTTP CONNECT 请求 JustMySocks 官方站点，CONNECT=200、HTTPS 响应=302。实际选择节点已由内核确认。
- 系统代理固定期限到达后：进程退出，系统代理/DNS/默认路由/utun197 状态与直连基线一致。RecoveryGuard 在 00:36:18（Europe/Paris）的日志明确记录独立限时回滚完成。中间 Helper 因恢复前提未满足拒绝启动是恢复门禁，随后恢复成功。
- TUN 限时验收：utun197 与 IPv4/IPv6 接管路由实际建立，DNS 指向 127.0.0.1，系统代理保持关闭。`env -i`、`curl --noproxy '*'` 的 JustMySocks HTTPS 请求返回 302，CONNECT=000；没有使用 HTTP/SOCKS 代理环境变量。
- TUN 会话中热切换全局 → 规则成功。连接面板实际显示 `codex` 命中 `ProcessPathRegex: ^/Applications/ChatGPT\.app/`，出站为选中的 VLESS → PROXY；Python 请求 JustMySocks、Chrome Helper 的新连接命中 Match → DIRECT。旧全局连接维持原出站，界面已补充说明。
- TUN 轮次结束后的快照再次与直连基线一致。此前强杀发生在 120 秒期限之后，无法区分恢复触发来源，不能计为运行中崩溃恢复通过。

相关私有证据位于 `work/clairroute-verification-2026-10-01/`：`system-proxy-active.json`、`system-proxy-after-deadline.json`、`tun-active.json`、`tun-after-gui-kill.json`。`observe.py` 只读对比网络状态；需要普通用户完整系统可见性，沙箱中的空动态状态不能当作网络故障。普通用户未看到 root socket 不等于远端端口验收通过。

最终 GUI 构建加入连接链显示与节点可访问性标签改进；完整签名预检再次通过（4 个正确身份、8 个错误身份拒绝、sealed bundle 与内核摘要）。运行的构建尚未替换 `/Applications` 中较旧的 GUI。新版首次读取凭据时出现 macOS Keychain 授权提示，由用户本机处理；Computer Use 不操作 SecurityAgent。

运行中强杀后的额外直连探测：在内核已退出、网络状态恢复的前提下，对此前授权的 JustMySocks 官方站点执行 `env -i` 与 `curl --noproxy '*'`，HTTPS 返回 302、CONNECT=000，确认恢复后实际 HTTPS 仍可用。没有查询外部出口 IP 服务。

最终安装前再次确认全部可见网络状态匹配直连基线，保存为 `before-final-install.json`。测试版 GUI 因新的 Keychain 提示暂停读取，已仅向核对路径的 GUI 发送 SIGTERM 关闭；内核未运行。尝试非交互事务更新返回 `sudo: a password is required`，未执行安装修改，现等待用户在本机终端完成更新。

## 最终安装版确认（2026-10-01 01:15，Europe/Paris）

用户完成事务更新。随后逐一比较安装目录与最终构建：GUI、Helper、RecoveryGuard、mihomo 四份二进制摘要完全一致；安装 bundle 的 deep/strict 签名及固定证书要求通过。`after-final-install.json` 记录安装后的代理、DNS、默认路由、TUN 和内核状态匹配原直连基线。

LaunchDaemon 的 Helper PID 59479、Guard PID 59475 均为 root、PPID 1，使用固定安装路径，runs=1、never exited。run/state 目录为 root:wheel 0700；普通用户不能读取受保护记录，未将此限制误报为记录缺失。computer use 已打开 `/Applications/ClairRoute.app`，确认双向 XPC 验签成功、默认规则模式和 s2 节点保留。启动限时测试时再次遇到 Keychain 访问提示，内核未启动；等待用户在系统授权窗口处理后继续同一进程的剩余测试。

## 同一运行中重复钥匙串读取的修复

用户完成授权后，安装版成功启动 TUN；同一 GUI 进程切换系统代理时又进入 SecurityAgent 授权等待。源码确认 `apply → runtimeProfile → readNodes → KeychainSecretVault.read` 每次都调用底层 Keychain。内核在等待期间已退出；关闭阻塞 GUI 后，`after-repeated-keychain-prompt.json` 的全部可见网络状态匹配直连基线。

修复在 ProfileStore 中加入进程内 `SessionSecretVault`：成功读取/写入后才缓存，凭据数据总量限制 8 MiB，LRU 淘汰；重新载入清空，删除前淘汰，提交及清理无论成功失败都按实际已提交引用保留缓存。持久 Keychain API、ACL 和访问属性不变，不将秘密写入磁盘配置或日志。缓存中的数据可复用，首次读取、淘汰或重启后仍可能要求 macOS 授权。

离线回归测试及全套既有测试通过：重复 runtimeProfile/readNode 的底层读取次数、凭据替换、reload、容量/LRU/超大项、失败读取重试、部分写入失败、删除失败及 removeAllData 均覆盖。另行只读审查未发现缓存与提交边界的阻塞问题。尚待将修复后的签名构建更新到安装目录并进行实际开关复测。

## 运行中 GUI 强杀后的恢复观察（2026-10-01）

本次强杀前记录时间为 00:53:08.019（Europe/Paris；UTC 为 2026-09-30 22:53:08.019）。GUI PID 为 37109，root 内核 PID 为 41587，`ps etime` 记录内核仅运行 00:35。`kill-active-gui.py` 先核对 GUI / 内核的固定路径与 UID、拒绝运行超过 45 秒的内核，并确认 utun197 存在，再保存前快照、仅对 GUI 发送 SIGKILL。前快照实际包含两个进程、utun197、IPv4/IPv6 接管路由及 127.0.0.1 DNS，证明此次强杀发生在仍接管网络的 TUN 会话内，不沿用先前已到期会话的强杀结果。

脚本在 `os.kill` 返回后等待 5 秒再采集后快照；该快照开始于 00:53:13.097，距强杀前事件记录约 5.078 秒。后快照显示 GUI 与内核均已退出，utun197 和其接管路由消失，DNS 恢复为 192.168.0.1，IPv4 默认路由仍为 192.168.0.1 / en0，HTTP/HTTPS/SOCKS/PAC 均关闭；可观察的网络状态与直连基线一致。Helper 与 RecoveryGuard 仍运行。此项计为活跃 TUN 会话中 GUI 强杀后的状态恢复观察通过。

证据为私有目录 `work/clairroute-verification-2026-10-01/` 下的 `confirmed-gui-crash-event.json`、`active-immediately-before-gui-crash.json`、`after-confirmed-active-gui-crash.json` 与 `kill-active-gui.py`。时间戳是快照开始时间，各项状态随后依次采集，不能据此给出精确恢复耗时上限。此次未读取 root 恢复日志、心跳或实际 trial deadline，不能确认具体由 Helper 还是 RecoveryGuard 完成恢复。本次前后快照本身未验证恢复后联网；随后独立的 JustMySocks HTTPS 检查已在上文记录。GUI 的 recoveryPending、特权监听端口及 LAN 可达性未由此次快照验证。

## 会话缓存修复版安装确认（2026-10-01 上午）

用户完成本机事务更新。安装目录与当前签名构建的 GUI、Helper、RecoveryGuard、mihomo 四份二进制摘要一致，deep/strict 签名及固定证书要求通过。Helper PID 13949、RecoveryGuard PID 13945 均处于 running，runs=1、never exited。安装版界面显示双向 XPC 验签成功、无待恢复修改。

网络已从昨晚的家庭网络切换：当前 DNS 为 137.194.22.230，IPv4 网关为 137.194.176.1 / en0。系统代理关闭，无 utun197 或内核进程。后续验收明确使用 `after-session-cache-install.json` 作为新直连基线；该快照与旧基线不一致是网络环境变化，不能按恢复失败处理，也不能恢复到旧网关或 DNS。

停止状态点击“应用配置”预先读取凭据，首次 Keychain 授权需用户在系统窗口完成。`cache-prewarm-observation.json` 确认此时所有可比较状态匹配新的直连基线；没有启动限时试验或接管网络。

## 安装版双模式与会话缓存实测通过（2026-10-01 10:16–10:18，Europe/Paris）

用户完成首次 Keychain 授权后，停止状态的“应用配置”显示校验成功。整个测试保留同一安装版 GUI 进程 PID 15756；开启 120 秒 TUN 验收、随后开启系统代理、再分别关闭 TUN 和系统代理，均未再次要求 Keychain 授权。该结果验证同一进程中已缓存凭据的复用，不代表重新启动后不会再弹系统授权。

- `cache-both-modes-active.json`：utun197 及其 IPv4/IPv6 接管路由存在，DNS 指向 127.0.0.1，HTTP/HTTPS/SOCKS 均指向 127.0.0.1:17890，内核运行。
- 节点页面实际点击所选 s2 VLESS Reality 的“测速”，先显示“测量中”，随后显示 **643 ms**。这是一次采样，不是长期性能保证。
- `cache-live-listeners.json`：`netstat -anv -p tcp` 显示 root mihomo 的代理入口为 **127.0.0.1:17890**；采集的 17890/9090 过滤结果中没有 9090 监听。仅为本机监听观察，未代替另一台 LAN 设备的远程验收。
- `cache-tun-off-proxy-on.json`：关闭 TUN 后，DNS 恢复到 137.194.22.230，utun197 及其路由消失，系统代理仍开启，内核仍运行；两个开关能够独立控制。
- `cache-both-modes-stopped.json`：关闭系统代理后内核退出，系统代理/DNS/IPv4 默认路由/utun197 状态全部匹配今天的基线。另对比快照中的 IPv6 默认路由，整个过程与基线一致，原有 utun0–5 保留。
- 最终刷新状态并检查实际截图：Helper 已连接并验签，内核未启动，无待恢复修改，消息为“Proxying stopped and owned network settings were restored.”
- 停止后的独立直连检查：清空代理环境，使用 `curl --noproxy '*'` 请求此前授权的 JustMySocks 官方网站，返回 HTTPS 302、CONNECT=000。

当前安装版已完成主要功能的本机联网验证，测试结束时两个网络开关均关闭。30 分钟真实睡眠、会话中切换 Wi-Fi/热点、微信/Telegram 指定样例和另一台 LAN 设备探测仍未执行；不能将已实现恢复逻辑或本次正常开关测试等同于这些验收已通过。

## 界面精简与窗口行为修复（2026-10-01）

按用户反馈，侧栏 Button label 在全宽布局和 padding 后增加矩形命中区域；移除页面副标题、冗余灰色说明和常驻成功提示。保留实际配置数据、错误、恢复异常及卸载确认。移除 MenuBarExtra 和 LSUIElement，改为普通 Dock 应用：关闭窗口仍保持 AppModel/心跳，重新打开时展示唯一主窗口，真正退出仍执行 stopAndRestore。

完整本机签名构建通过，日志为 `work/clairroute-ui-polish-build.log`。没有更改 Helper、内核、代理分流或恢复逻辑，也未进行新的联网或故障测试。

为避免影响正在使用的 TUN，会话外单独编译 UI Preview：同一批视图和 AppDelegate，独立 bundle identifier/空白资料目录；禁用订阅刷新，用拒绝访问的内存接口替代 Keychain，没有特权签名身份。computer use 实际点击侧栏右侧空白进入节点、规则和高级页，点击左侧空白进入连接页，均成功。截图确认冗余说明已删除。两次关窗后重新打开仍是 PID 39226，保留“高级与维护”页面；真正 Command-Q 后进程退出。这里验证的是通过本机启动入口重新打开的行为，未直接操作 Spotlight 搜索结果。

原安装版 GUI PID 15756、内核 PID 24513 在上述检查前后保持不变。`after-ui-polish-preview.json` 对比 `before-ui-polish.json`，代理、DNS、IPv4 默认路由、utun197 及内核运行状态一致。新版已准备好，尚待用户完成管理员安装；不能将预览结果当作 `/Applications` 已更新。

## 界面修复版已安装并核对（2026-10-01 10:43 起，Europe/Paris）

用户随后完成更新。四个已安装组件与签名构建摘要一致，deep/strict 签名及固定证书验证通过，LSUIElement 已移除。Helper PID 44104、Guard PID 44100 均 running、runs=1、never exited。`after-ui-polish-install.json` 显示系统代理、DNS、路由和内核状态匹配今天直连基线。

computer use 打开 `/Applications/ClairRoute.app`，实际点击侧栏“规则”右侧空白成功切页；界面已精简，规则和用户选择的 s3 节点保留。关闭窗口后应用仍运行，通过本机启动入口重新打开后仍为同一 GUI PID 45247，保留规则页状态；只有一个主窗口。随后回到运行页：两开关关闭、Helper 已验签、内核未启动、无待恢复修改。这轮检查未切换网络模式，未进行联网测试。

## 连接页未运行状态布局修复（2026-10-01）

用户截图显示连接数量/搜索框在页面中部，空状态偏左。原因是未运行分支没有撑满可用空间，父容器将整个内容按固有高度居中。仅调整 ConnectionsView：外层 VStack 占满内容区并顶部对齐，ContentUnavailableView 占满工具栏下方剩余空间并居中。

无特权身份、空白资料库、禁用订阅刷新和真实 Keychain 的独立预览编译通过；computer use 打开连接页，实际截图确认数量/搜索框位于顶部、空状态位于剩余内容区中央。随后退出预览。完整本机签名构建通过，日志为 `work/clairroute-connections-layout-build.log`。未改动网络配置或运行服务；布局修复构建尚待管理员安装。


## 明文配置保存与显式迁移（2026-10-01）

用户明确改为明文存储，替代原始 Keychain-only 要求。ProfileStore v3 在同一 profile.json 中保存节点完整凭据与订阅 URL；正常载入、编辑、删除、配置生成与订阅刷新不再调用 Keychain。文件0600、目录0700，32 MiB上限；先校验完整候选内容，再临时文件同步并原子替换。旧版只展示迁移入口，用户主动迁移时读取全部旧凭据，完整配置确认落盘后才清理旧条目；失败清理记录保留，正常启动不自动重试。

全套离线测试通过，包含明文字面值与重启读取、两次模拟订阅更新、规则/选中节点保留、权限、写入失败保持原文件/内存、v1/v2迁移、缺失旧项后重试、提交先于源删除、清理失败后日常零Keychain，以及8192个旧待清理引用加活跃凭据的容量边界。使用虚构凭据、临时目录和模拟vault/fetcher，没有读取真实钥匙串或联网。

隔离UI预览保留相同视图和ProfileStore，独立资料目录、无特权身份、自动订阅刷新关闭、Keychain替身拒绝所有访问。computer use 导入虚构 example.test 节点后界面显示成功；落盘检查确认schema3、明文测试密码匹配、文件0600/目录0700；退出并重新打开后节点仍存在。连接页截图确认搜索栏位于顶部，未运行状态在剩余区域居中。预览随后退出。

最终本机签名构建与deep/strict验证通过；构建摘要记录于work/clairroute-plaintext-build.json。实际 /Applications 更新与真实旧数据迁移仍待用户完成管理员安装和系统钥匙串授权。此轮未启动真实内核或切换系统代理/TUN，不新增联网验收结论。

用户随后完成管理员更新与迁移。只读核对确认 /Applications 中 GUI、Helper、RecoveryGuard、mihomo 四项摘要均匹配最终构建，deep/strict 及固定证书签名通过；真实 profile.json 为v3，6个节点和1个订阅的凭据引用完整，旧Keychain待清理引用为0，文件0600、目录0700。未输出凭据值。computer use确认安装版无迁移提示、Helper已连接并验签、两个开关关闭、内核未启动、无待恢复修改；连接页截图确认布局修复已生效。此次没有启动代理或进行真实订阅刷新。


## 后台运行隐藏 Dock（2026-10-01）

用户要求运行时不显示 Dock，继续保留 Spotlight 打开窗口且不恢复菜单栏图标。App-Info.plist 设置 LSUIElement=true；AppDelegate 的关窗继续运行、重开单一窗口和退出前恢复网络逻辑未变。“高级与维护”新增显式“退出 ClairRoute”按钮，调用 NSApp.terminate 进入同一恢复退出路径。README同步操作说明。

独立UI预览编译通过，computer use冷启动窗口显示正常；NSRunningApplication只读查询PID9635、activationPolicy=1（accessory），窗口显示时仍保持后台激活类型。关闭并重新打开后仍为PID9635且保留高级页；点击退出按钮后系统应用清单确认isRunning=false。该预览无特权身份、关闭订阅刷新，不读取实际配置或Keychain。没有进行联网/开关测试。

正式本机签名构建及deep/strict验证通过，最终Info.plist确认LSUIElement=true；构建摘要保存到work/clairroute-background-build.json。安装替换仍需用户输入管理员密码，尚未将预览结果视为安装版已生效。

用户完成后台版本安装后，只读核对确认 /Applications 中四个组件的 SHA256 均匹配 clairroute-background-build.json，deep/strict 签名验证通过，LSUIElement=true。实际 GUI PID11755，NSRunningApplication.activationPolicy=1（accessory），finishedLaunching=true；确认运行实例采用隐藏 Dock 的后台模式。computer use 打开实际安装版窗口正常，Helper 已连接并验签、双开关关闭、内核未启动、无待恢复修改。此次未切换代理或修改配置。
