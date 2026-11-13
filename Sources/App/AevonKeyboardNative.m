// ===========================================================================
// AevonKeyboardNative.m — 0.4.7 / 0.4.9 / 0.4.10 / 0.4.12 / 0.4.13 / 0.4.14 / 0.4.17
//
// 键盘的承载面接管。**1:1 复刻 Stheno 母版的 `SthenoKeyboard.dylib`**
// （0.1.23；修复版 final.3 的键盘组件与母版只差 1 处：`0x4de8` 那个「首启打开
// inject.stheno.com」的函数被改成 `ret`，与键盘机制无关）。
//
// 逆向数据：`stheno-逆向分析/final3/analysis/hooks-SthenoKeyboard.md`
//           `stheno-逆向分析/final3/analysis/disasm-SthenoKeyboard-s0.txt`
//
// ---------------------------------------------------------------------------
// 0.4.38 — 321：guide 修好了，932 只剩一个公开入口
// ---------------------------------------------------------------------------
// 321 先确认 0.4.37 那一条真的生效了（这次不是推的，是读数）：
//
//   `scn … guide=430x359@0,358 gh=2..8` —— 六个 App、每一个探针拍都是**同一个正确值**，
//   而且 `gh` 在涨（备忘录 2→7、威锋 2→8），说明钩子不但装了，还被真的读到。
//   320 里那七个错值（683 / 314 / 298 / 573 …）一条不剩。
//
// 落点也仍然干净：`note fix` 全线 `rem == meas`，取值只有 {359,386,404,431,476}。
//
// 于是 321 把问题切成两半，各自有明确读数：
//
//   ① **酷安 / QQ 正常**（用户 321 明确确认）。酷安 `bar 底边 314 d=44` 是探针误判：
//      它的回复容器 `_TtCC10CoolMarket23ReplyFeed 430x150@0,164` 自带一条 44 高的表头，
//      可见输入条在 302，视觉上贴着键盘。`d` 在这一家不作判据。
//   ② **威锋仍然抬高 215**，而它的读数把算式钉死了：
//      `WeiFeng.PostDetailReplyInput 430x175@0,-32` —— 静止位置是窗口底
//      （`717−175=542`），实际被上移到 −32，也就是**上移了 574 = 932 − 358**。
//      574 只可能是「屏幕高 932」减「我们报出去的键盘顶 358」。
//
// 932 的来源，321 的 `scr` 已经缩到两条（其余全部排除）：
//
//   `uin=430x717`             → `-bounds` 已钩，读它就是 717，**不是**来源
//   `key=… 430x717@0,0`       → keyWindow 也是 717，**不是**来源
//   `nb=1290x2796 ns=3.00`    → /3 = **932**，`-nativeBounds` 我们从来没钩
//   `list=… w1/w2=UITextEffectsWindow 430x932@0,0` → 窗口表里还有两个 932
//
// 本版只处理第一条，理由是它是**我们自己的不自洽**：`-bounds` 说 717、
// `-nativeBounds` 说 932，等于同时宣称两块屏。`-nativeBounds` 同时打 `nbf=`
// （钩后值）与 `nbr=`（被读次数）—— 若威锋修好，`nbr` 会很明显；若仍 215 而
// `nbr` 几乎不涨，那 574 就来自窗口表，下一版只关那一个口子，不用再猜。
//
// 顺带补一条只读 `ins`：系统应用（备忘录 / minis / Safari）的输入条量不到
// （焦点分别是整屏文档视图、屏幕顶搜索框、WebContent 进程），改看
// **滚动视图的内边距** —— 那是 App 自己对「键盘有多高」的结论，不依赖猜层级。
//
// ---------------------------------------------------------------------------
// 0.4.37 — 320：同一个进程里有**两面屏**，guide 就是那条缝
// ---------------------------------------------------------------------------
// 320 先钉死三件事：
//
//   ① 落点还是干净的：六个 App 的 `rem` 只有 {359, 386, 404, 431}，每条 `rem == meas`。
//      我们发出去的五条矩形通道没有一处错 —— 这条线从 0.4.34 起就一直是对的。
//   ② App 的坐标世界确实是 717：`co=430x717@0,0`、`uin=430x717`。0.4.36 猜的
//      「App 以为世界是 932」在**坐标空间这一层不成立**，那一版猜错了方向。
//   ③ 但同一个进程里还有第二面屏：`kbw=430x932@0,0`（键盘窗 = 整块物理屏），
//      而 App 的 scene 是 `430x717@0,215`。**原点差 215、高差 215。**
//
// 320 里 54 条 `guide` 读数，七个取值，全都能用这条缝算出来：
//
//     `430x34@0,683`   ×33  = 717 − 34（窗口底减安全区）＝「键盘没出现」
//     `430x403@0,314`  ×7   = 世界系宿主顶 314，高 403（含 44 占位，314+403=717）
//     `430x419@0,298`  ×4   同上，Safari 的占位是 60（298+419=717）
//     `430x188@0,529`  ×2   = 屏幕系宿主顶 529，配世界高 717−529=188
//     `430x204@0,513`  ×2   同上，Safari（513 = 573−60）
//     `430x144@0,573`  ×3   = 屏幕系可视顶 573，配世界高 717−573=144
//     `430x359@0,358`  ×3   **唯一那一组正确的**（minis 某一拍）
//
// 同一块 359 高的键盘，guide 在七个值之间跳；错的两族各有一个固定形状：
// 「顶边对、高度含占位」（抬高 44 / 60）与「顶边是屏幕坐标、高度被 717 夹住」
// （落在 573 / 683 ⇒ 被盖）。凡是按它排版的 App 只可能这两种表现。
//
// 威锋是另一条腿，而且更直白：`bar=WeiFeng.PostDetailReplyInput 143 d=215`。
// 它两次会话的 guide 分别是 403 和 188，而 bar 底边**两次都是 143**
// ⇒ 它根本不读 guide，自己算：`717 − (932 − 358) = 143`。
// 这个公式在全屏世界里是**对的**（`viewH == screenH` 时恒等于键盘顶边），
// 它需要的只是「screenH 等于 viewH」。它从某个通道拿到了 932。
//
// 所以本版两件事：
//   1. 把 `keyboardLayoutGuide.layoutFrame` 钉到我们已经在通知里报出去的矩形
//      （`AevonKbShown` / `AevonKbLastTop`）。改的是**读出来那一层**：不动键盘窗
//      几何、不动落点、不动 scene —— 那三样各有三次翻车记录，一个字符都不碰。
//   2. 只读把「这个进程能看到的每一面屏」打出来（`scr`），看 932 从哪个口子漏进
//      威锋：`nativeBounds/nativeScale`、`keyWindow`、`windows` 全表。
//
// 判据（321）：
//   `scn … gh=` 不为 0 ⇒ guide 钩子真的被 App 读到了（没读到就说明类名不对）；
//   `scn guide=` 应恒为 `430x359@0,358` 这一类（随候选条升降，但顶边 = 报出去的顶边）；
//   `scr` 两行里唯一那个 932 就是威锋公式的来源，下一版只关那一个口子。
// ---------------------------------------------------------------------------
// 0.4.35 — 318 把「谁错了」缩小到两个候选：焦点视图与 `keyboardLayoutGuide`
// ---------------------------------------------------------------------------
// 0.4.34 之后五条矩形通道（End / Begin / Bounds / CenterEnd / CenterBegin）已经
// 同值：318 的 340 条 `note fix` 全部 `rem == meas`，没有一条再把 456 / 429 透传。
// 但**症状还在**，说明剩下的错不在我们发出去的那份通知里。
//
// 318 里 `bar` 探针的读数说明它自己也靠不住（这就是本版要换掉它的原因）：
//   威锋   `WeiFeng.FeedTextView 398x40@16,354`   —— 可能是回复条，也可能是信息流里的编辑框
//   minis  `PastableTextView 374x21@28,32`        —— y=32，在屏幕顶上，不可能是输入条
//   Safari `UITextView 328x76@51,164`             —— y=164，网页里的表单
//   备忘录 `ICTK2TextView 430x717@0,0`            —— 整屏文档视图，bot 恒等于窗口底
//   酷安   `txt=none`                             —— 一个都没扫到
// 「面积最大的文本框」不是「用户正在打字的那个」，所以拿它判「抬高/被盖」根本不成立。
//
// 本版只加两行只读取证，**不动任何几何**：
//
//   `app: kb: fr  <tag> view=<类> w x h@x,y bot=… gap=… kbtop=…`  ← `isFirstResponder`
//   `app: kb: fr  <tag> anc=<父链三层>`                          ← 焦点视图在谁里面
//   `app: kb: scn <tag> win=… scene=…@… src=… co=… guide=… safe=…`
//
// `fr` 是唯一能代表「用户此刻在打字的那个框」的视图；`anc` 给出它的父链，
// 一眼就能看出是「App 把它抬了」还是「它本来就在这个位置」。
// `scn` 要回答的是 0.4.28 留下的那条线：318 里六个 App 的 `guide` **全是**
// `430x34@0,683`（= 窗口底减安全区，等于「键盘没出现」），而同一拍的宿主明明
// 已经量到 359/403/475。用 `keyboardLayoutGuide` 排版的 App（系统应用居多）
// 会把输入条放在窗口底 ⇒ 正好被键盘盖住。先把「scene 落点 / 坐标空间 / 指南」
// 三个数按正确时机（0.7 / 1.7 / 2.9 s）打出来，再决定要不要动它。
// ---------------------------------------------------------------------------
// 0.4.36 — 319：落点全对，`gap` 全废；把判据换成「输入条容器的底边」
// ---------------------------------------------------------------------------
// 319 先把上一版的两个怀疑都判了：
//
// ① `ph=44` 扣得对。树里 `_UIRemoteKeyboardPlaceholderView f=0,0,430x44 n=0`
//    —— 零子视图；宿主的其它所有层（`UIKeyboardDockView` / `_UIKBCompatInputView` /
//    `TUISystemInputAssistantView`）全都从 **y=44** 开始，被它整体下推。
//    所以可见键盘顶 = 529+44 = 573（物理）= 358（世界），与 `rem=359` 一致。
// ② 落点没有一处不自洽：340 条 `note fix` 全是 `rem == meas`；
//    `chan t0 host=430x403@0,529 … world=314` 里 `314 + ph 44 = 358 = rem`。
//
// 剩下的唯一矛盾是 `keyboardLayoutGuide`，它给出**三种互不相同的错值**：
//
//    威锋   guide=430x403@0,314   ← 含那 44，顶边比真实键盘高 44 ⇒ 抬高 44
//    minis/QQ guide=430x144@0,573  ← 573 是物理坐标没换算 ⇒ 低 215
//    备忘录/酷安 guide=430x34@0,683 ← 等于「键盘没出现」
//
// 吃它的 App 必然错，方向随它错的方向走；不吃的（QQ）一直正常。这条线**不由我们
// 控制**（它读键盘 scene 的 geometry，母版四个钩子里没有它），所以本版不碰。
//
// 本版要解决的是「拿不到真读数」这件事本身 —— 319 里三个 App 打了 `view=none`，
// 说明 0.4.35 只扫主窗是错的。此外 `gap` 在备忘录（整屏文档视图）与 minis
// （顶部搜索框）上天然离谱，不能当判据。改成：
//
//   `app: kb: fr  <tag> view=<类> … gap=… win=<窗口类>`   ← 扫**全部窗口**
//   `app: kb: fr  <tag> anc=<父链五层>`
//   `app: kb: fr  <tag> bar=<横满容器类> <底边> d=<kbtop−底边> depth=<第几层>`
//
// `bar` 是父链里第一个「横向占满、高 ≥ 20、且不到半屏」的祖先 —— 输入条/工具栏本体，
// 整屏页面容器被半屏那道闸排除。QQ 正常时 `barBot` 恒 = 358 = kbtop ⇒ `d=0`，
// 这是目前唯一的「好样本」。判据：`d` 0~10 正常、>10 抬高、<0 被盖。
// ⛔ 判据只用 `bar` 的 `d`，不要再用 `view` 的 `gap`。
// ---------------------------------------------------------------------------
// 0.4.34 — 同一份 userInfo 里还有第三个矩形：`UIKeyboardBoundsUserInfoKey`
// ---------------------------------------------------------------------------
// 317 的症状第一次把 App 分成两拨：
//
//   QQ / 微信                     正常（读 `UIKeyboardFrameEndUserInfoKey`）
//   威锋 / 贴吧 / 系统应用         输入框被抬高（读 `UIKeyboardBoundsUserInfoKey`）
//
// 三条通道里我们只改了两条（End / Begin），第三条一直是**系统原值**：
//
//   end=430x456@0,476  bo=456      ← 系统认为键盘占 456
//   end=430x429@0,718  bo=429      ← 或 429
//   而宿主量出来只有 359 / 386 / 404 / 431
//
// 456 − 359 = 97，429 − 359 = 70 —— 系统为候选条 / 快捷栏预留、但在卡片里没有
// 落出来的那一条。frame 那条我们削掉了，bounds 这条没削 ⇒ 读 bounds 的 App 仍然
// 按 456 让位 ⇒ 输入条多抬 70~97 pt。
//
// 0.4.32 减占位、0.4.33 调判据都在改「落点」，而那些 App 根本不看落点那条通道。
// 这不是参数问题，是**少改了一个键**。本版把三条矩形通道（End / Begin / Bounds）
// 与两个老的中心点一起对齐到同一个 `realH`，落点口径一个字符没动。
//
// 判据（318 日志）：`bo=` 与 `end` 的高应该相等，且 `note fix` 之后它们都等于 `rem`。
// ---------------------------------------------------------------------------
// 0.4.17 — 交集返回值改用「量出来的键盘占高」（Aevon(301)）
// ---------------------------------------------------------------------------
// 300/301 两版取证把四个钩子全部洗清了：
//   · `bounds sys=430x717` ⇒ `-bounds` 钩子是空操作（系统原值就等于我们返回的值）；
//   · scene 落点 215 补写成功（`frame drift` 收起时反向）；
//   · 键盘窗 717、root 717、`content`(=`_UIScenePresentationView`) 717 摆在 card 0,0，
//     card 在 215 —— 宿主侧与 App 侧数字完全自洽。
// 唯一对不上的量是**键盘自己**：`orig` 报 316，`UIInputSetHostView` 实占 431。
// 详见本文件 0.4.17 那一段的推导。本版只改这一处返回值，几何一行未动。
//
// ---------------------------------------------------------------------------
// 0.4.14 — 删掉我自己发明的 215 pt「窗下移」（Aevon(298)）
// ---------------------------------------------------------------------------
// 症状与 297 一模一样：键盘只露上半截、下半透明且点不到。
//
// 0.4.13 已经把 `bounds.origin` 归零（298 读数 `bnd=0,0 root=430x717@0,0` 证明
// 那一步真的生效了），症状不变 ⇒ 平移/裁切不在 bounds，而在**窗本身被我们挪了**。
// 298 的第一条读数就是铁证：
//
//   app: kb: win orig=430x717@0,0 … ask=430x717@0,215 frame=430x717@0,215 dy=1
//
// 系统把键盘窗建在 (0,0,430,717) —— **它本来就是对的**：窗底 = 承载面底 = 卡片底
// = 屏幕底 932。`dy=1` 是我在 0.4.12 加的「补偿」：看到原点在 0 就往下搬 215。窗里
// 的键盘视图按**窗底**摆，窗往下搬 215 ⇒ 键盘整个跟着下移 215 ⇒ 越过卡片下沿的
// 215 pt 被裁掉、也点不到。
//
// 母版从来没搬过窗：`0x5230` 竖屏两条分支都是 `setFrame:[UIScreen mainScreen].bounds`
// 一个分量都不改。本版回到那一句。⛔ 纪律：**补偿只能来自母版，不能来自「我觉得
// 应该对齐」** —— 这是第三次在同一个函数里调参数（0.4.10 拽窗顶、0.4.11 改窗高、
// 0.4.12 搬窗底），三次同一个形状。
//
// 同时加一份**只读**取证（`app: kb: tree …`）：若还有一层内部裁切，下一份日志能
// 直接指认是谁，不必再从截图反推。
//
// ---------------------------------------------------------------------------
// 0.4.13 — `setBounds:` 不能带 origin（Aevon(297)）—— **结论仍成立，但不充分**
// ---------------------------------------------------------------------------
// 症状：输入框已经正常（0.4.12 的恒等公式生效），但键盘只显示上半部分、下半透明
// 且无法触摸。
//
// 当时的判断：母版写 `[win setBounds:[win frame]]`，那行能成立是因为母版那一拍
// frame 原点恒为 (0,0) ⇒ bounds.origin 也是 0，等于「只改尺寸」。0.4.12 把窗原点
// 挪到 y=215 之后照抄这一行，bounds.origin 就成了 (0,215) —— 它是**内容坐标系**的
// 偏移，会把窗内所有内容整体上移 215。
//
// 这一条本身没错（bounds.origin 非 0 一定有害），但它不是 297 的全部原因：298 的
// 读数 `bnd=0,0 root=430x717@0,0` 证明归零已经生效，症状却一模一样 ⇒ 真正那一层
// 是 0.4.12 加的「把窗往下搬 215」，见文首 0.4.14 段。
// ⛔ 纪律：**照抄母版的一行语句之前，先确认它依赖的前提（这里是 frame.origin=0）
// 在我们这里也成立。** 归零这一条保留，它是母版语义，不是补偿。
//
// ---------------------------------------------------------------------------
// 0.4.12 — 键盘窗按**承载面高**建（Aevon(296)）—— 高度结论保留，x/y 结论已废
// ---------------------------------------------------------------------------
// 症状：键盘贴到屏幕底了，但只露出上面一截，下半面透明；输入框被抬高。
//
// 截图硬测量（885x1920，932/1920 = 0.4854 pt/px）：
//   卡片顶边 215.0 pt（= `band report 430x717 at 0,215`，精确吻合）
//   键盘内容顶边 573.0 pt（= 932 − 359，**位置已经对了**）
//   键盘在 **717.0 pt 被一条水平线硬切**，717.9 起全宽 #F1F1F1 到 932
// 717 正是 `UIScreen.bounds` 钩后的返回值（承载面高）。
//
// ✅ 仍成立的部分：`H` 必须取**承载面高 717**（不是物理屏高 932），所以
//    `kbH(717) == screenH(717)` ⇒ intersection 公式退化成恒等 = 真值 ⇒ 输入框
//    落回键盘上沿（297 起用户确认输入框正常）。这一条一直有效。
// ⛔ 已废的部分：把窗写到 (0,215,430,717)。母版竖屏分支的 x/y 取自
//    `[UIScreen mainScreen].bounds`，在 Aevon 里就是 (0,0) —— 见 0.4.14。
//
// ---------------------------------------------------------------------------
// 0.4.9 — 补上母版 `0x4f4c` 的第二道闸（Aevon(293) 的真机事故）
// ---------------------------------------------------------------------------
// 0.4.8 的四条钩子本身没问题，坏在**安装入口少了一道 return**。母版：
//
//   _injectApp = _inject()                       // plist Inject，缺省 1
//   if (!_injectApp) return
//   if (!_ringAppsContains(bundleId)) return     // ← 0.4.8 漏了这一条
//
// `SthenoKeyboard.dylib` 的 Filter 也是 `com.apple.UIKit`（注入每个 App），母版
// 之所以安全，全靠第二道闸：名单外的进程**一个类都不碰**，连
// `_UIRemoteKeyboards` 都不去 realize。0.4.8 漏掉之后，`AevonApp.dylib` 在全机
// 每个 UIKit 进程（日志里连 `com.apple.CarPlayApp` 都在装）的 `main()` 之前
// realize 四个 UIKit / FrontBoard 私有类并改它们的 IMP。
//
// Aevon(293) 的证词：90 条 `app: hang`，全部 `gap=-1ms`（主线程心跳一拍未跑
// ⇒ 构造函数没回来），而四条钩子的实际生效行（`bounds ->` / `inter` /
// `win frame` / `shell hook`）**一条都没有**。用户看到的是「点开 App 白屏、
// 桌面小组件不加载」—— 与 0.0.65 / 0.0.67 同一族故障。
//
// 两处修复：
//   ① 补 `_ringAppsContains` 等价闸：读 `com.aevon` 域的 `RingApps`（圆盘名单，
//      用户自选）+ `RingAppsSnapshot` 兜底，不在名单直接 return；
//   ② 构造期不再 `CFPreferencesCopyAppValue`（cfprefsd XPC 不能在 `main()`
//      之前做），改成第一次真正需要时懒读。
//
// ---------------------------------------------------------------------------
// 0.4.10 — 安装闸从「圆盘名单」换成「宿主真的把我托起来了」（Aevon(294)）
// ---------------------------------------------------------------------------
// 0.4.9 补的那道名单闸（`_ringAppsContains`）方向是对的，取数口错了。证据：
//
//   宿主侧 14:36:27 `[圆盘] 选中 QQ (com.tencent.mqq)，打开浮窗并收起圆盘`
//   QQ 侧  14:36:26 `app: kb: native skipped, notinlist`
//
// 同一个 App，在宿主进程里明明在名单上，在**刚起来的 App 进程**里读同一个偏好域
// 却读不到；同一份日志里 Preferences / Filza 两个进程又读到了。⇒ 跨进程偏好域在
// 「刚被拉起的 App 进程」里不是可靠的事实源，拿它当安装闸会把最常用的 App 漏掉
// —— 用户这一版看到的仍然是旧键盘（QQ 里一行 `app: kb:` 的生效读数都没有）。
//
// 换成宿主自己推过来的事实：`AevonBandOn`（走 `com.aevon.band.<bundle>`，
// `AevonAppHook.m` 里那套 0.1.29 起就在跑）。它在 QQ 进程里每次都成立：
//
//   app: band note from host
//   app: band prefs on=1 band=430x717 at 0,215
//
// 这条闸比母版的名单闸**更严**：名单闸回答「这个 App 允不允许被接管」，band
// 回答「这个 App 现在正被接管」。后者为真才装钩子 ⇒ 全屏 App、系统 App、没被
// 托起来的进程一个私有类都不 realize（0.4.8 的白屏正是死在「谁来都 realize」）。
//
// ⛔ 代价（写在这里，下一份日志要能直接判）：卡片建起来之后 0.15 s 才装钩子。
// 用户点输入框远晚于此，但「卡刚出现就立刻弹出键盘」这一类场景第一次可能漏。
//
// ---------------------------------------------------------------------------
// 为什么整条旧实现要删掉
// ---------------------------------------------------------------------------
// 0.1.43 ~ 0.4.6 的做法是：App 认为屏高 932，我们手工把键盘窗摆进「承载面」
// （430×717）那个格子里 —— 改 intersection 返回值、量键盘视图顶边、平移键盘窗、
// 改写键盘通知矩形、给安全区让位、给 `UIKeyboardLayoutGuide` 兜底。七种手段，
// 每一轮都在调参，每一轮都复发。
//
// Aevon(291) 三行读数把它钉死了：
//
//   win: keyboard native on card=430x717 at 0,215 … push=0
//   app: kb: win hold h=358 top=358 sceneY=0 sceneH=717
//   app: kb: lift aligned dy=0 bottom=717 base=744 scene=717 kb=430x717
//
// 键盘窗 `kb=430x717` —— 高度等于**场景**高，底边 `bottom=717` 贴在**场景**底。
// 而真实屏高 932 ⇒ 屏幕 717..932 那 215 pt 没有东西在画（用户看到的白条），
// 键盘整块悬在 401..717 之上盖住输入条。错的不是那几个数，是「App 以为自己在
// 932 的屏上、我们手工把键盘塞进 717 的格子」这个前提本身。
//
// 母版反过来做：**让 App 自己认为屏就是承载面那么高**。`UIScreen -bounds` 返回
// `[_appScene _boundsForInterfaceOrientation:]`（承载面 bounds = 430×717），于是
// UIKit 从布局到 safeArea 到键盘全部按 717 自洽 —— 不需要任何补偿。
//
// ---------------------------------------------------------------------------
// 母版的四条钩子（地址取自 0.1.23 arm64e slice）
// ---------------------------------------------------------------------------
//   0x5128  -[_UIRemoteKeyboards intersectionHeightForWindowScene:
//                                    isLocalMinimumHeightOut:ignoreHorizontalOffset:]
//   0x5230  +[UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:]
//   0x5430  -[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:
//                                          transitionContext:completion:]
//   0x54f4  -[UIScreen bounds]
//
// 母版还装了第五条 `+[UIApplication openURL:options:completionHandler:]`（通用链接
// 直开）。Aevon **不装**：URL 落点由 SpringBoard 侧的 `AevonOpenDecide` 单点决定
// （0.4.x 已把整条 URL 链下线），App 侧再钩一次会与它抢同一次打开。这一条不属于
// 键盘机制，缺它不影响键盘。
// ===========================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <limits.h>
#import <sys/stat.h>

// ===========================================================================
// 日志（与 AevonAppHook.m 同一落点：宿主那份优先，沙盒里退回自己的 tmp）
// ===========================================================================

