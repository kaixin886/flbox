# FlBox 设计说明

## 版本号规则（2026-11-05 用户定版）
- 大更新：动 beta 前的数字（如 0.71.2-beta → 0.71.3-beta），beta 后缀清零。
- 小更新：beta 前的数字不动，在 beta 后递增（如 0.71.2-beta1 → 0.71.2-beta2）。
- 版本名不带加号：显示与记录都写 0.71.2-beta1 这样，不写 +构建号。pubspec 内部仍保留 +N 作装机序号（不出现在版本号里），否则同名新包装不上；设置页底部字符串同步的是不带加号的版本名。

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

## 0.37 修复：全新安装规则模式启动失败（用户朋友截图＋用户清数据复现，2026-11-04）
- 定案：内置规则库解压目录错位——Kotlin extractBundledGeoData 把 geoip/geosite.dat 写进 filesDir，而 Dart 检查与 Xray 核心（assetDir＝日志所在目录）读的是 app_flutter（path_provider 文档目录）。全新安装/清数据后规则模式启动即报 geosite.dat 不存在；老用户因早期网络下载路径把文件落对了位置故不犯。全局模式不引用 geosite 故正常（用户实证）。
- 修法：Dart 把 docs 路径经通道参数 dir 传给 Kotlin、解压写到该目录；且 Dart 在解压报成功后复核文件确实落地（存在＋geosite >1MB）才认成功，否则回落网络下载路径，不再静默假成功。

## 0.38 修复：设置页开关点按不变样（用户 2026-11-04 录屏＋确认，其他开关同样）
- 定案：设置页是推入的路由，主页（HomeShell）setState 不会重建它；直接绑 widget 值的控件（自动连接/开机自启/IPv6/两个通知开关、路由模式勾选、分应用数量）改动其实已生效落盘，但本页视觉纹丝不动，关掉重开才显示新状态（导航样式与更新周期早用本地副本故无此症）。
- 修法：_SettingsPageState 给上述全部可变值加本地副本，各控件先 setState 本地副本再上抛回调；路由模式为乐观更新（壳层若因规则库失败拒绝会弹提示，重开页面自动校正）。

## 0.39 修复：后台划掉后系统 VPN 还在、面板却显示未启动（用户 2026-11-04 录屏）
- 定案：对账信号选错。旧 _resyncCoreState 只看 companion 的 active 标志，而它在停止一开始就翻 false、服务实际销毁却被系统 VPN 绑定拖住——于是「隧道/服务还活着、active 已假、核心已被有序停止」的半死状态对账时完全隐形，面板显示未启动，与通知栏里还在的 VPN 会话互相矛盾。此前只在启动时对账一次也放大了问题。
- 修法：对账改以（服务 alive && tunFd > 0）为「隧道存在」的准绳。隧道活＋核心活→接管（转发器死了就地重启）；隧道活＋核心死→在同一 fd 上重启核心＋转发器复活会话（不再拆掉系统还显示着的隧道）；只剩服务空壳（无隧道）→ stopVpn 清掉，让通知与系统 VPN 条目消失；核心孤儿→停核心。启动与每次回到前台（resumed，未运行且不忙时）都对账。

## 0.40：VPN 改 v2rayNG 式常驻 + 修测速闪退（用户 2026-11-04 两报）
- **常驻语义反转（用户拍板，覆盖 0.26/0.19 的旧契约）**：用户要求「和 v2rayNG 一样：后台划掉 VPN 服务仍然在，打开软件显示开启，点一下就可以关闭」。改法：① FlboxVpnService 删除 onTaskRemoved（不再喊 Dart 停、不再 800ms 自拆），清单给服务加 stopWithTask="false"；② Dart 删除 onTaskRemoved 通道处理；③ 常驻通知加 contentIntent，点击通知直接回到 App。会话生灭回归前台服务本身：进程还在→隧道＋核心＋转发器都在，重开靠 0.39 的对账接管（_running 直接延续或 adopt/revive），主开关一点即全拆；进程真被系统杀掉→隧道随进程消亡，null intent 仍 stopSelf 不复活僵尸（NOT_STICKY 不变）。休眠中的 FlboxCoreService 同步删 onTaskRemoved，免得日后复活时带回旧行为。注意：小米等 ROM 在划掉后强杀进程时 FGS 也保不住，那是系统层面的事，靠电池白名单缓解，不在本版范围。
- **测速闪退**：_testAll 是全仓最后一个把整表活放主 isolate 的地方——translateAll（47 节点逐个 LoadConfig 验活）＋两次整实例 xrayStart（测速实例与恢复原节点）全同步堵 UI 线程数秒，与 0.31「切分组卡顿」同源，堵到系统杀掉/ANR 即表现为闪退。改法：三处 FFI 全部走 Isolate.run（先快照 yaml 与原节点配置到本地变量，闭包不捕获 this），主 isolate 只留 6 路 HTTP 探测；另加 _busy 守卫。加固：Go 侧 FFI 边界加 panic 兜底（XrayStart/Stop、Translate/TranslateAll、VpnForwardStart/Stop、sing-box Start/Stop）——未捕获的 Go panic 会直接杀进程无任何提示，今后一律转成错误字符串走既有 toast＋日志路径，真有内核 panic 也能拿到文本定位。

## 0.41 修复：0.40 测速报「object is unsendable」（用户 2026-11-04 截图）
- 现象：0.40 点全部测速不再闪退（主线程解堵生效，应用活着），但 toast 报 `Illegal argument in isolate message: object is unsendable - _Timer ... <- _HomeShellState <- _testAll.<anonymous closure>`，测速在干活前就被拒。
- 定案：_testAll 里内联写的 Isolate.run 闭包继承了这个大方法的整个捕获上下文（State 对象及其内部 Timer），不可发送之物被一起打包，Isolate.run 直接抛错。而 _translate/_restartCoreInPlace 这类专用小方法没事，是因为它们的方法体里别无他物、上下文干净——「闭包先快照字段、绝不捕获 this」的旧规矩防的是直接捕获，防不住同方法内其他闭包把 this 拉进共享上下文这一路。
- 修法：测速的三处 isolate 调用（translateAll、起测速实例、恢复原节点/停核心）改走顶层函数（_translateAllInIsolate/_xrayStartInIsolate/_xrayStopInIsolate），顶层闭包只能捕获自己的参数，物理上带不进 State。耐久规矩追加：**大方法内绝不内联 Isolate.run，一律经顶层或专用小方法转发**。
- 本版仅 Dart 改动，0.40 的 VPN 常驻化原样保留、待一并验收。

## 0.42：全部测速改逐个串行（0.41 真机仍闪退后的定案修正）
- 三版演进复盘：0.39 测速在主 isolate 跑整表合并实例→闪退，0.40 归因主线程堵塞、挪后台 isolate（又踩 unsendable，0.41 改顶层函数修好）——0.41 真机点全部测速**仍闪退**。即工作真跑起来后照样死：堵塞说被证伪（后台线程不堵界面），崩溃点在「启动整表合并实例」本身——47 个出站（含从未被单独用过的协议类型）同一实例同时实例化，与日常单节点路径完全不同的负载形态。
- 改法：弃 TranslateAll 合并实例，改逐个串行——按节点自己的单节点配置（日常在用的同一份）逐个启动、经 7890 探一发、记延迟、下一个；结束恢复原运行节点或停核心。代价是慢（47 节点约半分钟到一分钟量级），换确定性。每个节点启动**前**先往日志文件写一行 `speed test: <节点名>`（同步落盘）——若某节点的出站仍能把进程杀掉，重开看日志页最后一行即肇事节点，下一步按类型定点修。单节点启动/探测失败只标超时、继续下一个。
- 顺带护栏：测速期间主开关与切节点拒绝操作并 toast（测速循环独占核心单例，避免并发换实例相撞）；网络变化自动重启本来就避开 _testing，不动。
- Dart 侧 CoreBridge.translateAllXray 与 Go 侧 FlboxXrayTranslateAll 保留不删（无调用方），日后若要复活并行测速，先在本地用真实节点类型矩阵压测合并实例再说。

## 0.43：测速改独立临时实例并行，撤操作锁（用户 2026-11-04：串行太慢＋测完前不能操作）
- 0.42 串行版真机能跑完（用户未再报闪退，截图证实测速进行中、当前节点有 147ms），但用户打回：逐个换主实例太慢，且测速期间护栏把开关/切节点全锁死，体验差。
- 新设计：测速不再碰主实例。Go 新增瞬态实例注册表（xrayTestStart/xrayTestStop，FFI FlboxXrayTestStart/Stop，带 panic 兜底）：拿节点自己的单节点配置，把首个入站端口改到 20100+i 私有端口、日志从共享错误文件摘掉（防多实例抢同一文件），StartInstance 起独立小实例，与主实例（7890＋转发器＋VPN 会话）完全隔离。Dart 恢复 6 路并发 worker：起实例→探私有端口→关实例；测完无恢复步骤。VPN 开着测速时流量照走当前节点不受扰。
- 操作锁全撤：_toggleCore/_selectNode 的 _testing 拒绝块删除，_onNetworkChanged 不再被 _testing 挡（它重启的是主实例，与测速无关）。测速期间切节点/开关照常可用。
- 保留的定位手段：每节点起实例前先写日志行 `speed test: <名>`；单节点失败标超时继续。新增 Go 测试 TestXrayTestInstances：两节点（vless＋hy2）并行起实例、端口可拨、主实例不受扰、停后端口释放、停未知端口无害。

