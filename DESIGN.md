# FlBox 设计说明

## 目标

从零自建的 Android 代理客户端：一机吃下机场 Clash 订阅与自建节点（VLESS/Hy2 等），界面仿 FlClash 版式，内核直连 sing-box 官方路线。不再 fork、不再做适配层缝合。

## 架构

```
┌──────────── Flutter UI（四页：仪表盘 / 代理 / 配置 / 日志）
│  Dart FFI（极简自有 API：FlboxSetup / FlboxTranslate /
│           FlboxStart / FlboxStop / FlboxVersion）
▼
Go core（core/，c-shared 导出 libflbox.so）
├─ sbtranslate/  Clash YAML → sing-box JSON 配置（复用现成纯 Go 包）
└─ experimental/libbox  服务生命周期（Setup + CommandServer）
     └─ sing-box 1.14.4 本体
```

数据流：Dart 读入 Clash YAML → `FlboxTranslate` 在 core 内译成 sing-box JSON → `FlboxStart` 交 libbox 启动。翻译只在 core 内做，UI 不碰 sing-box 配置细节。

## 与 FlClash 路线的切割点

- 不 fork FlClash，不把 sing-box 塞进 mihomo 形状的 core 接口（旧路线六批全死在适配层）。
- PlatformInterface 官方做法是平台侧实现；FlBox 里程碑 1 只做普通模式，先在 Go 侧给桩实现（`core/platform.go`），OpenTun 明确返回错误，TUN 留到 M2 再接 Android VpnService。
- API 只保留 FlBox 自己需要的几个函数，不追求与任何现有客户端兼容。

## Xray 试用（2026-11-02 用户拍板提前试）

- 同一个 libflbox.so 内嵌 Xray-core（与 sing-box 并存），新增 FFI：FlboxXrayVersion / FlboxXrayTranslate / FlboxXrayStart / FlboxXrayStop。
- 试用范围：Clash 配置导入 → 翻译为 Xray JSON（vless/vmess/trojan/ss；hysteria2 等暂跳过并在配置页列明）→ 普通模式启动（mixed 入站 127.0.0.1:7890、私有地址直连、其余全局走选中节点）→ 代理页点选节点即重启切换。TUN 与 sing-box 接入仍按原里程碑走。

## 里程碑

- **M0**：脚手架 + CI 出包。Flutter 四页骨架、core 能编 c-shared、GitHub Actions 产出 arm64 APK。
- **M1**：导入 Clash 配置 → 选节点 → 普通模式出网（本地 mixed 入站）+ 真测速。四项逐个真机验通才算过。
- **M2**：TUN 模式（VpnService + OpenTun 打通）。
- **M3**：再议 Xray 双核（sing-box 与 Xray 的 REALITY 不互通问题决定了双核的价值，届时按实测拍板）。

## UI 设计口径（硬性）

布局与信息密度按极简执行，只有一个例外（底部导航的液态玻璃）。

- **素净基线**：单底色 + 一个强调色；无渐变；页面内无阴影、无装饰元素；留白充足、信息密度低；一页只干一件事（仪表盘只看状态、代理只选节点、配置只管导入、日志只看日志）。
- **组件与字体**：系统默认字体，只用 Material 基础组件，不引入任何 UI 特效库。
- **液态玻璃（仅浮层）**：底部导航做成 FlClash 那种悬浮胶囊——半透明底色 + `BackdropFilter` 背景模糊、轻微高光描边、选中项胶囊指示平滑滑动。这套效果只用在底部导航和必要的浮层上，不蔓延到页面内容。
- **导航栏样式可切换**（设置页，持久化）：普通导航栏（Material 标准条）/ 液态玻璃（静态款）/ 液态玻璃（滑动）（静态外观＋可拖动＋点按/长按膨胀）。默认液态玻璃（滑动）。设置入口在仪表盘右上角齿轮，设置项不放在主页上。动态液态玻璃（透镜款）已于 2026-11-02 用户拍板移除，不再迭代。
- **动画**：手感对齐 FlClash。页面切换与指示器滑动用约 300–340ms 的 easeOutCubic 顺滑过渡；除此之外不加多余动画。
- **基线参数**（已落在 `lib/main.dart`）：底色浅 `#F7F7F9` / 深 `#101012`；强调色 `#3478F6`；页面边距 24；导航栏高 64、圆角 32、左右留 20、离底 14、模糊 sigma 20。

## 纪律