static const char *AevonKbLogPath(void) {
    static char chosen[PATH_MAX];
    static int ready = 0;
    if (ready) return chosen[0] != '\0' ? chosen : NULL;
    ready = 1;
    NSString *tmp = NSTemporaryDirectory();
    NSString *own = tmp.length > 0
        ? [tmp stringByAppendingPathComponent:@"aevon-app.log"] : nil;
    const char *candidates[2];
    candidates[0] = "/var/mobile/Aevon.log";
    candidates[1] = own != nil ? [own fileSystemRepresentation] : NULL;
    for (int i = 0; i < 2; i++) {
        if (candidates[i] == NULL) continue;
        int fd = open(candidates[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        close(fd);
        snprintf(chosen, sizeof(chosen), "%s", candidates[i]);
        break;
    }
    return chosen[0] != '\0' ? chosen : NULL;
}

static void AevonKbLog(const char *line) {
    const char *path = AevonKbLogPath();
    if (path == NULL || line == NULL) return;
    struct stat info;
    const char *mode = (stat(path, &info) == 0 && info.st_size > 512 * 1024) ? "w" : "a";
    FILE *file = fopen(path, mode);
    if (file == NULL) return;
    fputs(line, file);
    fclose(file);
}

/// 每类读数各有配额：一次输入会反复问交集高度，日志本身不能变成负担。
static volatile int AevonKbInterNotes = 0;
/// 0.4.27 — 本进程最近一次量到的键盘真实占高。
///
/// 通知有可能比宿主视图早一拍到（全新进程第一次弹键盘），那一拍量出来是 0。
/// 退回 0.4.26 的平移会给 App 一个错高度，而它未必再收到第二条通知去纠正。
/// 用上次的已知值顶上：同一台设备同一输入法，高度就那么几个值。
static volatile CGFloat AevonKbLastRealH = 0.0;
/// 0.4.31 — 我们**自己**记的键盘状态（世界坐标），专门用来生成 `begin`。
///
/// 314 的症状是「第一次正常、关掉再开就消失」，五家 App 里四家复现、QQ 不复现。
/// 唯一在两次之间变了的东西是**系统给的 `begin`**：
///   · 第一次升起：键盘原本在屏外，`begin` 是「收起时那个位置」；
///   · 关掉再开：键盘「上次的位置」被我们改写过（我们发出去的是 358 底 717），
///     而系统记的是它自己那套（503 / 718 / 1147 口径）。于是第二拍开始
///     `end.y − begin.y` 是一个几百点的假差值 —— 按「位移量」排版的那类 App
///     （评论区的输入条几乎都是这一种）照它加减，输入条一次就滑出可视区，
///     而且之后再来的通知 begin==end、差值恒 0，它再也回不来。
///
/// 所以 begin 不再用系统那个（它在三套口径之间跳），改成用**我们已经报出去的上一个矩形**：
///   键盘已经在屏上 ⇒ begin = 上次那个矩形（候选条升降时差值就是那 45 pt）
///   键盘不在屏上 ⇒ begin = (x, 世界底, w, 0)（从屏底外升起，差值 = 真实占高）
/// 这样 `begin → end` 这段位移在任何时刻都等于真实位移，App 加减都不会错。
static volatile CGFloat AevonKbLastTop = 0.0;
static volatile CGFloat AevonKbLastHeight = 0.0;
/// 0 表示「此刻我们报告的是键盘不在屏上」。
static volatile int AevonKbShown = 0;
static volatile int AevonKbBoundsNotes = 0;
// 0.4.15 — 系统原值只打一次（`-bounds` 没被我们接手的那个数）。配额 1，不刷屏。
static volatile int AevonKbSysNotes = 0;
static volatile int AevonKbWinNotes = 0;
static volatile int AevonKbShellNotes = 0;

// ===========================================================================
// 全局状态 —— 与母版 `0xc320..0xc3b8` 一一对应（地址写在注释里，便于回查）
// ===========================================================================

/// 0xc320 `_heightFraction`，初值 1.0。`_updateHeightFraction`（0x4a00）读
/// `com.nx.stheno.plist` 的 `HeightFraction`；Aevon 读自己域里的同名键。
static double AevonKbHeightFraction = 1.0;

/// 0xc3b8 `_bundleId`。
static NSString *AevonKbBundleId = nil;

/// 0xc3a8 `_injectApp`。母版读 plist 的 `Inject`（缺省 YES）。
/// Aevon 的等价物是下面那个「接管开没开」的开关。
static BOOL AevonKbInjectApp = NO;

/// 0xc3a9 `_init169`。
///
/// ⛔ 名字是作者自己的缩写，**不是**「iPhone X 判定**」。反汇编说得清楚
/// （`_updateInit169` @0x4968）：
///
///   ldr  x0,[0xc328]   ; _one = 1
///   tst  x0, x8, lsl #31
///   cset w8, ne
///   strb w8,[0xc3a9]
///
/// 它测的是 `SettingMask` 的**第 31 位**，也就是「键盘接管这个功能开没开」。
/// （我上一版逆向笔记把它写成「169 ≈ 16:9 高度比」，是错的，已在此更正。）
/// Aevon 的同一件事是偏好里的 `!ring.keyboardNative`（缺省开），由设置面板那
/// 一个开关写。
static BOOL AevonKbTakeOver = NO;

/// 0xc338 `_hookUIScreen`。**同寿命刷新源**：由 `0x5430`（FBSWorkspaceScenesClient
/// 的 settings 回调）每次重算 —— 这正是母版能一直正确的原因，它不是一次性开关。
/// 建键盘窗那一拍它被临时清 0（`0x5230`），为了读到**真**屏幕 bounds。
static BOOL AevonKbHookUIScreen = NO;

/// 0.4.21 — 建键盘窗那一拍「读真值」的计数器（>0 时 `UIScreen -bounds` **一律返回
/// 系统值**，即物理屏 430x932）。
///
/// 这条方向在 0.4.11~0.4.20 之间被搞反过两次，两次的病根是同一个：我们把
/// `displayConfiguration` 改成了卡片尺寸，于是「系统值」本身只剩 717，只能靠
/// 把承载面喂给建窗来凑。0.4.21 把 display 还给系统之后，系统值就是真屏 932，
/// 母版那句 `_hookUIScreen = 0` 才恢复它本来的语义。
///
/// 仍然需要冻结：band 的 Darwin 通知回调不保证主线程，能在读之前把旗子翻掉。
static volatile int AevonKbWinReal = 0;

/// 0xc3b0 `_appScene`。缓存承载面那个 `UIWindowScene`。
///
/// 母版是 strong（`0x54f4` 取到之后存进全局槽，覆盖时 release 旧值）。这里同样
/// 用 strong —— 用 `__unsafe_unretained` 在 scene 被销毁后会变成野指针，而这条
/// 路径正好是「App 关掉又打开」时最容易踩到的。
static UIWindowScene *AevonKbAppScene = nil;

/// 0xc378 / 0xc380 / 0xc388 / 0xc390 —— 四条原件槽。
static CGFloat (*AevonKbOrigIntersection)(id, SEL, id, BOOL *, BOOL) = NULL;
static id      (*AevonKbOrigRemoteWindow)(id, SEL, UIScreen *, BOOL) = NULL;
static void    (*AevonKbOrigSceneSettings)(id, SEL, id, id, id, id) = NULL;
static CGRect  (*AevonKbOrigBounds)(id, SEL) = NULL;

/// 0.4.37 — `UIKeyboardLayoutGuide -layoutFrame` 的原件。
///
/// 这条**不属于母版**（母版四钩子里没有 guide），是 320 实测出来的第六条：
/// 落点全对、`co`/`uin` 全是 717，唯一还在给 App 递错值的接口就是它。
/// 它只改「读出来的矩形」，不参与任何几何写入，所以关掉它（`kbGuideFixOff`）
/// 就等于回到 0.4.36 的行为。
static CGRect  (*AevonKbOrigGuideFrame)(id, SEL) = NULL;

/// 被读到的次数。`scn … gh=` 打的就是它 —— 0 表示钩子装了但没人读（或者类名不对）。
static volatile int AevonKbGuideHits = 0;

/// 0.4.39 — 键盘矩形**按哪套坐标报**。0 = 窗口坐标（默认），1 = 屏幕坐标。
///
/// 322 把威锋那条算式钉死了（不用再猜）：
///
///   `WeiFeng.PostDetailReplyInput 430x175@0,-32`  ⇒ 底边 = 143
///   我们报出去的 kbtop = 358
///   358 − 143 = **215** = 卡片偏移（`physicalH − worldH`）
///
/// 而它的父链全是 717（`UIView 430x717@0,0 > UITransitionView 430x717@0,0`）
/// ⇒ 它的世界没歪，是它在**把屏幕坐标换算成窗口坐标时又减了一次 215**。
///
/// 数值上这和「App 启动时缓存了 screenH=932」完全等价（932 − 717 = 215），
/// 322 也证明改 `nativeBounds` 治不了它（`nbr` 涨到 499、`d` 还是 215）。
/// 两种成因有同一个解 —— **按屏幕坐标报**（`origin.y += shift`）：
///   · 会做 screen→window 换算的 App：573 − 215 = 358 ✓
///   · 拿 932 去减的 App：           932 − 573 = 359 ✓
/// 而 QQ / 微信 / 酷安这类把矩形直接当窗口坐标用的 App 不能这样报
/// （会拿到 573，输入条掉到窗口底之外），所以**只在测出它正好错了 215 之后**
/// 才翻；单向、进程内粘住，靠 `kbScreenModeOff` 关掉。
static volatile int AevonKbScreenMode = 0;
static volatile int AevonKbScreenVotes = 0;
/// 0.4.42 — 「一拍一票」用的拍号：每进一次 `AevonKbProbeFocusAndScene` 加一。
static volatile int AevonKbVoteTick = 0;
static volatile int AevonKbVoteLastTick = -1;
/// 0.4.43 — 「假焦点」时摊开父视图子视图的配额（一次输入会话最多 6 条）。
static volatile int AevonKbPaneProbes = 0;
/// 0.4.43 — 翻到屏幕口径之后的「自证方向」行配额。
static volatile int AevonKbVerdicts = 0;

// ===========================================================================
// 跨文件事实：本 App 现在是不是被卡片托着
// ===========================================================================

/// `AevonAppHook.m` 里 `AevonBandOn` 是本文件的 static，跨文件只能走 C 符号。
extern int AevonBandHostedNow(void);

/// 母版把「屏幕最前面那个 App」写在 `/tmp/stheno_frontmost.json`（Orion 写），
/// 由 `_upadteFrontMost`（0x45f4）读进 `_frontMost`（0xc330）。
///
/// Aevon 没有那个文件，但同一件事实有另一个来源：宿主推过来的卡片几何
/// （`AevonBandOn`）。两者是同一件事的两面：
///
///   · 被卡片托着 ⇒ 这个 App 不是屏幕上最前的那一个 ⇒ 母版会读到别人的 bundleId
///   · 没被托着   ⇒ 它就是全屏前台                  ⇒ 母版会读到它自己的
///
/// 所以 `[_frontMost isEqualToString:_bundleId]` 在 Aevon 里精确等于
/// `!AevonBandHostedNow()`。这不是简化语义，是同一个判断的另一个取数口 ——
/// 母版取「别人是谁」，我们取「我是不是被托着」，两者互补且都只有两个取值。
static BOOL AevonKbIsFrontMost(void) {
    return AevonBandHostedNow() == 0;
}

/// 0.4.7 — `_hookUIScreen` 的第二个刷新源。
///
/// 母版只有 `0x5430`（scene settings 回调）一个常规刷新源，因为它的 `_frontMost`
/// 来自 `/tmp/stheno_frontmost.json`，那个文件由 Orion 在激活 App 的同一拍写下 ——
/// 时序天然对齐，settings 回调到的时候文件里已经是新值。
///
/// Aevon 的事实源是 `AevonBandOn`，它由宿主一条 Darwin 通知写进来，**不经过
/// scene settings**。所以除了 `0x5430` 那一条，还要在 band 真正翻转时补一次 ——
/// 否则「卡片刚建好、settings 还没更新」那一小段里 `_hookUIScreen` 是旧值，
/// `UIScreen.bounds` 会晚一拍才换成承载面尺寸。
///
/// 这不是新增机制：它写的是母版同一个变量、用的是母版同一个表达式
/// （`![_frontMost isEqualToString:_bundleId]`），只是把「什么时候重算」扩到
/// Aevon 的事实源变更点。

/// 0.4.9 — 懒读闸门（只读一次）。
///
/// 0.4.8 在构造函数里直接 `CFPreferencesCopyAppValue`。那是 `main()` 之前、
/// 主线程上的一次 cfprefsd XPC —— 与「构造期提前 realize UIKit 私有类」是同一类
/// 风险。Aevon(293) 的 90 条 `app: hang` 里 `gap=-1ms` 说明主线程心跳一拍未跑，
/// 构造函数没回来。
///
/// 现在读盘推迟到「第一次真的需要这个值时」：要么 scene settings 回调
/// （`AevonKbUpdateTakeOver`），要么 band 翻转（本函数）。两处都只读一次，
/// 读到的仍是同一个值，行为不变。
static volatile int AevonKbShellRead = 0;

/// 0.4.10 — 安装状态。母版 `_ringAppsContains` 那个位置换成了「这个 App 真的被
/// 托管了吗」，三个状态位：
///   · `AevonKbInstalled` 做过决定了（装成功、开关关掉、springboard 跳过，都算）；
///   · `AevonKbArmed`     已经排了 0.15 s 那一拍，别重复排；
///   · `AevonKbVerdictNotes` 证词预算。
///
/// 为什么要「排一拍再装」而不是收到 band 立刻装：band 通知的回调不保证在主线程，
/// 而装钩子会 `NSClassFromString` 到 UIKit 私有类并改 IMP —— 必须在主队列上、
/// 且在 App 已经跑起来的正常状态里做（理由见文首 0.4.9 那一段）。
static volatile int AevonKbInstalled = 0;
static volatile int AevonKbArmed = 0;
static volatile int AevonKbVerdictNotes = 0;

/// 定义在下面「配置读取」一节；这里只要一份声明（懒读要用它）。
static BOOL AevonKbBridgeEnabled(void);

/// 0.4.10 — 唯一安装入口（下面「安装闸门」一节）。`AevonKbRefreshShell` 先用到它。
void AevonKbEnsureInstalled(void);

void AevonKbRefreshShell(void) {
    // 0.4.10 — 还没装：这里只回答「现在该不该装」，**不读盘**。
    // 构造函数那一拍就会走这一支（`AevonBandObserve` 的首次读值），
    // 所以它必须保持是一次纯内存判断。
    if (!AevonKbInstalled) {
        AevonKbEnsureInstalled();
        return;
    }
    if (!AevonKbShellRead) {
        AevonKbShellRead = 1;
        AevonKbInjectApp = AevonKbBridgeEnabled();
        AevonKbTakeOver = AevonKbInjectApp;
        // 母版 `0x4f78` 那个分支的等价证词：开关关着 ⇒ 四条钩子体全部透传。
        if (!AevonKbInjectApp) AevonKbLog("app: kb: native off, inject=0\n");
    }
    if (!AevonKbTakeOver) return;
    AevonKbHookUIScreen = !AevonKbIsFrontMost();
}

// ===========================================================================
// 配置读取（母版 `_updateInit169` / `_updateHeightFraction`）
// ===========================================================================

static CFStringRef const AevonKbDomain = CFSTR("com.aevon");

/// 母版 `_inject` + `SettingMask` bit31 的合并版：Aevon 用一个开关表达同一件事。
/// 缺省开 —— 它和卡片是一体的功能：关掉它，悬浮窗里的键盘就退回「只露一条工具栏」。
static BOOL AevonKbBridgeEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("!ring.keyboardNative"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? YES : NO;
        }
        CFRelease(value);
    }
    return on;
}

/// 母版 `_ringAppsContains` 的位置 —— 0.4.10 换成「这个 App 真的被托管了吗」。
/// 状态位与理由写在上面 `AevonKbRefreshShell` 之前那一节，这里只剩下机制。

static void AevonKbNativeInstall(void);

static void AevonKbInstallTick(void *context) {
    (void)context;
    AevonKbArmed = 0;
    if (AevonKbInstalled) return;
    // 排队的这 0.15 s 里卡片被关了 / 又被收回去 ⇒ 不装。下一次宿主开口再排。
    if (AevonBandHostedNow() == 0) {
        if (AevonKbVerdictNotes < 4) {
            AevonKbVerdictNotes += 1;
            AevonKbLog("app: kb: install drop, nothosted\n");
        }
        return;
    }
    AevonKbNativeInstall();
}

/// 唯一的安装入口。宿主每翻一次 band 都会走到这里（`AevonKbRefreshShell`），
/// 构造函数那一拍也会（`AevonBandObserve` 的首次读值）。
void AevonKbEnsureInstalled(void) {
    if (AevonKbInstalled || AevonKbArmed) return;
    if (AevonBandHostedNow() == 0) return;
    AevonKbArmed = 1;
    AevonKbLog("app: kb: install armed (hosted)\n");
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, AevonKbInstallTick);
}

/// 母版 `_updateHeightFraction`（0x4a00）：先把 1.0 写回去，再读 plist 覆盖。
/// `HeightFraction` 的语义是「键盘高度占屏高的比例」，1.0 = 不缩放。
///
/// ⛔ 0.4.12 — **Aevon 不读这个键，恒 1.0。**
///
/// 母版读的是自己域里的 `HeightFraction`，没有别人用这个名字；Aevon 的设置面板
/// 用的是同一个键名表达**浮窗首帧高度**（`gen-settings.py` 的「尺寸 / 高度」滑条，
/// 缺省 0.63）。照母版去读，用户一动那个滑条，键盘的 inset 就会被乘 0.63 —— 在
/// 0.4.12 的几何下（`kbH == screenH`，公式退化成恒等）那等于让键盘盖住输入条。
///
/// 1.0 就是母版的缺省值，所以行为与本条存在时完全一致；只是不再跟着滑条抖。
static void AevonKbUpdateHeightFraction(void) {
    AevonKbHeightFraction = 1.0;
}

/// 母版 `_updateInit169` + `_upadteFrontMost` 的合并入口，由 `0x5430` 每次调用。
///
/// ⛔ 与母版的唯一差别：**加 0.5 s 节流**。
///
/// 母版每收到一次 scene settings 更新就读一次 plist 文件。Aevon 不能照抄这一点：
/// 我们自己就会改 scene settings（`AevonWriteFrame` → `updateSettings:`），那些
/// 提交会再触发这个回调 —— 不节流就是「改 settings → 回调 → 读盘 → 再改」的自激。
/// 节流只减少读取次数，读到的仍是同一个值，行为不变。
static void AevonKbUpdateTakeOver(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last > 0 && now - last < 0.5) return;
    last = now;
    AevonKbInjectApp = AevonKbBridgeEnabled();
    AevonKbTakeOver = AevonKbInjectApp;
    // 已经在这里读过一次，`AevonKbRefreshShell` 不必再读（0.4.9）。
    AevonKbShellRead = 1;
}

// ===========================================================================
// `_mainScene`（母版 0x4bf8）
// ===========================================================================
//
// 反汇编语义：
//   for (scene in [UIApplication sharedApplication].connectedScenes) {
//       if (![scene isKindOfClass:[UIWindowScene class]]) continue;
//       if ([scene activationState] != 0) continue;        // 0 = foregroundActive
//       for (window in [scene windows]) if ([window isKeyWindow]) return scene;
//   }
//   return nil;
static UIWindowScene *AevonKbMainScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return nil;
    for (id object in [app connectedScenes]) {
        if (![object isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *scene = (UIWindowScene *)object;
        if ([scene activationState] != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in [scene windows]) {
            if ([window isKeyWindow]) return scene;
        }
    }
    return nil;
}

/// `-[UIWindowScene _boundsForInterfaceOrientation:]` —— 私有。返回承载面的矩形
/// （宿主把 scene frame 摆成 430×717@0,215 时，这里就是 430×717）。
typedef CGRect (*AevonKbBoundsForOrientationIMP)(id, SEL, long);

static CGRect AevonKbSceneBounds(UIWindowScene *scene) {
    if (scene == nil) return CGRectZero;
    SEL sel = NSSelectorFromString(@"_boundsForInterfaceOrientation:");
    if (sel == NULL || ![scene respondsToSelector:sel]) return CGRectZero;
    AevonKbBoundsForOrientationIMP fn =
        (AevonKbBoundsForOrientationIMP)[scene methodForSelector:sel];
    if (fn == NULL) return CGRectZero;
    return fn(scene, sel, (long)[scene interfaceOrientation]);
}

// ===========================================================================
// 钩子 4：`-[UIScreen bounds]`（母版 0x54f4，156 B）
// ===========================================================================
//
// ⛔ 这是 Aevon 历史上最危险的一条：0.0.65 / 0.0.67 两次装它都换来「App 打不开、
// 桌面黑屏、小组件空白」，0.1.42 又试一次仍然黑屏。三次事故的共同点是**在没有
// 承载面的时候也改写**，以及**写了存储**。
//
// 母版这一版是安全的，原因有三条，缺一条都不行：
//   ① 它**只换返回值**，不写 `UIScreen` 的任何 ivar（`bounds` 是计算属性，
//      `_boundsForInterfaceOrientation:` 也只是读）；
//   ② 两道闸同时成立才动：`_init169`（功能位）与 `_hookUIScreen`（本 App 不是
//      前台最前）。`_hookUIScreen` 由 settings 回调刷新，不是一次性开关；
//   ③ 拿不到承载 scene 就**原样返回系统值**（`if (_appScene)`）。
//
// Aevon 照抄三条，一个都不省。另外这个文件只编进 `AevonApp.dylib`（App 进程），
// 而 `AevonApp.plist` 的 Filter 排除了 SpringBoard —— 桌面进程里根本没有这条代码。
static CGRect AevonKbBounds(id self, SEL _cmd) {
    // 0.4.21 — 建键盘窗那一拍 `AevonKbWinReal > 0`：**读真值**。
    //
    // 这一条 0.4.12 曾反着写过（冻结期读承载面），当时的理由是「窗底要落在屏底
    // 932、root 又要 717，两根尺子只能统一成 717」。那个理由成立的前提是
    // `displayConfiguration` 已经被我们改成 717 —— 前提本身是错的，见
    // `AevonWriteDisplay` 里 0.4.21 那一段。display 还给系统之后，母版那句
    // `_hookUIScreen = 0`（读真屏）就是唯一的正确解：窗 932、root 932、
    // 键盘内容 501..932，全部落在真屏里。
    if (AevonKbWinReal > 0) {
        if (AevonKbOrigBounds != NULL) return AevonKbOrigBounds(self, _cmd);
        return CGRectZero;
    }
    if (AevonKbTakeOver && AevonKbHookUIScreen) {
        if (AevonKbAppScene == nil) {
            AevonKbAppScene = AevonKbMainScene();
        }
        if (AevonKbAppScene != nil) {
            CGRect box = AevonKbSceneBounds(AevonKbAppScene);
            if (!CGRectIsEmpty(box)) {
                // 0.4.15 — 系统原值只打一次：它回答「我们到底改掉了什么」。
                // `-bounds` 是计算属性，`AevonKbOrigBounds` 就是系统原实现，只读。
                // 与下面那行并排看：`sys` 的 origin 若也是 (0,0)，说明 215 这个偏移
                // 从头到尾不在 `UIScreen` 上，键盘贴 0..717 就是必然。
                if (AevonKbSysNotes == 0) {
                    AevonKbSysNotes = 1;
                    if (AevonKbOrigBounds != NULL) {
                        CGRect sysBox = AevonKbOrigBounds(self, _cmd);
                        char sline[224];
                        snprintf(sline, sizeof(sline),
                                 "app: kb: bounds sys=%.0fx%.0f@%.0f,%.0f (hook off)\n",
                                 sysBox.size.width, sysBox.size.height,
                                 sysBox.origin.x, sysBox.origin.y);
                        AevonKbLog(sline);
                    }
                }
                // 0.4.15 — origin 一起打。0.4.14 只打了尺寸，于是「App 认为屏幕从
                // 哪一点开始」这件事从来没被记录过 —— 而键盘窗是按 `-bounds` 摆的，
                // 若它的原点恒为 (0,0)，键盘就永远贴在 0..717，离屏底 215。
                if (AevonKbBoundsNotes < 6) {
                    AevonKbBoundsNotes += 1;
                    char line[224];
                    snprintf(line, sizeof(line),
                             "app: kb: bounds -> %.0fx%.0f@%.0f,%.0f (hosted=%d)\n",
                             box.size.width, box.size.height,
                             box.origin.x, box.origin.y,
                             1 - (int)AevonKbIsFrontMost());
                    AevonKbLog(line);
                }
                return box;
            }
        }
    }
    if (AevonKbOrigBounds != NULL) return AevonKbOrigBounds(self, _cmd);
    return CGRectZero;
}

// ===========================================================================
// 0.4.38 — `UIScreen.nativeBounds`：`bounds` 说是 717，`nativeBounds` 还说是 932
// ===========================================================================
//
// 321 的 `scr` 把「932 还能从哪来」缩到两条，其余全部排除：
//
//   uin=430x717      ← `-bounds` 已钩，App 读它就是 717，不是来源
//   key=UIWindow 430x717@0,0   ← keyWindow 也是 717，不是来源
//   nb=1290x2796 ns=3.00       ← /3 = **932**，没有钩
//   list=… w1/w2=UITextEffectsWindow 430x932@0,0 ← 窗口表里还有两个 932
//
// 威锋的算式被 321 的读数钉死了：它的回复条静止位置是窗口底（`717−175=542`），
// 实际落在 `y=−32`，也就是被上移了 **574 = 932 − 358**。574 只能来自「屏幕高 932」
// 减「我们报出去的键盘顶 358」—— 而 932 只剩 `nativeBounds` 这一个公开入口。
//
// 这一条不是「再编一个补偿」，它补的是**我们自己的不自洽**：我们把 `-bounds` 改成
// 承载面(717)，却把 `-nativeBounds` 留在物理屏(932)，等于同时对外宣称
// 「逻辑屏 717 / 物理屏 932」。分屏（Split View）里系统确实会这样，但那里
// App 不该拿 nativeBounds 排版；我们把 App 塞进卡片，就得给它一个说得通的屏。
//
// 三条纪律与 `-bounds` 完全相同：建窗那一拍读真值、只在本 App 被托着时动、
// 拿不到承载 scene 就原样返回。另外内部所有「物理屏高」都必须走
// `AevonKbRealNativeBounds()` —— 否则 `AevonKbPhysicalHeight()` 会读到自己伪造的
// 717，整套量测（meas / shift / 建窗）会一起塌。
static CGRect  (*AevonKbOrigNativeBounds)(id, SEL) = NULL;
static volatile int AevonKbNativeHits = 0;
static volatile int AevonKbNativeFixOn = 0;

/// 0.4.38 — 开关（缺省开）。`com.aevon.kbNativeOff = true` + respring
/// 即回到「nativeBounds 用系统值」（其余各条不受影响）。
static BOOL AevonKbNativeFixEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("kbNativeOff"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? NO : YES;
        }
        CFRelease(value);
    }
    return on;
}