## 0.44：测速提速（用户 2026-11-04 报 0.43「测速太慢」）
- 两处根因（读 0.43 代码定案）：①`xrayTestStart` 把注册表互斥锁跨着 `StartInstance` 持有——启动是最贵的一步却全程串行，6 路 worker 实际只有探测在并行，47 个节点的启动一个接一个排队；②规则模式的单节点配置自带 geosite/geoip 路由＋分流 DNS，每个测速实例启动时都要加载 geo 数据文件并建匹配器——纯延迟探测根本用不上路由，这份成本却付了 47 遍。
- 改法：`xrayTestStart` 先把配置瘦身——删 routing/dns/stats/policy（无路由时实例默认全走第一个出站，恰好就是被测节点；删 DNS 一并去掉其 geo 引用，测速实例不再碰资源目录），再把 `StartInstance` 移到锁外（锁只护注册表 map，换入时旧实例在锁外关闭，stop 同理）；Dart worker 数 6→12。
- 新增 Go 回归测试：TestXrayTestStartStripsGeoSections（喂带假 geosite 名的路由/DNS 配置，剥离失效则启动必失败）、TestXrayTestStartConcurrent（4 路 goroutine 同时起实例、全数监听成功）。

## 0.45：测速照 v2rayNG 的做法重写（用户 2026-11-04：0.44 测到约 32 个闪退，要求参考 v2rayNG）
- 证据：用户日志截图——0.44 的 speed test 行从 15:38:49.401 起 1.7 秒内连打 32 行（按列表顺序数到新加坡专线02）随后进程消失；死点不在某类节点首次出现的位置。而 0.43（启动被锁串行、6 路）不闪只慢——差异变量收敛为「真并行启动＋带监听端口的实例跨多次 FFI 调用存活、与其它实例的启停交错」。
- v2rayNG 的实际做法（读其主仓与 AndroidLibXrayLite 源码，存于 flbox-verify/refs/）：每个节点单独一次原生调用 MeasureOutboundDelay——配置先在 Kotlin 侧裁掉 inbounds、清空 routing 规则、dns/fakedns/stats/policy 置空（postProcessForSpeedtest），原生侧解析后再把 App 段只留 proxyman-outbound/dispatcher/log、Inbound 置 nil，core.New 起实例，用 core.Dial 让 HTTP 探针从实例内部走默认出站，测两次取小，建、测、拆全在一次调用内完成，不开任何监听端口；并发默认 16，但全量（自定义）配置的测量被他们全局串行，源码注释原话：并行拆建可能 abort 掉探针进程。
- 本版照此落地：Go 新增 xrayMeasureDelay（FFI FlboxXrayMeasureDelay，返回毫秒数或 -1，panic 兜底）：JSON 层先删 inbounds/routing/dns/fakedns/stats/policy——本仓 Xray 版本的 JSON 加载器在**解析期**就会解析 geosite 引用（实测假 geosite 名在 LoadJSONConfig 阶段即报加载失败），只靠 App 过滤挡不住、必须先裁；随后 App 过滤＋Inbound=nil＋core.New/Start＋core.Dial 探针两次取小＋Close。Dart _testAll 改走该调用、8 路并发，逐节点日志行保留；旧的注册表式测速实例入口（xrayTestStart/Stop 与对应 FFI、桥接方法）保留无调用方作后备。
- 新增 measure_test.go 三件：freedom 出站直测本地 204 服务器走通全链路、带假 geosite 的路由/DNS 配置能测通（证两层裁剪生效）、6 路并发测量全过；Go 全包测试与 analyze 均过。

## 0.46：测速实例生命周期串行化（用户 2026-11-04：0.45 第 23 个闪退）
- 证据链补完：0.45 真机测到第 23 个完成时闪退（日志 start 行已打到第 31 个、新加坡专线01）。跨版本对照成为定案级证据——凡实例**串行**创建的版本（0.42 逐个换主实例、0.43 启动被注册表锁串行）全程不闪；凡实例**并发**创建的版本（0.44 真并行、0.45 测量调用全并发）都在同一订阅中段（20–32 个）闪退。
- v2rayNG 为何同设计不闪，也查清了：其清单里 CoreTestService 跑在独立的 `:tasks` 进程（原生层权威进程是 `:daemon`），原生探针就算 abort 也只死测试进程、界面无感；FlBox 测量跑在界面进程里，同样的 abort 就是闪退。这也是它敢默认并发 16 的前提。
- 改法：`xrayMeasureDelay` 的实例生命周期（LoadJSONConfig＋New＋Start＋Close）全部收进一把全局锁串行，只放探针本身并行——裁剪后的创建是毫秒级、慢的是探针，速度损失可忽略；这与 v2rayNG 对不可裁剪配置全局串行的处理同理。Dart 侧每节点补 `speed test done:` 完成日志，与 start 行配对：万一再死，无 done 行的在飞集合至多 8 个具名节点，可继续收窄。
- 若本版仍闪：下一手是将测速整体迁到独立进程（仿 `:tasks`），工程量大、留作后手不在本版。

## 0.47：测速迁独立进程＋分应用页改版（用户 2026-11-04：0.46 测到第 25 个仍闪退，拍板大改，并要求分应用照 AsteriskNG 图改）
- 0.46 真机测到第 25 个完成仍闪退——生命周期串行化未根治，进程内调度变量至此排除干净。剩下与 v2rayNG 的唯一结构差异就是宿主进程，本版按用户拍板做这个大改。
- 测速独立进程：新增 `FlboxTestService`（清单声明 `android:process=":tasks"`、非导出），内起第二个 Flutter 引擎跑 Dart 入口 `testMain`（`@pragma('vm:entry-point')` 保入 AOT 快照，不注册任何插件）。两进程经应用沙盒内 filesDir 文件通信：界面写任务文件（writeTestJob 通道落盘并清旧结果）→ MainActivity 拉起服务 → testMain 经 `flbox/testhost` 通道取任务、逐条回传结果（服务追加写 results 文件）→ 界面每 300ms 轮询结果应用延迟；done 标记收尾，25 秒无新结果判测试进程已死、按已有结果定稿、其余节点留未测。测试进程被原生 abort 只损失本轮测速，界面与其余结果无恙。服务起不来时自动回退 0.46 的进程内测速并在日志注明。
- 分应用页照用户截图改版：页首双开关（启用分应用／绕行模式，同一行），列表行带应用图标（listApps 通道新增图标 PNG 字节、后台线程渲染）、应用名＋灰色小字包名、右侧勾选框，行点击亦可切换；搜索框保留。模式语义补齐：绕行开＝勾选应用绕过 VPN（addDisallowedApplication）；绕行关＝仅勾选应用走 VPN（addAllowedApplication，此时本应用自动在隧道外、核心出站不回环）；未启用＝不做任何分应用处理。新增偏好 bypass_enabled／bypass_allow（备份/恢复一并带上），保存仍走页首「保存」、下次启动 VPN 生效，设置页行摘要随三态更新。
- Kotlin 改动较多且本地无 Gradle 无法编译验证，靠 CI 首构建检验：新文件 FlboxTestService.kt、MainActivity（startVpn 透传 splitOn/splitAllow、listApps 图标、四条测速通道）、FlboxVpnService（splitOn/splitAllow 消费）、清单加服务声明；Dart analyze 与 Go 全包测试本地已过。
- 0.47 构建成功（#49，41799820417）且真机首测：**界面未闪退**（进程隔离达成），但测速停在 23/47 不再前进。用户日志截图定性：38.7 秒全部 start 行打完（界面侧统一记录）、done 行自 40.26 起以轮询批次落盘（同毫秒多行＝轮询消费特征）、start 与 done 之间无「test service unavailable」行——服务路径确实在跑，测试进程在约 23 个完成处以与旧版相同的墙死/楔（同进程内旧版的闪退点），区别只是这次死在测试进程里。修法见 0.48。

## 0.48：测速停滞自动重启续测（用户 2026-11-04：0.47 卡在 23/47）
- 机制：单轮启动视为可消耗品。界面轮询 15 秒无新结果（原 25 秒）即判该轮已死/楔死，调新通道 `killTestProcess` 按进程名（包名＋:tasks、同 UID 可杀）强杀测试进程，再只带未测节点重新写任务、拉起服务续测；最多 4 轮，一轮零产出即停。每轮开始前都先 kill（上一轮正常结束残留的进程一并清掉，保证每轮都是全新进程——旧版证据显示那堵墙疑似按进程生命周期累计）。结果按节点名合并回同一张延迟表，已测的不重测。
- MainActivity 新增 killTestProcess（ActivityManager 查 runningAppProcesses 按名 killProcess）；FlboxTestService 与 Go 侧不动。停滞窗取舍：探针上限 12 秒，一整波 8 个同时超时时结果间隔可达约 12 秒，15 秒留了余量；误判停滞的代价仅是重测在飞的至多 8 个，无正确性损失。
- 0.48 真机结果（2026-11-04 17:02 用户截图）：这一轮**正常收尾**了（页首恢复「全部测速」、不再永恒测速中），但只测出前半段：已测为名单前缀（港/新/日高速，98–354ms），日本高速05 起的后半段整片空白——续测轮次零产出。定性：首轮启动走的是全新进程所以好使；续测的 start 落在「进程没杀掉（onStartCommand 见 engine 已存在直接忽略）」或「强杀未落地、start 被正拆除的旧实例接走」两者之一，新任务根本没跑起来。0.47 的永恒卡死与本轮的干净收尾差别，说明停滞定稿逻辑本身通了，坏的只是重启这一环。