- 节点、订阅、密钥、签名文件绝不进仓；测试配置只用占位值。
- 包名 `com.kaixin886.flbox.dev`，与现有 FlClash 构建并存，互不覆盖。
- `.github/workflows/` 路径连接器写不了，工作流文件由用户手贴（见仓库根 `WORKFLOW-FOR-USER-PASTE.yaml`）。
- core 构建必须带 `-ldflags=-checklinkname=0`（libbox 内 oomprofile 用了 linkname 引 runtime 内部符号，缺了链接不过；sing-box 官方构建同此）与 tags `with_gvisor,with_quic,with_utls`（Hy2/REALITY 必需）。

## 大改版（2026-11-03 晚，对照 v2rayNG / sing-box 官方客户端后定）

- **核心必须有前台服务托管**：参考项目从不让核心裸跑在 UI 进程里（会被冻结、socket 流量被系统静默丢弃）。FlBox 普通模式由 `FlboxCoreService`（specialUse 前台服务）托管，启动顺序是服务先升前台、核心后开 socket；VPN 模式由 `FlboxVpnService` 托管。
- 仪表盘：状态卡（状态点/节点/模式/运行时长）＋实时流量卡（上下行速度与总量，Xray stats 计数器，每 2 秒刷新）。
- 代理页：节点卡片＋搜索＋按测速结果排序（最快在前、未测居中、超时最后），延迟按绿/橙/红分级着色。
- 配置页：文件导入＋订阅链接导入/更新＋删除配置。
- 设置：分应用代理（勾选的应用经 addDisallowedApplication 绕过 VPN，下次启动生效）。

## 版本与包名（2026-11-03 晚，用户定）

- 版本号从 0.01 起、按成功构建数递增且把既往构建计入：M0=0.01、840a3bd=0.02、f72223e=0.03、5641c88=0.04、284731b=0.05、43cb001=0.06、3139fda=0.07、3999d86=0.08、f3b15e8=0.09、改名版=0.10（versionCode 同步取构建序号）。以后每次发版序号 +1。注：Flutter 的 pubspec 只收三段式语义版本，两段式「0.10+10」会被 pub get 拒绝（db44875 首建实锤），故落盘格式为 0.<序号>.0+<序号>，如 0.10.0+10。
- 包名（applicationId）改为 `app.flbox`（原 com.kaixin886.flbox.dev 弃用）；新包名是全新应用身份（新 UID，旧版可卸载），namespace 仍为 com.kaixin886.flbox。

## 0.11 优化（2026-11-03 晚）

- **多订阅分组**：配置页改为订阅列表，可存多份订阅/本地配置，卡片显示节点数、来源、更新时间与订阅流量/到期（subscription-userinfo 头解析）；支持切换（运行中禁止）、逐个更新、删除（带确认）；当前订阅蓝框＋「使用中」标记。旧单配置（profile.yaml）在首启时自动迁移为第一条（id=legacy，文件存 sub_<id>.yaml，索引在 prefs 的 subs_v2/active_sub）。
- **并行测速**：Go 新增 TranslateAll（单配置多出站＋每节点一个本地入站端口 20100+i，FFI FlboxXrayTranslateAll），Dart 6 路并发探测，测完恢复原运行节点；取代逐节点重启实例的串行测速。
- **代理页**：标题行显示当前订阅名，新增排序菜单（智能/按延迟/按名称）。
- **仪表盘**：状态卡显示当前订阅名。
- **日志页**：新增「清空」按钮。
- **设置页**：底部版本号行（与 pubspec 同步手改）。

## 0.12 功能补齐（2026-11-03 晚）

- **规则模式（分流）**：设置→代理可选全局/规则。规则模式下翻译器把配置自带 Clash rules 翻译为 Xray 路由（DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD/IP-CIDR/GEOIP/GEOSITE/DST-PORT/MATCH；组名目标一律落到当前选中节点；不支持的类型跳过并计数）；无可用规则时兜底 geosite:cn＋geoip:cn 直连。geoip.dat/geosite.dat 运行时从 Loyalsoldier 规则库（jsdelivr 优先、GitHub 兜底）下载到文档目录，Go 侧 Start 前以 `xray.location.asset` 指到该目录；设置里可手动更新规则库。规则翻译有单元测试 core/xraytranslate/rules_check_test.go。
- **收藏节点**：代理页星标收藏，智能排序时置顶（prefs fav_nodes）。
- **测速选最快**：代理页闪电按钮＝全量并行测速后自动切换到延迟最低的节点。
- **启动后自动连接**（设置开关，prefs auto_connect）、**订阅每天自动更新**（超过 24 小时在启动时静默拉取，prefs sub_auto_update）。
- **仪表盘**：运行中状态行显示当前节点最近一次测速延迟。

