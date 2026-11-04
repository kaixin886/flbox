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

## 0.20 普通导航栏选中图标不可见修复（2026-11-04 00:0x，真机反馈）

- **反馈**：普通导航栏「显示不全」。截图放大＋像素取样实锤：选中的目的地图标渲染为纯白（pill 区域白色像素 700、强调色像素 0），落在浅色 indicator 上等于没画出来，只剩文字标签。
- **病根**：_theme 手搓 ColorScheme 时未设 secondaryContainer/onSecondaryContainer；Material NavigationBar 的选中图标色取 onSecondaryContainer，未指定时在本工程解析为白色。玻璃导航用自定义 _NavItemContent 显式配色，故只有普通样式中招。
- **修法**：① ColorScheme 补 secondaryContainer/onSecondaryContainer（浅色底＋深强调色字）；② ThemeData 加 navigationBarTheme，iconTheme/labelTextStyle 按 selected 状态显式解析（选中＝强调色＋半粗）；③ _PlainNavBar 的目的地再带 selectedIcon 强调色，双保险。

## 0.21 日志可靠性（2026-11-04 00:1x，真机反馈）

- **反馈**：规则模式下日志页「暂无日志」（核心 running=true、自检 dial OK 的同时）。助手本地真启动对照实验：同一代码路径下全局/规则两模式均正常写日志（规则模式含 DNS 客户端行），故配置与翻译无罪，问题在设备端文件生命周期。
- **头号嫌疑（已修）**：日志页「清空」原为删除文件——Xray 整场持有日志文件句柄，路径被删后后续日志全写进已脱链的 inode，页面永远读不到、直到核心重启才恢复，表象与模式无关、只与「在哪种模式下按过清空」有关。改：清空＝截断（writeAsString('')），保留同一文件。
- **可观测性**：日志页新增文件状态行（不存在/字节数）；每次核心启动成功后由 Dart 追加一条 `[flbox] core started (vpn/rules/node)` 标记——启动后文件必存在且有内容，下次再遇「没日志」可一眼区分是读不到文件还是核心没写。
- 本版同时包含 0.20 的普通导航栏选中图标修复，未单独构建 0.20 者直接构建本版。

## 0.22 日志显示修复＋运行中切模式＋自动选最快排除信息节点（2026-11-04 00:4x，用户睡前清单）

- **日志真相**：0.21 真机截图——文件在长（6,261,224 → 6,418,895 字节/2 分钟），页面却恒显「暂无日志」。即日志一直在记，是**读不出来**：_loadLog 原用 readAsLines 整文件严格 UTF-8 解码，6MB 累积里任一坏字节即抛异常被 catch 吞成空串。改尾部读取：只读最后 96KB、allowMalformed 解码、取末 200 行——文件多大/有坏字节都能显示。另加启动前轮转：文件 >2MB 时只留最后 256KB（在核心停止时执行，避免与核心持有的句柄冲突），防无限膨胀。日志文本改等宽 11px。
- **运行中切模式**：_setRulesMode 原本在 _running 时直接拒绝（「先停止再切换」）。改为：照常保存＋重翻译，若运行中则用新配置在同一隧道上原地重启核心（xrayStart 换实例、fd 不变、VPN 不断），与网络切换重启同一机制；失败才落到停止态并提示。
- **自动选最快排除信息节点**：机场订阅里的伪节点（剩余流量/套餐到期/重置倒计时）按名识别（isInfoNode 正则：剩余|流量|到期|重置|套餐|官网|公告|订阅|客服|expire|traffic|reset|remaining）——全部测速跳过它们（不再白测）、⚡自动选最快跳过它们（原 _pickFastest 不排除、可能选中流量卡）、节点卡片给它们打「订阅信息」灰标。手动点选不受限。
- 顺带确认：0.21 截图里普通导航栏选中图标已变蓝，0.20 修复真机生效。

## 0.23（2026-11-04）VPN 数据通路换 sing-box 转发器