## 0.49：续测重启加固＋计数分母修正
- FlboxTestService.onStartCommand 改为**每次 start 都销毁旧引擎、建新引擎**跑新任务——无论进程杀没杀掉、start 有没有被旧实例接走，新任务必然被执行。
- 界面续测时序改为：killTestProcess 后轮询新通道 `testProcessAlive`（同为 ActivityManager 按名查）等进程真消失（200ms×15≈3 秒上限；平台不给进程列表时立即返回、由服务侧重建引擎兜底），再写任务、拉起服务。
- 零产出容忍：单轮零结果不再立即放弃，连续两轮零产出才停；总轮次上限 4→5。
- 计数分母修正：页首「测速中 X/Y」的 Y 原为 profile.nodes.length（47，含 3 个订阅信息伪节点），改为可测节点数（过滤 isInfoNode 后 44），免得用户以为永远差 3 个。
- 0.49 真机结果（2026-11-04 20:02 用户截图）：又停在**恰好 23**（23/44）——加上 0.47、0.48，三版不同进程形态全停同一个数，且缺失结果是散布的（日本高速05、美国高速04 没数，同批的美国高速05 却有 834ms）。进程隔离与重启加固都没动这个数，说明触发点不在进程调度层。回读 measure.go 定案嫌疑：**某个实例的 Close() 死锁、吃住 measureMu**——探针有 12 秒上下文封顶、创建是毫秒级，唯独 Close 无超时且在锁内执行：它一卡，后续实例创建全排队等锁；在飞探针陆续完成凑到 23，而它们自己的延迟 Close 同样堵在锁后、结果永远发不出去（散布缺失正由此来）；进程不死、纯楔死，与全部现象吻合（0.48 续测零产出亦可由同一楔死在续测轮复现解释）。

## 0.50：Close 移出锁＋单节点看门狗
- Go：measureMu 只管创建（Load/New/Start）；Close 改走后台**串行关闭队列**（单独 goroutine 逐个关，关闭之间仍串行；队列满则退化为一次性 goroutine），单个 Close 卡死只堵关闭队列、泄漏的实例在一次性进程里无害，测量永不等待拆除。
- Dart（testMain）：单个节点测速加 30 秒看门狗——核心侧探针上限 12 秒、创建毫秒级，30 秒不返回即判定该调用楔死，记超时、弃置该 isolate（迟到结果忽略）、继续下一个，双保险兜底未知楔点。
- 0.50 真机结果（2026-11-04 20:22 用户日志）：**仍恰好 23**（done 行 20:22:36.35–40.01 共 23 条后停，最后一条美国高速02 timeout；JP05 本轮有数 245、US05 有数 313，US03/US04 仍缺）——**Close 吃锁说证伪并撤回**：0.50 的 Close 已不经过返回路径、不可能再堵住结果，计数却分毫不差。六版（0.45–0.50）跨 UI 进程/独立进程/串行/并行/换锁全停 23、缺失散布，形态签名只剩「某个节点的实例把共享机制楔住、同批在飞者陆续落地凑满 23」一类解释，逐个理论已试尽。

## 0.51：换方法——分块测速（每块 6 个、全新进程）
- _testAllViaService 重写为**分块启动**：名单按 6 个一一切块，每块先强杀旧测试进程（并等其消失）→写该块任务→全新进程只测这 6 个→轮询收果；块内未报节点一律记超时、打日志 `speed test: chunk gave up on N nodes`，继续下一块。每块边界打日志 `speed test: chunk K (6 nodes)`，日志可直接定位楔死块（把毒节点范围缩到 6 个名字）。
- 收益：毒节点爆炸半径＝6 个节点；名单尾部（专线/流媒体，从 0.45 起任何一版都没测到过）首次能被测到；整轮必然收尾、计数必然走满 44/44。代价：每块一次引擎冷启（约 1–3 秒），44 个共 8 块，整轮预计 40–80 秒。
- 0.48 的续测整表重启与 0.49 的零产出重试逻辑随之退役；kill＋等消失＋服务侧每次 start 重建引擎保留（每块仍需要可靠的冷启动）。
- 0.51 真机结果（2026-11-04 20:44 用户回报）：分块测速**能跑完**，但超过 30 个后**特别慢、且大批显示超时、实际节点可用**（假超时）。定性：done 后服务只 stopSelf——进程连同 .so 的累计状态（实例/连接/goroutine）作为缓存进程存活，下一块的引擎建在残渣之上；UI 侧强杀依赖 runningAppProcesses 可见性、本机不可证——「每块全新进程」从未被保证，累计约 30 个后探针被残渣拖垮，与 23 墙同源（同一进程累计测量的天花板）。

## 0.52：测试进程自杀——每块真正全新
- FlboxTestService 的 done 处理改为：回执＋stopSelf 后 400ms **killProcess(myPid) 自杀**（带 startGeneration 代次护栏：窗口内已有新 start 接管进程则不杀）。自杀不需要任何权限与可见性，必定成功；下一块的 startService 必然新建进程、Go 状态清零。
- 界面侧无需改动：既有的「每块先 kill＋等进程消失」正好等过这 400ms。楔死块不发 done、不自杀，仍由界面停滞强杀兜底（最坏污染相邻一块，与 0.51 分析一致）。
- 0.52 真机结果（2026-11-04 21:06 用户回报）：**和以前一样、仍是 30 个左右之后延迟虚高/超时**——进程自杀没改变曲线，说明累计源不在测试进程内（或不在进程层）：同一进程天花板说随之降级。用户问 v2rayNG 与 Clash 怎么解决：查实 Clash 系为**单实例装全部出站、逐出站借道探针**（零建拆）；v2rayNG 的原生测量与 FlBox 逐节点版同构（每节点建拆），靠独立进程＋1 秒 TCP 预检＋自定义配置全局串行缓冲，且其测 47 节点订阅的表现用户并未实测、无从认为它已解决。

## 0.53：按 Clash 形状重做——组合实例测速
- Go 新增 xrayMeasureAll：把一块 6 个节点的出站合并进**一个实例**：单个 SOCKS 入站＋每节点一个账号＋路由按 user 分流到对应出站 tag；探针为以该账号开 SOCKS 隧道的 HTTP 客户端（两次取小，与逐节点版同口径）。实例一块只建一次、只关一次（仍走后台关闭队列），逐节点零建拆。
- 整实例建不起来（某出站配置非法/端口被楔死的前任进程占用）→ 返回空串，testMain 自动回退该块走原逐节点测速（带 30 秒看门狗），不丢块。
- testMain 流程改为：先组合测速（60 秒看门狗）→ 成功逐条回报；失败才走原 8 工人逐节点回退。本地 Go 测试三件新增并全过：逐出站路由判别（中间死 SOCKS 出站必 -1、两侧 freedom 有数，路由串线即挂）、坏协议整实例失败回退信号、geo 段裁剪后仍可测。
- 0.53 真机仍同曲线，用户 21:30 拍板测速线关闭（见上条），0.54 转新需求：删无用代码＋加 root 模式。

## 0.54：删无用代码＋Root TUN 模式（一期）
- **删无用代码**（全部先验无调用方才删，删后 Go 全量测试＋analyze 绿）：Go FFI 九个不可达导出（FlboxVersion/SelfCheck/Translate/Start/Stop、FlboxXrayVersion/TranslateAll/TestStart/TestStop）及 translateClash＋自检 init；service_xray 的瞬态测试实例注册表（0.43 旧测速路）与 xrayTranslateAll；xraytranslate.TranslateAll＋AllResult＋OutboundCheck；xray_test_instance_test.go 整文件与 smoke 里两处 TranslateAll 测试；Dart bridge 四个死方法＋XrayAllTest 类；Kotlin FlboxCoreService 整文件＋三个通道处理器＋清单条目（push-files 不能删文件，仓内两文件以「仅包声明」形式清空）。**保留**：startCore/stopCore（转发器在用）、sbtranslate（root 模式要用）、逐节点测速（组合测速的回退）。
- **Root 模式架构**：App 进程拿不到 root，另设守护进程 `core/cmd/flboxd`（独立 sing-box 可执行，CGO 关、android/arm64，本地交叉编译实证 44.6MB）：以 libflboxd.so 之名进 jniLibs，Kotlin 首用时复制到 filesDir 并 chmod（防未解压打包无法 exec），经 su＋nohup 拉起；状态文件（running＋pid / error / stopped）为唯一回执通道，停止靠 su kill pid。
- **配置生成**（core/rootconfig.go，FFI FlboxRootTunConfig）：sbtranslate 全量翻译＋Selected 预设当前节点 → 入站换 TUN（auto_route、strict_route、gVisor 栈、分应用 include/exclude_package 沿用既有偏好）→ 路由砍为全局形（hijack-dns＋私网直连＋final 不变，规则集剥离）→ DNS 双服务器：bootstrap 走 direct 只解节点域名、remote 经 final 出。本地测试三件全过（含 sing-box Options 解析校验）。
- **App 接线**：设置页新增「运行模式」组（VPN／Root TUN／Root eBPF 禁用占位）；pref run_mode 贯通备份恢复；_toggleCore/_stopCore/_restartForMode（切节点/切订阅/切规则时重生成配置重启守护进程）/_resyncCoreState（状态文件 adopt）/_onNetworkChanged（root 下跳过）/状态轮询（root 下跳过）全部分流。root 模式下划掉 App 不影响守护进程（比 VPN 常驻更彻底）。
- **一期边界（明示）**：Root TUN 仅全局模式（规则模式需 .srs 规则集管线，后续阶段）；手动节点订阅在 root 下会报「节点不在订阅中」；仪表盘无流量曲线（守护进程无计数通道）；开机自启恢复对 root 模式未接。**eBPF 为二期**：设置项已占位禁用。
- **构建前置（需用户手改工作流一次）**：build-apk.yaml 的 Build Go core 步在 libflbox.so 之后加守护进程构建行（CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -o ../android/app/src/main/jniLibs/arm64-v8a/libflboxd.so ./cmd/flboxd），未改时构建照常成功、App 内 rootCheck 报「未包含守护进程」。
- 0.54 真机：构建成功（run 41845380098、产物 51MB、守护进程确认打入），Root TUN 启动即败：`start dns-transport: start dns/udp[dns-bootstrap]: detour to an empty direct outbound makes no sense`——转 0.55 修。