/// 系统真值，**不过钩子**。内部一切「物理屏」都必须用这个。
static CGRect AevonKbRealNativeBounds(void) {
    UIScreen *screen = [UIScreen mainScreen];
    if (screen == nil) return CGRectZero;
    if (AevonKbOrigNativeBounds != NULL) {
        return AevonKbOrigNativeBounds(screen, @selector(nativeBounds));
    }
    return [screen nativeBounds];
}

static CGRect AevonKbNativeBoundsGet(id self, SEL _cmd) {
    if (AevonKbOrigNativeBounds == NULL) return CGRectZero;
    CGRect real = AevonKbOrigNativeBounds(self, _cmd);
    if (AevonKbWinReal > 0) return real;        // 建窗那一拍：读真值
    if (!AevonKbNativeFixOn || !AevonKbTakeOver || !AevonKbHookUIScreen) return real;
    if (AevonKbAppScene == nil) {
        AevonKbAppScene = AevonKbMainScene();
    }
    if (AevonKbAppScene == nil) return real;
    CGRect box = AevonKbSceneBounds(AevonKbAppScene);
    if (CGRectIsEmpty(box)) return real;
    CGFloat ns = ((CGFloat (*)(id, SEL))objc_msgSend)(self, @selector(nativeScale));
    if (ns <= 0.0) return real;
    // 计数的是「被读了几次」。322 里若威锋修好，`nbr` 会是几千；若仍 215 而
    // `nbr=0`，说明那 574 来自窗口表里的 `UITextEffectsWindow`，不是这里 ——
    // 两条路都能被这一列判死，不用再猜。
    AevonKbNativeHits += 1;
    return CGRectMake(0.0, 0.0, box.size.width * ns, box.size.height * ns);
}

// ===========================================================================
// 0.4.17 — 键盘在这一块屏上的**真实占高**
// ===========================================================================
//
// 301 的现场（Preferences，键盘带 accessory）：
//
//   app: kb: inter orig=316 screen=717 kb=717 hf=1.00 -> 316      ← 公式给 316
//   app: kb: tree UIInputSetHostView f=0,286,430x431               ← 键盘真占 431
//   app: kb: tree   UIView           f=0,0,430x361                 ← 键区只有 361
//   app: kb: tree     UIKBInputBackdropView f=0,0,430x431          ← 背景 431 被父级裁到 361
//   app: kb: tree   UIKeyboardDockView      f=0,0,430x431          ← 底部 70 只剩按钮，没有背景
//
// 拿三份日志并排，缺口的量不固定，缺口的方向却永远是「公式 < 真实」或「公式 > 真实」
// 由 `kbH` 决定：
//
//   299 (0.4.14) 公式 316 / 真实 386 ⇒ 少 70   ⇒ 键盘盖住输入框
//   301 (0.4.16) 公式 316 / 真实 431 ⇒ 少 115  ⇒ 盖住 + 底部 70 透明
//   296 (0.4.11) 公式 458 / 真实 386 ⇒ 多 72   ⇒ 输入框被抬高
//
// ⚠ 这不是母版公式写错了，而是母版公式的**前提**在我们这里不成立：母版的 `orig`
// 与 `kbH` 同源（都来自物理 932 那个世界），所以 `(orig*S/W)+W−S` 那一段是它的
// 换算项；Aevon 从 0.2.46 起把 display 改成卡片尺寸，`screenH` 与 `kbH` 双双变成
// 717 ⇒ 公式恒等 ⇒ `orig` 被原样透传，可它仍然是 932 的口径（316）。
// 换句话说：**母版四个钩子到这个配置下已经数学恒等，坏的是喂进去的量。**
//
// 所以这里不再猜系数，只量一个客观量：键盘窗内部 `InputSetHostView` 的顶边。
//   footprint = screenH − (窗 frame.y + host 在窗内的 y)
// 窗底与屏底对齐时它等于 host 的高度；不对齐时它仍然是「键盘遮住了屏幕多少」。
// 只用公开的 view 接口（`subviews` / `convertRect:toView:` / `frame`），不调任何
// 私有选择子、不写任何几何 ⇒ 量错最多是数值不对，不会杀进程。
//
// ⛔ **0.4.23：上面那整段前提已经不成立，这个测量不再参与任何决策。**
// 0.4.21 把 display 还给系统之后 `kbH` 回到 932，母版公式重新成立，而且它量的是
// 「这一刻」的键盘 —— 键盘升起与候选条到达是两个时刻，用「此刻」的值去答一个
// 一次性的问句，就会漏掉后来那 45 pt。现在这里**只打日志**，inset 的唯一来源是
// 母版公式。保留它是因为日志里 `formula=` 与 `meas=` 并排能直接看出余量够不够；
// 哪天母版公式真的不够了，这份读数就是第一个证据，而不是又一轮猜系数。
static UIView *AevonKbFindHostView(UIView *root, int depth) {
    if (root == nil || depth < 0) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if (cls != nil && [cls rangeOfString:@"InputSetHost"].location != NSNotFound) {
        return root;
    }
    NSArray *subs = [root subviews];
    NSUInteger count = [subs count];
    for (NSUInteger i = 0; i < count && i < 8; i++) {
        UIView *found = AevonKbFindHostView([subs objectAtIndex:i], depth - 1);
        if (found != nil) return found;
    }
    return nil;
}

/// 0.4.33 — 宿主顶部那条**透明占位**的高度。
///
/// 316 把这件事量清楚了。同一台机器、同一个输入法，五家 App 的宿主高是：
///
///   微信 359   酷安 359   贴吧 359             ← 占位 0
///   抖音 399                                   ← 占位 40
///   Safari 419                                 ← 占位 60
///
/// 把占位减掉之后，五家的「键盘高」归一成**同一组值** `{359, 386, 404, 431}`：
///
///   抖音  399−40=359  426−40=386  444−40=404  471−40=431
///   Safari 419−60=359 446−60=386  464−60=404  491−60=431
///
/// 键盘是硬件+输入法决定的，跟 App 无关 —— 五家能落回同一组，就说明那 40/60 不是
/// 键盘的一部分，而是宿主顶部一条 0 子视图的 `_UIRemoteKeyboardPlaceholderView`：
/// 它把整个键盘内容（键区、候选条、dock）从宿主顶往下推了 40/60，宿主自己跟着长高，
/// 但那一条**不画任何东西**。
///
/// 于是 `hostH` 不是「键盘遮住屏幕多少」，而是「键盘 + 顶部空白」。我们按 hostH 报，
/// App 就把输入条排到空白之上 ⇒ 用户看到的是「输入框被抬高了」。Safari 的空白最大
/// （60），偏移也最大，连输入框都出画面了。
///
/// 判据只认形状（贴宿主顶边、宽度占满、高度 > 0、类名含 `Placeholder`），
/// 不认具体类名 —— 私有类换个名字也还在那个位置。
static CGFloat AevonKbHostTopSpacer(UIView *host) {
    if (host == nil) return 0.0;
    CGRect hostBounds = [host bounds];
    if (hostBounds.size.height < 1.0) return 0.0;
    NSArray *subs = [host subviews];
    NSUInteger count = [subs count];
    CGFloat best = 0.0;
    for (NSUInteger i = 0; i < count && i < 16; i++) {
        UIView *sv = [subs objectAtIndex:i];
        if (sv == nil) continue;
        NSString *cls = NSStringFromClass([sv class]);
        if (cls == nil) continue;
        if ([cls rangeOfString:@"Placeholder"].location == NSNotFound) continue;
        CGRect f = [sv frame];
        if (f.origin.y > 1.0) continue;                       // 只认贴顶边那条
        if (f.size.height < 1.0) continue;
        if (f.size.width + 8.0 < hostBounds.size.width) continue;   // 只认横向占满的
        if (f.size.height > best) best = f.size.height;
    }
    // 占位比宿主还高只可能是量错（布局中/横屏），不参与。
    if (best >= hostBounds.size.height) return 0.0;
    return best;
}

static CGFloat AevonKbMeasuredCoverage(id keyboardWindow, CGFloat screenHeight,
                                       CGFloat *outHostY, CGFloat *outHostH,
                                       CGFloat *outSpacer) {
    if (outHostY != NULL) *outHostY = 0.0;
    if (outHostH != NULL) *outHostH = 0.0;
    if (outSpacer != NULL) *outSpacer = 0.0;
    if (keyboardWindow == nil || ![keyboardWindow isKindOfClass:[UIView class]]) return 0.0;
    if (screenHeight < 1.0) return 0.0;
    UIView *win = (UIView *)keyboardWindow;
    UIView *host = AevonKbFindHostView(win, 3);
    if (host == nil) return 0.0;
    CGRect inWindow = [host convertRect:[host bounds] toView:win];
    if (outHostY != NULL) *outHostY = inWindow.origin.y;
    if (outHostH != NULL) *outHostH = inWindow.size.height;
    if (inWindow.size.height < 8.0) return 0.0;
    CGFloat spacer = AevonKbHostTopSpacer(host);
    if (outSpacer != NULL) *outSpacer = spacer;
    // 口径 = 「窗底到键盘顶」，**对窗的 origin 免疫**。
    //
    // 旧写法 `screenHeight − (win.y + host.y)` 默认「窗底 = App 世界底」，0.4.20 把窗
    // 挪到 215 之后这条就不成立了（会算出 216，而键盘实占 431）。
    // 现在的写法只依赖一条事实：**键盘窗的底边就是屏幕底边**。0.4.21 起窗是
    // `[main bounds]` = 物理屏 (0,0,430,932)，键盘内容贴窗底 501..932
    // ⇒ footprint = 932 − 501 = 431，与 scene 空间里的占高（717 − 286）同值。
    CGRect winFrame = [win frame];
    CGFloat footprint = winFrame.size.height - inWindow.origin.y - spacer;
    if (footprint < 8.0 || footprint > screenHeight + 1.0) return 0.0;
    return footprint;
}

// ===========================================================================
// 0.4.25 — App 的 safeArea 到底被设成了多少（只读取证，一次输入会话 6 条）
// ===========================================================================
//
// 0.4.21→0.4.23 三版都在改「我们认为该报的值」：386 → 431 → 458，`-> N` 每版都在变，
// 但**从来没有验证过 App 收下的是不是这个 N**。
//
// 308 给了最硬的对照：`formula=458` 报出去了，输入框还是被「键盘的工具栏」盖住。
// 如果 App 真按 458 让位，输入框底部会在 App 世界 `717−458=259`，而键盘顶在 286，
// 中间空 27 pt —— 不可能被盖。所以只剩两种可能：App 没收到这个值，或者它收到了
// 但算的时候用的是别的量。
//
// 0.4.24 用 `contentInset` 去问，309 证明这个口不可用：
//   QQ    `inset=none`       —— 深 6 层一个 UIScrollView 都没命中
//   微信  `inset=0,0,0,0`     —— 命中的对象恒为 0，不可能是键盘升起时的聊天列表
// 两个都不作数，等于这一版白取。
//
// 0.4.25 换成 `safeAreaInsets` —— 它是 `_UIRemoteKeyboards` 的**直接输出终点**：
// 系统算完 intersectionHeight 就把它写进 window 的 safeArea，App 从那里读。
// 四个读数并排就能定性：
//   safe=       App 主窗的 safeAreaInsets（`bottom` 就是它给键盘留的高度）
//   rsafe=      rootViewController.view 的 bottom（App 内容真正挂的那层，可能被容器改过）
//   inset=      所有 UIScrollView 里 bottom 最大的那个（兜底，量不到打 `none`）
//   hostm=      键盘在 App 世界的顶边；校验关系 `App 世界高 − hostm == meas`
//
// 判定：
//   safe.bottom ≈ 458/437 ⇒ 我们的值生效了，问题在 App 自己的输入条布局；
//   safe.bottom ≈ 431/359 ⇒ App 用的是键盘几何，我们的返回值被丢弃；
//   safe.bottom ≈ 316/289 ⇒ App 用的是系统 orig，钩子整条是空转；
//   safe.bottom 不随键盘变 ⇒ App 根本不用 safeArea，要换钩点。
static volatile int AevonKbInsetProbes = 0;

// 0.4.25 — 改成「遍历全部、取 bottom 最大者」，而不是深度优先第一个。
//
// 309 证伪了「第一个」这个选法：QQ 打出 `inset=none`（深 6 层一个 UIScrollView
// 都没命中），微信打出 `inset=0,0,0,0 off=0`（命中了，但那个对象恒为 0，
// 不可能是键盘升起时的聊天列表）。深度 6 对现代 App 的视图层级本来就不够，
// 而「第一个」在多标签 / 侧滑容器里天然选错。
//
// 键盘升起时，真正让位的那个 scrollView 的 bottom 是全场最大的，取最大即可。
// 只接受 bottom > 0.5：键盘没升起时所有 scrollView 都是 0，那时宁可不打，
// 也不要用一个 0 冒充读数。
static void AevonKbScanScrollViews(UIView *root, int depth,
                                   UIScrollView **best, int *seen, CGFloat *bestBottom) {
    if (root == nil || depth < 0 || best == NULL || seen == NULL || bestBottom == NULL) return;
    if ([root isKindOfClass:[UIScrollView class]]) {
        *seen += 1;
        UIScrollView *sv = (UIScrollView *)root;
        CGFloat bottom = [sv contentInset].bottom;
        if (bottom > 0.5 && (*best == nil || bottom > *bestBottom)) {
            *best = sv;
            *bestBottom = bottom;
        }
    }
    NSArray *subs = [root subviews];
    NSUInteger count = [subs count];
    for (NSUInteger i = 0; i < count && i < 32; i++) {
        AevonKbScanScrollViews([subs objectAtIndex:i], depth - 1, best, seen, bestBottom);
    }
}

// ===========================================================================
// 0.4.40 — 全树滚动视图读数（补 `ins` 打不到的那一档）
// ===========================================================================
//
// `ins` 只从**焦点视图**往上 8 层找滚动视图。这对 QQ / 威锋 / 酷安够用，对
// Safari 一条都打不出来：网页输入框的焦点在 WebContent 进程，主进程这边
// `AevonKbFindFirstResponderAnyWindow` 摸到的是底部地址栏（`UnifiedField`），
// 父链是 `SFCapsuleURLField > SFCapsuleView > SFCapsuleCollectionView`，
// 全程没有 UIScrollView ⇒ 323 里 Safari 一个 `ins` 都没有。
//
// 而 Safari 恰恰是「输入框在页面底部时看不见」的那一家 —— 它到底给页面留了
// 多少，只能从 `WKScrollView` 自己的 inset 上看。323 唯一的线索是
// `probe inset=297`，但那一行只取「全树 `contentInset.bottom` 最大值」、
// 不带类名，无法判断 297 是 WebKit 的让位量，还是底部胶囊栏自己的内边距。
//
// 所以这里把 `adjustedContentInset.bottom` 最大的三个连类名、连尺寸打出来：
//   · `ai ≈ 359`（世界高 − kbtop） ⇒ App 的认知是对的，问题在它之后的一步；
//   · `ai ≈ 297`（= 359 − 60）    ⇒ 它把 Safari 那 60 的顶部占位又扣了一遍；
//   · `ai ≈ 574`（= 359 + 215）   ⇒ 它按 932 在算，跟威锋同一个病，可投票。
// 只读，不改任何几何。
#define AEVON_KB_SV_SCAN 24
#define AEVON_KB_SV_SHOW 3
typedef struct {
    UIScrollView *sv;
    CGRect frame;
    CGFloat ci;
    CGFloat ai;
    CGFloat off;
} AevonKbSvHit;

static void AevonKbCollectScrollViews(UIView *root, int depth,
                                      AevonKbSvHit *hits, int *count) {
    if (root == nil || depth < 0 || hits == NULL || count == NULL) return;
    if (*count >= AEVON_KB_SV_SCAN) return;
    if ([root isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)root;
        AevonKbSvHit *hit = &hits[*count];
        hit->sv = sv;
        hit->frame = [sv frame];
        hit->ci = [sv contentInset].bottom;
        hit->ai = [sv adjustedContentInset].bottom;
        hit->off = [sv contentOffset].y;
        *count += 1;
    }
    NSArray *subs = [root subviews];
    NSUInteger n = [subs count];
    for (NSUInteger i = 0; i < n && i < 32; i++) {
        AevonKbCollectScrollViews([subs objectAtIndex:i], depth - 1, hits, count);
        if (*count >= AEVON_KB_SV_SCAN) return;
    }
}

/// 配额 6 —— 与 `ins` 同拍（1.7 s / 2.9 s 各一次），一次弹键盘最多三屏。
static volatile int AevonKbSvProbes = 0;

static void AevonKbProbeScrollViews(const char *tag, UIWindow *appWin) {
    if (appWin == nil || tag == NULL) return;
    if (AevonKbSvProbes >= 6) return;
    if (![NSThread isMainThread]) return;
    AevonKbSvProbes += 1;

    AevonKbSvHit hits[AEVON_KB_SV_SCAN];
    int count = 0;
    char line[420];
    AevonKbCollectScrollViews(appWin, 12, hits, &count);
    if (count <= 0) {
        snprintf(line, sizeof(line), "app: kb: svs %s n=0\n", tag);
        AevonKbLog(line);
        return;
    }
    // `ai` 降序取前三个；取过的格子置 −1 当「已用」标记（`ai` 本身不会为负）。
    char list[380] = "";
    int shown = 0;
    int k;
    for (k = 0; k < AEVON_KB_SV_SHOW; k++) {
        int best = -1;
        int i;
        for (i = 0; i < count; i++) {
            if (hits[i].ai < 0.0) continue;
            if (best < 0 || hits[i].ai > hits[best].ai) best = i;
        }
        if (best < 0) break;
        char bit[132];
        snprintf(bit, sizeof(bit), "%s%.22s %.0fx%.0f@%.0f,%.0f ci=%.0f ai=%.0f off=%.0f",
                 (shown == 0) ? "" : " | ",
                 class_getName([hits[best].sv class]),
                 hits[best].frame.size.width, hits[best].frame.size.height,
                 hits[best].frame.origin.x, hits[best].frame.origin.y,
                 hits[best].ci, hits[best].ai, hits[best].off);
        size_t room = sizeof(list) - strlen(list) - 1;
        if (room > 1) strncat(list, bit, room);
        hits[best].ai = -1.0;
        shown += 1;
    }
    snprintf(line, sizeof(line), "app: kb: svs %s n=%d %s\n", tag, count, list);
    AevonKbLog(line);
}

static UIWindow *AevonKbAppMainWindow(void) {
    Class appCls = objc_getClass("UIApplication");
    if (appCls == Nil) return nil;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, @selector(sharedApplication));
    if (app == nil) return nil;
    NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
    if (wins == nil) return nil;
    NSUInteger count = [wins count];
    for (NSUInteger i = 0; i < count && i < 16; i++) {
        id w = [wins objectAtIndex:i];
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if (([w windowLevel]) != 0.0) continue;      // 键盘窗、状态栏窗都不是 0
        NSString *cls = NSStringFromClass([w class]);
        if (cls != nil && [cls rangeOfString:@"Keyboard"].location != NSNotFound) continue;
        if ([w isHidden]) continue;
        return (UIWindow *)w;
    }
    return nil;
}

static void AevonKbProbeAppInsets(id keyboardWindow) {
    if (AevonKbInsetProbes >= 6) return;
    UIWindow *appWin = AevonKbAppMainWindow();
    if (appWin == nil) return;
    AevonKbInsetProbes += 1;

    // 0.4.25 — 取证口换成 `safeAreaInsets`。
    //
    // `safeAreaInsets` 是这条链路的**直接终点**：`_UIRemoteKeyboards` 算完
    // `intersectionHeightForWindowScene:` 之后，系统把它写进 window 的 safeArea，
    // App 再从那里读。所以这一个数就能回答「我们报的 458 有没有被采纳」：
    //   safe.bottom ≈ 458/437 ⇒ 采纳了，问题在 App 自己的输入条布局；
    //   safe.bottom ≈ 431/359 ⇒ 采纳的是键盘几何，我们的返回值被丢弃；
    //   safe.bottom ≈ 316/289 ⇒ 采纳的是系统 orig，钩子整条是空转；
    //   safe.bottom 不随键盘变 ⇒ App 根本不用 safeArea，要换钩点。
    //
    // 同时读 `rootViewController.view` 那一份 —— App 内容几乎都挂在这层，
    // 自定义容器会改它，两份不一定相等。
    UIEdgeInsets safe = [appWin safeAreaInsets];
    UIEdgeInsets rsafe = UIEdgeInsetsZero;
    id rvc = [appWin rootViewController];
    if (rvc != nil) {
        UIView *rv = (UIView *)[rvc view];
        if (rv != nil) rsafe = [rv safeAreaInsets];
    }

    UIScrollView *best = nil;
    int seen = 0;
    CGFloat bestBottom = 0.0;
    AevonKbScanScrollViews(appWin, 12, &best, &seen, &bestBottom);

    CGRect wf = [appWin frame];
    char line[320];
    if (best != nil) {
        snprintf(line, sizeof(line),
                 "app: kb: probe win=%.0fx%.0f safe=%.0f,%.0f,%.0f,%.0f rsafe=%.0f inset=%.0f sc=%d\n",
                 wf.size.width, wf.size.height,
                 safe.top, safe.left, safe.bottom, safe.right,
                 rsafe.bottom, bestBottom, seen);
    } else {
        snprintf(line, sizeof(line),
                 "app: kb: probe win=%.0fx%.0f safe=%.0f,%.0f,%.0f,%.0f rsafe=%.0f inset=none sc=%d\n",
                 wf.size.width, wf.size.height,
                 safe.top, safe.left, safe.bottom, safe.right,
                 rsafe.bottom, seen);
    }
    AevonKbLog(line);

    // 第二行：键盘在 App 世界的顶边。
    // `hostc`（`convertRect:toView:` 到 App 主窗）已被 309 证伪：App 主窗在进程内
    // 的 origin 恒为 0（宿主在外部把 scene 摆到屏幕 215），跨 window 转换拿不到
    // 那 215 的屏幕偏移，退化成窗内坐标。所以只打手工算法 `hostm`。
    // 校验关系：`App 世界高 − hostm == meas`（309 四个样本全部吻合）。
    if (keyboardWindow != nil && [keyboardWindow isKindOfClass:[UIView class]]) {
        UIView *kbWin = (UIView *)keyboardWindow;
        UIView *host = AevonKbFindHostView(kbWin, 4);
        if (host != nil) {
            CGRect inKbWin = [host convertRect:[host bounds] toView:kbWin];
            CGRect kbFrame = [kbWin frame];
            CGRect native = AevonKbRealNativeBounds();
            CGFloat nativeScale = [[UIScreen mainScreen] nativeScale];
            CGFloat physicalH = nativeScale > 0.0 ? native.size.height / nativeScale : 0.0;
            // App 主窗贴屏幕底是卡片侧一直保证的，所以 shift = 物理屏高 − App 世界高。
            CGFloat shift = physicalH - wf.size.height;
            CGFloat hostManual = kbFrame.origin.y + inKbWin.origin.y - shift;
            // 0.4.33 — 顶部占位：宿主顶边要**再加上**这一段才是键盘真正露头的位置
            // （那一条不画任何东西）。校验关系变成
            //   `App 世界高 − (hostm + ph) == meas`
            CGFloat spacer = AevonKbHostTopSpacer(host);
            char line2[224];
            snprintf(line2, sizeof(line2),
                     "app: kb: probe host=%.0fx%.0f@%.0f,%.0f hostm=%.0f ph=%.0f\n",
                     inKbWin.size.width, inKbWin.size.height,
                     inKbWin.origin.x, inKbWin.origin.y, hostManual, spacer);
            AevonKbLog(line2);
        }
    }
}

// ===========================================================================
// 0.4.26 — 键盘通知里的 frame：屏幕坐标还是 App 世界坐标
// ===========================================================================
//
// 310 的 probe 把两条候选出口**都**排除了：
//   · `safe=59,0,34,0`、`rsafe=34` 十次采样恒为 34（top 59 是灵动岛、
//     bottom 34 是 home indicator）。我们算出的 458 从来没进过 window 的 safeArea；
//   · `inset` 对 QQ 是 `none`（深 12 层没扫到带 inset 的滚动视图）、对微信是
//     133/365/344，与键盘真实占高 386/431/359 不成比例 —— 那是微信自己的列表内边距。
//
// 两条合起来只有一个结论：**这两家 App 都不吃 `intersectionHeightForWindowScene:`。**
// 它们吃的是 `UIKeyboardWillChangeFrameNotification` 里的
// `UIKeyboardFrameEndUserInfoKey`，自己算让位。0.4.17~0.4.23 那六版调的是
// 一个不会被它们读的值 —— 这就是「六版无效」的全部原因。
//
// 而这条路上有一个 215 pt 的坐标差：
//   键盘窗按真屏建在 `(0,0,430,932)`（0.4.21 定案），App 主窗是 `(0,0,430,717)`。
//   两者在进程内都以 `(0,0)` 为原点 —— 那 215 是**宿主在屏幕上的摆放偏移，
//   进程内看不见**。所以 UIKit 发的 frame 极可能仍是屏幕坐标。
//   App 若拿 546（屏幕）当自己的 717 坐标用，遮挡会算成 `717−546=171`，
//   而键盘真实占 386 ⇒ 输入条被压进键盘内部 215 pt，整块被盖。
//
// 判据不是猜的：`hostm` 已经把真值量出来了（310 四个样本全部满足
// `App 世界高 − hostm == meas`）。所以这里第一次采样只并排打出两个数：
//   `note … end=0,546,430x386 … shift=215` 与 `probe host … hostm=331`
//   · `end.y ≈ 546` 而 `hostm=331` ⇒ 通知是屏幕坐标，App 算错 215（确诊，本版即修）
//   · `end.y ≈ 331` 且等于 `hostm`  ⇒ 通知本来就是对的，问题不在这一层
//
// ⛔ 0.4.26 只把 `origin.y` 减了 215，**高度原样留着 528** —— 311 证明那是错的另一半：
// App 按 528 让位，输入条升到 189，比真顶边 331 高 142，中间那片空当就是黑屏。
// 0.4.27 改成整块换成量出来的真值（y = world − meas、高 = meas），见下面 `AevonKbPostNote`。
static IMP AevonKbOrigPostNote = NULL;
static volatile int AevonKbNoteNotes = 0;
static volatile int AevonKbNoteFixes = 0;
/// 0.4.26 — 修正开关。install 那一拍读一次（运行期、主队列，不在构造期），
/// 之后只在热路径上做一次内存判断。偏好 `com.aevon.kbNoteFixOff = true`
/// 并 respring 即回到「只取证不改帧」。
static volatile int AevonKbNoteFixOn = 0;