## 0.13 流畅度与规则库内置（2026-11-03 晚，用户定）

- **规则库内置**：geoip.dat/geosite.dat 不再在手机端运行时下载。构建时由 Gradle 任务 `downloadGeoData`（android/app/build.gradle.kts）从 Loyalsoldier 规则库（jsdelivr 优先、GitHub 兜底，>1MB 校验，失败即构建失败）下载进 `src/main/assets/geo/` 打进 APK；运行时 Dart 经 MethodChannel `extractGeoData` 让 Kotlin 从 assets 本地复制到文档目录（后台线程），开规则模式即刻可用。手机端网络下载仅保留为 assets 缺失时的兜底路径；设置页「分流规则库」改为刷新内置版本。代价：APK 体积增加约 15–25MB。
- **流畅度**：① 流量轮询（2 秒）改走 ValueNotifier，只重绘仪表盘状态/流量卡区域，不再每 tick 整壳四页重绘；② 玻璃导航去掉「模糊＋饱和度矩阵」复合滤镜，改为单个静态缓存的 sigma 16 模糊，导航整体套 RepaintBoundary 隔离重绘；③ 代理页节点列表改 ListView.builder＋独立 _NodeTile，不再整表急切构建。

## 0.14 FlClash 式布局与 APK 瘦身（2026-11-03 晚，用户定）

- **布局模仿 FlClash**：仪表盘改为卡片网格——状态卡（整行）＋上行/下行双卡（速度大字＋总量）＋出站模式卡（全局/规则两段切换，直接调 _setRulesMode）＋当前节点卡（点按跳代理页）；启动/停止改 FlClash 式右下角圆形悬浮钮（FAB，仅仪表盘显示，运行中为停止图标、处理中为转圈）。代理页节点改双列网格卡（高 104，选中卡 accent 描边＋淡底，名称两行省略，底部类型＋延迟）。页面边距 24→16、卡片圆角 20 更紧凑。导航样式设置保留（默认仍滑动玻璃），配色纪律不变。
- **APK 瘦身**：android.packaging.jniLibs.useLegacyPackaging=true——.so 改回压缩存储（AGP 9 默认不压缩、APK 里是原样大小；Go 核心 .so 占 APK 大头且可压性好），安装时系统照常解出，装机占用不变、下载体积下降。规则库 dat 维持内置全量（assets 内已 deflate）。

## 0.15 规则模式修复与排序交互（2026-11-03 晚，真机反馈）

- **规则模式启动失败修复**：真机 0.13/0.14 规则模式必挂（`app/router: this rule has no effective fields`、全局正常）。病根：xraytranslate 把 Clash 的 MATCH/FINAL 翻成只有 outboundTag、零条件字段的 field 规则，Xray 26.x 在实例创建时整表拒绝（订阅必带 MATCH 收尾故必挂）。修法：MATCH 规则补 `network: "tcp,udp"` 作有效字段（全匹配语义不变、保留 target 指向）。新增真启动回归测试 core/xray_rules_start_test.go（StartInstance 实启，沙箱已验：去修复必红、带修复通过）——rules_check_test 只验翻译映射、没真启内核，是漏检原因，延续「校验在 Start 阶段」教训。
- **排序改非模态**：代理页排序原为 PopupMenuButton 弹出菜单，模态层吞掉全部手势、菜单开着时网格不能滑动，必须点一项才能继续（真机反馈）。改：排序图标点按在页头下方内联展开一行 ChoiceChip（智能排序/按延迟/按名称，AnimatedSize 150ms），选中即应用并收起，全程无遮罩、滑动不受影响。

## 0.16 规则模式改 v2ray 原版预设（2026-11-03 晚，真机反馈）