## 0.55：修 Root TUN 的 DNS bootstrap detour
- **根因**：sing-box 1.14.4 common/dialer/detour.go 的 DetourDialer 有「空 direct 检查」：detour 指向 DialerOptions 全默认的 direct 出站即在 DNS 传输启动时报错。rootconfig 给 dns-bootstrap 写了 `detour: "direct"` 而翻译产物的 direct 出站恰是全默认，触发此检查。VPN 路径不用这套 DNS 配置故从未暴露；0.54 的本地测试只验到 Options 解析、没跑 box.Start，故漏网。
- **修法**：dns-bootstrap 去掉 detour——新式 DNS 服务器无 detour 时用自身直连拨号器（官方文档口径：等价于空 direct 出站），正是 bootstrap 要的系统直连路径，且不经 DetourDialer、无此检查。注释已同步改写。
- **回归测试**：新增 core/rootstart_test.go——生成 root 配置后真的 box.New＋Start，断言不得死在 DNS/detour 阶段（本地沙箱在 TUN 创建处因权限停下属预期环境差异）。修复前本地逐字复现真机报错、修复后过关。今后动守护进程配置须跑此测试，不只解析校验。
- 0.55 真机：DNS 关已过、守护进程能启动，但**全部流量不通**。日志定案：HK 域名节点死于引导 DNS 查询 10 秒无回包；换 NTT（IP 服务器）仍不通，死于对 128.242.109.233:443 的裸 TCP 拨号 5 秒超时（夹杂个别 RST）——未到 REALITY 握手层，与已知的 sing-box↔Xray MLKEM 不互通无关。**定案：守护进程自身出站流量被自己的 TUN 捕获回环**。用户补充的旁证：开启前 Xray 路径测速正常，节点与网络无辜。另发现并顺手修：仪表盘运行文案写死「VPN 模式」，root 模式下亦然（纯显示 bug）。

## 0.56：修 Root TUN 自捕获回环
- **route.auto_detect_interface=true**：出站套接字绑物理接口，TUN 表路由对它们不可选（sing-box 桌面 TUN 的标准豁免机制）。
- **去掉 strict_route**：其防泄漏拦截在 Android 上连核心自身的回程流量一并吃掉。
- **TUN 路由排除名单**（route_exclude_address；注意 1.14 已删除 inet4_/inet6_ 前缀的旧字段名，用了会在 box.New 硬报错，本地启动测试当场抓住）：引导 DNS 223.5.5.5/32 ＋节点服务器 IP——域名服务器在配置生成时以 3 秒预算顺带解析（resolveServerIPs，软失败为空，靠第一条兜底），即 Magisk 代理模块通用的「服务器主机路由绕过」。已知局限：轮换 IP 的节点在会话中途重连到新 IP 时排除名单可能不覆盖，属二期课题。
- **仪表盘文案按模式分流**：root 运行时显示「sing-box 守护进程 · Root TUN 模式」（_DashboardPage 新增 rootMode 入参）。

## 0.57：Root TUN 改走 auto_redirect（netproxy 式结构）
- 0.56 真机新症状：电报能连、十余秒断、随后又恢复，且**只有电报能用、其他应用全灭**；`ip rule` 前后两张完全一致（规则没被动过），2022 号表为前缀切割形——route_exclude_address 以「补集前缀＋/32 挖洞」实现（223.5.5.5 与节点 AWS IP 的洞清晰可见）。定案：本机生成流量（含 netd 的系统 DNS）不在 auto_route 的接管范围内，DNS 逃逸 → 靠域名工作的应用全灭，只剩直连 IP 的电报独活；/32 快照对轮换 IP 亦先天脆弱。
- **TUN 入站开启 auto_redirect**：Android 上 sing-tun 以 iptables 把本机流量（含 53 端口）重定向进本地 redirect 监听，网络管理器给守护进程自身出站打 output mark（0x2024）按**发送者**豁免——即 netproxy/AsteriskNG 的结构，对节点 IP 轮换免疫。auto_route/auto_detect_interface/route_exclude_address 保留作兜底。
- **守护进程日志强制 info＋时间戳**：覆盖翻译器默认（低于 warn 不可见），此后真机日志可直接定案连接级问题。

## 0.58：守护进程配置瘦身为单节点 + 日志跨重启保留
- 0.57 真机：主功能通（浏览器走香港出口）但新连接随运行时间死亡——浏览器对谷歌/百度均 ERR_CONNECTION_CLOSED，已建长连的电报/Play 独活；NTT（443 与 8444）与 Muse App 亦连不上。两份 info 日志（守护进程各自只活了 50 秒/9 秒）均零错误、流量全经香港高速03——失败窗口从未被日志覆盖到（每次重启截断日志＋用户切节点测试即重启）。
- **配置剥离分组**（rootconfig）：翻译后只保留所选节点出站＋direct/block，route.final 与 dns-remote 的 detour 一并钉死该节点。动因：原配置继承订阅的 urltest 分组——日志一半以上是它对 47 个出站（含伪节点）的 gstatic 健康检查，且它能在会话中途改选出口，与「新连接死、长连活」的症状形态完全吻合；VPN 模式全天正常正因 Xray 路径钉死所选节点。剥离后出口确定、无测速风暴、守护进程内存亦降。
- **日志改追加**：Kotlin rootStart 的重定向由 `>` 改 `>>`，Dart 启动前写会话分隔行（时间/节点/ipv6）、超 1MB 才重置。此后失败窗口必在日志内，不再被重启抹掉。

## 0.59：新增 Root eBPF 模式（重定向接管，TUN 保留不动）
- 0.58 真机仍「还是一样」。其会话日志定案最后一层：全日志仅 2 条错误，均为并行 Google v6 连接的 `report handshake success: connection refused`——出站拨号已成功，死在 gVisor 持有式握手向应用交还的一步；该层在上游协议栈内部、无配置旋钮。用户拍板：TUN 保留不动，新增 eBPF 模式。
- 机制（netproxy/Asterisk 的交接结构）：守护进程仍是同一个 flboxd、同一套控制面与状态文件；配置改为 redirect 入站（TCP，127.0.0.1:7892）＋tproxy 入站（UDP，0.0.0.0:7893），单节点剥离同 0.58，route.default_mark=0x2B2B。应用连接的握手在本机监听处即时完成，不再被出站拨号绑架。
- 转向规则由 App 经 su 安装（Kotlin netRules）：nat OUTPUT→FLBOX_NAT（mark 豁免→本地地址豁免→分应用 uid 规则→REDIRECT）、mangle OUTPUT→FLBOX_MNG（同前置→TPROXY --tproxy-mark 0x2B2C）、ip rule fwmark 0x2B2C→table 100（local 0.0.0.0/0 dev lo）、ip6tables FLBOX_6 丢弃非本地 v6（本阶段只转向 IPv4，宁断不漏）。守护进程自身流量带 mark 天然豁免，自捕获不可能。
- 生命周期：启动＝守护进程确认 running 后才装规则（装失败回滚停守护进程）；停止＝先拆规则再杀进程；resync 发现守护进程已死时自动拆规则，绝不留指向死监听的规则。运行中切节点重启守护进程时规则不动（端口不变）。
- 边界：全局模式（分应用按 uid 支持包含/排除两档）；无流量曲线（同 TUN）；IPv6 开关在此模式不生效（v6 一律拦截）；开机自启未接。

## 0.60：启动失败改 AS 式报错弹窗 + netRules 诊断化 + 回滚清规则
- 0.59 真机：eBPF 启动恒报「规则安装失败，已回滚」，但日志实证守护进程零连接、规则实际半装——回滚只停守护进程没清规则，残链把 AsteriskNG 的 bpf2socks helper 也绊倒（用户手动跑清理命令后 AS 恢复，反证残局真实存在）。探针证 mangle 建链挂钩本身 OK=0；失败点因 netRules 只回布尔而不可见。
- **报错弹窗（用户指定照 AsteriskNG 样式）**：三种模式的启动失败统一走弹窗——标题「代理启动失败」＋模式＋时间＋错误详情＋设备与系统（Kotlin deviceInfo：app 版本/机型/Android/build/abi/内核/页大小/SELinux）＋启动日志（netRules 输出和/或 daemon 日志尾 6KB），按钮「关闭／复制日志」（复制全文）。原 toast 仅保留前置提示（如先选节点）。
- **netRules 诊断化**：回执改 {ok, log}；脚本分 nat/mangle/route/v6 四段带 echo 标记；成败不再信 -C 退出码（0.59 疑似在此误判），改 grep 实时规则列表（-S OUTPUT 含 FLBOX_NAT 与 FLBOX_MNG 才打 FLBOX_ALL_OK），且无论成败都 dump OUTPUT 与两条链的实际规则进 log——失败长什么样，弹窗里直接可见。
- **回滚补洞**：eBPF 规则安装失败时先停守护进程、再执行一次规则清除，杜绝半成品残留；停止流程与 resync 的既有清除不变。