- **定案过程**：Telegram 规则/全局模式间歇卡「连接中」。先后排除：机场节点出口（换自建 NTT 节点同症）、确定性配置错误（间歇性、且 0.10 曾通过）、出境环境干扰（其他代理软件同机同网无此病）。决定性 A/B：Termux 经 127.0.0.1:7890 直连 TG 数据中心 149.154.175.52:443 拿到了回应字节（DC 讲 MTProto，curl 报 wrong version number 正是连通的证据）——核心与节点健康，坏的是应用流量进核心的那一段，即 Xray 原生 tun 入站的 gVisor 协议栈（日志里 gVisor 系错误 endpoint is closed for send + proxy/tun connection was refused 刷屏，与此互证）。
- **新通路**：VPN 模式下由一个专用 sing-box 实例接管隧道：tun 入站（172.19.0.1/30、MTU 1500、gVisor 栈、auto_route 关）→ SOCKS5 出站 127.0.0.1:7890 → Xray 混合入站，即经典 tun2socks 结构；sing-box 的栈正是用户其他客户端在用的那套。fd 由 VpnService 交 Dart、Dart 经新 FFI FlboxVpnForwardStart 传入 Go，platform 的 OpenTun 返回该 fd 的 dup（sing-box 关它自己的副本，VpnService 保持原 fd 所有权）。Xray 配置不再带 tun 入站（翻译器去掉、冒烟测试改为断言其缺席）；fd 只归转发器，Xray 的所有 xrayStart 调用一律 fd=0。
- **生命周期接线**：启动顺序＝起隧道→起 Xray→起转发器，转发器启动失败走既有失败清理（连 Xray 一起拆）；停止＝先停转发器、再停 Xray、再拆隧道；网络切换/切节点/切模式只重启 Xray，转发器的 SOCKS 出站按连接重拨、无需动；启动对账新增一支：隧道与 Xray 都活着但转发器死了时，用找回的 fd 原地把转发器拉起来，拉不起来才整场拆掉，绝不认领一个会黑洞的会话。测速换实例期间转发器照常指向 7890（与旧行为等价：测速实例不接隧道流量，测完恢复）。
- 本地验证：Go 三包测试全过（新增转发器代码、OpenTun dup、翻译器去掉 tun 入站均编译入内）；flutter analyze 干净。转发器在真机上的启动（libbox Setup + OpenTun 路径）只能真机验：重点看 VPN 模式开启后 Telegram 是否秒连、网页/视频是否照常。

## 0.24（2026-11-04）协议补齐＋节点编辑＋自动更新改版＋仪表盘速率图

- **协议补齐（Xray 翻译器）**：新增 hysteria2 与 wireguard。hy2 按 Xray 的拆分结构生成：出站 settings 只放 version/address/port，auth 在 hysteria 传输层，salamander 混淆走 finalmask.udp，带宽走 finalmask.quicParams 的 brutalUp/Down（数字按 Mbps、字符串透传）；TLS 默认 ALPN h3；端口跳跃未映射。WG：私钥/公钥/预共享密钥、内网 IP 自动补 /32 或 /128、allowedIPs 缺省双栈全量、mtu 与 reserved 直通。自签名服务器的新出路：节点可带 FlBox 扩展字段 pinned-cert-sha256 → tlsSettings.pinnedPeerCertSha256（Xray 已宣布 allowInsecure 于 2026-06-01 后变硬错误，本版起新节点优先用指纹）。冒烟测试扩为三节点（vless REALITY＋hy2 混淆带宽＋WG）且每份配置必须过真 Xray LoadConfig；sbtranslate 不动，TUIC/AnyTLS 仍跳过。
- **节点编辑＋手动添加**：字段处理放 Go 侧（xraytranslate/nodeedit.go，经 yaml 节点树改文档，其余内容与注释不丢）：NodeDetail 读单节点字段、UpsertNode 按原名替换/同名替换/追加、DeleteNode、FilterNodes（keep/drop 正则）。Dart 是按协议的表单页（六协议字段集，照 v2rayNG 编辑页口径）：编辑从原条目深拷贝叠加表单，未知字段不丢；清空字段即删键；现实字段（reality-opts/ws-opts）空了自动剪枝。入口：节点卡铅笔按钮编辑、代理页右上 ＋ 添加。添加写入独立的本地订阅「手动节点」（id=manual、无链接），订阅更新永不覆盖；编辑订阅节点则就地改该订阅文件，编辑页对链接订阅明示「订阅更新后覆盖」。改名撞名拦截；运行中禁止编辑（先停止）。
- **自动更新改版（照 netproxy）**：订阅新增每份独立设置——autoIntervalHours（6/12/24/48/72）、updateViaProxy（直连/经当前代理 7890）、keepRegex/dropRegex（更新时经 FilterNodes 应用到节点名）。配置页订阅卡加「编辑」打开 _SubEditPage（名称/链接/自动更新/周期/更新网络/过滤，保存时校验正则）。设置页的全局间隔降为「新订阅默认更新周期」。到期检查三路：启动时、应用存活期 30 分钟定时器、WorkManager 每小时后台任务（独立 isolate 拉取＋过滤＋翻译验活＋写文件与 subs_v2、置 bg_subs_changed 标志；经代理类订阅后台跳过）；UI 在启动/回前台时消费标志：元数据重载，活动订阅被后台换了文件且核心未运行时自动重新激活。自动路径全程静默（失败不弹 toast，成功只记日志行）；手动更新保持原有提示。
- **UI 第一批**：仪表盘加实时速率曲线卡（复用 2 秒流量轮询的样本队列、上限 45 点；下行强调蓝填充、上行绿线，带峰值读数与图例）；代理页顶加订阅页签（多订阅时横滑 ChoiceChip 切换）；延迟配色统一 _delayColor 并收紧阈值（<120 绿、<280 橙、其余红，原 300/800 在本用户线路上几乎全绿等于没信息）；仪表盘当前节点延迟同步配色；状态文案注明「Xray 核心 · sing-box 数据通路」。
- 本地验证：Go 三包测试全过（新增 nodeedit 五个用例＋FilterNodes 用例、冒烟三节点全量 LoadConfig）；flutter analyze 干净。真机待验：hy2 节点（机场＋自建指纹）实连、WG 节点导入、节点编辑改名/删除、手动节点不被订阅更新冲掉、订阅编辑页保存、后台自动更新（关应用等周期或改小周期观察）、速率图与订阅页签观感。workmanager 为新依赖，CI 若因插件构建失败优先看 Android 侧报错。