/// 0.4.26 — 修正开关（缺省开）。`com.aevon.kbNoteFixOff = true` + respring
/// 即回到「只取证、一帧不改」。
static BOOL AevonKbNoteFixEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("kbNoteFixOff"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? NO : YES;
        }
        CFRelease(value);
    }
    return on;
}

/// 0.4.37 — `keyboardLayoutGuide` 的修正开关（缺省开）。
/// `com.aevon.kbGuideFixOff = true` + respring 即回到「guide 用系统值」。
///
/// 为什么给它单独一个开关：它和落点那条线是**两件独立的事**。落点错了，
/// 键盘会画在错的位置；guide 错了，只有按它排版的 App 会把输入框放错。
/// 分开开关，出问题时能一句话定位是谁在起作用。
static volatile int AevonKbGuideFixOn = 0;

static BOOL AevonKbGuideFixEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("kbGuideFixOff"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? NO : YES;
        }
        CFRelease(value);
    }
    return on;
}

/// 0.4.41 — guide **引擎**那条线的开关（缺省开）。写 `com.aevon.kbGuidePadOff = true`
/// 即只读不写：`graw` 照打，但一次 `keyboardDismissPadding` 都不设。
static volatile int AevonKbGuidePadOn = 0;

static BOOL AevonKbGuidePadEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("kbGuidePadOff"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? NO : YES;
        }
        CFRelease(value);
    }
    return on;
}

/// 0.4.39 — 自动换口径的开关。缺省开；写 `true` 即回到「一律窗口坐标」。
static BOOL AevonKbScreenModeEnabled(void) {
    BOOL on = YES;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("kbScreenModeOff"),
                                                        AevonKbDomain);
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)value) ? NO : YES;
        }
        CFRelease(value);
    }
    return on;
}

/// 物理屏高。`UIScreen.bounds` 此刻已被我们钩成承载面（717）、`nativeBounds`
/// 自 0.4.38 起也被钩成承载面，所以这里必须走**系统原值**
/// （`AevonKbRealNativeBounds`），不能读 `nativeBounds`。
static CGFloat AevonKbPhysicalHeight(void) {
    CGRect native = AevonKbRealNativeBounds();
    CGFloat scale = [[UIScreen mainScreen] nativeScale];
    if (scale <= 0.0) return 0.0;
    return native.size.height / scale;
}

/// 0.4.27 — 窗口表里那个键盘窗（level > 0 且类名带 `Keyboard`）。
///
/// 通知钩子里没有 `_UIRemoteKeyboards` 这个 `self`，拿不到 `-keyboardWindow`；而
/// 「键盘此刻真实占多少」必须在**收到通知的那一拍**量，晚一拍就是旧值。App 的窗口
/// 表只有十几项，扫一遍是常数级开销，也省掉一份会失效的缓存。
/// 0.4.29 — 键盘窗缓存，由 `intersectionHeightForWindowScene:` 那一拍留住。
///
/// 313 证明窗口表这条路在通知钩子里**拿不到**键盘窗：`chan … kbwin=0x0`，于是
/// `note … host=0,0`、`meas` 只能吃 `inter` 留下的旧值。旧值这次恰好对，但那是
/// 运气 —— `inter` 不一定在每条通知之前被调，而通知钩子里没有 `_UIRemoteKeyboards`
/// 这个 `self`，问不到 `-keyboardWindow`。
///
/// 那个窗是「每屏一个」的单例，App 活着它就活着；这里 retain 一次（不释放），
/// 就不会留下野指针。量的时候仍然走 `AevonKbMeasuredCoverage`：宿主找不到就返回 0，
/// 不会因为拿错窗就编一个数出来。
static UIWindow *AevonKbWindowKeep = nil;

static UIWindow *AevonKbKeyboardWindowLive(void) {
    Class appCls = objc_getClass("UIApplication");
    if (appCls != Nil) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, @selector(sharedApplication));
        if (app != nil) {
            NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
            NSUInteger count = [wins count];
            for (NSUInteger i = 0; i < count && i < 24; i++) {
                id w = [wins objectAtIndex:i];
                if (![w isKindOfClass:[UIWindow class]]) continue;
                if (((CGFloat (*)(id, SEL))objc_msgSend)((id)w, @selector(windowLevel)) < 1.0) continue;
                NSString *cls = NSStringFromClass([w class]);
                if (cls != nil && [cls rangeOfString:@"Keyboard"].location != NSNotFound) {
                    return (UIWindow *)w;
                }
            }
        }
    }
    return AevonKbWindowKeep;
}

// 0.4.32 — 在**所有**候选键盘窗里取占屏最多的那一个。
//
// 315 把这个坑照得很清楚。同一个进程里，`[UIApplication windows]` 表里不止一个
// 类名带 `Keyboard` 的窗，而「第一个」在不同会话里不是同一个：
//
//   会话一（正常）   note … meas=386 host=546,386     ← 拿到的是真的那个
//   会话二/三        note … meas=0   host=932,289     ← 拿到的是另一个（宿主整块在屏下）
//
// `host=932,289` 里 289 这个高度不是任何一个键盘的高度（键盘是 386/431/359/426/471…），
// 所以它不是「键盘收起了」，是**量错了窗**。而同一拍的 `inter` 钩子是 `host=573,359`
// —— 它问的是母版的 `[self keyboardWindow]`，那才是活的。
//
// 判据不猜：键盘是「露在屏幕上的那一块」，所以取 footprint 最大的候选。量不出
// （全 0）就返回 0，由调用方决定怎么办，这里绝不编一个数。
#define AEVON_KB_MAX_WINS 8
static CGFloat AevonKbMeasureBest(CGFloat physicalH,
                                  CGFloat *outHostY, CGFloat *outHostH,
                                  CGFloat *outSpacer, int *outCount) {
    if (outHostY != NULL) *outHostY = 0.0;
    if (outHostH != NULL) *outHostH = 0.0;
    if (outSpacer != NULL) *outSpacer = 0.0;
    if (outCount != NULL) *outCount = 0;
    id wins[AEVON_KB_MAX_WINS];
    int n = 0;
    Class appCls = objc_getClass("UIApplication");
    if (appCls != Nil) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, @selector(sharedApplication));
        if (app != nil) {
            NSArray *list = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
            NSUInteger count = [list count];
            for (NSUInteger i = 0; i < count && i < 24; i++) {
                id w = [list objectAtIndex:i];
                if (![w isKindOfClass:[UIWindow class]]) continue;
                if (((CGFloat (*)(id, SEL))objc_msgSend)((id)w, @selector(windowLevel)) < 1.0) continue;
                NSString *cls = NSStringFromClass([w class]);
                if (cls == nil || [cls rangeOfString:@"Keyboard"].location == NSNotFound) continue;
                if (n < AEVON_KB_MAX_WINS) wins[n++] = w;
            }
        }
    }
    if (AevonKbWindowKeep != nil && n < AEVON_KB_MAX_WINS) {
        BOOL dup = NO;
        for (int i = 0; i < n; i++) {
            if (wins[i] == AevonKbWindowKeep) { dup = YES; break; }
        }
        if (!dup) wins[n++] = AevonKbWindowKeep;
    }
    if (outCount != NULL) *outCount = n;
    CGFloat best = 0.0;
    CGFloat bestY = 0.0;
    CGFloat bestH = 0.0;
    CGFloat bestSpacer = 0.0;
    for (int i = 0; i < n; i++) {
        CGFloat hy = 0.0;
        CGFloat hh = 0.0;
        CGFloat sp = 0.0;
        CGFloat footprint = AevonKbMeasuredCoverage(wins[i], physicalH, &hy, &hh, &sp);
        if (footprint > best) {
            best = footprint;
            bestY = hy;
            bestH = hh;
            bestSpacer = sp;
        }
    }
    if (outHostY != NULL) *outHostY = bestY;
    if (outHostH != NULL) *outHostH = bestH;
    if (outSpacer != NULL) *outSpacer = bestSpacer;
    return best;
}

// ===========================================================================
// 0.4.28 — 「第二条通道」取证：App 到底从哪儿读到键盘顶边
// ===========================================================================
//
// 312 把症状钉得很准：**QQ 完全正确；微信先对，0.5 秒后输入框自己下移、被键盘盖住。**
// 同一份日志里 App 主窗从头到尾都是 `430x717`（`probe win=430x717` 十次不变），
// 卡片没缩、scene 没动 —— 所以这不是悬浮窗的问题，是**微信自己又排了一次版**，
// 而它这次用的不是我们改过的那份通知。
//
// App 还能从两条路问到键盘，两条都不经过通知：
//   · `-[UIView keyboardLayoutGuide]`（iOS 15+）：`layoutFrame` 由 UIKit 用
//     「键盘在本窗口坐标系里的位置」现算，通知改了它也不会跟着改；
//   · 自己转窗口：`[kbWin convertRect:hostFrame toWindow:appWin]`。
// 在我们的进程里这两条只能看到**物理屏**那一套：键盘窗 `(0,0,430,932)`、
// 宿主 `573..932`。而 App 的世界只有 717 ⇒ 照它们排版会把输入条放到 573，
// 比真顶边 358 低 215 pt，整块塞进键盘里 —— 正是「下移被挡住」。
//
// 判据（一次会话两拍：0.06 s 与 1.00 s）：
//   `guide≈358`            ⇒ 指南是对的，微信那 0.5 s 不在这一层，换线；
//   `guide≈573`            ⇒ 确诊，下一版把它改成我们控制的矩形；
//   `t0=358 而 t1=573`      ⇒ 最硬的证据：UIKit 是动画收尾后才把指南落到窗坐标。
//
// ⛔ 这一版**只读**：一个新钩子都没装，`installed` 仍是 5、`mask` 仍是 `0x1f`。
// 只打日志，不改任何几何 —— QQ 这一版必须和 312 完全一样。
static volatile int AevonKbChanProbes = 0;
/// 0.4.29 — 每个进程只排一轮两拍。`DidShow` 与 `PrivateDidShow` 是同一拍发出的两条，
/// 只看 `AevonKbChanProbes == 0` 挡不住（那时探针还没跑、计数仍是 0）。
static volatile int AevonKbChanScheduled = 0;

/// 读某个视图的 `keyboardLayoutGuide.layoutFrame`。两个选择子都先问
/// `respondsToSelector:`：iOS 15 以下没有这个属性，私有改版的机型上也可能没有，
/// 问一句比 catch 一次崩溃便宜。
static BOOL AevonKbGuideFrame(UIView *owner, CGRect *out) {
    if (out != NULL) *out = CGRectZero;
    if (owner == nil || out == NULL) return NO;
    SEL selGuide = NSSelectorFromString(@"keyboardLayoutGuide");
    if (![owner respondsToSelector:selGuide]) return NO;
    id guide = ((id (*)(id, SEL))objc_msgSend)(owner, selGuide);
    if (guide == nil) return NO;
    SEL selFrame = NSSelectorFromString(@"layoutFrame");
    if (![guide respondsToSelector:selFrame]) return NO;
    *out = ((CGRect (*)(id, SEL))objc_msgSend)(guide, selFrame);
    return YES;
}

/// 两行一组：指南读到的矩形 + 窗口转换读到的矩形。配平关系：
/// `world = App 世界高 − 宿主高`；`conv.y` 若等于 `host.y` 就说明窗口转换那一路
/// 拿的是物理坐标（比 world 大 215）。
static void AevonKbProbeChannels(const char *tag) {
    if (AevonKbChanProbes >= 24) return;
    if (![NSThread isMainThread]) return;
    UIWindow *appWin = AevonKbAppMainWindow();
    if (appWin == nil) return;
    AevonKbChanProbes += 1;

    UIView *rootView = nil;
    id rvc = ((id (*)(id, SEL))objc_msgSend)(appWin, @selector(rootViewController));
    if (rvc != nil) {
        rootView = (UIView *)((id (*)(id, SEL))objc_msgSend)(rvc, @selector(view));
    }
    CGRect winGuide = CGRectZero;
    CGRect rootGuide = CGRectZero;
    BOOL hasWinGuide = AevonKbGuideFrame(appWin, &winGuide);
    BOOL hasRootGuide = AevonKbGuideFrame(rootView, &rootGuide);

    CGRect wf = [appWin frame];
    CGRect rf = rootView != nil ? [rootView frame] : CGRectZero;
    char line[288];
    snprintf(line, sizeof(line),
             "app: kb: chan %s win=%.0fx%.0f root=%.0fx%.0f guide=%.0fx%.0f@%.0f,%.0f wg=%.0fx%.0f@%.0f,%.0f has=%d%d\n",
             tag, wf.size.width, wf.size.height, rf.size.width, rf.size.height,
             rootGuide.size.width, rootGuide.size.height,
             rootGuide.origin.x, rootGuide.origin.y,
             winGuide.size.width, winGuide.size.height,
             winGuide.origin.x, winGuide.origin.y,
             (int)hasRootGuide, (int)hasWinGuide);
    AevonKbLog(line);

    UIWindow *kbWin = AevonKbKeyboardWindowLive();
    CGRect inKb = CGRectZero;
    CGRect inWin = CGRectZero;
    if (kbWin != nil) {
        UIView *host = AevonKbFindHostView(kbWin, 4);
        if (host != nil) {
            inKb = [host convertRect:[host bounds] toView:kbWin];
            // ⛔ `convertRect:toWindow:` 是 `UIWindow` 的方法，`UIView` 没有这个选择子
            // （CI 第一次就是被 `-Werror` 挡在这行）。转进主窗用 `toView:`，语义一样：
            // 目标视图的 bounds 坐标系就是它的窗口坐标系（bounds.origin 恒 0,0）。
            inWin = [host convertRect:[host bounds] toView:appWin];
        }
    }
    CGRect kbf = kbWin != nil ? [kbWin frame] : CGRectZero;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    char line2[288];
    snprintf(line2, sizeof(line2),
             "app: kb: chan %s host=%.0fx%.0f@%.0f,%.0f conv=%.0fx%.0f@%.0f,%.0f kbwin=%.0fx%.0f@%.0f,%.0f world=%.0f\n",
             tag, inKb.size.width, inKb.size.height, inKb.origin.x, inKb.origin.y,
             inWin.size.width, inWin.size.height, inWin.origin.x, inWin.origin.y,
             kbf.size.width, kbf.size.height, kbf.origin.x, kbf.origin.y,
             inKb.size.height > 8.0 ? worldH - inKb.size.height : 0.0);
    AevonKbLog(line2);
}

/// 一次会话两拍。0.06 s 抓「刚起来、微信排对了」那一拍，1.00 s 抓「已经下移」那一拍。
/// 两拍对比就能分清是我们的值不对，还是 UIKit 在动画收尾后又换了一套口径。
static void AevonKbScheduleChannelProbes(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeChannels("t0"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeChannels("t1"); });
}

// ===========================================================================
// 0.4.31 — 输入条到底被摆到哪儿了（只读，每次弹键盘两拍）
// ===========================================================================
//
// 314 的症状是「第一次正常、关掉再开就消失」，但那一版的日志配额（24 条）在第
// 一次会话里就用光了 —— **第二次开键盘发生在日志之外**，于是只能看到「键盘起来了」
// 看不到「输入条去哪儿了」。这一组把判据放在结果上，而不是推理上：
//
//   bar t=… txt=<类名> 宽x高@x,y bot=…  （窗口坐标，y 从上往下）
//   · `bot <= 键盘顶边`  ⇒ 输入条在键盘之上，正常
//   · `bot >  键盘顶边`  ⇒ 输入条压在键盘底下 —— 就是用户说的「消失」
//
// 找的是 `UITextField` / `UITextView`（评论区的输入条几乎都是这两种），深度优先
// 第一个命中。窗口坐标系里 b = 0 在上，和 `UIScreen.bounds` 同一套（钩过 ⇒ 717）。
static volatile int AevonKbBarProbes = 0;
/// 0.4.42 — 收起后的「静止位」取证配额（见通知钩子里 `down` 那一支）。
static volatile int AevonKbDownProbes = 0;

/// 0.4.34 — 收集**全部**命中，不再边扫边选。
///
/// 317 里威锋打出 `WeiFeng.FeedTextView 398x40@16,843 bot=883`：那是一个已经滚出
/// 屏幕（世界高 717）的编辑框，`bot=883` 在屏外。旧写法「按面积取最大」会把它当
/// 输入条，读数等于废的 —— 而这一组读数正是判断「抬高还是被盖」的唯一依据。
/// 所以先把候选都收下来，在窗口坐标里过滤掉不可见的，再按面积选。
#define AEVON_KB_INPUT_MAX 24
static void AevonKbCollectTextInput(UIView *root, int depth,
                                    UIView **list, int *count) {
    if (root == nil || depth < 0 || list == NULL || count == NULL) return;
    if (*count >= AEVON_KB_INPUT_MAX) return;
    NSString *cls = NSStringFromClass([root class]);
    if (cls != nil && ([cls rangeOfString:@"TextField"].location != NSNotFound
                       || [cls rangeOfString:@"TextView"].location != NSNotFound)) {
        list[*count] = root;
        *count += 1;
    }
    NSArray *subs = [root subviews];
    NSUInteger n = [subs count];
    for (NSUInteger i = 0; i < n && i < 32; i++) {
        AevonKbCollectTextInput([subs objectAtIndex:i], depth - 1, list, count);
        if (*count >= AEVON_KB_INPUT_MAX) return;
    }
}

/// 0.4.35 — 找 `isFirstResponder`。
///
/// 这是唯一「用户此刻真的在这个框里打字」的判据。文本框面积、可视性、
/// 类名都只是间接线索（318 里四个 App 全部猜错）。深度 20 够：UIKit 的
/// 输入视图层级再深也不会超过这个数，超了说明扫的是别的树。
static UIView *AevonKbFindFirstResponder(UIView *root, int depth) {
    if (root == nil || depth < 0) return nil;
    if ([root isFirstResponder]) return root;
    NSArray *subs = [root subviews];
    NSUInteger n = [subs count];
    for (NSUInteger i = 0; i < n && i < 64; i++) {
        UIView *hit = AevonKbFindFirstResponder([subs objectAtIndex:i], depth - 1);
        if (hit != nil) return hit;
    }
    return nil;
}

/// 0.4.36 — 在**全部窗口**里找第一响应者。
///
/// 0.4.35 只扫主窗，319 里威锋与酷安都打了 `view=none`。那不是「没有输入框」，
/// 是**扫的范围不对**：威锋的输入框在 `WKContentView`（WebKit 的容器，挂在它自己的
/// 子树上），酷安的输入条挂在扩展/浮层窗口，两者都不在 `rootViewController.view`
/// 的可见子树里。键盘弹着就一定有第一响应者，所以「找不到」只能说明找错地方。
///
/// `windows` 在 iOS 15 起标了 deprecated，`-Werror` 会拦，所以走 `respondsToSelector:`
/// + `objc_msgSend` 取，不直接调属性。
static UIView *AevonKbFindFirstResponderAnyWindow(UIWindow **outWin) {
    if (outWin != NULL) *outWin = nil;
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return nil;
    SEL wsel = NSSelectorFromString(@"windows");
    if (![app respondsToSelector:wsel]) return nil;
    id raw = ((id (*)(id, SEL))objc_msgSend)(app, wsel);
    if (raw == nil || ![raw isKindOfClass:[NSArray class]]) return nil;
    NSArray *wins = (NSArray *)raw;
    NSUInteger n = [wins count];
    for (NSUInteger i = 0; i < n && i < 12; i++) {
        id obj = [wins objectAtIndex:i];
        if (obj == nil || ![obj isKindOfClass:[UIWindow class]]) continue;
        UIWindow *w = (UIWindow *)obj;
        UIView *hit = AevonKbFindFirstResponder(w, 24);
        if (hit != nil) {
            if (outWin != NULL) *outWin = w;
            return hit;
        }
    }
    return nil;
}

/// 0.4.35 — scene 的**物理落点**（三级回落，全部先 `respondsToSelector:`）。
///
/// 与 `AevonKbKeyboardTree` 里那段同源，但对象是 **App 主窗自己的 scene** ——
/// 键盘窗那个 scene 答不出 frame（318 的 `tree settled scene=0x0@0,0 src=none`），
/// 而「App 的 scene 到底摆在屏幕 0..717 还是 215..932」只有主窗能答。
static BOOL AevonKbSceneRect(UIWindowScene *scene, CGRect *out, const char **outSrc) {
    if (out != NULL) *out = CGRectZero;
    if (outSrc != NULL) *outSrc = "none";
    if (scene == nil || out == NULL) return NO;
    SEL frameSel = NSSelectorFromString(@"frame");
    SEL uiSel = NSSelectorFromString(@"uiSettings");
    if ([scene respondsToSelector:uiSel]) {
        id us = ((id (*)(id, SEL))objc_msgSend)(scene, uiSel);
        if (us != nil && [us respondsToSelector:frameSel]) {
            *out = ((CGRect (*)(id, SEL))objc_msgSend)(us, frameSel);
            if (outSrc != NULL) *outSrc = "ui";
            return YES;
        }
    }
    SEL fbsSel = NSSelectorFromString(@"_scene");
    SEL setSel = NSSelectorFromString(@"settings");
    if ([scene respondsToSelector:fbsSel]) {
        id fb = ((id (*)(id, SEL))objc_msgSend)(scene, fbsSel);
        if (fb != nil && [fb respondsToSelector:setSel]) {
            id st = ((id (*)(id, SEL))objc_msgSend)(fb, setSel);
            if (st != nil && [st respondsToSelector:frameSel]) {
                *out = ((CGRect (*)(id, SEL))objc_msgSend)(st, frameSel);
                if (outSrc != NULL) *outSrc = "fbs";
                return YES;
            }
        }
    }
    return NO;
}

/// 0.4.37 — 「这个进程能看到几个『屏幕』」的只读取证。
///
/// 320 的威锋给出了一个和 guide 无关的恒等式：bar 底边 **两次会话都是 143**，
/// 而 `143 = 717 − (932 − 358)`。这个公式在全屏世界里恒等于键盘顶边（因为那时
/// `viewH == screenH`），只有在 `screenH` 被取成 932 时才会错 215。
///
/// `uin=430x717` 已经排除了 `[UIScreen mainScreen].bounds` 这一条。剩下的口子
/// 只有三个，本行把它们并排打出来：
///   nb/ns  `nativeBounds / nativeScale` **系统真值**（不走钩子）；
///   nbf    0.4.38 起：钩后 App 读到的 nativeBounds —— 应与「承载面 × ns」一致
///          （1290/3 = 430、2796/3 = 932，未钩之前 932 最廉价的来源就是它）；
///   key    `[UIApplication keyWindow]` 的类名与 frame —— 如果它是键盘窗，那 App
///          读 `keyWindow.bounds.height` 就直接拿到 932；
///   list   `[UIApplication windows]` 全表（类名 / frame / level），最多 6 条 ——
///          查「App 枚举窗口找键盘」时会不会把 932 那扇窗挑走。
static void AevonKbProbeScreenChannels(const char *tag) {
    UIScreen *main = [UIScreen mainScreen];
    if (main == nil) return;
    // 0.4.38 — `nb` 打**系统真值**（不走钩子），`nbf` 打**钩后 App 看到的**。
    // 两个并排是为了让 322 能直接判「钩子有没有生效」，而不是靠推。
    CGRect nb = AevonKbRealNativeBounds();
    CGRect nbf = [main nativeBounds];
    CGFloat ns = [main nativeScale];
    CGFloat sc = [main scale];
    UIApplication *app = [UIApplication sharedApplication];
    if (app == nil) return;
    UIWindow *key = nil;
    SEL ksel = NSSelectorFromString(@"keyWindow");
    if ([app respondsToSelector:ksel]) {
        id raw = ((id (*)(id, SEL))objc_msgSend)(app, ksel);
        if ([raw isKindOfClass:[UIWindow class]]) key = (UIWindow *)raw;
    }
    NSArray *wins = nil;
    SEL wsel = NSSelectorFromString(@"windows");
    if ([app respondsToSelector:wsel]) {
        id raw = ((id (*)(id, SEL))objc_msgSend)(app, wsel);
        if ([raw isKindOfClass:[NSArray class]]) wins = (NSArray *)raw;
    }
    char line[420];
    CGRect kf = (key != nil) ? [key frame] : CGRectZero;
    snprintf(line, sizeof(line),
             "app: kb: scr %s nb=%.0fx%.0f nbf=%.0fx%.0f ns=%.2f sc=%.2f key=%.24s %.0fx%.0f@%.0f,%.0f wins=%d\n",
             tag, nb.size.width, nb.size.height,
             nbf.size.width, nbf.size.height, (double)ns, (double)sc,
             (key != nil) ? class_getName([key class]) : "none",
             kf.size.width, kf.size.height, kf.origin.x, kf.origin.y,
             (int)[wins count]);
    AevonKbLog(line);

    char list[420] = "";
    NSUInteger n = [wins count];
    for (NSUInteger i = 0; i < n && i < 6; i++) {
        id obj = [wins objectAtIndex:i];
        if (obj == nil || ![obj isKindOfClass:[UIWindow class]]) continue;
        UIWindow *w = (UIWindow *)obj;
        CGRect f = [w frame];
        char bit[104];
        snprintf(bit, sizeof(bit), "%sw%lu=%.20s %.0fx%.0f@%.0f,%.0f L=%.0f",
                 (list[0] == '\0') ? "" : " ", (unsigned long)i,
                 class_getName([w class]),
                 f.size.width, f.size.height, f.origin.x, f.origin.y,
                 (double)[w windowLevel]);
        size_t room = sizeof(list) - strlen(list) - 1;
        if (room > 1) strncat(list, bit, room);
    }
    snprintf(line, sizeof(line), "app: kb: scr %s list=%s\n", tag,
             (list[0] != '\0') ? list : "none");
    AevonKbLog(line);
}