## 0.61：eBPF 转向改 MARK＋PREROUTING TPROXY，弃 addrtype
- 0.60 真机（2026-11-05 08:19，弹窗日志一次定案）：nat 段实际装上（verify dump 里 FLBOX_NAT 挂在 OUTPUT、REDIRECT 规则在位），但 mangle 的 OUTPUT 挂钩失败——`iptables: Invalid argument`；三处 `-m addrtype --dst-type LOCAL` 全部报 `Extension addrtype revision 0 not supported, missing kernel module`；v6 段同因 addrtype 失败。
- 定案一：**TPROXY 目标不能用于 OUTPUT**（sing-tun 源码注释亦明言 tproxy is not available in output）。0.59/0.60 把 TPROXY 规则放进 OUTPUT 跳转的链，插跳转时内核 EINVAL——建链与加规则本身能过、挂钩过不了，正对上「链都在、OUTPUT 里没有 FLBOX_MNG」的 dump。
- 定案二：本机内核**没有 xt_addrtype**，本地豁免不能用 addrtype。
- 修法：FLBOX_MNG 只做 `-p udp -j MARK --set-xmark 0x2B2C`（OUTPUT 合法）；新增 mangle PREROUTING 链 FLBOX_PRE，仅对 mark 0x2B2C 的 UDP 做 TPROXY --on-port 7893；ip rule/table 100 不变（marked 包经 lo 回环进 PREROUTING）。本地豁免改显式 CIDR 段（0/8、10/8、100.64/10、127/8、169.254/16、172.16/12、192.168/16、224/4、255.255.255.255/32）；v6 链本地豁免改 `-d ::1/128`。
- verify 升级：FLBOX_ALL_OK 须同时 grep 到 nat OUTPUT 的 FLBOX_NAT、mangle OUTPUT 的 FLBOX_MNG、mangle PREROUTING 的 FLBOX_PRE 与 ip rule 的 0x2b2c，并 dump FLBOX_PRE 与 ip rule 全表；清除脚本同步拆 FLBOX_PRE。
- 顺手：selinuxState 只接受 enforcing/permissive/disabled 单词答案，不再把 getenforce 的报错文本当状态显示（0.60 弹窗里露出的那串 permission denied）。

## 0.62：eBPF 的 DNS 劫持修复 + debug 日志 + 规则自检愈合
- 0.61 真机：规则首次装成功、电报/Play 通，但浏览器谷歌 ERR_CONNECTION_ABORTED、百度 ERR_CONNECTION_CLOSED，与 TUN 症状复现。daemon 日志（2135 行、5 个会话）定案三点：①全日志**零 ERROR**，失败会话 201 条 TCP 全部经节点拨通（双行日志、握手约 550ms）——拨号层无辜，info 级别看不见拨通后流的死因（sing-box 源码：拨通后关闭原因只记 debug）；②**DNS 劫持在 eBPF 下从未生效**：08:42 会话里 174 个发往运营商 DNS（43.239.172.1/.2:53）的包被当普通 UDP 经节点转发、反复重试。源码实锤：routePacketConnection 仅对 TUN 入站特判 protocol=dns 直劫，redirect/tproxy 须靠规则匹配，而 protocol 匹配须先有 sniff 动作——ebpfconfig 两样都缺（TUN 配置因此幸免）；③08:39 失败会话里 **UDP 到达数为零**、08:42 重启后的会话 UDP 立刻涌入，转向在安装校验通过后仍出现会话级不稳定（机制未定案）。
- 修法（ebpfconfig）：route 规则改为 **port 53 hijack-dns 打头**＋sniff 动作＋protocol dns hijack 兜底（顺序：port→sniff→protocol→ip_is_private）；log 级别改 **debug**（eBPF 稳定后再降回 info），让下一份日志能直接给出流的死因。
- 规则自检愈合：Kotlin netRules 新增只读 verify 动作（与安装同一 FLBOX_ALL_OK 判据）；Dart 在 eBPF 启动 6 秒后与 resync 认领活会话时各验一次，失败自动重装一次并记事件日志——落实「软件自己检测问题」的既定方向，也给③留了兜底。

## 0.63：root 模式启动自动刷 netd DNS 缓存
- 0.62 真机定案全貌：DNS 劫持修复生效（hijack 命中、泄漏归零、零真 ERROR），百度/必应/YouTube/GitHub/Play/电报全通；剩谷歌与 ChatGPT 死于 **netd 系统缓存里的污染记录**——守护进程两份日志里 www.google.com 查询均为 0 条、连接全指假 IP 104.244.42.197（chatgpt.com→107.181.166.244），记录疑写于 0.61 DNS 泄漏期、TTL 约 1 小时，强停浏览器与重启守护进程都刷不掉；用户开关飞行模式（换网逼 netd 倒缓存）后 **09:28 谷歌恢复、微信亦恢复**（微信「网络不可用」横幅同为该窗口的滞留状态，其 DNS/短连接在日志里一直健康）。
- 修法：Kotlin 通道新增 flushDns（su 跑 `ndc resolver flushdefaultif` 与 `cmd netd resolver flushdefaultif` 两式、失败不抛、输出记事件日志）；Dart `_launchRootDaemon` 在守护进程 running 确认后调用 `_flushDnsCache()`——Root TUN 与 eBPF 两模式共用此启动路径，一并覆盖。原计划的 ebpf DNS ipv4_only 经微信自愈证据撤销，不做无证据改动。
- 待验证：Root TUN 复测（同一 netd 缓存层若为 0.57/0.58 浏览器失败的主因，TUN 应随本次定案一并复活；0.58 的两条 handshake refused 证据太薄、亦可能为拨假 IP 被拒）。

## 路线备忘（2026-11-05 用户定）：eBPF 改进参考 AS/bpf2socks 与 netproxy
- 用户指示：FlBox 后续改进参考 AsteriskNG 的 bpf2socks 与 netproxy 两个项目（均开源/可查）。
- 借鉴点：①bpf2socks 的真 eBPF 形态——cgroup connect/sendmsg/recvmsg 钩子＋令牌地址映射保原始目的地，替代现 iptables REDIRECT/TPROXY 拼装（即原「真 BPF 程序化」项，现升为明确方向）；②其 DNS 事务跟踪/fast path 的解析观感；③netproxy 的 socket_assign＋sing-box 栈在 DNS 模式（优先劫持）与规则成熟度上的行为参考；④AsteriskEnhance 的 netd 缓存隔离是结构性终局（Zygisk 钩 netd，重），0.63 刷缓存为现阶段平民版，是否走终局待评估。
- 纪律：现 iptables 版 eBPF（0.62/0.63）是出货基线、继续修；真 BPF 化先做设计研究（读 bpf2socks 源码与本机内核能力探针），不推倒正在用的东西。

## 0.64 设计：eBPF 模式换 bpf2socks 桥（2026-11-05 用户拍板「直接按照 AS 方式改」）
- 弃 iptables REDIRECT/TPROXY 转向（规则会自发消失、自检只能治标；且 netd 污染缓存问题在包层无解）。 vendored Asterisk4Magisk/bpf2socks v1.2.2 源码（GPL-3.0，保留 LICENSE）入仓 bridge/bpf2socks/，CI 用 NDK clang `make android ABI=arm64-v8a` 产 libbpf2socks.so 进 jniLibs（与 libflboxd.so 同款 PIE 冒充 .so）。
- 拓扑：flboxd 兼任监督者——同进程内 sing-box 核心改出 SOCKS 入站 127.0.0.1:7891；flboxd 以自定义 gid 启动桥子进程（桥的 self-bypass 按 egid 认亲，核心出站同 gid 得豁免、防回环；netd gid 不同、其 53 流量照常被钩）。桥 bridgePort=65534（同 AS），pinnedObjectDir=/sys/fs/bpf/flbox/bpf2socks，enableDnsHijack=true，enableIpv6 随 pref，policy.mode 映射分应用三档（2 全局/0 排除/1 仅列表），私网段走 bridge 的 bypassPrivateCidrs（真直连）＋核心 route 兜底。
- 生命周期：flboxd CLI 第三参为桥配置路径（有则监督桥：先 --probe 验内核、再拉起、随核心同生共死、退出清理）；Dart/Kotlin 控制面不变（同一状态文件回执）；eBPF 模式启动失败（probe 不过/桥起不来）走 AS 式报错弹窗（含 probe 输出与启动日志），不自动回退 iptables 版（其规则消失问题正是本次要逃离的），旧 netRules 代码保留在 Kotlin 侧未删、Dart 不再调用。TUN/VPN 不动。
- 实现落点（0.64 已落地待真机）：core/bridgeconfig.go（FlboxBridgeConfig 信封 core+bridge、SOCKS 7891、bridgePort 65534、policy 映射分应用三档、包名→uid 由 Kotlin packageUids 解析）；flboxd 监督者模式（--core 子进程＋Credential gid 55991＋Pdeathsig）；Kotlin bridgeBinary/bridgeCheck＋rootStart 第三参；Dart _launchRootDaemon 的 ebpf 分支改走桥、netRules 三方法已删、ebpf 不再调 flushDns。工作流需用户手贴一步：在守护进程构建行后加 bridge/bpf2socks 的 make android 并把 libbpf2socks.so 拷进 jniLibs。
- DNS 依据：bpf2socks 的 cgroup 程序对未标记 DNS 有强制代理路径（绕过 CIDR 策略、跟随 UID 选择），桥内含 DNS 事务跟踪与 fast path——即 AS 不踩 netd 缓存坑的本体机制（无须 Enhance 模块）。
- 0.65 修复：0.64 真机起得来但零代理——bridgeListenAddress 误填 127.0.0.1，令牌地址池（127.128.0.0/9）的连接无监听可落；改 0.0.0.0（与官方示例一致），测试加断言。探针实证本机 supported=true（tcRedirect/reuseport 为 false 不影响 cgroup 路径）。