- **反馈**：0.15 规则模式（订阅 Clash 规则翻译版）「很一般，有的国内软件会没有网络」，用户定：移植原版 v2ray 规则模式。
- **病根分析**：① 翻译器 domainStrategy 为 AsIs——域名型流量永远走不到 IP 规则，GEOIP,CN 只对裸 IP 连接生效，国内 App 多为域名先行，未命中域名规则就落 MATCH 进代理；② 机场 Clash 规则重度依赖 RULE-SET 规则集与 Clash 的 DNS 语义，翻译器整段跳过 RULE-SET，分流表残缺。两者叠加即「国内软件没网/绕远」。
- **改法**：规则模式不再翻译订阅规则，改为 v2ray 原版绕过大陆预设——domainStrategy 改 IPIfNonMatch（域名未命中先解析、再用 IP 规则复判，这是原版的关键）、geosite:cn 直连、geoip:cn 直连、私有段直连、其余走代理；配套分流 DNS（geosite:cn 域名走 223.5.5.5 且 expectedIPs 限定 geoip:cn，其余走 8.8.8.8，v2rayNG 同款）；嗅探 destOverride 补 quic。translateRule 及计数逻辑删除，rules_check_test 改为预设断言；真启动测试拆为全局（常开）＋预设（FLBOX_TEST_ASSETS 指向 geodata 目录时启用），本地已用 Loyalsoldier 全量 dat 实测 Start 通过。
- **文案**：设置页规则模式副标题与切换 toast 改为「v2ray 原版绕过大陆」。

## 0.17 订阅自动更新可自选（2026-11-03 晚，用户定）

- **改法**：原全局开关「订阅每天自动更新」（只更当前订阅、固定 24 小时）拆成两层——① **每个订阅单独开关**：SubProfile 新增 autoUpdate 字段，配置页订阅卡片上（仅链接订阅，本地文件无此行）有「自动更新」开关；② **全局间隔可选**：设置页原开关位改为间隔选项行（6/12/24/48/72 小时，prefs sub_auto_interval_hours，默认 24）。启动检查改为遍历全部订阅，开启且超间隔者依次静默拉取（沿用 _fetchSubscription，非当前订阅只更新存储、当前订阅才重新激活）。
- **迁移**：旧 subs_v2 无 autoUpdate 字段时，以旧全局开关 sub_auto_update 的值作种子（开过全局＝每份订阅默认开启），恢复后回写一次固化。

## 0.18 订阅拉取排除本地代理（2026-11-03 晚，用户定）

- **要求**：自动更新要排除本地代理。落地为双重排除——① 对象排除：本地文件配置本来就不参与自动更新（无 URL、无开关、启动检查跳过，0.17 已如此）；② 通道排除：_fetchSubscription（手动更新与自动更新共用同一拉取路径）给 HttpClient 显式设 `findProxy = DIRECT`，订阅流量不走 FlBox 自己的本地代理口、不吃系统代理设置；应用本身也已在自家 VPN 隧道里被排除（addDisallowedApplication），故拉取全程直连。意义：节点全挂时恰恰最需要更新订阅，此时绝不能依赖代理通道。

## 0.19 会话生命周期修复（2026-11-03 晚，真机反馈）

- **反馈一**：开着代理划掉后台，VPN 还在；再进软件点关闭关不掉，只能强停。**病根**：FlboxVpnService 原为 START_STICKY——进程被划掉/MIUI 杀死后系统以 null intent 复活服务，旧代码走 else 分支重新 establish 一条新隧道，却把 fd 发给已死的引擎通道，核心根本没起：僵尸隧道全网黑洞；且 Dart 新状态 _running=false，仪表盘按钮只会走启动路径，服务里 tun 已存在又使启动变 no-op、fd 等待永挂，关不掉只能强停。
- **反馈二**：用一段时间后网页加载一点就断、反复重开才好。主嫌疑：默认网络切换（Wi-Fi/移动）后核心出站 socket 静默腐烂，实例不自知；与进程被冻/杀后会话半死同属生命周期问题。
- **改法**：① 两个服务改 START_NOT_STICKY，null intent 直接 stopSelf——会话随进程生灭，不复活无核心隧道；② 服务 companion 暴露 active 与 tunFd，MainActivity 加 vpnActive/coreActive/tunFd 查询；③ Dart 启动时 _resyncCoreState 对账：隧道与核心都活→认领会话（含找回 tunFd、恢复轮询），只剩一半→拆掉残留并记日志、toast 提示；④ _toggleCore 启动前先查并清掉残留隧道（自愈），避免 fd 等待永挂；⑤ 两服务注册默认网络回调，网络真切换时通知 Dart 在原隧道上重启核心（15 秒去抖），即「手动重开」的自动化；⑥ 生命周期事件以 [flbox] 前缀追加进核心日志，日志页可复盘。