/// 0.4.39 — 把「窗口坐标的键盘矩形」换成「真正写进 userInfo 的那一个」。
///
/// 只在 `AevonKbScreenMode` 翻起来之后加回那 215。`AevonKbLastTop` 仍然存窗口坐标
/// （`guide` 钩子、`begin` 自建、所有探针都按窗口坐标算），否则量测会自己咬到自己。
static CGRect AevonKbReportRect(CGRect windowRect, CGFloat shift) {
    if (!AevonKbScreenMode) return windowRect;
    CGRect r = windowRect;
    r.origin.y += shift;
    return r;
}

/// 0.4.39 — 记一票「这个 App 把键盘矩形当屏幕坐标在换算」。
///
/// 判据只有一条：`d = 报出去的 kbtop − 输入条底边` 正好等于卡片偏移（±12）。
/// 两票（同一轮弹键盘的 1.7 s 与 2.9 s 两拍）才翻，且只翻一次、不往回翻。
/// 误判的代价是把输入条再往下推 215（会被键盘盖住），所以门槛必须硬。
/// 0.4.42 — 投票内核。判据一字不差，`src` 只进日志。
///
/// 0.4.42 之前只有容器那一票（`src=bar`）。Turrit 证明容器票会被容器自己的
/// 「底板」骗掉：可见输入条 `430x40@0,95`（底 135）、外面那层玻璃底板 104 高
/// 一直铺到 199 ⇒ 容器票 `d=159`（差 56，投不出），焦点票 `d=227`（差 12，正好）。
/// 0.4.43 — 计票内核：判据交给调用方，这里只管「两拍才翻、只翻一次」。
static void AevonKbScreenVoteTake(CGFloat d, const char *src) {
    if (AevonKbScreenMode || !AevonKbTakeOver) return;
    if (!AevonKbShown) return;
    if (AevonKbScreenVotes >= 2) return;
    // 一拍只记一票：0.4.42 起同一拍里「容器票」与「焦点票」可能同时成立，
    // 若都算进去就变成「一拍翻」，把原本「两拍才翻」的保险丝短路了。
    if (AevonKbVoteTick == AevonKbVoteLastTick) return;
    if (!AevonKbScreenModeEnabled()) return;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat shift = AevonKbPhysicalHeight() - worldH;
    AevonKbVoteLastTick = AevonKbVoteTick;
    AevonKbScreenVotes += 1;
    char line[200];
    if (AevonKbScreenVotes >= 2) {
        AevonKbScreenMode = 1;
        snprintf(line, sizeof(line),
                 "app: kb: mode screen shift=%.0f d=%.0f votes=%d src=%s next=screen\n",
                 shift, d, (int)AevonKbScreenVotes, src);
    } else {
        snprintf(line, sizeof(line),
                 "app: kb: mode vote d=%.0f shift=%.0f votes=%d src=%s\n",
                 d, shift, (int)AevonKbScreenVotes, src);
    }
    AevonKbLog(line);
}

/// 判据 A（「抬高」票）：输入条底边比 kbtop **高**了正好一个 shift。
/// 威锋 `d=215`、minis `d=223`、Turrit 焦点 `d=227` 都是这一族。
static void AevonKbScreenVoteCore(CGFloat d, const char *src) {
    if (!AevonKbShown) return;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat shift = AevonKbPhysicalHeight() - worldH;
    if (shift < 20.0 || shift > 400.0) return;          // 全屏 / 横屏不参与
    if (fabs(d - shift) > 12.0) return;                 // 必须**正好**错了 215
    AevonKbScreenVoteTake(d, src);
}

/// 0.4.43 — 判据 B（「被盖」票）：App 把内容底对齐到了 `世界底 − shift`。
///
/// 325/326 的 Safari 把判据 A 彻底绕开了：它的地址栏不是被「抬高 215」，
/// 而是被「压到 502」——`barBot = 500`，两个数只差 2。
///
/// 这一族怎么来的：它把 `430x359@0,358` 当成**屏幕坐标**（358..717），
/// 于是算出的键盘顶 = `717 − 215 = 502`，地址栏底就落到 500。
/// 屏幕口径的 App 我们改通知里的 y 就能治（`AevonKbReportRect` 加 shift），
/// 但它摆错之后 `d = 358 − 500 = −142`，永远落不进判据 A 的 ±12。
///
/// 换一条只跟「它摆到哪」有关的判据：
///   `d + meas − shift ≈ 0`   ⇔   `kbtop + meas − shift ≈ barBot`
/// 左边 `kbtop + meas` 就是**我们报出去的矩形底边**（正常恒等于世界底 717），
/// 减 shift 得到 502 —— 它把内容底对齐到那儿，就是在说「我以为键盘底在世界 502」。
///
/// 用 326 七家实测核对过，只有 Safari 命中：
///   Safari 500 ⇒ |−142+359−215| = 2 ✓
///   QQ 358 ⇒ 144 ✗   威锋 143 ⇒ 359 ✗   酷安 314 ⇒ 188 ✗
///   Turrit 131 ⇒ 371 ✗   minis 135 ⇒ 367 ✗   贴吧 202 ⇒ 300 ✗
/// 两道硬闸：**必须真的被盖住**（`d < −40`，排除「本来就摆得高」的 App）+
/// 量到的键盘高必须合理（`meas ≥ 40`，否则是收键盘那一拍）。
/// ⛔ 判据能成立的前提是 `kbtop + meas` 确实贴世界底；键盘浮起 / 外接键盘时它会不贴，
/// 那时 `meas` 与 `kbtop` 一起偏，这条票自然会投不出来 —— 这是想要的保守。
///
/// ⚠ **翻过去是一次带自证的实验，不是已验证的修法。**
/// 「被盖」只说明它把矩形摆错了 215，**没说该加还是该减**：
/// 威锋是「减」（`358 → 143`），Safari 若按 `WKScrollView` 那条线读是「加」（`358 → 573`），
/// 两者在 `barBot` 上都只留下一个数，分不出来。所以 `AevonKbReportRect` 照旧按
/// `+= shift` 翻，翻完由 `verdict` 那行自己判：`fit` 收工、`overshoot` 说明该改 `-=`。
static void AevonKbScreenVoteCover(CGFloat d, const char *src) {
    if (!AevonKbShown) return;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat shift = AevonKbPhysicalHeight() - worldH;
    if (shift < 20.0 || shift > 400.0) return;
    CGFloat meas = (CGFloat)AevonKbLastHeight;
    if (meas < 40.0) return;                            // 收键盘那一拍 / 量不到
    if (d > -40.0) return;                              // 没被盖，不是这一族
    if (fabs(d + meas - shift) > 12.0) return;
    AevonKbScreenVoteTake(d, src);
}

static void AevonKbScreenVote(CGFloat d, int barDepth) {
    if (barDepth < 1) return;
    AevonKbScreenVoteCore(d, "bar");
}

/// 0.4.41 — Safari 的底部地址栏：**它根本没读我们报的那个矩形**。
///
/// 324 的 Safari 每一拍都是同一组数，四个通道全对、症状却还在：
/// ```
///   note fix end=430x489@0,443 -> 430x359@0,358      （报出去的，窗口坐标）
///   chan t0  guide=430x359@0,358                     （我们的钩子）
///   tree     host=0,513,430x359 ph=60                （键盘树、可见顶 573..932）
///   fr t0.7  view=UnifiedField 342x45@28,455 bot=500 gap=-142   ← 地址栏压在键盘底下
/// ```
/// 而它自己的两处避让都停在 144 上下：`WKScrollView ai=134`、那个 932 高的
/// `UICollectionView 574−440=134`；`144 = 717 − 573`，573 正是键盘**在本进程里**
/// 的可见顶边（宿主 513 + 占位 60）。⇒ 这个 App 把「键盘窗的屏幕坐标」当成世界坐标
/// 用了：与威锋**相反方向**、同一个 215。它不会因为通知里改成 358 就好。
///
/// 这一版只做两件可验证的事，都不动键盘窗、不动 App 的视图：
///
///   · `graw`（只读）—— 布局引擎里那份 guide 矩形：直接调**被我们替换掉的原件**，
///     绕过钩子。"engine" 与 "layoutFrame" 的区别就是 0.4.37 那条已知缺口
///     （走 topAnchor 的 App 用引擎值）。`d = 引擎顶 − kbtop` 分三族：
///     `≈ +shift` ⇒ 引擎也是屏幕口径（**唯一有解的一族**）；
///     `≈ 0`     ⇒ 引擎是对的，地址栏另有来源，别乱动；
///     其它（+44/+60）⇒ 第三族，原样保留。
///
///   · 抬引擎（可回退）—— 只在第一族动手：`keyboardDismissPadding = shift`。
///     这是 UIKit 自己的「键盘上方留白」量，作用是把 guide 的顶边整体上抬，
///     不改键盘窗、不改任何业务视图；写错也只是布局偏高，删开关即回原样。
///     同一行把写入后的引擎矩形再读一次 ⇒ 日志自己回答「抬没抬动」，不靠猜。
///
/// ⛔ 别用「按包名特判 Safari」这条路：判据必须是量出来的 `d`，否则下一个同病
/// 的 App 还要再写一次特判。`kbGuidePadOff = true` 可整条关掉。
static void AevonKbGuideEngineNudge(const char *tag, UIWindow *appWin, CGFloat kbTop) {
    if (!AevonKbGuidePadOn || AevonKbShown == 0 || appWin == nil) return;
    if (AevonKbOrigGuideFrame == NULL) return;
    if (kbTop <= 0.0) return;
    SEL ksel = NSSelectorFromString(@"keyboardLayoutGuide");
    if (![appWin respondsToSelector:ksel]) return;
    id guide = ((id (*)(id, SEL))objc_msgSend)(appWin, ksel);
    if (guide == nil) return;
    SEL fsel = NSSelectorFromString(@"layoutFrame");
    if (![guide respondsToSelector:fsel]) return;
    // 引擎原值：直接调原件，绕过 0.4.37 的钩子。
    CGRect e0 = AevonKbOrigGuideFrame(guide, fsel);
    // `layoutFrame` 的坐标系是 `owningView`，判据要的是窗口坐标。
    UIView *owner = nil;
    SEL osel = NSSelectorFromString(@"owningView");
    if ([guide respondsToSelector:osel]) {
        owner = ((id (*)(id, SEL))objc_msgSend)(guide, osel);
    }
    CGRect e0w = (owner != nil) ? [owner convertRect:e0 toView:appWin] : e0;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat shift = AevonKbPhysicalHeight() - worldH;
    if (shift < 40.0 || shift > 400.0) return;
    if (kbTop >= worldH - 8.0) return;
    CGFloat d = e0w.origin.y - kbTop;
    CGFloat want = -1.0;
    if (fabs(d - shift) <= 12.0) want = shift;        // 屏幕口径 ⇒ 整条上抬 shift
    else if (fabs(d) <= 12.0) want = 0.0;             // 已经对 ⇒ 确保不残留
    CGFloat applied = -1.0;                           // -1 = 这一拍没写（第三族/读不到）
    if (want >= 0.0) {
        SEL pset = NSSelectorFromString(@"setKeyboardDismissPadding:");
        SEL pget = NSSelectorFromString(@"keyboardDismissPadding");
        if ([guide respondsToSelector:pset] && [guide respondsToSelector:pget]) {
            CGFloat cur = ((CGFloat (*)(id, SEL))objc_msgSend)(guide, pget);
            if (fabs(cur - want) > 0.5) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(guide, pset, want);
            }
            applied = want;
        } else {
            applied = -2.0;                           // 系统没有这个属性（iOS 15 以前）
        }
    }
    CGRect e1 = AevonKbOrigGuideFrame(guide, fsel);
    CGRect e1w = (owner != nil) ? [owner convertRect:e1 toView:appWin] : e1;
    char line[320];
    snprintf(line, sizeof(line),
             "app: kb: graw %s eng0=%.0fx%.0f@%.0f,%.0f eng1=%.0fx%.0f@%.0f,%.0f d=%.0f kbtop=%.0f pad=%.0f shift=%.0f\n",
             tag, e0w.size.width, e0w.size.height, e0w.origin.x, e0w.origin.y,
             e1w.size.width, e1w.size.height, e1w.origin.x, e1w.origin.y,
             d, kbTop, applied, shift);
    AevonKbLog(line);
}

/// 0.4.41 — 焦点**被盖住**时把整条祖先链并排打出来（只读）。
///
/// 触发条件刻意写成「焦点底边比键盘顶低 40 pt 以上」：那已经不是抖动，是真被盖。
/// 324 里只有 Safari 命中（地址栏 `bot=500` vs `kbtop=358`，差 142）；
/// 贴吧 `-33`、酷安/QQ 都是正的 ⇒ 不会被这条刷屏。
/// 每层打 `ci`（adjustedContentInset.bottom）/`off`/`sb`（safeAreaInsets.bottom），
/// 目的是看那个 136（= 144 − 8）究竟挂在哪一层 —— 是 Safari 自己设的 inset，
/// 还是某一层的安全区被算成了「键盘高」。
static volatile int AevonKbCoveredProbes = 0;

static void AevonKbProbeCoveredChain(const char *tag, UIView *focus, UIWindow *win, CGFloat kbTop) {
    if (focus == nil || win == nil) return;
    if (AevonKbCoveredProbes >= 4) return;
    AevonKbCoveredProbes += 1;
    CGRect uin = [[UIScreen mainScreen] bounds];
    char line[300];
    snprintf(line, sizeof(line), "app: kb: sfx %s kbtop=%.0f uin=%.0fx%.0f\n",
             tag, kbTop, uin.size.width, uin.size.height);
    AevonKbLog(line);
    UIView *node = focus;
    for (int i = 0; i < 6 && node != nil; i++) {
        CGRect r = [node convertRect:[node bounds] toView:win];
        CGFloat ai = 0.0;
        CGFloat off = 0.0;
        if ([node isKindOfClass:[UIScrollView class]]) {
            ai = [(UIScrollView *)node adjustedContentInset].bottom;
            off = [(UIScrollView *)node contentOffset].y;
        }
        snprintf(line, sizeof(line),
                 "app: kb: sfx   %d %.24s %.0fx%.0f@%.0f,%.0f ai=%.0f off=%.0f sb=%.0f\n",
                 i, class_getName([node class]), r.size.width, r.size.height,
                 r.origin.x, r.origin.y, ai, off, [node safeAreaInsets].bottom);
        AevonKbLog(line);
        node = [node superview];
    }
}

/// 0.4.43 — Filza 的「假焦点」取证。
///
/// 326 的 Filza（`com.tigisoftware.Filza`）把**用来拉键盘的隐藏输入框**留成了第一响应者：
/// ```
///   fr t4.6 view=UITextField 0x0@0,0 win=UIWindow
///   fr t4.6 anc=RenameView 430x717@0,0 > UIWindow 430x717@0,0
/// ```
/// 它的 `bounds` 是 0x0 ⇒ 以 `fr` 为基准的 `bot`/`gap`/`d` 三条全部作废，
/// `bar` 也一路 `none`（父链里没有输入条）。真正会被键盘盖住的那块编辑区是
/// Filza 自绘的，只能从**父视图的子视图清单**里认。
///
/// 只读，不动任何视图。配额 6（填满就不再打，避免长按对话框时刷屏）。
///
/// 0.4.43 起它同时是 Filza 的**投票入口**：`RenameView` 的子视图里若有一个
/// 「横满、有高度、底边正好落在 `世界底 − shift`」的面板，那就是屏幕口径
/// （判据 B）。通道和 `bar` 完全一样，只是候选来自子视图清单而不是焦点父链。
static void AevonKbProbeSiblingPanes(const char *tag, UIView *host, UIWindow *win,
                                     CGFloat kbTop) {
    if (host == nil || win == nil) return;
    if (AevonKbPaneProbes >= 6) return;
    if (![NSThread isMainThread]) return;
    AevonKbPaneProbes += 1;
    CGFloat worldW = [UIScreen mainScreen].bounds.size.width;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    NSArray *subs = [host subviews];
    NSUInteger total = [subs count];
    char list[900] = "";
    NSUInteger shown = 0;
    for (NSUInteger i = 0; i < total && shown < 10; i++) {
        UIView *sv = [subs objectAtIndex:i];
        if (sv == nil) continue;
        CGRect r = [sv convertRect:[sv bounds] toView:win];
        if (r.size.width < 20.0 || r.size.height < 8.0) continue;
        char bit[130];
        snprintf(bit, sizeof(bit), "%s%.20s %.0fx%.0f@%.0f,%.0f bot=%.0f%s",
                 (shown == 0) ? "" : " | ", class_getName([sv class]),
                 r.size.width, r.size.height, r.origin.x, r.origin.y,
                 r.origin.y + r.size.height, [sv isHidden] ? " hid" : "");
        size_t room = sizeof(list) - strlen(list) - 1;
        if (room > 1) strncat(list, bit, room);
        // 只有「像输入条」的候选才投票：横满、高 20..半屏。整屏遮罩/背景出局。
        if (![sv isHidden]
            && r.size.width >= worldW * 0.88
            && r.size.height >= 20.0
            && r.size.height <= worldH * 0.5) {
            AevonKbScreenVoteCover(kbTop - (r.origin.y + r.size.height), "pane");
        }
        shown += 1;
    }
    char line[1000];
    snprintf(line, sizeof(line), "app: kb: pane %s host=%.20s n=%d %s\n",
             tag, class_getName([host class]), (int)total,
             (list[0] != '\0') ? list : "none");
    AevonKbLog(line);
}

/// 0.4.35 — 两行只读取证：焦点视图（含父链）与 App 主窗 scene 的落点。
/// 0.4.36 — 焦点改成扫**全部窗口**，并多打一行「输入条容器」的底边。
///
/// 319 证明「焦点视图自己」不够用：
///   · 备忘录 `ICTK2TextView 430x717@0,0` —— 整屏文档视图，`gap=-359` 是必然的，不是症状；
///   · minis `PastableUITextView 374x21@28,51` —— 顶部搜索框，`gap=287` 也不是症状；
///   · 威锋/酷安 `view=none` —— 压根没扫到（输入框不在主窗可见子树里）。
/// 三种情形下 `gap` 都不能当判据，唯一能用的是**承载输入条那个横满容器的底边**：
/// QQ 正常时它恒等于 358（= 我们报出去的 kbtop），这是目前唯一的「好样本」基线。
/// 所以这里把「父链里第一个横满、且高 ≥ 20 的容器」单独打出来，`d = kbtop − barBot`：
/// 0~10 正常、>10 抬高、<0 被盖。
static void AevonKbProbeFocusAndScene(const char *tag, UIWindow *appWin,
                                      UIView *rootView, CGFloat kbTop) {
    if (appWin == nil) return;
    AevonKbVoteTick += 1;                               // 0.4.42 — 一拍一票（见 `AevonKbScreenVoteCore`）
    UIWindow *focusWin = nil;
    UIView *focus = AevonKbFindFirstResponderAnyWindow(&focusWin);
    if (focus == nil) {
        focus = AevonKbFindFirstResponder(((rootView != nil) ? rootView : appWin), 24);
        if (focus != nil) focusWin = appWin;
    }
    if (focusWin == nil) focusWin = appWin;
    CGFloat worldW = [UIScreen mainScreen].bounds.size.width;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    char line[400];
    if (focus == nil) {
        snprintf(line, sizeof(line),
                 "app: kb: fr %s view=none kbtop=%.0f\n", tag, kbTop);
        AevonKbLog(line);
    } else {
        CGRect fr = [focus convertRect:[focus bounds] toView:focusWin];
        CGFloat bot = fr.origin.y + fr.size.height;
        // `gap` 与 `bar` 同义：正 = 在键盘之上（越大越「抬高」），负 = 压在键盘底下。
        snprintf(line, sizeof(line),
                 "app: kb: fr %s view=%.28s %.0fx%.0f@%.0f,%.0f bot=%.0f gap=%.0f kbtop=%.0f win=%.22s\n",
                 tag, class_getName([focus class]),
                 fr.size.width, fr.size.height, fr.origin.x, fr.origin.y,
                 bot, kbTop - bot, kbTop, class_getName([focusWin class]));
        AevonKbLog(line);
        // 0.4.43 — `bounds` 为空 ⇒ 这是「假焦点」（Filza 的隐藏输入框）：下面所有
        // 以它为基准的判据都作废，改看父视图的子视图清单找那块真正的编辑区。
        if (fr.size.width < 1.0 || fr.size.height < 1.0) {
            AevonKbProbeSiblingPanes(tag, [focus superview], focusWin, kbTop);
        }
        // 0.4.41 — 焦点整块压在键盘底下（不是抖动）⇒ 把祖先链的 inset 摊开看。
        // 0.4.43 — 只在焦点落在主窗里才摊：跨窗口那条链是键盘自己的视图
        // （Filza 的焦点在 `UITextEffectsWindow`，摊出来全是 `UIInputSet*`，没用）。
        if (bot > kbTop + 40.0 && focusWin == appWin) {
            AevonKbProbeCoveredChain(tag, focus, focusWin, kbTop);
        }

        // 0.4.42 — 焦点自己的底边也投一票。
        //
        // Turrit（`com.seastar.turrit`，Texture）证明容器票会被「底板」骗掉：
        // 可见输入条 `430x40@0,95`（底 135）、玻璃底板 104 高一路铺到 199，
        // 容器票 `d = 358−199 = 159`（差 56，投不出），而焦点票 `d = 358−131 = 227`
        // （差 12，正好）。它自己的算式与 minis 一模一样：`135 = 358 − 215 − 8`。
        //
        // 两道闸，缺一不可：
        //   ① **只有焦点在主窗里才算** —— 换窗口换算跨不出那 215（见 `hostm` 注释）；
        //   ② **焦点底边必须落在世界上三分之一** —— 输入条跟着键盘上来时才这么高；
        //      正常 App 的输入条贴着 kbtop（`d≈0`）直接出局，不会被这条投歪。
        if (focusWin == appWin && bot < worldH / 3.0) {
            AevonKbScreenVoteCore(kbTop - bot, "focus");
        }
        // 0.4.43 — 判据 B（被盖那一族，Safari）：焦点底边落在世界下半部、
        // 且比 kbtop 低出「键盘高 − shift」时，是它把矩形当屏幕坐标用了。
        if (focusWin == appWin) {
            AevonKbScreenVoteCover(kbTop - bot, "focus");
        }

        // 父链五层 + 「输入条容器」。SwiftUI 的类名很长，每段截 28 字符，
        // 够认出「是不是整套被移动的容器」。
        char chain[300] = "";
        CGFloat barBot = -1.0;
        int barDepth = -1;
        const char *barCls = "";
        UIView *p = [focus superview];
        int i;
        for (i = 0; i < 5 && p != nil; i++) {
            CGRect pr = [p convertRect:[p bounds] toView:focusWin];
            char bit[96];
            snprintf(bit, sizeof(bit), "%s%.28s %.0fx%.0f@%.0f,%.0f",
                     (i == 0) ? "" : " > ", class_getName([p class]),
                     pr.size.width, pr.size.height, pr.origin.x, pr.origin.y);
            size_t room = sizeof(chain) - strlen(chain) - 1;
            if (room > 1) strncat(chain, bit, room);
            // 第一个「横向占满、且有高度」的祖先就是输入条/工具栏本体。
            // 排除那些整屏容器：世界高 717 的祖先不是输入条，是页面。
            //
            // 0.4.40 — 宽度门槛从 `worldW − 8` 放宽到 `worldW × 0.88`。
            // 旧门槛只认「几乎满宽」的，而 SwiftUI 自绘的输入条容器两侧各留 12：
            // 323 里 minis 的 `_UIInheritedView 406x142@12,-7`（406 / 430 = 0.944）
            // 就卡在 422 的门外，一路 `bar=none` ⇒ `AevonKbScreenVote` 拿不到 `d`，
            // 它那一份「按 932 换算」的 215 pt 永远投不出票。
            // ⛔ 放宽宽度只是让容器能被量到，判据仍是 `|d − shift| ≤ 12`：
            // 贴吧的 202（差 13）、酷安的 44（差 171）、Safari 的 −142 都不会翻。
            if (barDepth < 0
                && pr.size.width >= worldW * 0.88
                && pr.size.height >= 20.0
                && pr.size.height <= [UIScreen mainScreen].bounds.size.height * 0.5) {
                barBot = pr.origin.y + pr.size.height;
                barDepth = i;
                barCls = class_getName([p class]);
            }
            p = [p superview];
        }
        snprintf(line, sizeof(line),
                 "app: kb: fr %s anc=%s\n", tag, (chain[0] != '\0') ? chain : "none");
        AevonKbLog(line);
        if (barDepth >= 0) {
            // `d = kbtop − barBot`，与 `gap` 同向：正 = 抬高、负 = 被盖。
            // 这条取代 `gap` 当判据 —— QQ 正常时 barBot 恒 = 358 = kbtop ⇒ d=0。
            CGFloat d = kbTop - barBot;
            snprintf(line, sizeof(line),
                     "app: kb: fr %s bar=%.28s %.0f d=%.0f depth=%d\n",
                     tag, barCls, barBot, d, barDepth);
            AevonKbLog(line);
            // 0.4.39 — 顺手记一票「这个 App 是不是在按屏幕坐标换算」（见 `AevonKbScreenVote`）。
            AevonKbScreenVote(d, barDepth);
            // 0.4.43 — 同一个 `d` 再按判据 B 试一票（Safari 走这条：`d=-142`）。
            AevonKbScreenVoteCover(d, "bar");
            // 0.4.43 — 翻过去之后自己证明方向对不对（⚠ 这一步只读，不改任何几何）：
            //   `fit`        输入条底边回到 kbtop 附近 ⇒ 屏幕口径是对的，收工；
            //   `overshoot`  冲到世界底部 ⇒ 这个 App 是「加 shift」型，翻反了，
            //                下一版把 `AevonKbReportRect` 改成 `origin.y -= shift`；
            //   `mid`        两个方向都不像 ⇒ 判据 B 是巧合，回退这条票。
            if (AevonKbScreenMode && AevonKbVerdicts < 12) {
                AevonKbVerdicts += 1;
                const char *v = "mid";
                if (fabs(barBot - kbTop) <= 12.0) v = "fit";
                else if (barBot > worldH - 40.0) v = "overshoot";
                else if (barBot > kbTop) v = "cover";
                snprintf(line, sizeof(line),
                         "app: kb: verdict %s bar=%.0f kbtop=%.0f world=%.0f %s\n",
                         tag, barBot, kbTop, worldH, v);
                AevonKbLog(line);
            }
        } else {
            snprintf(line, sizeof(line),
                     "app: kb: fr %s bar=none d=999\n", tag);
            AevonKbLog(line);
        }

        // 0.4.38 — 系统应用（备忘录 / Safari / minis）量不到输入条：焦点视图要么是
        // 整屏文档视图（321 备忘录 `ICTK2TextView 430x717@0,0`），要么在屏幕顶上的
        // 搜索框（321 minis `@28,23`），要么在 WebContent 进程（Safari）。
        // 它们避让键盘的最终落点一定是**滚动视图的内边距**，那个数就是
        // 「这个 App 认为键盘有多高」，不必再去猜哪一层是输入条。
        // 判据：`ai`（adjustedContentInset.bottom）应等于 `世界高 − kbtop`（359）；
        // 大 215 ⇒ 它按 932 算；大 44/60 ⇒ 它把顶部占位也算成了键盘。
        UIScrollView *scroll = nil;
        UIView *node = focus;
        for (int up = 0; up < 8 && node != nil; up++) {
            if ([node isKindOfClass:[UIScrollView class]]) {
                scroll = (UIScrollView *)node;
                break;
            }
            node = [node superview];
        }
        if (scroll != nil) {
            UIEdgeInsets ci = [scroll contentInset];
            UIEdgeInsets ai = [scroll adjustedContentInset];
            CGPoint off = [scroll contentOffset];
            CGRect sr = [scroll convertRect:[scroll bounds] toView:focusWin];
            snprintf(line, sizeof(line),
                     "app: kb: ins %s sc=%.24s ci=%.0f ai=%.0f off=%.0f h=%.0f kb=%.0f\n",
                     tag, class_getName([scroll class]), ci.bottom, ai.bottom,
                     off.y, sr.size.height, kbTop);
            AevonKbLog(line);
        }
    }

    // 0.4.40 — `ins` 打不到的那一档（Safari 的网页输入框）走全树扫描。
    AevonKbProbeScrollViews(tag, appWin);

    UIWindowScene *scene = [appWin windowScene];
    CGRect sf = CGRectZero;
    const char *ssrc = "none";
    AevonKbSceneRect(scene, &sf, &ssrc);
    CGRect co = CGRectZero;
    if (scene != nil) {
        id space = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(coordinateSpace));
        if (space != nil) {
            co = ((CGRect (*)(id, SEL))objc_msgSend)(space, @selector(bounds));
        }
    }
    CGRect guide = CGRectZero;
    BOOL hasGuide = AevonKbGuideFrame(rootView, &guide);
    if (!hasGuide) hasGuide = AevonKbGuideFrame(appWin, &guide);
    CGRect wf = [appWin frame];
    UIEdgeInsets ins = [appWin safeAreaInsets];
    // 0.4.36 — 两个「坐标系」读数。319 里 `kb: win ask=430x932@0,0` 说明键盘窗是
    // **物理屏尺寸 (0,0,430,932)**，而 App 世界只有 717 —— 键盘窗比 App 的世界高 215。
    // UIKit 算 `keyboardLayoutGuide` 用的是「键盘顶（窗坐标）→ 世界底」，两者底座不同
    // 就会算出三种错值里的任意一种（见文首 0.4.36 那一段）。把这两个数并排打出来，
    // 320 就能一眼确认「guide 的错值是不是就是这 215 / 44 换算出来的」。
    CGRect uin = [[UIScreen mainScreen] bounds];
    UIWindow *kbw = AevonKbKeyboardWindowLive();
    CGRect kbwf = CGRectZero;
    CGRect kbwb = CGRectZero;
    if (kbw != nil) {
        kbwf = [kbw frame];
        kbwb = [kbw bounds];
    }
    snprintf(line, sizeof(line),
             "app: kb: scn %s win=%.0fx%.0f scene=%.0fx%.0f@%.0f,%.0f src=%s co=%.0fx%.0f@%.0f,%.0f guide=%.0fx%.0f@%.0f,%.0f has=%d safe=%.0f/%.0f uin=%.0fx%.0f kbw=%.0fx%.0f@%.0f,%.0f b=%.0f,%.0f gh=%d nbr=%d\n",
             tag, wf.size.width, wf.size.height,
             sf.size.width, sf.size.height, sf.origin.x, sf.origin.y, ssrc,
             co.size.width, co.size.height, co.origin.x, co.origin.y,
             guide.size.width, guide.size.height, guide.origin.x, guide.origin.y,
             (int)hasGuide, ins.top, ins.bottom,
             uin.size.width, uin.size.height,
             kbwf.size.width, kbwf.size.height, kbwf.origin.x, kbwf.origin.y,
             kbwb.origin.x, kbwb.origin.y,
             (int)AevonKbGuideHits, (int)AevonKbNativeHits);
    AevonKbLog(line);
    // 0.4.37 — 同一拍把「这个进程能看到的每一面屏」也打出来（见函数上方注释）。
    AevonKbProbeScreenChannels(tag);
}

