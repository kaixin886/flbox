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