## 0.66：eBPF 桥后换 Xray（AS 原配）＋日志与流畅度优化
- 背景：0.65 桥模式已全通，但 Muse 客户端在桥＋sing-box 与 TUN＋sing-box 下皆败、网页端正常、AS（桥＋Xray）日常正常——A/B 指向核心差异，用户拍板「把 AS 的移植过来」。桥已是 AS 的 bpf2socks 本体，本版补齐其原配核心。
- 核心替换：新增 core/rootxray.go——以 xraytranslate 的单节点配置为底，入站换桥面 SOCKS 127.0.0.1:7891（udp 开、sniff 开）；DNS 两段式与 sing-box root 配置同构：节点域名走直连 bootstrap 223.5.5.5（生成器按选中节点注入 full: 域名）、其余经节点到 8.8.8.8，DNS 客户端查询带 "dns" 入站标签由路由钉死（bootstrap 直连、其余走 proxy）；桥送来的 53 端口流量按 inboundTag＋port 路由到 dns 出站作答（hijack-dns 的 Xray 形态）；私网直连、其余走节点，全局模式与其它 root 模式齐平。flboxd 的 --core 按配置风味分发（入站带 protocol＝Xray、带 type＝sing-box），TUN 不动。原 sing-box 桥核心与 ebpfconfig（iptables 时代）一并删除，FlboxBridgeConfig FFI 换名 FlboxBridgeXrayConfig。
- 验证：rootxray_test 断言配置形状（域名节点有 bootstrap、IP 节点无）并真启 Xray 实例验监听；全量 Go 测试与 flutter analyze 绿。真机验收点：eBPF 模式下 Muse 客户端冷启连通（本版的立项理由）、其余应用不退化。
- 日志优化：守护日志改每会话一文件——启动时旧文件轮转为 root-daemon.prev.log、新会话独占 root-daemon.log（弃 1MB 阈值删除，失败窗口不再被截断或埋没）；日志页新增三源切换（核心／守护·本次／守护·上次），打开时自动落到最近修改的一源，守护日志从此不必再用文件管理器外捞。仪表盘状态行标注模式与内核（eBPF 显示「Xray 核心 · bpf2socks 桥」）。
- 流畅度：_logEvent 改异步队列写（原为 UI 线程同步落盘；全量测速每节点两行、44 节点近百次同步追加）；测速结果回填改批量——进程内路径 300ms 合并一次 setState、测试服务路径按轮询批次合并（原为每节点一次整页重建）。
- 附带定案（非本版代码）：同日「两模式用一会谷歌也不能」经飞行模式开关恢复，定案为切模式空档写回的 netd 污染缓存（09:28 同机制），与数据面无关；IPv6 开关打开后 Muse 仍败，IPv6 黑洞假设证伪。

## 0.67：修复 0.66 eBPF 全灭——出站域名解析走错解析器
- 0.66 真机（11:49 两会话、两节点同症）：桥与 DNS 出站都活、app/dns 能答问，但一切经节点的连接死于 `lookup aws-linkX.lxyun.xyz on [::1]:53: read: connection refused`——节点域名根本没解析出来。
- 定案（Xray 源码 transport/internet/dialer.go）：系统拨号器只在出站 sockopt 带 domainStrategy 时才经内置 DNS 客户端解析出站服务器域名（LookupForIP），否则落到 Go 系统解析器；Android 上系统解析走 netd 的 [::1]:53，而守护核心被桥按 gid 豁免、其未标记套接字被 netd 拒答。VPN 模式在 App 进程里系统解析可用，故从未暴露；AS 的配置带了这个旋钮。
- 修法（rootxray.go）：proxy 出站的 streamSettings 合并 sockopt.domainStrategy=UseIPv4；顺带修 DNS 客户端排序——域名命中的服务器优先但仍进 fallback 轮换，0.66 的 bootstrap（223.5.5.5）因此把所有查询都答了（日志实证 hatch-api 等均由它作答，CN 解析器答外国域名有地理分裂风险）：改为远程 8.8.8.8 在前、bootstrap 在后且 skipFallback=true（只服务节点域名）。
- 本地实证：探针测试真启实例并经 SOCKS 发起连接，日志出现 `app/dns: UDP:223.5.5.5:53 querying DNS for: a.example.com`——出站解析已走内置客户端的目标路径；全量 Go 测试绿。

## 0.68.0-beta：删 Root TUN、出站三态、IPv6 全自动、Root 开机自启、eBPF 流量显示
- **删 Root TUN（用户拍板）**：设置页模式项、Dart 启动路径、FFI FlboxRootTunConfig、core/rootconfig.go 一并移除；flboxd 同步去掉 sing-box 风味（runCore 只剩 Xray），守护进程约 51MB→48MB。存量 run_mode=root_tun 与旧备份一律迁移到 VPN。仓库内 rootconfig.go/rootconfig_test.go/rootstart_test.go 因 push-files 无删除通道仍留存，已无任何引用、不参与入口（与 ebpfconfig 同例）。
- **IPv6 全自动（用户定）**：手动开关删除。Root 模式恒关——桥配置 enableIpv6 写死 false（当日横测实证：AS 四模式仅 VPN 服务的 v6 真通、netproxy eBPF 的 v6 同样不通、桥的 v6 UDP 是按端口打捞的尽力路径，专坑 Muse 这类长连接应用）。VPN 模式改为启动时检测：核心先起，经本地混合入口对 Cloudflare v6 anycast（2606:4700:4700::1111/::1001）做 SOCKS5 CONNECT 探测，通→双栈建隧道，不通→纯 v4 建隧道（AAAA 不再进黑洞）；结论按节点名缓存（pref ipv6_probe_cache），换节点才重探；会话有效值持久化（vpn_ipv6_effective）供 resync 复用。设置页改为只读状态行，仪表盘状态行标注 IPv6 开/关（自动）。
- **出站三态（用户补单）**：规则/全局之外补直连模式，outbound_mode（0 规则/1 全局/2 直连）取代 rules_mode 布尔（首读迁移、备份兼容旧字段）。VPN 侧：xraytranslate 加 Direct 选项——最终规则指向 freedom、无预设无分流 DNS。**eBPF 补规则模式**（此前仅全局）：rootxray 按三态生成路由——规则模式插入 v2ray 绕过大陆预设（geosite:cn/geoip:cn 直连＋domainStrategy IPIfNonMatch＋223.5.5.5 的 geosite:cn 分流 DNS，其查询按 IP 钉直连）；flboxd 在 --core 启动时把 Xray 资源目录指到配置文件所在目录（即应用释放 geo 库的文档目录）。仪表盘与设置页的模式切换同步三态，运行中切换照旧重启核心/守护进程生效。
- **Root 开机自启动（用户定，AS 同款）**：开关仅在选中 Root 模式时出现于设置页运行模式组。机制与 AsteriskNG 相同——应用经 su 向 /data/adb/service.d/flbox.sh 写入开机脚本（Magisk late_start 执行）：等 sys.boot_completed 后以最近发布的 root-config.json/root-bridge.json 直接拉起 filesDir 里的 flboxd，全程不经应用进程。开启时先发布配置（只生成不启动）；运行中切节点由重启路径重发布，停止状态下切节点/换订阅由 _republishRootConfigsIfNeeded 补发布；切走 Root 模式自动卸载脚本。应用打开时经既有 status 文件 resync 收养开机拉起的会话；root_boot_start 开启时应用侧 autoConnect/restore_on_boot 的自动启动让位，避免与脚本实例竞态。旧 BootReceiver 的 VPN 恢复逻辑不变。
- **eBPF 仪表盘流量（用户指正「这些都不显示」）**：flboxd 的 --core 子进程每 2 秒把 proxy 出站累计上/下行字节原子写入 root-traffic.json；Dart 轮询改双源（VPN 读进程内计数、Root 读该文件），速率/累计/实时速率曲线共用同一套计算，Root 模式仪表盘不再恒 0/暂无数据。计数器回退（核心重启）处理与 VPN 同逻辑。
- 待真机验收：①eBPF 规则模式国内直连、国外走代理、Muse 冷启仍通；②直连模式在 VPN/eBPF 下全流量直连；③VPN 模式：NTT（无 v6 出口）启动自动关 v6、机场节点自动开 v6 且真通；④开机自启：开启→重启→不打开应用代理已可用，打开应用能收养会话且状态正确；⑤eBPF 仪表盘速率与累计有数；⑥Root TUN 入口消失、模式组只剩 VPN/Root eBPF。
- **0.68 内更正（同日，用户改口）**：IPv6 改回**手动开关**（VPN 模式，设置→高级，pref ipv6_enabled，默认关，下次启动生效，进备份）——自动探测整套（_decideVpnIpv6/_probeNodeIpv6/按节点缓存）已移除；**eBPF 模式强制禁用不变**（开关在该模式下置灰锁定、桥配置恒 ipv6=false）。仪表盘状态行随之去掉「（自动）」字样。验收③相应改为：手动开开关＋有 v6 出口的节点启动后 v6 真通、关开关则 v4-only。