/// 0.4.42 — 窗口清单（只读）。
///
/// Filza 的取证在 325 里整段缺 `bar`/`fr`（`chan` 与 `graw` 都在，说明探针排过队），
/// 而它家「重命名」的输入框到底在哪个窗口、谁把它托起来、离键盘多远，必须看见。
/// 这一条不依赖「扫到输入条」，也不依赖焦点一定在主窗：每个窗口连它自己的第一响应者
/// 一起打，一行一个，`bot` 按窗口坐标算（与 `note fix` 报出去的口径可比）。
static volatile int AevonKbWinListProbes = 0;

static void AevonKbProbeWindowList(const char *tag) {
    if (AevonKbWinListProbes >= 3) return;
    Class appCls = objc_getClass("UIApplication");
    if (appCls == Nil) return;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)appCls, @selector(sharedApplication));
    if (app == nil) return;
    NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
    if (wins == nil) return;
    AevonKbWinListProbes += 1;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat kbTop = AevonKbShown ? (CGFloat)AevonKbLastTop : worldH;
    char line[360];
    snprintf(line, sizeof(line), "app: kb: winl %s n=%d world=%.0f kbtop=%.0f\n",
             tag, (int)[wins count], worldH, kbTop);
    AevonKbLog(line);
    NSUInteger count = [wins count];
    for (NSUInteger i = 0; i < count && i < 6; i++) {
        id w = [wins objectAtIndex:i];
        if (![w isKindOfClass:[UIWindow class]]) continue;
        UIWindow *win = (UIWindow *)w;
        CGRect f = [win frame];
        id rvc = [win rootViewController];
        const char *rvcCls = (rvc != nil) ? class_getName([rvc class]) : "nil";
        UIView *fr = AevonKbFindFirstResponder(win, 24);
        if (fr != nil) {
            CGRect r = [fr convertRect:[fr bounds] toView:win];
            snprintf(line, sizeof(line),
                     "app: kb: winl   %d %.24s L=%.0f %.0fx%.0f@%.0f,%.0f hid=%d rvc=%.20s fr=%.24s %.0fx%.0f@%.0f,%.0f bot=%.0f\n",
                     (int)i, class_getName([win class]), [win windowLevel],
                     f.size.width, f.size.height, f.origin.x, f.origin.y,
                     (int)[win isHidden], rvcCls, class_getName([fr class]),
                     r.size.width, r.size.height, r.origin.x, r.origin.y,
                     r.origin.y + r.size.height);
        } else {
            snprintf(line, sizeof(line),
                     "app: kb: winl   %d %.24s L=%.0f %.0fx%.0f@%.0f,%.0f hid=%d rvc=%.20s fr=none\n",
                     (int)i, class_getName([win class]), [win windowLevel],
                     f.size.width, f.size.height, f.origin.x, f.origin.y,
                     (int)[win isHidden], rvcCls);
        }
        AevonKbLog(line);
    }
}

static void AevonKbProbeBarText(const char *tag) {
    if (AevonKbBarProbes >= 40) return;
    if (![NSThread isMainThread]) return;
    AevonKbProbeWindowList(tag);
    UIWindow *appWin = AevonKbAppMainWindow();
    if (appWin == nil) {
        // 0.4.42 — 以前这里静默返回，日志里就只剩「探针没跑」的错觉。
        AevonKbBarProbes += 1;
        char miss[80];
        snprintf(miss, sizeof(miss), "app: kb: bar %s appwin=none\n", tag);
        AevonKbLog(miss);
        return;
    }
    AevonKbBarProbes += 1;
    UIView *rootView = nil;
    id rvc = ((id (*)(id, SEL))objc_msgSend)(appWin, @selector(rootViewController));
    if (rvc != nil) {
        rootView = (UIView *)((id (*)(id, SEL))objc_msgSend)(rvc, @selector(view));
    }
    if (rootView == nil) rootView = appWin;
    // 0.4.32 — 取「面积最大的那个」而不是「第一个」。
    //
    // 315 里微信打出来的是 `CTRichTextView 0x0@74,-46`：命中了一个 0x0 的
    // 富文本视图，它的位置跟输入条没关系，读数等于废的。评论区输入条几乎都是
    // 有尺寸的 `UITextField` / `UITextView`，所以按面积取最大的那个；
    // 实在全是 0 尺寸就退回第一个，并用 `z=1` 标出来（那种读数不能当判据）。
    //
    // 0.4.34 — 加一道「看得见」的过滤（见 `AevonKbCollectTextInput`）。判据：
    // `!hidden`、`alpha > 0.3`、转换到窗口后**整块落在世界矩形内**。满足的第一批
    // 里按面积取最大；一个都不满足就照旧取面积最大并标 `off=1`，绝不悄悄打一条假读数。
    UIView *cands[AEVON_KB_INPUT_MAX];
    int candCount = 0;
    AevonKbCollectTextInput(rootView, 16, cands, &candCount);
    UIView *field = nil;
    CGRect fieldRect = CGRectZero;
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat bestArea = 0.0;
    CGFloat fallbackArea = 0.0;
    UIView *fallback = nil;
    CGRect fallbackRect = CGRectZero;
    for (int i = 0; i < candCount; i++) {
        UIView *v = cands[i];
        if (v == nil) continue;
        CGRect r = [v convertRect:[v bounds] toView:appWin];
        CGFloat area = r.size.width * r.size.height;
        if (!isfinite(r.origin.x) || !isfinite(r.origin.y)) continue;
        if (area <= 1.0) continue;
        if (area > fallbackArea) { fallback = v; fallbackArea = area; fallbackRect = r; }
        if ([v isHidden] || [v alpha] < 0.3) continue;
        if (r.origin.y < -1.0 || r.origin.y + r.size.height > worldH + 1.0) continue;
        if (area > bestArea) { field = v; bestArea = area; fieldRect = r; }
    }
    BOOL offScreen = NO;
    if (field == nil) {
        field = fallback;
        fieldRect = fallbackRect;
        offScreen = (fallback != nil);
    }
    CGFloat kbTop = (CGFloat)AevonKbShown ? (CGFloat)AevonKbLastTop : worldH;
    char line[360];
    if (field == nil) {
        snprintf(line, sizeof(line),
                 "app: kb: bar %s txt=none world=%.0f kbtop=%.0f vis=%d probes=%d seen=%d\n",
                 tag, worldH, kbTop, (int)AevonKbShown, (int)AevonKbBarProbes, candCount);
        AevonKbLog(line);
        // 酷安这一支就是 `txt=none`：一个文本框都没扫到，恰恰是最需要看焦点的情形。
        AevonKbProbeFocusAndScene(tag, appWin, rootView, kbTop);
        return;
    }
    // 转进窗口坐标 —— `toView:appWin` 就是窗口坐标（appWin 的 bounds.origin 恒 0,0）。
    CGRect r = fieldRect;
    CGFloat bottom = r.origin.y + r.size.height;
    // `gap = kbtop − bot`：正数 = 输入条在键盘之上（数值越大越「抬高」），
    // 负数 = 压在键盘底下（就是用户说的「被盖住 / 消失」）。这一列是判据本身。
    snprintf(line, sizeof(line),
             "app: kb: bar %s txt=%s %.0fx%.0f@%.0f,%.0f bot=%.0f kbtop=%.0f gap=%.0f ok=%d z=%d sc=%d hid=%d a=%.2f\n",
             tag, class_getName([field class]),
             r.size.width, r.size.height, r.origin.x, r.origin.y,
             bottom, kbTop, kbTop - bottom, (int)(bottom <= kbTop + 1.0),
             (int)offScreen, candCount,
             (int)[field isHidden], (double)[field alpha]);
    AevonKbLog(line);
    AevonKbProbeFocusAndScene(tag, appWin, rootView, kbTop);
}

static void AevonKbScheduleBarProbes(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeBarText("t0.7"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.70 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeBarText("t1.7"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeBarText("t2.9"); });
    // 0.4.42 — 4.6 s 再补一拍：抓「前半拍正常、后半拍自己又抬上去」那种迟到的第二次布局
    // （Turrit 用户看到的是 0.5 s，但 App 的第二段动画常常更晚），也用来确认换口径之后
    // App 有没有自己重排过一次 —— 重排了，下一拍读数就会变；没变，就只能等下一次弹键盘。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AevonKbProbeBarText("t4.6"); });
    // 0.4.41 — guide **引擎**那一拍：0.40 s 时动画已收尾、布局引擎有值；1.30 s 再补
    // 一次，抓「App 在动画后又自己排了一遍」的情形。两拍都只对「引擎顶比真顶低
    // 正好一个 shift」那一族动手（见 `AevonKbGuideEngineNudge`）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = AevonKbAppMainWindow();
        if (w != nil) AevonKbGuideEngineNudge("g0.4", w, (CGFloat)AevonKbLastTop);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = AevonKbAppMainWindow();
        if (w != nil) AevonKbGuideEngineNudge("g1.3", w, (CGFloat)AevonKbLastTop);
    });
}

// 0.4.27 — 通知里那个 frame，**y 用什么、高用什么**。
//
// 311 把两条通道的错法同时钉死了。同一拍的三组读数：
//   inter  orig=316 screen=717 kb=932 hf=1.00 formula=458 meas=386 host=546,386
//   probe  host=430x386@0,546 hostm=331
//   note   end=430x528@0,404 world=717 phys=932 shift=215 screen=1
//
// 键盘真实位置（相对 App 自己的世界）：宿主顶边 = 717 − 386 → `hostm=331`，
// 也就是键盘占 `331..717`，高 386。而通知里那个 404 是**屏幕坐标**，App 直接当
// 自己的 717 世界用 ⇒ 它以为键盘顶在 404：
//   · 306~310（0.4.22~0.4.25）用的是 404 ⇒ 输入条落在 404，比真顶边 331 低 73 pt
//     ⇒ 被键盘（含顶部工具栏）压住，正是那六版的症状；
//   · 0.4.26 只把 y 减了 shift（404−215=189），**高度还是 528**：App 让位 528，
//     输入条升到 189，比真顶边 331 高 142 pt ⇒ 中间那段是 App 自己的窗口底色，
//     就是用户看到的「抬高之后一片黑」；
// 两个症状是同一个错的两种表现：**报出去的量不是键盘真实大小**。
//
// 所以这一版不再「平移」，而是**换成量出来的真值**：
//   realH = `InputSetHostView` 的高度（386 / 431，含候选条与顶层工具栏）
//   y     = worldH − realH  ⇒  331 / 286，底边正好落在 App 世界的底 717
// 两条通道（本钩子 + `intersectionHeightForWindowScene:`）从此同值，不会再出现
// 「有时按这个排、有时按那个排」。量不到（宿主还没建）才退回 0.4.26 的平移。
//
// ⛔ 别再用 `end.size.height − shift` 当高度：528−215=313，比真实 386 少 73 ——
// 那 73 正好是键盘顶部工具栏 + 它上面那一条，等于把输入条重新塞回键盘里。
// ===========================================================================
// 0.4.29 — 判据换轴：不问「是不是屏幕坐标」，只问「键盘在不在屏幕上」
// ===========================================================================
//
// 313 把最后一块拼图补齐了。一次弹键盘，系统连发 **三批** 通知，三批的口径
// 各不相同（QQ 与微信完全一样）：
//
//   W1  end=430x456@0,476   bottom=932 = 物理屏底   meas=386   ← 0.4.27 认得出，修了
//   W2  end=430x501@0,646   bottom=1147 = 932+215   meas=431   ← 放过去了
//   W3  end=430x429@0,718   bottom=1147 = 932+215   meas=359   ← 放过去了
//
// 0.4.27 的判据是「底边贴在物理屏底（±2）」，只有 W1 命中。W2/W3 原样透传给 App：
// `end.origin.y=718`，而 App 的世界只有 717 —— **它读到「键盘顶边在 718」，等于
// 「键盘在我底下，看不见」**，于是把输入条放回窗口底部，正好被真实键盘盖住。
// 这就是微信「先对、0.5 秒后自己下移」的机制：先吃 W1（对），再吃 W2/W3（错）。
// QQ 不吃后面两批，所以它一直是对的。
//
// W2/W3 的底边正好是「world + 430 = world + 2×shift」，顶边减 430 之后落在
// 216 / 288 —— 也就是它们就是「键盘真实位置再整体下移 2×shift」。这解释了那 215，
// 但**不要去算这个 430**：换设备、换缩放、换输入法它都可能不是 430。
// 我们只需要一条不变式：
//
//   键盘只要在屏幕上，报给 App 的矩形永远 = (x, worldH − realH, w, realH)
//
// 底边恒落在 App 世界底（= 卡片底），高度恒等于量到的真实占高。这条式子对
// 932 口径、1147 口径、甚至将来别的口径都成立，因为**我们不读输入，只量事实**。
//
// 判据（是否「在屏幕上」）：
//   · 高 ≥ 40            —— 收起那一拍发的是 `(0,932,430,0)`
//   · 顶边 ≤ 屏底 − 40    —— 收起时还可能发 `(0,932,430,359)`（整块在屏底之下）
//   · 名字不含 `Hide`    —— 收起通知一律不碰，让 App 自己收输入条
// 三条都不看坐标口径，只描述「露出来没有」。
//
// ⛔ 0.4.28 取证的那条 `keyboardLayoutGuide` 线**判死**：QQ `guide=430x144@0,573`、
// 微信 `guide=430x34@0,683`，两家都不是 358，而 QQ 是完美的 ⇒ 这两家根本不读它。
// 剩下的就只有通知这一条，也就是本节这条。
//
// ⛔ 别用「底边 == 物理屏底」当判据（0.4.27 的错）：它只覆盖第一批，而**后面的
// 那两批才是把输入条按下去的手**。判据要描述事实（在不在屏幕上），不要描述坐标系。
/// 0.4.34 — 三个老键名，按**字符串**取。
///
/// `UIKeyboardBoundsUserInfoKey` / `UIKeyboardCenterEndUserInfoKey` /
/// `UIKeyboardCenterBeginUserInfoKey` 在 SDK 里标着 `deprecated: first deprecated
/// in iOS 3.2`，而 `-Werror` 会把「用了它」直接判成编译失败（run 43228527655）。
/// 它们至今仍在每一份键盘通知的 `userInfo` 里（317 的 `bo=429/456` 就是这么来的），
/// 只是官方不建议新代码使用。
///
/// 这三个常量的**值就是它自己的名字**（UIKit 里是 `NSString * const X = @"X"`），
/// 所以直接写字符串与引用常量二进制等价 —— 不是绕过检查，是同一个值。
static NSString *const AevonKbBoundsKey = @"UIKeyboardBoundsUserInfoKey";
static NSString *const AevonKbCenterEndKey = @"UIKeyboardCenterEndUserInfoKey";
static NSString *const AevonKbCenterBeginKey = @"UIKeyboardCenterBeginUserInfoKey";