## 0.25（2026-11-04）单节点链接导入＋多格式文件导入＋选择器白名单

- **单节点链接导入**：Go 侧 ParseShareLinks 解析 vless/vmess/trojan/ss/hysteria2/wireguard 六种链接（多行或整段 base64 blob），产出与节点编辑器同构的条目、经 UpsertNode 存入「手动节点」；hy2 链接的 pinSHA256 直落 pinned-cert-sha256，vless 的 raw 传输名归一为 tcp。入口：代理页右上链接图标、配置页「从单节点链接导入」按钮（对话框带粘贴键）；无法解析的条数在 toast 里报数。六链接全链路测试（解析→upsert→翻译，REALITY 与 obfs 存活断言）在内。
- **多格式文件导入**：Go 侧 ConvertImport 统一嗅探并归一为 Clash YAML：YAML 直通、链接清单/base64、Xray JSON（protocol 体系，hysteria 出站的 finalmask salamander/quicParams 与 pinnedPeerCertSha256 反向映射回条目）、sing-box JSON（type 体系，含 endpoints 的 wireguard，selector/direct 跳过）。_addSubFromYaml 与订阅更新路径都先归一，JSON 型订阅可加可更新；导入 toast 标注来源格式。Xray/sing-box 两组真配置转换测试在内。
- **文件选择器白名单**：_importProfile 由 FileType.any 改为 custom 扩展名（yaml/yml/json/txt），无关文件不可选、防加错。历史注记：any 是当年 yaml MIME 不一致变灰的对策；若本机再现变灰，退回 any＋ConvertImport 内容校验（非配置内容本就导不进）。

## 0.26（2026-11-04）修测速全灭（allowInsecure）与 VPN 关不掉