## 0.68.1-beta：删两个自启开关（构建号 69，0.68 已被构建过）
- 用户圈图指定删除设置→连接里的「启动后自动连接」（auto_connect）与「开机自启恢复」（restore_on_boot）：两开关、Shell 侧字段/存储/setter、启动序列的应用侧自动启动分支、备份字段一并移除；打开应用不再自动启动任何会话（Root 开机自启走 service.d 脚本＋resync 收养，VPN 手动点按钮）。was_running 记账随之删除。AndroidManifest 注销 BootReceiver（其类文件因 push-files 无删除通道留仓但已无注册、永不触发）。
- 顺手修：设置页 Root eBPF 副文案写死「全局模式」，改为跟随当前出站模式（规则/全局/直连）。
- 真机另发现（待用户拍板）：eBPF 的 IPv6「禁用」实为桥不接管——bpf2socks 在 enableIpv6=false 时不改写 v6 流量，v6 沿系统路由直连（IPCheck 实证出口为广电山西真地址），与旧 iptables 版 eBPF 的丢弃式禁用（宁断不漏）不同；换桥时丢弃没跟过来。修法候选：flboxd 在桥会话期间维护 ip6tables 非本地 v6 出站 DROP、停会话清除。
- 0.68.1 续（同日，用户拍板「宁断不漏」）：flboxd 在桥会话期间维护 ip6tables 链 FLBOX6——OUTPUT 跳入，非本地 IPv6 一律 DROP（豁免 loopback/::1、fe80::/10、ff00::/8 与桥令牌前缀 fd7a:7374:6572:6973::/64）；探针通过后、拉起子进程前安装，装不上或自检（-C）不过则整个会话启动失败、绝不静默泄漏；会话结束 defer 清除，启动时先清残链（防 SIGKILL 遗留，重启手机亦自清）。验收：eBPF 运行时 IPCheck 的 v6 探针应无结果，停掉 FlBox 后 v6 恢复直连。

## 0.69.0-beta：UI 改版——FlClash 布局（构建号 70）
- 参照来历：用户发 FlClash 四页整套截图拍板「以后布局改成这种」；只仿布局形态与交互组织，不复制其代码与资源（FlClash 为 GPL 且本仓公开，保持本仓实现原创；bpf2socks 的 vendored 属另一回事、已标注来源）。
- 底栏四页改为仪表盘／代理／配置／工具：「日志」页签取消，日志改为工具页入口推出的一级页面；原仪表盘齿轮的设置入口并入工具页（仪表盘齿轮保留为快捷入口）。
- 仪表盘：状态卡换参照形态——左侧为状态徽标（运行中/未运行）、节点名大字、通路说明与运行时长；**启停改为卡内 76px 大圆钮**（忙碌时转圈），原右下悬浮按钮删除。网络速度双卡与实时速率曲线、出站三态胶囊（规则/全局/直连）、当前节点卡维持原有实现并入新骨架。
- 代理页：订阅横向页签改为**分组卡片列表**（参照的策略组卡形态）——每订阅一张卡（首字瓷砖、组名、类型标「订阅/本地」、展开箭头）；当前订阅卡展开，下挂原有工具栏（导入链接/加节点/全部测速/选最快/排序）、搜索与懒加载双列节点网格（CustomScrollView 分段 sliver，懒构建不回退）；点其它卡即切换订阅，仍走原切换路径（运行中热切逻辑不变）。测速/收藏/自动选最快/节点编辑能力全保留。
- 配置页：右上加操作簇（更新全部订阅＋从订阅链接导入）；新增 Shell._updateAllSubs 依次刷新全部启用的带链接订阅。卡面流量/到期信息沿用订阅信息行。
- 工具页（新增）：功能卡含日志入口、设置入口、分流规则库（状态文案随 geo 是否就绪，刷新与设置页共用 _updateGeoData）；「其他」组含关于行。顺带处理 0.68 的小疣：日志页在 eBPF 模式且停在「核心」页签时给出说明（核心日志是 VPN 模式的、当前会话看「守护·本次」），LogsPage 新增 ebpfMode 入参由 Shell 按当前模式传入。
- 死代码清理：删除 Kotlin MainActivity 里 iptables 时代的 netRules 通道及其脚本生成器 buildNetRulesScript/buildVerifyRulesScript（Dart 侧自桥版落地后零调用）；仓库内其余历史留存文件（BootReceiver.kt、core/rootconfig.go 等）因 push-files 无删除通道仍按前例标注留存。
- 性能/耗电口径（实事求是）：本版的实质项是代理页懒加载网格得以保留（分组卡片化没有退回整表急切构建）与死代码移除；仪表盘 2 秒轮询、守护流量文件 2 秒写盘的既有节奏不加频。没有可验证的大项，不虚报优化数字，待真机体感与耗电观察。
- 待真机验收：①四页切换与底栏形态；②状态卡圆钮启停 VPN 与 eBPF 均可、忙碌转圈；③代理页点卡切换订阅、展开卡内测速/搜索/排序/选节点全可用；④配置页「更新全部订阅」真刷新；⑤工具页各入口可达、eBPF 下日志页提示出现；⑥并合验收 0.68.1 的 v6 丢弃与删开关（若未单独构建 0.68.1，本版已包含其全部内容，构建号 70）。

## 0.70.0-beta：IPv6 改 AS 式系统级守卫、卡片可点切换、日志开关（构建号 71）
- **0.69 真机三报**：①eBPF 模式 IPCheck 的 v6 探针仍出广电山西真地址——FLBOX6 没拦住；②代理页分组卡「点不了」（且卡片看不见）；③配置页要求点卡切换、不要「使用」按钮。另录屏两件：日志页长按/拖选文本时整页反色发黑（SelectableText 的选区覆盖层在本 ROM 上把整页压黑，红字即选中态）；状态栏下拉时多一次回弹（疑为常驻通知每 2 秒刷新文字时通知栏重排，未定案、不在本版处理）。
- **IPv6 换机制（用户指示：解决不了就拉 AS 源码参考）**：已克隆 Asterisk4Magisk/AsteriskNG 与其 asteriskd 守护源码核对——AS 的桥配置同样只是 enableIpv6=false（桥的内核程序对 v6 是 bypass，AS 亦然），其「关 IPv6 不漏」靠的是 asteriskd 的 **disableSystemIpv6**：root 会话期间对每个网卡写 /proc/sys/net/ipv6/conf/<iface>/disable_ipv6=1，并挂 netlink 守卫（netd 在网络变化时重新启用 v6 就再压回去），退出时恢复。flboxd 照此实现（自研等价物，不搬其代码）：v6GuardStart 枚举 conf 下网卡（跳 lo 与 all、保留 default 覆盖后出现的网卡），记录原值后写 1，写失败且系统存在全球 v6 地址则启动失败（不静默漏）；守卫 goroutine 每 3 秒复查、被改回就重写并记日志；会话结束 restore 写回原值。守护日志会打出每张网卡的 disable 动作与 restore，验收可直接在「守护·本次」核对。FLBOX6 ip6tables 链整套删除——它在本机装得上、验得过、却没拦住流量，留着只是第二个错觉（其不生效的微观原因未定案：疑与本 ROM 的 ip6tables 后端/净过滤路径有关，不再深挖）。VPN 模式仍是手动开关，但关态在本版补上黑洞：此前 Builder 仅在开时加 v6 地址与 ::/0 路由，关时系统 v6 在运营商接口上原样直连（是漏的，代码注释里本就写明）；0.70 起 Builder 两种状态都装 v6 地址＋::/0 路由——开时双栈转发器承载，关时 v4-only 转发器把送进隧道的 v6 包全部丢弃，宁断不漏，与 Root 守卫同一口径；设置页 IPv6 文案已同步改写。
- **卡片可见＋可点**：定因——0.69 的分组卡/工具页卡用 colorScheme.surface 上色，而本主题里 surface 约等于页面底色，卡片形同无形（录屏逐帧实证：代理页分组行只剩文字浮在底色上）。代理页分组头与工具页分组统一改 _cardColor＋描边（与配置页卡一致），当前订阅卡用 accent 淡染＋亮边（同配置页「使用中」卡）；代理页分组头改 Material＋InkWell 整卡可点（水波纹可见），配置页订阅卡同样整卡 InkWell 点按切换（禁用中的订阅不响应）、「使用」按钮删除。卡内开关与图标按钮仍各自响应（手势竞技场子优先）。
- **日志开关（用户点名）**：设置→高级新增「核心日志」开关（pref log_enabled，默认开，进备份）。关时两条核心配置路径都把 Xray loglevel 置 none：VPN 路径经 xraytranslate.Options.LogOff（FFI mode 串加 :logoff 段），Root 路径经 FlboxBridgeXrayConfig 新增 logOff 参数→rootXrayConfig。守护进程自身的 flboxd 行（启动/守卫/流量）不受影响——那是排障的最后信道，且量极小。下次生成配置时生效（启动会话或切订阅）。
- **日志页去 SelectableText**：日志正文与自检结果改普通 Text，选区黑屏随之消失；日志分享本来就走文件（MT 管理器取 root-daemon.log / xray-error.log），页内复制非必需。
- 待真机验收：①eBPF 启动后 IPCheck v6 探针无结果，且「守护·本次」日志能看到 ipv6 guard 逐网卡 disable 记录；停会话后 v6 恢复广电地址、日志有 restored；②会话中切一次网络（飞行模式开关）后 v6 仍不漏（守卫重申）；③代理页点 liangxin 卡切换、配置页点卡切换均有水波纹且真切换；④日志页长按不再发黑；⑤关日志开关后重启会话，日志页核心/守护日志不再增长（flboxd 自身行除外）。