static void AevonKbPostNote(id self, SEL _cmd, id name, id object, id userInfo) {
    if (AevonKbOrigPostNote == NULL) return;
    void (*orig)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))AevonKbOrigPostNote;
    if (userInfo == nil || !AevonKbTakeOver
        || ![name isKindOfClass:[NSString class]]
        || ![(NSString *)name hasPrefix:@"UIKeyboard"]) {
        orig(self, _cmd, name, object, userInfo);
        return;
    }
    NSDictionary *info = (NSDictionary *)userInfo;
    NSValue *endValue = [info objectForKey:UIKeyboardFrameEndUserInfoKey];
    if (endValue == nil || ![endValue isKindOfClass:[NSValue class]]) {
        orig(self, _cmd, name, object, userInfo);
        return;
    }
    CGRect end = [endValue CGRectValue];
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;   // 钩过 ⇒ 717
    CGFloat physicalH = AevonKbPhysicalHeight();                 // 932
    CGFloat shift = physicalH - worldH;
    // 只有「世界比屏幕矮」时才有这个差（悬浮窗卡片）。全屏 shift≈0、横屏 worldH=430
    // ⇒ 两条都不会进下面的修正分支。
    BOOL canFix = (shift > 20.0 && shift < 400.0);
    CGFloat bottom = end.origin.y + end.size.height;
    // 「键盘此刻在不在屏幕上」——不看口径，只看几何事实（见上面 0.4.29 那一段）。
    BOOL hideNote = [(NSString *)name rangeOfString:@"Hide"].location != NSNotFound;
    BOOL visible = canFix && !hideNote
                   && end.size.height >= 40.0 && end.origin.y <= physicalH - 40.0;
    // 只读取证：这一批 frame 是哪套口径。`screen`=贴物理屏底（W1）、
    // `world`=贴 App 世界底、`off`=两套都不是（W2/W3 就是这一档，且底边更低）。
    const char *inSpace = "off";
    if (fabs(bottom - physicalH) < 2.0) {
        inSpace = "screen";
    } else if (fabs(bottom - worldH) < 2.0) {
        inSpace = "world";
    }

    // 量「这一刻」键盘真实占多少 —— 这是唯一的数据来源。
    //
    // ⛔ 量不到时**不要退回 0.4.26 那种「减 215」的平移**：311 已经证明平移只改 y、
    // 不改高度，App 按错的高度让位，中间那 142 pt 就是黑屏。
    // 0.4.29 起改成「量不到就不动」，但 315 证明这条也有洞：不动 = 把系统那条
    // `y=718`（键盘在世界底之下）原样交给 App，而那一刻键盘其实好好地在屏上
    // （同一拍 `AevonKbShown=1`、`inter` 量到 359）。App 收下「键盘在窗口底下」
    // 就把输入条放回窗口底 ⇒ 被真键盘盖住。所以「不动」只在**键盘确实不在**
    // 的时候才对，而不是在我们量不到的时候。
    CGFloat realH = 0.0;
    CGFloat hostY = 0.0;
    CGFloat hostH = 0.0;
    CGFloat spacer = 0.0;
    int winCount = 0;
    const char *src = "none";
    BOOL showNote = [(NSString *)name rangeOfString:@"Show"].location != NSNotFound;
    // frame 自己说「键盘顶边在我世界的底之下」—— 一个已经在屏外的位置。
    BOOL offFrame = (end.origin.y >= worldH - 1.0);
    if (visible && [NSThread isMainThread]) {
        // `[UIApplication windows]` 只能在主线程问；不在主线程就整段跳过。
        realH = AevonKbMeasureBest(physicalH, &hostY, &hostH, &spacer, &winCount);
        // 比 App 世界还高的读数只能是量错（多窗重叠 / 非竖屏），不参与决策。
        if (realH > worldH + 1.0) realH = 0.0;
        if (realH >= 8.0) {
            src = "meas";
            AevonKbLastRealH = realH;
        } else if (AevonKbLastRealH >= 8.0 && !offFrame) {
            // 宿主还没建出来（全新进程弹第一拍）。这一批 frame 自己说「键盘在我的
            // 世界里」（顶边在 world 底之上），那就用上次已知的高顶着 ——
            // 同一台设备同一输入法，高就那么几个值。
            realH = AevonKbLastRealH;
            src = "last";
        } else if (AevonKbLastRealH >= 8.0 && showNote) {
            // 0.4.32 — `showNote` 这一支就是 315 的那个洞。
            //
            // 名字里带 `Show`（`WillShow` / `PrivateWillShow` / `DidShow` /
            // `PrivateDidShow`）说明系统在说「键盘正在显示」，可这一拍量不到
            // （宿主被拆、或拿错窗）而 frame 又说键盘在屏外 —— 两者只能有一个是真的，
            // 而「名字说显示」不会骗人：真正收起的那一批里一定带 `Hide`，早被
            // `hideNote` 挡在外面了。所以这里报上次已知的真实占高，
            // **绝不把「看不到键盘」递给 App**。
            //
            // 反过来说：不带 `Show` 又不带 `Hide` 的 `WillChangeFrame`（收起那一批的
            // 第一拍）走不到这里，原样放行 ⇒ 收起动画不受影响。
            realH = AevonKbLastRealH;
            src = "lastshow";
        }
    }

    if (AevonKbNoteNotes < 96) {
        AevonKbNoteNotes += 1;
        char line[420];
        const char *noteName = [(NSString *)name UTF8String];
        // 0.4.34 — `bo=` 是 **系统原值** 里 `UIKeyboardBoundsUserInfoKey` 的高。
        // 它和 `end` 的高一起，能直接看出这一批通知带了几条「多留」通道：
        // QQ/微信 `bo=0`（不带这个键）；威锋/贴吧/系统应用 `bo=429/456`（带，且含富余）。
        CGFloat rawBoundsH = 0.0;
        NSValue *braw = [info objectForKey:AevonKbBoundsKey];
        if (braw != nil && [braw isKindOfClass:[NSValue class]]) {
            rawBoundsH = [braw CGRectValue].size.height;
        }
        snprintf(line, sizeof(line),
                 "app: kb: note %s end=%.0fx%.0f@%.0f,%.0f bo=%.0f world=%.0f phys=%.0f shift=%.0f meas=%.0f host=%.0f,%.0f ph=%.0f n=%d in=%s src=%s fix=%d vis=%d\n",
                 noteName != NULL ? noteName : "?",
                 end.size.width, end.size.height, end.origin.x, end.origin.y,
                 rawBoundsH, worldH, physicalH, shift, realH, hostY, hostH, spacer, winCount,
                 inSpace, src, (int)visible, (int)AevonKbShown);
        AevonKbLog(line);
    }

    // 0.4.28 — 会话级两拍取证（见上面 `AevonKbProbeChannels` 那一节）。
    // 只取第一次 `DidShow`：一次弹键盘会连发 `DidShow` 与 `PrivateDidShow`，
    // 不设这道闸就会排两轮四拍，日志里配不上对。
    if (visible && AevonKbChanScheduled == 0
        && [(NSString *)name isEqualToString:UIKeyboardDidShowNotification]) {
        AevonKbChanScheduled = 1;
        AevonKbScheduleChannelProbes();
    }

    if (!visible || !AevonKbNoteFixOn || realH < 8.0) {
        // 这一拍之后键盘就不在屏上了 ⇒ 下一次升起要重新「从屏底升上来」。
        // 只认真正收起的形状：高度 < 40，或顶边落在世界底之下（含 (0,932,430,359)
        // 那种「整块在屏底下方」的收起帧）。`Hide` 那几条通知本身也走这一支。
        if (!visible && (hideNote || end.size.height < 40.0
                         || end.origin.y >= worldH - 40.0)) {
            AevonKbShown = 0;
            // 0.4.42 — 收起之后补一拍「静止位」：输入条回到哪儿、滚动视图 inset 归零没有。
            // Safari 那条线全靠这一拍分辨两种情形：
            //   · 静止位 = 世界底（638 附近）⇒ 键盘本来能让它动，是键盘给的高度不对；
            //   · 静止位 = 455（= 717 − 215 − 45）⇒ 地址栏本来就停在那儿、跟键盘无关，
            //     那是另一条 bug（App 自己留了 215 的底边），得换钩点，别再调矩形。
            if (AevonKbDownProbes < 4) {
                AevonKbDownProbes += 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ AevonKbProbeBarText("down"); });
            }
        }
        orig(self, _cmd, name, object, userInfo);
        return;
    }

    NSMutableDictionary *fixed = [info mutableCopy];
    if (fixed == nil) {
        orig(self, _cmd, name, object, userInfo);
        return;
    }
    // 三批通知口径各不相同，但真值只有一个：底边落在 App 世界底（= 卡片底），
    // 高度等于量到的占高。这条式子里没有「输入」，所以对哪一套坐标都成立。
    CGRect end2 = end;
    end2.origin.y = worldH - realH;
    end2.size.height = realH;
    // 0.4.39 — 写进去的那一份可能再加回 215（`AevonKbScreenMode`，见它的注释）。
    // `end2` 本身保持窗口坐标：`AevonKbLastTop` / `guide` / 探针全都按窗口坐标算。
    CGRect endRep = AevonKbReportRect(end2, shift);
    [fixed setObject:[NSValue valueWithCGRect:endRep] forKey:UIKeyboardFrameEndUserInfoKey];
    // 0.4.34 — **同一份 userInfo 里还有第三个矩形，0.4.33 之前一直没改。**
    //
    // `UIKeyboardBoundsUserInfoKey` 是「键盘自身多大」，坐标系是键盘本地（origin 恒 0,0），
    // 所以它不会随卡片的 215 pt 偏移而错 —— 也正因如此，它一直是**系统原值**：
    //
    //   end=430x456@0,476   ⇒ bounds 高 456
    //   end=430x429@0,718   ⇒ bounds 高 429
    //   而键盘实际只占 359 / 386 / 404 / 431
    //
    // 456 与 359 差 97、429 与 359 差 70 —— 这正是系统为「候选条 / 快捷键栏」预留、
    // 但在卡片里根本没有落出来的那一条。我们用 frame 把富余削掉了，bounds 却没削：
    // **读 bounds 的 App 仍然按 456 让位，输入条多抬 70~97 pt** —— 这就是 317 里
    // 「威锋、minis 等第三方应用的输入框会被抬高」。
    //
    // QQ / 微信读 frame（已修），所以一直正常；系统应用与论坛类老 App 读 bounds，
    // 于是一直被抬高。这也解释了为什么 0.4.27~0.4.33 连改七版落点都没治好它们：
    // 改的是一个 App 未必看的那条通道。
    //
    // ⛔ 三条通道必须同值。以后再有 App 位置不对，先数 userInfo 里有几个矩形，不要先调落点。
    NSValue *boundsValue = [info objectForKey:AevonKbBoundsKey];
    if (boundsValue != nil && [boundsValue isKindOfClass:[NSValue class]]) {
        CGRect kbBounds = CGRectMake(0.0, 0.0, end.size.width, realH);
        [fixed setObject:[NSValue valueWithCGRect:kbBounds] forKey:AevonKbBoundsKey];
    }
    // 0.4.31 — `begin` 不再用系统那个，用**我们自己上次报出去的矩形**（原因见
    // `AevonKbLastTop` 那一段：系统那个值在 503 / 718 / 1147 三套口径之间跳，
    // 关掉再开时它给出的差值会把输入条一次推出去，而且之后再也回不来）。
    CGRect begin2;
    if (AevonKbShown && AevonKbLastHeight > 8.0) {
        begin2 = CGRectMake(end.origin.x, (CGFloat)AevonKbLastTop,
                            end.size.width, (CGFloat)AevonKbLastHeight);
    } else {
        // 从屏底外升上来：底边 = 世界底、高度 0。差值正好是真实占高。
        begin2 = CGRectMake(end.origin.x, worldH, end.size.width, 0.0);
    }
    NSValue *beginValue = [info objectForKey:UIKeyboardFrameBeginUserInfoKey];
    if (beginValue != nil && [beginValue isKindOfClass:[NSValue class]]) {
        [fixed setObject:[NSValue valueWithCGRect:AevonKbReportRect(begin2, shift)]
                  forKey:UIKeyboardFrameBeginUserInfoKey];
    }
    // 0.4.34 — 老 API 的两个中心点（iOS 3.2 起就在，至今仍在 userInfo 里）。
    // 它们和 frame 是同一件事的另一种写法，留着旧值就等于留了一条「多抬 70 pt」的路。
    NSValue *centerEnd = [info objectForKey:AevonKbCenterEndKey];
    if (centerEnd != nil && [centerEnd isKindOfClass:[NSValue class]]) {
        [fixed setObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(endRep), CGRectGetMidY(endRep))]
                  forKey:AevonKbCenterEndKey];
    }
    NSValue *centerBegin = [info objectForKey:AevonKbCenterBeginKey];
    if (centerBegin != nil && [centerBegin isKindOfClass:[NSValue class]]) {
        CGRect beginRep = AevonKbReportRect(begin2, shift);
        [fixed setObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(beginRep), CGRectGetMidY(beginRep))]
                  forKey:AevonKbCenterBeginKey];
    }
    AevonKbLastTop = end2.origin.y;
    AevonKbLastHeight = end2.size.height;
    // 0.4.31 — 新的一次「弹键盘」：从 0→1 这一拍排三拍输入条读数。
    if (AevonKbShown == 0) AevonKbScheduleBarProbes();
    AevonKbShown = 1;
    if (AevonKbNoteFixes < 96) {
        AevonKbNoteFixes += 1;
        char line[320];
        snprintf(line, sizeof(line),
                 "app: kb: note fix end=%.0fx%.0f@%.0f,%.0f -> %.0fx%.0f@%.0f,%.0f src=%s rem=%.0f bgn=%.0fx%.0f@%.0f,%.0f m=%d\n",
                 end.size.width, end.size.height, end.origin.x, end.origin.y,
                 endRep.size.width, endRep.size.height, endRep.origin.x, endRep.origin.y,
                 src, worldH - end2.origin.y,
                 begin2.size.width, begin2.size.height, begin2.origin.x, begin2.origin.y,
                 (int)AevonKbScreenMode);
        AevonKbLog(line);
    }
    orig(self, _cmd, name, object, fixed);
    [fixed release];
}

// ===========================================================================
// 钩子 1：`-[_UIRemoteKeyboards intersectionHeightForWindowScene:
//             isLocalMinimumHeightOut:ignoreHorizontalOffset:]`（母版 0x5128，264 B）
// ===========================================================================
//
// 反汇编逐条（0x5128..0x5208）：
//
//   orig = orig_impl(self, _cmd, scene, out, ignore)      ; d8 = d9 = d0
//   sameApp = [_frontMost isEqualToString:_bundleId]
//   kbWin   = [self keyboardWindow]
//   if (sameApp || !kbWin) return orig                    ; 分支到 0x520c 时 d9 仍是 orig
//   _updateHeightFraction()
//   if ([scene interfaceOrientation] != 1) return 0        ; d9 在这里才被清零
//   screenH = [UIScreen mainScreen].bounds.size.height     ; 注意：此刻 bounds **已被钩**
//   kbH     = [kbWin frame].size.height
//   return (orig * screenH / kbH) * _heightFraction + kbH - screenH
//
// 指令对应：0x51f4 `fmul d0,d8,d9` / 0x51f8 `fdiv d0,d0,d3` /
//           0x5204 `fmadd d0,d0,d1,d3` / 0x5208 `fsub d9,d0,d9`。
//
// 这条钩子的输入量里有一件容易看漏的事：`screenH` 读的是**钩过的** `UIScreen.bounds`
// （717），而 `kbH` 读的是键盘窗 frame。母版里这两个数不同源（717 vs 932），公式正是
// 为这个差而存在的。
//
// ⛔ 0.4.17 起这个差在 Aevon 里**恒为 0**（display 被改成卡片尺寸后，键盘窗也是 717），
// 于是母版公式退化成恒等、`orig` 原样透传。301 已证 `orig` 是 932 那个世界的口径
// （316），透传进 717 的世界就短了 115 —— 这就是「键盘盖住输入框」。所以本版在公式
// 之后加一道「量出来的占高」，见上面 0.4.17 那一段。公式本身**一个字符没改**。
static CGFloat AevonKbIntersection(id self, SEL _cmd, id scene, BOOL *isLocal, BOOL ignore) {
    CGFloat orig = 0.0;
    if (AevonKbOrigIntersection != NULL) {
        orig = AevonKbOrigIntersection(self, _cmd, scene, isLocal, ignore);
    }
    BOOL sameApp = AevonKbIsFrontMost();
    id keyboardWindow = ((id (*)(id, SEL))objc_msgSend)(self,
                                                       NSSelectorFromString(@"keyboardWindow"));
    // 0.4.29 — 把窗留住给通知钩子用（见 `AevonKbWindowKeep` 的说明）。
    // 0.4.32 — 从「只在为 nil 时留」改成**永远留最新的那个**。315 证明这个窗会换：
    // 第一次会话里 `[UIApplication windows]` 扫到的是真的那个（host=546/386），
    // 收起再开之后就变成另一个（host=932/289），而 `[self keyboardWindow]` 一直是
    // 真的。留最新 + `AevonKbMeasureBest` 取最大 footprint，两道一起兜住。
    if (keyboardWindow != nil && [keyboardWindow isKindOfClass:[UIWindow class]]
        && AevonKbWindowKeep != keyboardWindow) {
        UIWindow *old = AevonKbWindowKeep;
        AevonKbWindowKeep = [(UIWindow *)keyboardWindow retain];
        if (old != nil) [(id)old release];
    }
    if (sameApp || keyboardWindow == nil) return orig;

    AevonKbUpdateHeightFraction();
    long orientation = ((long (*)(id, SEL))objc_msgSend)(scene,
                                                        @selector(interfaceOrientation));
    if (orientation != 1) return 0.0;

    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(keyboardWindow, @selector(frame));
    CGFloat keyboardHeight = frame.size.height;
    if (keyboardHeight < 1.0 || screenHeight < 1.0) return orig;

    CGFloat answer = (orig * screenHeight / keyboardHeight) * (CGFloat)AevonKbHeightFraction
                   + keyboardHeight - screenHeight;

    // 0.4.23 — **删掉 0.4.17 加的「量出来的占高优先」，回到母版公式一个出口。**
    //
    // 0.4.17 加那一层，是为了修「kbH=717 的世界」。那时 display 被我改成卡片尺寸，
    // `keyboardHeight` 与 `screenHeight` 双双是 717 ⇒ 母版公式退化成恒等、`orig`
    // 被原样透传成 316，比真实 386 少 70 ⇒ 键盘盖住输入框。旧世界里除了测量没有别的路。
    //
    // 0.4.21 把 display 还给系统之后，**那个前提不存在了**：`keyboardHeight` 回到
    // 物理 932，母版公式重新开始工作 —— `(316 × 717 ÷ 932) + 932 − 717 = 458`，
    // 而 458 > 431（真实占高）。母版公式的哲学本来就是「宁可留白，不盖内容」，
    // 富余的 27 pt 正好覆盖候选条后到时把键盘顶高的那一段。
    //
    // 反过来，0.4.17 那一层在现在**是有害的**：它量的是「此刻」的键盘，而键盘升起
    // 和候选条到达是两个时刻。第一次量到 386（无候选条），App 就按 386 排完版；
    // 等候选条把键盘顶到 431，App 不再重排 ⇒ 输入框被盖 45 pt。307 现场：
    //
    //   inter … formula=458 meas=386 -> 386   ← 第一次，报了无候选条的值
    //   inter … formula=458 meas=431 -> 431   ← 候选条到了，App 已经不看了
    //
    // `formula` 从头到尾是 458 没变过，它只看 `orig`（键区高），一次到位；
    // 候选条怎么变都落在那 27 pt 余量里，根本不需要 App 重排。
    //
    // 所以整层删掉。它属于「为旧地基打的补丁」，旧地基 0.4.21 已经拆了。
    //
    // ⛔ 教训：**换了地基，要回头审所有「为旧地基打的补丁」。** 0.4.21 拆地基时
    // 我只删了自己记得的那几条补偿，0.4.17 这条留在原地，又烧了一版才看出来。
    CGFloat chosen = answer;
    // 只读取证：量出来的真实占高仍然打日志，方便对照公式的余量够不够。
    CGFloat hostY = 0.0;
    CGFloat hostH = 0.0;
    CGFloat spacer = 0.0;
    CGFloat measured = AevonKbMeasuredCoverage(keyboardWindow, screenHeight, &hostY, &hostH, &spacer);
    if (measured > screenHeight) measured = screenHeight;
    if (measured > 8.0) AevonKbLastRealH = measured;

    // 0.4.27 — **两条通道必须同值。**
    //
    // 311 的病灶是「同一拍里两个数不一样」：本钩子答 458，通知那条答 528（平移后 313），
    // 而键盘真实占 386。App 用哪个，取决于它在哪一刻读哪一条 —— 这就是用户说的
    // 「有时被盖住，有时被抬高」。只要两条都等于量出来的真值，就不会再有时有时：
    //   本钩子 → 386（键盘在 App 世界里遮住多少）
    //   通知   → y=331、h=386（键盘顶边 331，底边 717）
    // 量不到（宿主未建 / 横竖屏切换的空档）才退回母版公式，公式本身一个字符没改。
    //
    // 只在「承载面比真屏矮」时接管（卡片态）。全屏 App 的 `screenHeight` 就是物理屏高，
    // 那时母版公式退化成 `orig` 透传，是母版对全屏的既有行为，不要动。
    CGFloat physicalH = AevonKbPhysicalHeight();
    BOOL hosted = (physicalH - screenHeight > 20.0 && physicalH - screenHeight < 400.0);
    if (hosted && measured > 8.0) chosen = measured;

    if (AevonKbInterNotes < 16) {
        AevonKbInterNotes += 1;
        char line[304];
        snprintf(line, sizeof(line),
                 "app: kb: inter orig=%.0f screen=%.0f kb=%.0f hf=%.2f formula=%.0f meas=%.0f host=%.0f,%.0f ph=%.0f -> %.0f\n",
                 orig, screenHeight, keyboardHeight, AevonKbHeightFraction,
                 answer, measured, hostY, hostH, spacer, chosen);
        AevonKbLog(line);
    }
    // 0.4.24 — 只读取证：App 收到这个值之后，到底给键盘留了多少。
    // 放在返回值之前，是因为 App 通常是「拿到 intersection 之后」才去改
    // scrollView 的 inset，第一拍可能还是上一轮的状态；配额 3 次横跨三次调用，
    // 恰好覆盖 386 / 431 / 359 三种键盘形态，够对照。
    AevonKbProbeAppInsets(keyboardWindow);
    return chosen;
}

// ===========================================================================
// 0.4.14 — 键盘窗视图树取证（**只读，不改任何几何**）
// ===========================================================================
//
// 0.4.11 / 0.4.12 / 0.4.13 三版都死在同一处：屏幕 717 那条硬切线。而三版的读数
// （`win frame=` / `bnd=` / `root=`）每次都显示「我们写的三层几何完全正确」——
// 说明裁切或平移发生在**窗口内部某一层**，不在我们下笔的那几层。
//
// 这组读数只做一件事：把键盘窗真实的视图树按层打出来（类名 / frame / bounds.origin /
// clipsToBounds / 子视图数），并附上 window 自身、它所在的 windowScene、以及 App 主窗
// 的矩形。下一份日志就能指认「是谁把内容裁在 717」，不用再从截图反推。
//
// 配额：每进程 3 次、深度 3、总行 20。一次输入会话最多三屏，日志不会变负担。
static volatile int AevonKbTreeDumps = 0;
static UIWindow *AevonKbTreeTarget = nil;

static void AevonKbDumpView(UIView *view, int depth, int *budget) {
    if (view == nil || budget == NULL || *budget <= 0 || depth > 3) return;
    *budget -= 1;
    CGRect frame = view.frame;
    CGRect bounds = view.bounds;
    NSUInteger count = [[view subviews] count];
    char line[240];
    snprintf(line, sizeof(line),
             "app: kb: tree %*s%s f=%.0f,%.0f,%.0fx%.0f b=%.0f,%.0f,%.0fx%.0f cl=%d n=%d\n",
             depth * 2, "", class_getName([view class]),
             frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
             bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
             [view clipsToBounds] ? 1 : 0, (int)count);
    AevonKbLog(line);
    for (UIView *child in [view subviews]) {
        AevonKbDumpView(child, depth + 1, budget);
    }
}

static void AevonKbDumpChain(UIWindow *window, const char *why) {
    if (window == nil || why == NULL) return;
    if (AevonKbTreeDumps >= 3) return;
    AevonKbTreeDumps += 1;
    char line[256];
    CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
    CGRect wb = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
    snprintf(line, sizeof(line),
             "app: kb: tree %s win=%.0fx%.0f@%.0f,%.0f bnd=%.0f,%.0f,%.0fx%.0f lvl=%.0f\n",
             why, wf.size.width, wf.size.height, wf.origin.x, wf.origin.y,
             wb.origin.x, wb.origin.y, wb.size.width, wb.size.height,
             ((CGFloat (*)(id, SEL))objc_msgSend)(window, @selector(windowLevel)));
    AevonKbLog(line);

    UIWindowScene *scene = ((id (*)(id, SEL))objc_msgSend)(window, @selector(windowScene));
    if (scene != nil) {
        // 0.4.15 — scene 的**物理落点**（origin 才是关键）。
        //
        // 0.4.14 只试了 `-_frame`，`UIWindowScene` 没有这条选择子 ⇒ 每份日志都是
        // `scene=0x0@0,0`，等于什么都没读到。而「键盘悬空 215 + 下面透明」这个形状，
        // 唯一还没被排除的变量就是它：App 的承载面到底住在屏幕 0..717 还是 215..932。
        //
        // 三级回落，全部先 `respondsToSelector:` 再读（问是免费的，裸调会杀进程）：
        //   ① `-uiSettings` → `-frame`        （UIScene 私有，最常见）
        //   ② `-_scene` → `-settings` → `-frame`（FBScene 这一层，兜底）
        //   ③ `-_frame`                        （0.4.14 那条，多半不答）
        // 日志里带 `src=` 指明哪一级命中，拿不到就写 `none` —— 不拿 0 冒充。
        CGRect sf = CGRectZero;
        const char *src = "none";
        SEL uiSel = NSSelectorFromString(@"uiSettings");
        SEL frameSel = NSSelectorFromString(@"frame");
        if ([scene respondsToSelector:uiSel]) {
            id us = ((id (*)(id, SEL))objc_msgSend)(scene, uiSel);
            if (us != nil && [us respondsToSelector:frameSel]) {
                sf = ((CGRect (*)(id, SEL))objc_msgSend)(us, frameSel);
                src = "ui";
            }
        }
        if (src[0] == 'n') {
            SEL fbsSel = NSSelectorFromString(@"_scene");
            SEL setSel = NSSelectorFromString(@"settings");
            if ([scene respondsToSelector:fbsSel]) {
                id fb = ((id (*)(id, SEL))objc_msgSend)(scene, fbsSel);
                if (fb != nil && [fb respondsToSelector:setSel]) {
                    id st = ((id (*)(id, SEL))objc_msgSend)(fb, setSel);
                    if (st != nil && [st respondsToSelector:frameSel]) {
                        sf = ((CGRect (*)(id, SEL))objc_msgSend)(st, frameSel);
                        src = "fbs";
                    }
                }
            }
        }
        if (src[0] == 'n') {
            SEL plain = NSSelectorFromString(@"_frame");
            if ([scene respondsToSelector:plain]) {
                sf = ((CGRect (*)(id, SEL))objc_msgSend)(scene, plain);
                src = "raw";
            }
        }
        CGRect cb = CGRectZero;
        id space = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(coordinateSpace));
        if (space != nil) {
            cb = ((CGRect (*)(id, SEL))objc_msgSend)(space, @selector(bounds));
        }
        snprintf(line, sizeof(line),
                 "app: kb: tree %s scene=%.0fx%.0f@%.0f,%.0f src=%s co=%.0fx%.0f@%.0f,%.0f\n",
                 why, sf.size.width, sf.size.height, sf.origin.x, sf.origin.y, src,
                 cb.size.width, cb.size.height, cb.origin.x, cb.origin.y);
        AevonKbLog(line);
    }

    // 0.4.16 — 键盘窗在**屏幕坐标空间**里的绝对矩形。
    //
    // 300 已经证到：`-bounds` 的系统原值就是 430x717（我们的钩子是空操作）、
    // scene 落点最终确实是 215、root=窗=717 —— 三个数全对而画面悬空。于是只剩
    // 「内容最终被摆在哪」这一个变量。`UIScreen.coordinateSpace` 是公开的空间，
    // 跨窗口换算正是它的用途；万一 UIKit 拒绝跨空间，`convertRect:toCoordinateSpace:`
    // 会抛 NSException，所以整段包在 @try 里 —— 取证不许杀进程。
    //
    // 判据：`abs` 的 y = 215 ⇒ App 的世界确实从物理 215 开始，键盘贴底是对的，
    // 病根在别处；y = 0 或 331 ⇒ App 的世界从物理 0 开始，键盘悬空 215 是必然。
    {
        Class scrClass = (Class)objc_getClass("UIScreen");
        id scr = nil;
        if (scrClass != Nil && [(id)scrClass respondsToSelector:@selector(mainScreen)]) {
            scr = ((id (*)(id, SEL))objc_msgSend)((id)scrClass, @selector(mainScreen));
        }
        SEL spaceSel = NSSelectorFromString(@"coordinateSpace");
        if (scr != nil && [scr respondsToSelector:spaceSel]) {
            id space = ((id (*)(id, SEL))objc_msgSend)(scr, spaceSel);
            if (space != nil) {
                CGRect absBox = CGRectZero;
                BOOL ok = NO;
                @try {
                    absBox = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(
                        window, @selector(convertRect:toCoordinateSpace:), wb, space);
                    ok = YES;
                } @catch (NSException *e) {
                    (void)e;
                    ok = NO;
                }
                if (ok) {
                    snprintf(line, sizeof(line),
                             "app: kb: tree %s abs=%.0fx%.0f@%.0f,%.0f\n",
                             why, absBox.size.width, absBox.size.height,
                             absBox.origin.x, absBox.origin.y);
                } else {
                    snprintf(line, sizeof(line), "app: kb: tree %s abs=err\n", why);
                }
                AevonKbLog(line);
            }
        }
    }

    // App 主窗：它的尺寸就是 App 认为的屏幕。与键盘窗并排看，才知道谁短了。
    Class appClass = (Class)objc_getClass("UIApplication");
    id app = nil;
    if (appClass != Nil && [(id)appClass respondsToSelector:@selector(sharedApplication)]) {
        app = ((id (*)(id, SEL))objc_msgSend)((id)appClass, @selector(sharedApplication));
    }
    if (app != nil && [app respondsToSelector:@selector(windows)]) {
        NSArray *all = ((id (*)(id, SEL))objc_msgSend)(app, @selector(windows));
        for (id item in all) {
            if (item == window) continue;
            CGRect mf = ((CGRect (*)(id, SEL))objc_msgSend)(item, @selector(frame));
            snprintf(line, sizeof(line),
                     "app: kb: tree %s main=%.0fx%.0f@%.0f,%.0f %s\n",
                     why, mf.size.width, mf.size.height, mf.origin.x, mf.origin.y,
                     class_getName([item class]));
            AevonKbLog(line);
            break;
        }
    }

    UIViewController *root = ((id (*)(id, SEL))objc_msgSend)(window,
                                                            @selector(rootViewController));
    UIView *top = window;
    if (root != nil) {
        UIView *rv = [root view];
        if (rv != nil) top = rv;
    }
    int budget = 20;
    AevonKbDumpView(top, 0, &budget);
}