- **allowInsecure 根除**：0.24 真机实锤——良心云 47 节点里混有普通 TLS 节点，翻译器给 tlsSettings 恒写 allowInsecure（false 也写），而内嵌 Xray 26.3.27 对该字段是「出现即硬错误」（已移除特性），单个节点选作出口时启动必死、TranslateAll 的整表配置一加载就被 proxy-31 拖沉、全部测速直接报「测速失败」。修法：翻译器任何路径都不再输出 allowInsecure（TLS 与 hy2 两处）；skip-cert-verify 在 Xray 侧无等价物，自签服务器走 pinnedPeerCertSha256（普通 TLS 分支也接上 pin）。另加防线：宿主包给 TranslateAll 注入 OutboundCheck（逐出站用真 LoadConfig 验活），验不过的节点不给测速端口——今后任何单个坏节点只死自己、不沉整表。测试：TLS 版三节点（vless/trojan/hy2 均带 skip-cert-verify）逐个与整表 LoadConfig 全过、配置全文断言无 allowInsecure、人造毒节点被跳过。
- **VPN 停止加固**：用户报「开关关了 VPN 服务还在」。停止路径三层兜底：Dart 侧抽出 _stopCore 统一拆除（转发器→核心→隧道），停后轮询 vpnActive 校验、没停掉记日志并重试一次，结果行（core stopped (vpn service down)）进日志页可查；MainActivity 的 stopVpn/stopCoreService 在发停止意图后 600ms 再 stopService 兜底（服务没自停则系统强拆、onDestroy 关隧道）；两个服务都加 onTaskRemoved——划掉后台时先喊 Dart 走正规停止，800ms 没落地则本地自拆。本地模式的「核心服务」通知残留同理覆盖。
- 文件导入在 0.24 真机已确认可用（ntt-test-profile.yaml 导入成功）。

## 0.27（2026-11-04）VPN 关不掉定案：OpenTun 的 dup fd 泄漏

- **真凶（dumpsys＋sing-box 源码双实锤）**：0.26 实测停止后代理停了但 VPN 图标/服务不走。用户 dumpsys 抓到 FlboxVpnService 的 ServiceRecord 还在：startRequested=false（stopSelf 已生效），但 system 进程经 android.net.VpnService 的绑定不撤——系统只在 tun 接口真正消失时才解绑。读 sing-box 1.14.4 libbox 源码定案：wrapper 的 OpenInterface 拿到 OpenTun 返回的 fd 后只做 getTunnelName 查询、再 dup 一份给 tun 设备（tun.Close 关的是这份 dup），**OpenTun 返回的那个 fd 本身 libbox 从不关闭**。而 FlBox 的 platform.OpenTun 恰恰返回的是自己 unix.Dup 的副本——于是每开一次 VPN 就泄漏一个永不关闭的 fd 句柄，tun 接口永远有活句柄、永不消失，服务被系统绑住直到强行停止整个进程（与用户「强行停止才消」吻合）。
- **修法**：OpenTun 改为把 VpnService 的原始 fd 原样交回（所有权仍在 Kotlin 服务手里、由它 stop 时关闭），libbox 内部 dup 自管。platform.go 注释已换成源码核实过的契约，并注明旧注释「sing-box 会关掉给它的 fd」是错误假设、勿再 dup。
- **校验口径纠正**：0.26 的 _stopCore 轮询 vpnActive 判「down」是假证据——active 在 stopVpn() 入口就被置 false、远早于系统拆完。VpnService 新增 alive 标志（onCreate→onDestroy）经通道 vpnServiceAlive 暴露，_stopCore 改为轮询服务是否真被销毁才记 core stopped (vpn service down)，没销毁则记 still alive 并重试。
- 0.26 的 onTaskRemoved 与 stopService 兜底保留（无害），但它们治不了绑定不撤——本版 fd 修复才是根子。

## 0.28（2026-11-04）文件选择器白名单撤回：yaml 在用户 ROM 上被灰掉

- 0.25 的 FileType.custom 扩展名白名单真机翻车：用户截图实锤 config.yaml 在系统选择器里不可选（同目录 .json 可选）。根子是安卓选择器按扩展名→MIME 映射过滤、yaml 无标准映射。按预定 fallback 撤回：选择器恢复 FileType.any，防加错改为选后双闸——①扩展名拦截（非 yaml/yml/json/txt 当场 toast 拒绝）；②ConvertImport 内容校验（不是配置的文件导不进去）。代价：无关文件恢复「能点」，但点错也只是被拒、导不进来。

## 0.29（2026-11-04）去普通模式/普通导航栏、运行中切订阅、通知系统、排版收拾