## 0.70.1-beta：导航栏药丸额外回弹修复（构建号 72）
- 用户澄清「状态栏回弹」实为**导航栏**：滑动药丸（默认 NavStyle.slidingGlass）拉过去后多回弹一次。定案为双重结算：①药丸拖拽结束时 dragEnd 自己 _slideTo 一次，紧接着 onTap 触发父层 index 变化、didUpdateWidget 又 _slideTo 一次；②点导航跳页时 PageView 的 animateToPage 途经每一页都回调 onPageChanged，逐页 setState 使药丸动画逐页重启（跨多页时最明显）。
- 修法：拖拽结束不再本地滑行，结算只由 didUpdateWidget 驱动（同目标且已在滑则跳过）；Shell 加 _pageAnimating 标志，程序化跳页期间 onPageChanged 的途经页一律忽略，到达目标或动画结束清标志。页面手势滑动（非程序化）不受影响。

## 0.70.2-beta：内容钻到玻璃栏下面（构建号 73）
- 用户截图圈出仪表盘底部：当前节点卡被导航栏挡住，并要求「这下面做透明、别让导航栏挡住」。此前 _PageFrame 底部留 120 的死区、页面内容到不了栏下，玻璃填充又是 0.52 的乳白，整条栏读起来像实心带子。
- 改法（浮动栏的标准形态）：_PageFrame 底部 padding 120→24，内容借 extendBody 一直铺到屏底、滚动时从玻璃下穿过；四个标签页各自在滚动内容末尾加 104 的 spacer，保证最后一张卡仍能完整滚出栏外；玻璃填充 alpha 浅色 0.52→0.30、深色 0.50→0.38（模糊保留）。

## 0.70.3-beta：IPv6 开关管到 eBPF 模式（构建号 74）
- 用户在 0.70.2 上验收反馈：普通模式开 IPv6 用 NTT（无 v6 出口）没 v6、换带 v6 的节点正常（符合预期）；并要求「把 eBPF 强制关闭的关了，让他也能自己开关」。
- 改动三处：设置页 IPv6 开关在 eBPF 下解禁（值与回调与 VPN 共用，副文案改 eBPF 版）；根配置生成把开关真值传给桥配置（此前恒 false），经既有 FFI 参数落到桥 JSON 的 enableIpv6；flboxd 读桥配置决定守卫去留——enableIpv6=true 时守卫不启动（日志打 `ipv6 guard: off`）、桥自行尝试接管 v6 走节点，false/读不到时守卫照常（安全默认，含开机脚本的旧配置）。
- 预期与 AS 一致：root 数据面 v6 普遍不稳，此开关在 eBPF 下定位为用户自主要求的实验位；关态仍是宁断不漏的守卫语义。

## 0.70.4-beta：普通模式 UDP 全灭修复（构建号 75）
- 用户报普通模式下 IPCheck 的 WebRTC/STUN 四项全「连接错误」，AS 正常。定案在 Xray 源码：mixed 就是 socks 服务的别名，其 UDP associate 仅在入站 settings 带 `"udp": true` 时启用（infra/conf/socks.go 的 UDP 字段默认 false、proxy/socks 按 UdpEnabled 决定是否处理）；FlBox 的 7890 混合入站从 0.23 转发器架构起就没带 settings，转发器送来的 UDP 在核心门口被拒——TCP 一切正常，所以日常浏览毫无症状，只有 STUN/游戏/语音这类纯 UDP 暴露。eBPF 模式的桥面入站一直有 udp:true，未中招。
- 出站侧核过：Xray 本版 VLESS 出站对 vision 流量的 UDP 会转 mux 经 TCP 连接送达（仅 UDP/443 被 XTLS 拒，STUN 端口 3478/19302 不受影响），故入口开 UDP 即全线通。修法：入站补 `"settings": {"udp": true}` 一行。

## 0.70.5-beta：开机自启偏好跨模式保留、日志页逐行渲染（构建号 76）
- 用户报切运行模式会把「开机自启动」关掉：原 _setRunMode 离开 eBPF 时连偏好一起清。改为偏好保留、只拆脚本；切回 eBPF 时静默重装（_tryInstallRootBootScript，无节点/无 root 时静默跳过，偏好不动）。显式拨开关的报错路径不变。
- 日志页在 0.70 去 SelectableText 后仍「进去不到一秒变黑」（整页黑、正文红字带下划线，按钮正常）：正文此前是单个 Text 承载 200 行长行、随异步加载落地——是全应用最大的单块文本。本版改 ListView.builder 逐行渲染。是否为该 ROM 的文本层问题仍待真机验证：若逐行后仍黑，则需区分「手指不碰也黑」与「滑动才黑」。
- 附带实证：用户 15:25 的日志截图里 15:22 的核心日志反复出现 `proxy/socks: UDP is not enabled`——正是 0.70.4 所修入站缺 udp 的真机回执（普通模式核心所写）。

## 0.71.0-beta：日志页重写（构建号 77）
- 0.70.5 逐行渲染后真机仍报日志页变黑，用户拍板「重新写一下日志」并附带要求去除无用注释。整页重写：不再走 _PageFrame（无 Scaffold 的裸 Column），改为与设置页同构的独立 Scaffold＋AppBar（设置页在本机渲染一直正常）；三源切换换 SegmentedButton；状态逻辑（开页选最新文件、96KB 尾读、截断式清空、自检）保留，旧页的大段沿革注释随重写删除，新代码只留承重注释两处。
- 变黑机制至此仍未定案（已排除：SelectableText 选区、单个巨型 Text）；若同构于设置页后仍黑，问题即在页面结构之外，届时按真机二分（静置是否变黑）继续。
- 待查：用户报 eBPF 模式下 IPCheck 的 DNS 出口显示中国（AS 测为 Google/美国）。规则模式根配置的 DNS 服务器列表首位为 223.5.5.5（geosite:cn 门控＋expectedIPs），全局模式只有 8.8.8.8 经节点——待用户做全局/规则对照测一次再定案，不先改。

## 0.71.1-beta：代理页只显示当前订阅（构建号 78）
- 用户在 0.70 的点卡切换之上改选另一方案（其 14:34 原话的备选）：代理页只渲染当前订阅的头部卡＋工具栏＋节点网格，其余订阅卡全部撤下，切换订阅只走配置页。当前卡保留名称与已选节点作上下文，去掉展开箭头。

## 0.71.2-beta：提示条美化（构建号 79）
- 用户截了切换订阅的默认 SnackBar（全宽黑条贴在玻璃栏上方）说影响观感。全局换 _showToast：悬浮胶囊（圆角 999、深灰 92% 不透明、居中文字），左右留 56、底部留 96 正好让开玻璃栏，时长 4 秒→2 秒，新提示顶掉旧的；_toast 与两处编辑页报错共三处调用统一走它。

## 0.71.2-beta1：IPv6 改 AS 式双开关（构建号 80）
- 起因：白天普通模式测完 IPv6 开关留在开，重启后开机自启的 eBPF 会话让桥接管 v6，国内应用几乎全灭（用户实证关掉即愈）。用户问 AS 怎么做、并拍板改成 AS 那种。
- AS 源码实证：IPv6 开关与系统级禁用是两个独立开关（disableSystemIpv6 = !enableIpv6 && enableRootIpv6Disabler，后者默认关）；AS 默认「关 IPv6」只是桥不接管、v6 走运营商原生直连，所以国内照常但属直连。桥的 C 配置解析是按 key 查找，未知 key 天然忽略——禁用标志可安全塞进桥配置文件。
- FlBox 落法：新增独立开关「系统级禁用 IPv6」（pref ipv6_disabler，默认开以保持宁断不漏），仅 eBPF 模式在设置页出现（紧贴 IPv6 开关下方；VPN 模式不受影响）。_writeRootDaemonConfigs 把桥 JSON 解开、盖上 disableSystemIpv6 再写盘；flboxd 新增 bridgeDisablesIpv6（键缺失默认 true，兼容旧已发布配置/开机脚本），守卫三分支：IPv6 开→不守；关＋禁用开→守卫在；关＋禁用关→不守、v6 原生直连（守护日志 ipv6 guard: off - disabler switch off）。备份格式同步带 ipv6_disabler。

## 0.71.2-beta2：代理页删当前订阅头卡（构建号 81）
- 用户圈图点名删除 0.71.1 保留的当前订阅头部卡（名称＋已选节点＋本地/订阅角标）。代理页改为直接从「N 个节点」工具行开始；groupHeader 构建器、ProxiesPage 的 subs/activeSubId/onSwitchSub 三个入参一并清除。切换订阅仍只走配置页。