static void AevonKbDumpTick(void *context) {
    (void)context;
    AevonKbDumpChain(AevonKbTreeTarget, "settled");
}

// ===========================================================================
// 钩子 2：`+[UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:]`
//         （母版 0x5230，512 B）
// ===========================================================================
//
//   win = orig_impl(cls, _cmd, screen, create)
//   if (!win) return nil
//   root = [win rootViewController]
//   _hookUIScreen = 0                        ← 先关自己的 bounds 钩子，读真值
//   main = [UIScreen mainScreen]
//   if (sameApp) {
//       [win setFrame:[main bounds]]; [win setBounds:[win frame]]; scale = (1,1)
//   } else if (_appScene.interfaceOrientation == 1) {
//       H = [main bounds].size.height
//       [win setFrame:(x, y, w, H)]; [win setBounds:[win frame]]; scale = (1,1)
//   } else {
//       H = [main bounds].size.height; W = [main bounds].size.width
//       [win setFrame:(-0.5H + 0.5W, 0, H, H)]; [win setBounds:(0,0,H,H)]; scale = (0,0)
//   }
//   [root.view setTransform:scale]
//   _hookUIScreen = 1
//   return win
//
// 要点（别自作聪明去「优化」）：
//   · **只在建窗这一拍**写几何。之后键盘位置由系统自己摆，母版不介入。
//   · 竖屏两条分支的差别只有一样：sameApp 用原 bounds 的四个分量，非 sameApp
//     保留 x/y/w、只把高改成 H。二者在真屏上等价 —— 它就是「确保键盘窗是真屏尺寸」。
//   · 横屏把内容 scale 到 0（不显示）。这是母版的选择，不是 bug。
static id AevonKbRemoteWindow(id self, SEL _cmd, UIScreen *screen, BOOL create) {
    id window = nil;
    if (AevonKbOrigRemoteWindow != NULL) {
        window = AevonKbOrigRemoteWindow(self, _cmd, screen, create);
    }
    if (window == nil) return nil;

    UIViewController *root = ((id (*)(id, SEL))objc_msgSend)(window,
                                                            @selector(rootViewController));
    // 母版在这里直接读 `_appScene`。它由 `0x54f4`（bounds 钩子）懒填充，正常情况
    // 下早就不是 nil 了；但「建键盘窗」这一拍如果恰好还没问过 `bounds`（后台 App
    // 第一次被托起来、或者 scene 刚换过），`_appScene` 会是 nil ⇒ 走进下面那个
    // 横屏分支 ⇒ `setTransform:` scale 到 0 ⇒ **键盘整块不显示**。
    //
    // 这里只是把母版在 `0x54f4` 里做的那件事提前做一次（同一个 `_mainScene`），
    // 不是新机制。取不到仍然保持 nil，走母版原路。
    if (AevonKbAppScene == nil) {
        AevonKbAppScene = AevonKbMainScene();
    }
    // 0.4.21 — 建窗这一拍读**真值**（母版 `_hookUIScreen = 0`）。
    //
    // 0.4.11~0.4.20 在这里读的是承载面（717），因为当时 `displayConfiguration` 已被
    // 我们改成 717，「系统值」本身就不存在了。0.4.21 把 display 还给系统之后，
    // 这一拍读到的就是物理屏 (0,0,430,932) —— 母版那句的语义完整回来了。
    AevonKbWinReal += 1;
    UIScreen *main = [UIScreen mainScreen];
    CGAffineTransform scale = CGAffineTransformMakeScale(1, 1);

    // 系统建好这一拍的原框 —— **只用于证词，不参与计算**（0.4.14 起）。
    CGRect orig = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));

    // 0.4.14 / 0.4.21 — **窗就用 `[main bounds]`，一个分量都不改。**
    //
    // 母版两条竖屏分支（`0x5280` / `0x52d8`）合起来只有一句话：把窗设成
    // `[UIScreen mainScreen].bounds`（`_hookUIScreen` 关着那一拍读到的矩形）。
    // 0.4.21 的世界里这一拍读到的是**物理屏** (0,0,430,932)，语义与母版逐字相同：
    // 「键盘窗 = App 的整个屏幕」。
    CGRect box = [main bounds];          // 真值 ⇒ 物理屏 (0,0,430,932)
    CGFloat width = box.size.width;
    CGFloat height = box.size.height;

    CGRect asked = CGRectZero;
    // ⛔ 0.4.20 在这里加过一个 `shiftY = 物理屏高 − 承载面高 = 215`，把窗挪到 215..932。
    //
    // 它修掉了「悬空」（窗底终于贴到屏底），代价是窗的**下半 215 pt 被推出了 App 的
    // 世界** —— 0.4.20 的世界只有 717 高，所以那 215 pt 直接越界，系统裁掉 ⇒
    // 用户 305 报的「贴着底部、但下半透明」。位移不是解法，它只是把「键盘不该被塞进
    // 一个 717 高的世界」这件事换了个方向又证明了一遍。0.4.21 整段删掉。
    int dy = 0;                          // 恒 0：证实词用，几何上不再有任何位移
    if (AevonKbIsFrontMost()
        || (AevonKbAppScene != nil && [AevonKbAppScene interfaceOrientation] == 1)) {
        // 竖屏（母版 0x5280 / 0x52d8 两路的合并语义）：窗 = 整个物理屏。
        asked = CGRectMake(box.origin.x, box.origin.y, width, height);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setFrame:), asked);
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        // ⛔ 0.4.13 — bounds **只给尺寸，origin 必须是 (0,0)**。
        //
        // 母版原文是 `[win setBounds:[win frame]]`，那行能成立是因为母版这一拍
        // `_hookUIScreen = 0`、系统原框原点恒为 (0,0) ⇒ `frame.origin` 是 0，
        // `bounds.origin` 也就是 0 —— 等价于「只改尺寸」。
        //
        // 0.4.12 把窗原点挪到 y=215（让窗底对齐屏底），照抄这一行就把
        // `bounds.origin` 写成了 (0,215)。bounds.origin 是**内容坐标系**的偏移，
        // 于是窗里所有内容整体上移 215：本该渲染在屏幕 573..932 的键盘画到了
        // 358..717，717 以下既没有像素、也不接收触摸 —— 这就是 Aevon(297) 的
        // 「只显示上半部分、下半透明无法触摸」。窗自己的 frame 仍是 215..932，
        // 所以从 `win frame=` 那行完全看不出异常。
        //
        // 正确写法：bounds 尺寸 = frame 尺寸、origin 归零。与母版语义等价
        // （母版 origin 本来就是 0），不是新机制。
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setBounds:),
                                                 CGRectMake(0, 0,
                                                            now.size.width,
                                                            now.size.height));
    } else {
        // 横屏：母版把内容 scale 到 0（不显示）。
        asked = CGRectMake(-0.5 * height + 0.5 * width, 0.0, height, height);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setFrame:), asked);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(window, @selector(setBounds:),
                                                 CGRectMake(0, 0, height, height));
        scale = CGAffineTransformMakeScale(0, 0);
    }

    if (root != nil) {
        UIView *view = [root view];
        if (view != nil) {
            ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(view,
                                                                @selector(setTransform:),
                                                                scale);
            // root view 的高度必须等于窗的高度，否则它就是那把裁刀
            // （0.4.11 的 `win frame=430x932@0,0` + root 717 ⇒ 键盘切在屏幕 717）。
            CGRect want = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
            ((void (*)(id, SEL, CGRect))objc_msgSend)(view, @selector(setFrame:), want);
        }
    }
    AevonKbWinReal -= 1;
    AevonKbHookUIScreen = YES;

    if (AevonKbWinNotes < 6) {
        AevonKbWinNotes += 1;
        CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(frame));
        char line[320];
        snprintf(line, sizeof(line),
                 "app: kb: win frame=%.0fx%.0f@%.0f,%.0f scale=%.1f hosted=%d\n",
                 now.size.width, now.size.height, now.origin.x, now.origin.y,
                 scale.a, 1 - (int)AevonKbIsFrontMost());
        AevonKbLog(line);
        // 0.4.21 — 各数分开写，下一份日志能直接指出是哪一环断的：
        //   orig  系统建好这一拍的原框（期望 430x932@0,0）
        //   host  我们要求窗的宽×高（期望 430x932 = 物理屏）
        //   phys  物理屏高（与 host 同源，0.4.21 起两者应当相等）
        //   ask   我们要求窗口多大（期望 430x932@0,0）
        //   frame 系统最终给的框（比 ask 矮 ⇒ 被夹；`dy` 恒 0，恒等式证词）
        // 0.4.13 — 再补两个：
        //   bnd   **窗的 bounds.origin，必须是 0,0**（非 0 ⇒ 整窗内容被平移，Aevon(297)）
        //   root  root view 的 frame，尺寸必须等于 frame、origin 必须是 0,0
        CGRect bnd = ((CGRect (*)(id, SEL))objc_msgSend)(window, @selector(bounds));
        CGRect rvf = CGRectZero;
        if (root != nil) {
            UIView *probe = [root view];
            if (probe != nil) {
                rvf = ((CGRect (*)(id, SEL))objc_msgSend)(probe, @selector(frame));
            }
        }
        CGRect nativeBox = AevonKbRealNativeBounds();
        CGFloat nativeScale = [main nativeScale];
        CGFloat phys = nativeScale > 0.0 ? nativeBox.size.height / nativeScale : height;
        snprintf(line, sizeof(line),
                 "app: kb: win orig=%.0fx%.0f@%.0f,%.0f host=%.0fx%.0f phys=%.0f ask=%.0fx%.0f@%.0f,%.0f frame=%.0fx%.0f@%.0f,%.0f dy=%d bnd=%.0f,%.0f root=%.0fx%.0f@%.0f,%.0f\n",
                 orig.size.width, orig.size.height, orig.origin.x, orig.origin.y,
                 width, height, phys,
                 asked.size.width, asked.size.height, asked.origin.x, asked.origin.y,
                 now.size.width, now.size.height, now.origin.x, now.origin.y,
                 dy, bnd.origin.x, bnd.origin.y,
                 rvf.size.width, rvf.size.height, rvf.origin.x, rvf.origin.y);
        AevonKbLog(line);
    }
    // 0.4.14 — 0.55 s 后打一次「落地态」的视图树。键盘窗由 UIKit 长期持有，
    // 这个静态槽只是记「打哪一扇窗」，不增加它的生命周期。
    if (AevonKbTreeDumps < 3) {
        AevonKbTreeTarget = (UIWindow *)window;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(0.55 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, AevonKbDumpTick);
    }
    return window;
}

// ===========================================================================
// 钩子 3：`-[FBSWorkspaceScenesClient sceneID:updateWithSettingsDiff:
//             transitionContext:completion:]`（母版 0x5430，196 B）
// ===========================================================================
//
//   _updateInit169();
//   _upadteFrontMost();
//   _hookUIScreen = ![_frontMost isEqualToString:_bundleId];
//   return orig_impl(...);
//
// 它是 `_hookUIScreen` 的**常规刷新源**。母版真正的功力在这一条：开关不是装钩子
// 时算一次，而是每次 scene settings 变化都重算 —— 「同寿命刷新源」，所以它永远
// 跟得上「这个 App 现在是不是被浮起来的」。
static void AevonKbSceneSettings(id self, SEL _cmd, id sceneID, id diff,
                                 id transitionContext, id completion) {
    AevonKbUpdateTakeOver();
    AevonKbHookUIScreen = !AevonKbIsFrontMost();
    if (AevonKbShellNotes < 6) {
        AevonKbShellNotes += 1;
        char line[160];
        snprintf(line, sizeof(line), "app: kb: shell hook=%d takeOver=%d\n",
                 (int)AevonKbHookUIScreen, (int)AevonKbTakeOver);
        AevonKbLog(line);
    }
    if (AevonKbOrigSceneSettings != NULL) {
        AevonKbOrigSceneSettings(self, _cmd, sceneID, diff, transitionContext, completion);
    }
}

// ===========================================================================
// 安装（母版 0x4f4c）
// ===========================================================================
//
// 母版顺序：bundleId → _inject → _ringAppsContains → 五条 addHook →
//           notify_register_dispatch → 状态初始化。
//
// Aevon 的第二道闸换成「宿主真的托起来了」（0.4.10，理由见文首）：调用点只有
// `AevonKbEnsureInstalled`，而它先看 `AevonBandHostedNow()`。所以进到本函数时
// 这个 App **已经**在卡片里，不必再判名单。

/// 装一条实例方法。返回**原件**（装不上返回 NULL）。
///
/// 用 `method_setImplementation` 的返回值取原件，而不是先 `method_getImplementation`
/// 再写 —— 后者在「同一进程里这条方法已经被别人换过」时拿到的是别人那一版，
/// 我们的 return 路径就会跳过它。母版用 Orion 的 `addHook` 拿原件，行为等价。
static IMP AevonKbInstallInstance(Class cls, SEL sel, IMP replacement) {
    if (cls == Nil || sel == NULL) return NULL;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) return NULL;
    return method_setImplementation(method, replacement);
}

static IMP AevonKbInstallClass(Class cls, SEL sel, IMP replacement) {
    if (cls == Nil || sel == NULL) return NULL;
    Method method = class_getClassMethod(cls, sel);
    if (method == NULL) return NULL;
    return method_setImplementation(method, replacement);
}

/// 只在**类自己拥有**这条方法时换实现；否则用 `class_addMethod` 加一条遮蔽父类的。
///
/// 这条是为 `UIKeyboardLayoutGuide -layoutFrame` 写的。`layoutFrame` 声明在
/// `UILayoutGuide` 上，如果 `UIKeyboardLayoutGuide` 自己没实现它，
/// `class_getInstanceMethod` 返回的是**父类那个 Method** —— 直接
/// `method_setImplementation` 会在 `UILayoutGuide` 上打洞，整个进程所有布局指南
/// （输入框、占位、第三方自定义 guide）全都跟着变。那不是「修键盘」，那是改 UIKit。
static IMP AevonKbInstallOwn(Class cls, SEL sel, IMP replacement) {
    if (cls == Nil || sel == NULL) return NULL;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) return NULL;
    IMP old = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (types == NULL) return NULL;
    // 新增成功 ⇒ 类原本没有自己那一版，原实现仍在父类，直接返回刚才取到的 old。
    if (class_addMethod(cls, sel, replacement, types)) return old;
    return method_setImplementation(method, replacement);
}

// ---------------------------------------------------------------------------
// 钩子 6：`-[UIKeyboardLayoutGuide layoutFrame]`（0.4.37 新增，母版没有）
// ---------------------------------------------------------------------------
//
// 320 的 54 条 guide 读数只有 3 条是对的，其余分成两族（见文首 0.4.37 那一段），
// 两族都是「键盘窗（430x932@0,0）」与「App 的 scene（430x717@0,215）」这条 215 的
// 缝算出来的。我们改不了那两块几何（各有三次翻车记录），但可以改**读出来那一层**：
// 交给 App 的矩形，就用我们已经在通知里报出去的那个。
//
// 只做三件事：
//   · 键盘不在屏上（`AevonKbShown == 0`）⇒ 原值返回，绝不介入「没有键盘」的布局；
//   · 只处理 **level 0 的窗口**（App 自己的窗）。键盘窗里的 guide 是系统在用的，不碰；
//   · 换算进 `owningView` 的坐标系 —— `layoutFrame` 的定义就是这个坐标系，
//     直接给窗口坐标会在 owner 有偏移时又错一次。
static CGRect AevonKbGuideLayoutFrame(id self, SEL _cmd) {
    CGRect orig = CGRectZero;
    if (AevonKbOrigGuideFrame != NULL) orig = AevonKbOrigGuideFrame(self, _cmd);
    if (!AevonKbGuideFixOn || AevonKbShown == 0) return orig;
    UIView *owner = nil;
    SEL osel = NSSelectorFromString(@"owningView");
    if ([self respondsToSelector:osel]) {
        owner = ((id (*)(id, SEL))objc_msgSend)(self, osel);
    }
    if (owner == nil) return orig;
    UIWindow *win = [owner window];
    if (win == nil) return orig;
    if ([win windowLevel] != 0.0) return orig;          // 键盘窗 / 状态栏窗不是 0
    CGFloat worldH = [UIScreen mainScreen].bounds.size.height;
    CGFloat top = (CGFloat)AevonKbLastTop;
    // 顶边必须落在世界里面，否则宁可返回原值 —— 这一条挡的是「通知还没来、
    // `AevonKbShown` 却是旧值」那种脏状态。
    if (top <= 0.0 || top >= worldH - 8.0) return orig;
    CGRect want = CGRectMake(0.0, top, [win bounds].size.width, worldH - top);
    want = [owner convertRect:want fromView:win];
    AevonKbGuideHits += 1;
    return want;
}

static void AevonKbNativeInstall(void) {
    // 无论后面装成没装成，这一进程只做这一次决定。
    AevonKbInstalled = 1;
    AevonKbBundleId = [[[NSBundle mainBundle] bundleIdentifier] copy] ?: @"";
    // 母版 `_ringAppsContains` 的第一条就是排除 springboard（0x4f4c 的 0x4f9c
    // 分支）。AevonApp.dylib 的 Filter 是 `com.apple.UIKit`，它**也会**加载进
    // SpringBoard —— 进程内的 `AevonWorthInjecting()` 已经三重排除了那个进程，
    // 这里再挡一道：`UIScreen.bounds` 装进桌面的代价是整台机器黑屏，不值得
    // 只靠上游那一处判据。
    if ([AevonKbBundleId isEqualToString:@"com.apple.springboard"]) {
        AevonKbLog("app: kb: native skipped, springboard\n");
        return;
    }
    // 开关（母版 `_inject` + `SettingMask` bit31）。这里已经是主队列、App 跑起来
    // 之后了，读盘安全 —— 0.4.9 那条「构造期不读盘」的约束仍然成立：构造函数
    // 走的是 `AevonKbRefreshShell` 的 `!AevonKbInstalled` 那一支，纯内存判断。
    AevonKbInjectApp = AevonKbBridgeEnabled();
    AevonKbTakeOver = AevonKbInjectApp;
    AevonKbShellRead = 1;
    // 0.4.26 — 通知帧校正的开关。走盘只在这一拍（主队列、App 已跑起来），
    // 钩子热路径上只读这个 int。
    AevonKbNoteFixOn = (AevonKbInjectApp && AevonKbNoteFixEnabled()) ? 1 : 0;
    // 0.4.37 — guide 那条线单独一个开关（`kbGuideFixOff`）。
    AevonKbGuideFixOn = (AevonKbInjectApp && AevonKbGuideFixEnabled()) ? 1 : 0;
    // 0.4.38 — `nativeBounds` 那条线也单独一个开关（`kbNativeOff`）。
    AevonKbNativeFixOn = (AevonKbInjectApp && AevonKbNativeFixEnabled()) ? 1 : 0;
    // 0.4.41 — guide **引擎**抬升（`kbGuidePadOff`）。与 0.4.37 的 guide 读取钩子
    // 是两件事：那条改「读出来的矩形」，这条改「引擎排出来的矩形」。
    AevonKbGuidePadOn = (AevonKbInjectApp && AevonKbGuidePadEnabled()) ? 1 : 0;
    if (!AevonKbInjectApp) {
        AevonKbLog("app: kb: native off, inject=0\n");
        return;
    }
    // 装钩子这一拍按当前事实算一次，与母版 `0x5050` 的
    // `_hookUIScreen = ![_frontMost isEqualToString:_bundleId]` 同一表达式。
    // 走到这一拍 band 必然是「托着」（`AevonKbEnsureInstalled` 的闸），所以这里是
    // 真值 ⇒ 装上就立刻接管，不用等下一次 settings 回调。之后由
    // `AevonKbSceneSettings` 与 `AevonKbRefreshShell` 持续校正。
    AevonKbHookUIScreen = !AevonKbIsFrontMost();

    int installed = 0;
    int mask = 0;

    Class keyboards = NSClassFromString(@"_UIRemoteKeyboards");
    SEL intersectionSel = NSSelectorFromString(@"intersectionHeightForWindowScene:"
                                               @"isLocalMinimumHeightOut:"
                                               @"ignoreHorizontalOffset:");
    IMP oldIntersection = AevonKbInstallInstance(keyboards, intersectionSel,
                                                 (IMP)AevonKbIntersection);
    if (oldIntersection != NULL) {
        AevonKbOrigIntersection = (CGFloat (*)(id, SEL, id, BOOL *, BOOL))oldIntersection;
        installed += 1;
        mask |= 1 << 0;
    }

    Class keyboardWindow = NSClassFromString(@"UIRemoteKeyboardWindow");
    SEL remoteWindowSel = NSSelectorFromString(@"remoteKeyboardWindowForScreen:create:");
    IMP oldRemote = AevonKbInstallClass(keyboardWindow, remoteWindowSel,
                                        (IMP)AevonKbRemoteWindow);
    if (oldRemote != NULL) {
        AevonKbOrigRemoteWindow = (id (*)(id, SEL, UIScreen *, BOOL))oldRemote;
        installed += 1;
        mask |= 1 << 1;
    }

    Class scenesClient = NSClassFromString(@"FBSWorkspaceScenesClient");
    SEL settingsSel = NSSelectorFromString(@"sceneID:updateWithSettingsDiff:"
                                           @"transitionContext:completion:");
    IMP oldSettings = AevonKbInstallInstance(scenesClient, settingsSel,
                                             (IMP)AevonKbSceneSettings);
    if (oldSettings != NULL) {
        AevonKbOrigSceneSettings = (void (*)(id, SEL, id, id, id, id))oldSettings;
        installed += 1;
        mask |= 1 << 2;
    }

    IMP oldBounds = AevonKbInstallInstance([UIScreen class], @selector(bounds),
                                           (IMP)AevonKbBounds);
    if (oldBounds != NULL) {
        AevonKbOrigBounds = (CGRect (*)(id, SEL))oldBounds;
        installed += 1;
        mask |= 1 << 3;
    }

    // 0.4.26 — 第五条：键盘通知的坐标系校正（理由见 `AevonKbPostNote` 那一节）。
    // 装在 `NSNotificationCenter` 而不是各类 UIKit 内部方法上，是因为这里
    // 是唯一一个「所有键盘通知都必须经过」的公开收口；block 观察者、
    // selector 观察者都在它下游，改一次就全覆盖。
    Class center = NSClassFromString(@"NSNotificationCenter");
    IMP oldPost = AevonKbInstallInstance(center,
                                         @selector(postNotificationName:object:userInfo:),
                                         (IMP)AevonKbPostNote);
    if (oldPost != NULL) {
        AevonKbOrigPostNote = oldPost;
        installed += 1;
        mask |= 1 << 4;
    }

    // 0.4.37 — 第六条：`keyboardLayoutGuide` 的读出口。
    //
    // 320 里 54 条 guide 读数只有 3 条正确，而落点、`co`、`uin` 全都是对的 ——
    // 这一条就是最后一处还在给 App 递错值的接口。类名取不到（iOS 15 以前没有
    // 这个类）就跳过，`mask` 第 5 位为 0 就是「没装成」。
    Class guideCls = NSClassFromString(@"UIKeyboardLayoutGuide");
    IMP oldGuide = AevonKbInstallOwn(guideCls, @selector(layoutFrame),
                                     (IMP)AevonKbGuideLayoutFrame);
    if (oldGuide != NULL) {
        AevonKbOrigGuideFrame = (CGRect (*)(id, SEL))oldGuide;
        installed += 1;
        mask |= 1 << 5;
    }

    // 0.4.38 — 第七条：`-[UIScreen nativeBounds]`（理由见函数上方那一节）。
    //
    // 它与 `-bounds` 必须同步：`-bounds` 给 717 而 `-nativeBounds` 给 932，等于
    // 同时宣称两块屏。威锋按「屏幕高 − 键盘顶」算键盘高，正好吃这条 932 ⇒ 多抬 215。
    // `UIScreen` 自己就实现了 `nativeBounds`，所以仍走 `AevonKbInstallOwn`
    // （万一某版本它是从父类继承的，也不能在父类上打洞）。
    IMP oldNative = AevonKbInstallOwn([UIScreen class], @selector(nativeBounds),
                                      (IMP)AevonKbNativeBoundsGet);
    if (oldNative != NULL) {
        AevonKbOrigNativeBounds = (CGRect (*)(id, SEL))oldNative;
        installed += 1;
        mask |= 1 << 6;
    }

    char line[192];
    snprintf(line, sizeof(line), "app: kb: native on installed=%d mask=0x%x bundle=%s\n",
             installed, mask, [AevonKbBundleId UTF8String] ?: "?");
    AevonKbLog(line);
}