- 用户拍板删**普通模式**：产品只剩 VPN 模式。删 _modeVpn 全部分支（启停/对账/翻译 vpn 恒 true）、设置里「模式」整节删除；FlboxCoreService 与通道方法留置不用（无害）。仪表盘状态文案恒为 VPN 口径。删**普通导航栏**：NavStyle 只剩液态玻璃/液态玻璃（滑动），_PlainNavBar 删除；旧的 nav_style 索引错位一格（原 2=滑动超出范围回落默认滑动，无感）。
- **运行中切订阅**：_switchSub 不再拦截，激活新订阅后原地 xrayStart 重启核心（同规则/全局切换的做法，VPN 不断）；重启失败则整体停止并告知。
- **通知**（设置「通知」节两开关，均默认开）：①启动通知——启动成功后经运行中核心实测一发 generate_204 延迟（顺带回填节点卡延迟）＋Cloudflare 200KB 下载测速，拼「节点·延迟·速度」走新通道方法 notifyStatus（MainActivity，独立 flbox_status 渠道）；②订阅自动更新通知——前台静默更新成功即发，后台 WorkManager 更新把名字存 bg_updated_names、下次打开 App 时补发（后台 isolate 无通道可用）。
- 排版：代理页工具栏标题去掉与页签重复的订阅名、只留节点数，图标按钮改 compact（此前排序图标被挤出屏幕）；配置页三个导入大按钮合并为一张列表卡（三行带图标）。

## 0.30（2026-11-04）延迟/速度改常驻通知

- 用户 0.29 实测：启动通知能收到，但一次性的点「清除」就没了。改法：节点/延迟/速度不再发一次性通知，改为写进 VPN 服务那条**前台常驻通知**（运行期间不可划掉、不可清除，停止才消失）。Dart 每 2 秒流量轮询顺带推送状态行（节点 · 延迟 X ms · ↓速率 ↑速率，文本变了才发通道）；启动时仍探一发延迟回填；切节点时立即刷新。FlboxVpnService 新增 companion statusTitle/statusText＋updateStatus（同 NOTIF_ID 重发 buildNotification 原地更新），MainActivity 新增 updateVpnStatus 通道方法。原 _probeSpeedMbps 一次性测速删除（常驻显示的是实时速率）。
- 设置开关沿用同一 pref（notify_on_start），文案改「常驻通知信息」；关掉则常驻通知保持默认文案。订阅自动更新通知按用户要求不変。

## 0.31（2026-11-04）常驻通知跟随切节点

- 用户要求：运行中换节点，常驻通知也要实时跟着变。0.30 已有切节点即推＋2 秒轮询兜底，0.31 补齐：切节点/运行中切订阅后除立即推送新节点名外，再 _primeStatus 重探新节点延迟填进通知（此前新节点没测速过时通知缺延迟段）；顺带修轮询的计数器回绕——原地重启核心后流量计数从 0 重来，旧算法会算出负速率闪进仪表盘与通知，现钳为 0。
- 追加（用户报「开启时切换分组卡顿」）：卡顿源是切分组时整表翻译＋逐节点 LoadConfig 校验（47 节点近一秒）与原地重启全在 UI 线程同步跑。_activateYaml 等全部主 isolate 的 translateXray 改走 Isolate.run（新增 _translate 助手，先快照字段再进 isolate——闭包不得捕获 this），四处原地重启（切节点/切订阅/切模式/网络变化）改走 _restartCoreInPlace。后台 isolate 与测速路径不动。

## 0.32（2026-11-04）UI 精修一轮＋自动更新开关收进编辑页

- 用户两点：①UI 太简陋；②自动更新不要在订阅卡上放开关、收进编辑里（编辑页本来就有该开关，卡面的是冗余）。卡面 Switch 行删除（含 onToggleAutoUpdate 全套管线），卡面只在 meta 里报状态（自动更新 24h/关）。
- 视觉：新增共享 _cardDecoration（卡面填充＋发丝边框＋浅色模式淡阴影）与 _iconTile（圆角方形着色图标）、_delayPill（延迟药丸）。仪表盘：状态卡换图标块＋时长绿药丸、上下行卡加方向图标块、当前节点卡换图标块＋延迟药丸；节点卡：协议改徽标、延迟改药丸、未选卡加发丝边框；订阅卡：左侧图标块（云/文件/手写按类型）、使用中改实心徽标、按 subInfo 解析出流量进度条；设置页主要条目补 leading 图标。

## 0.33 AsteriskNG 式视觉定版（用户 2026-11-04 发 AsteriskNG 截图指定模仿面）
- 版式总纲改为参照系客户端（AsteriskNG）：**灰底页面＋纯白实心卡片**（深色：页 #101012、卡 #1E1E22），取代旧半透明填充（用户评「太简陋」的根子）。页面浅底改为 #F2F2F6。
- 设置页改**分组白卡**：小灰标题在卡外（外观/代理/路由/连接/通知/系统/内核），行收进白卡内；功能一项不加——参照系里的 Mux/Fragment/HWID/Age 私钥/广播控制/隐藏图标等本产品不需要的明确不抄。
- 订阅编辑改**底部弹层**（圆角顶白卡）：填充式无边框圆角输入框（聚焦蓝框）、标题居中、底部取消/保存双按钮；打开方式由 push 整页改 showModalBottomSheet，返回值契约不变。卡面操作改图标按钮（刷新/编辑/删除，右对齐）＋未使用时左置「使用」浅色按钮。
- 仪表盘速率曲线**溢出修复**（用户截图实锤：切分组后绿线贯穿全屏）：根因＝旧版轮询未钳制、原地重启后计数归零算出大负速率＋Painter 无裁剪无 y 钳制。修法三重：轮询检出计数回退即判新核心实例——速率归零且清空历史样本（0.31 起已有速率钳制，本版补清历史）；Painter 加 clipRect 硬裁剪＋y 钳制＋非有限值归零——数据再坏也画不出卡外。

## 0.34 功能补强（用户 2026-11-04：「ipv6 那些加上」「订阅分组可以参考他的」）
- **IPv6 支持开关**（设置→高级，默认关，下次启动 VPN 生效）：开后 VpnService 加 fdfe:dcba:9876::1/126 地址＋::/0 路由，转发器 tun 同步双栈地址——关着时 IPv6 流量绕过隧道直连（泄漏口），开后一并接管；节点服务器无 IPv6 出口时 v6 目标会不通，故默认关、用户自选。链路：Dart pref ipv6_enabled → startVpn 通道参数 → MainActivity intent extra EXTRA_IPV6 → FlboxVpnService Builder；FFI FlboxVpnForwardStart 加 ipv6 参数选 vpnForwardConfig6。
- **订阅分组对齐 AsteriskNG**：①卡面右上加**启用开关**——禁用后该分组从代理页页签消失、自动更新（前台/后台）跳过；禁用正在使用的分组＝先停连接、当前位顺延到下一个启用分组（无则置空）；②编辑弹层加 **User-Agent** 字段＋预设 chips（ClashMeta/1.0、v2rayNG/2.3.10、sing-box/1.14.4），拉取订阅（手动/前台自动/后台自动三路）都用该订阅自己的 UA（此前写死 ClashMeta/1.0）。HWID/Age 私钥等 Mihomo 专属字段仍不抄。

## 0.35 仪表盘开启前布局修复（用户 2026-11-04 真机报障）
- 未启动时速率卡只剩标题行也要占满高（空图表 72＋图例），页面临界溢出一点点却滑不动、下方模式开关够不着。修法：无样本（<2）时速率卡只显示标题行（实时速率＋暂无数据），图表与图例有数据才展开；仪表盘滚动改 AlwaysScrollableScrollPhysics＋Column mainAxisSize.min，临界溢出也能拖动。

## 0.36 功能补齐（用户 2026-11-04 点选，到期提醒明确不要）
- 节点分享：Go 侧逆翻译 ShareLinkFor（xraytranslate/nodeshare.go）把任意节点导回协议分享链接（vless/vmess/trojan/ss/hy2/wg；pin 走 pinSHA256、hy2 跳跃走 mport），编辑节点页右上角分享按钮一键复制。附带补齐 hy2 端口跳跃全链路：clashProxy 加 ports/hop-interval、翻译器输出 finalmask.quicParams.udpHop、链接导入读 mport、nodeedit 字段序登记。
- 备份/恢复：设置页新增「备份」组。导出＝全部订阅（元数据＋YAML 内容）＋用户设置存成一个 JSON，经系统保存对话框落盘（失败回退剪贴板）；恢复＝选文件校验 app/kind 标记后全量覆盖订阅文件与设置、重载当前订阅。
- 开机自启恢复：was_running 在启动成功/接管会话时置真、手动停止时清零；设置→连接新增「开机自启恢复」开关；Kotlin BootReceiver 读 FlutterSharedPreferences，两者都真时拉起 MainActivity，Dart 侧以与自动连接相同的路径重连（ROM 拦后台拉起时退化为下次手动打开时恢复）。
- 后台自动更新修复：_bgRefreshDueSubs 此前假设订阅内容恒为 Clash YAML，现与前台一致先走 convertImport 归一化，并顺手把 subscription-userinfo 写回（formatSubInfoText 抽为顶层函数共用）。
