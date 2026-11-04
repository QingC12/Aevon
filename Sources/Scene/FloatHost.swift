import UIKit

/// The floating window shell.
///
/// 0.2.x already proved the two hard parts on this phone: a window built from
/// the main `UIWindowScene`, and a `hitTest` that answers nil for itself so a
/// touch that misses the card falls through to whatever is underneath.
///
/// 0.0.35 moved the gesture surface out of the card, and that part is settled: a
/// hosted scene view is a real UIView that owns its touches and forwards them to
/// the app, so recognizers on the card's own view never fired (Aevon(33)). The
/// band has to be a sibling ring *outside* the picture.
///
/// 0.0.40 is the operator's own map, and 0.0.47 gives the top edge its gestures
/// back so that the map is a perimeter rather than three edges:
///
///    · 四周（含顶部）：拖动 = 移动窗口
///    · 左侧 / 右侧：点一下 = 贴边吸附
///    · 底边中段：上滑 = 关闭
///    · 左下 / 右下角：拖动 = 缩放，长按 = 复位
///
/// 0.0.43 — the corners resize again. 0.0.40 removed the two resize cells on
/// the honest grounds that a resize reachable only through the dead top strip
/// was no resize at all; Aevon(41) answered with the operator's own map: the
/// bottom corners are where resize belongs. A drag on a corner now scales the
/// card around its opposite corner — the shape the master's own caption
/// promises (「边角区域滑动缩放，长按重启」) — and the long press keeps its
/// geometry reset. The card's aspect never changes: the picture is one shape
/// scaled, so a resize is a height choice and the width follows.
///
/// Why the top strip came back. 0.0.35-0.0.39 had four cells up there — 边中's
/// flick-to-close and the two top corners' resize — and 0.0.40 punched the strip
/// out when those cells left. 0.0.47 restores it as plain 拖动: the master's own
/// caption is 「浮窗手势区域为边缘外侧」— a perimeter, all four sides — and
/// Aevon(44)/(45) reporting 「四边手势依旧失效」 three rounds running is what a
/// perimeter with one dead edge looks like from the outside. The strip still
/// answers no tap and no long press, so nothing docks or resets by accident.
///
/// 吸附 changed meaning in this version. It used to be a drag that snapped to an
/// edge and a double tap that minimised. Both are gone. 吸附 is now one tap on a
/// side band: the card becomes a docked 停靠小窗 on that side, and a tap anywhere
/// on the mini's picture brings the full card back. Two taps were always the
/// wrong shape for this — the operator has to aim at a specific band twice, and
/// the way *out* of the mini was a band, not the window it had just become.
///
/// 0.0.54 — 画面里不再有自己的控件。右上角那颗 ✕ 撤了：它压在 App 画面右上角，
/// 和 App 自己的顶栏挤在一起，既挡内容又不好看；关窗仍有底边上滑与十分钟上限。
///
/// 0.0.60 — 那刀裁切撤了。裁切能去掉顶栏，但切掉的东西不会自己回来：App 仍是
/// 按整屏排好的，卡片只是它的一截。改比例是另一条路 —— 承载面按小胖屏的尺寸
/// （5 : 3）重新布局，App 会排一版适合这个窗口的界面，顶栏、底栏都在里面。
/// 这也是母本的做法：她的窗口比例是设置项（`CustomFrameInit` /
/// `RightCornerTrim` / `LeftCornerTrim`），不是屏幕比例。
///
/// 0.0.62 — 交给系统的那块「屏幕」改成**与手机等宽**（高按 5:3），卡片是它的
/// 等比缩小。0.0.61 交的是卡片自己的尺寸（345 宽），任何按屏幕宽度布局的层都会
/// 出界（抖音右侧那一列、视频居中都不对）；等宽之后它们全部落在界内，字号与
/// 圆角也顺带按同一个 scale 收敛。见 `fatRender`。
final class FloatHost: NSObject, UIGestureRecognizerDelegate {
    static let shared = FloatHost()

    /// Which part of the ring a touch landed on.
    private enum Zone {
        case left
        case right
        case top
        case bottomMiddle
        /// 0.0.69 — 底角拆成两个。
        ///
        /// 母本的语言包把左右两角当成两件事：`LeftCornerTrim`「左角::滑动进一步
        /// 调整比例, 长按反向调整」、`RightCornerTrim`「右角::点击切换基础窗口
        /// 比例」，而 `GestureIntroduction` 里「长按」只出现在「边中区域…长按切换
        /// 横竖」这一句上。Aevon(59) 的要求与这条一致：**长按重启只留在右下角，
        /// 左下角这一格空出来给横屏手势**。合并成一个 `bottomCorner` 时这两件事
        /// 无法分开 —— 一个格子只能有一个长按。
        case bottomLeft
        case bottomRight

        var isCorner: Bool { self == .bottomLeft || self == .bottomRight }
    }

    private var window: FloatWindow?
    /// 0.0.47 — 手势面自己的窗口，层级 statusBar+1。见 `makeBand()`。
    private var bandWindow: BandWindow?
    /// 手势环相对卡片的四边内嵌量。卡片贴到某一边时，那一边的环就被屏幕截短，
    /// 所以它是算出来的，不是常数 `reach`。
    private var bandInset: CGPoint = .zero
    private var card: UIView?
    private var content: UIView?
    private var grip: GripView?
    /// The transparent shield a docked card puts over its own picture. It exists
    /// for one reason: while the card is mini, a tap on the picture has to mean
    /// "give me the window back" instead of reaching the app.
    private var shield: UIControl?
    private var onClose: ((String) -> Void)?
    /// The scene's own size. Every resize is this shape, scaled — the card never
    /// gets an aspect the picture does not have.
    ///
    /// 0.0.62 — `natural` 是**交给系统的那块屏幕**（`fatRender` 算的：与手机等宽，
    /// 高按 5:3），不是卡片尺寸、也不是真机屏幕。承载面的 `bounds` 与 scene 的
    /// `settings.frame` 都是它，所以 App 按这个尺寸排版；卡片是它的等比缩小
    /// （scale 约 0.80）。拖大拖小走 transform，`natural` 不变 ——
    /// 窗口在手上被拉扯的时候不该让 App 每一帧重排一次。
    ///
    /// `visible` 与它相等（不再裁顶栏），留成两个名字是因为 `followContent` /
    /// `recenterCard` 都读 `visible`：语义上一个是「坐标空间」，一个是「看得见的
    /// 那一块」，0.0.60 之后两者重合。
    private var natural: CGSize = .zero
    private var visible: CGSize = .zero

    /// 0.0.65 — 设备屏幕圆角，开窗时读一次。`applyCorner` 每一帧都要用，而
    /// `_displayCornerRadius` 是一次 KVC。
    private var screenCorner: CGFloat = 0
    /// 0.0.54 的顶栏裁切量。0.0.60 起恒为 0（改比例而不是裁画面），保留这个量
    /// 是因为两条对齐路径都按它算中心，0 就是「不用对齐」。
    private var cropTop: CGFloat = 0

    /// 0.0.58 — 卡片是不是在等第一帧。
    ///
    /// 母本 `ReflectManager` 里有 `_launching` / `_showCover` / `_covered` /
    /// `_cover` 四个字段，但整张表里没有任何快照或图像缓存字段 —— 她的 cover
    /// 不是截图。0.0.57 按这四条做了一版「图标 + 名字」的封面，被否了：那不是
    /// 画面，只是另一张图。这一版改成不画任何东西，等真画面自己到。
    private var awaitingFrame = false
    private var frameAt: CFTimeInterval = 0
    /// 0.0.73 — `reapplyPlacement` 写过几行日志。抹一次写一行，稳定之后闭嘴。
    private var placementLogs = 0

    private var pan: UIPanGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var tap: UITapGestureRecognizer?

    private var zone: Zone = .left
    private var panStep: CGPoint = .zero
    /// 0.0.43 — the frame a corner resize started from, and which corner the
    /// finger is on. The opposite corner is the anchor that never moves.
    private var resizeStart: CGRect?
    private var resizeFromLeft = false
    /// The frame to come back to. Non-nil is the only definition of "docked".
    private var miniFrame: CGRect?
    /// 0.0.47 — how many hitTest questions the band window has answered (and
    /// written down). Bounded, like every other probe here: SpringBoard's log is
    /// not the place for a stream.
    private var ringProbe = 0

    // 0.0.48 — 应用层原始触摸的状态（见 `rawTouch`）。识别器那条路有自己的
    // 状态机（UIKit 的），这条路必须有自己的一份：谁在跑由「事件有没有被吞掉」
    // 决定，而一次触摸只可能走其中一条。
    private var rawActive = false
    private var rawStart = CGPoint.zero
    private var rawLast = CGPoint.zero
    private var rawMoved = false
    private var rawStamp: TimeInterval = 0
    private var rawVelocity = CGPoint.zero
    private var rawProbe = 0
    /// 卡片开着时，前 12 个到达应用层的触摸都写一行（不管落在哪里）。它回答的
    /// 是「卡片外面到底有没有触摸进到 SpringBoard」—— 0.0.44-0.0.47 四轮里唯一
    /// 始终分不开的问题。
    private var rawSeen = 0
    private var rawPress: DispatchWorkItem?

    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 480
    /// 0.0.48 — 原来这里是 `edge = 2`，卡片那圈白描边。描边撤了（见 `show`），
    /// 常量一起撤，免得留一个没人读的 2。
    private let margin: CGFloat = 8
    /// 0.0.60 — 小胖屏的宽高比（高 : 宽），5 : 3。
    ///
    /// 母本没有「裁掉顶栏」这种东西。她的三个设置项在二进制里连成一串：
    /// `CustomFrameInit`（修改窗口比例）、`RightCornerTrim`（**点击切换基础窗口
    /// 比例**）、`LeftCornerTrim`（**滑动进一步调整比例, 长按反向调整**），
    /// 另一个 `HeightFraction`（高度系数）单独管大小。也就是说：她的窗口
    /// 比例是一个可以选的量，不是屏幕的比例。
    ///
    /// 内容之所以完整，是因为 `setResizesHostedContext:` —— 承载面按**窗口自己
    /// 的尺寸**重新布局，App 会排一版适合这个窗口的界面。0.0.54 那刀（按原比
    /// 例布局、再把高度减掉顶栏）是「从整屏画面里切一截」，切掉的东西不会自己
    /// 回来；换比例是「让 App 重新画一张」，顶栏、底栏、抖音右侧那一列都在新布
    /// 局里。
    ///
    /// 12 : 7 是另一个候选（略瘦一点，高 12 宽 7）。改这一行即可。
    static let fatAspect: CGFloat = 5.0 / 3.0

    /// 0.0.62 — 交给系统的「这块屏幕有多大」。
    ///
    /// 0.0.60/0.0.61 交的是**卡片本身**的尺寸（345×574）。比例对了，但宽度只有
    /// 屏幕的 80 %，于是任何按屏幕宽度布局的层都会出界：Aevon(53) 里抖音的右侧
    /// 点赞/评论那一列按 430 贴在右缘，落在 345 之外，整块看不见；视频在 430×932
    /// 里居中，被 345×574 的上半截裁掉。
    ///
    /// 母本交给系统的从来不是「小卡片」，是**一个比例的屏幕**：她调的是窗口比例，
    /// 比例一变 App 就重排一版，而屏幕宽度这个量她从没动过。
    ///
    /// 所以这里给的是「和这台手机一样宽、但矮成 5:3」的一块屏幕：
    ///   宽 = 屏宽，高 = 屏宽 × 高宽比（5:3 ⇒ 416 pt 屏给 430×716）。
    /// 好处一次解决三件事：
    ///   ① 按屏幕宽度布局的东西（抖音工具栏、各种贴边浮层）全部落在界内；
    ///   ② 卡片是从它缩出来的（428 → 345，scale 0.80），字号跟着缩 20 % ——
    ///      「悬浮窗内字体有点大」不用另加一套缩放，它就是同一个缩放；
    ///   ③ 圆角按同一个 scale 缩（55 → 44），「太圆」也是同一件事。
    /// 比例由宽高共同决定，所以它仍然是 5:3，不是把整屏压扁。
    /// 0.0.65 — 形状固定 5:3，不再有「记住的形状」。
    ///
    /// 0.0.63/0.0.64 让角拖动改窗口比例（母本 `LeftCornerTrim` 那条路），代价是
    /// 画布尺寸变成一个需要持久化的变量。Aevon(57) 的判决是这条路没有价值：
    /// 「几何缩放没有任何用处」。于是它连同 `CanvasHeight` 一起撤掉 —— 少一个
    /// 状态，就少一整类「读回来和上次不一样」的错位。
    static func fatRender(in screen: CGSize) -> CGSize {
        guard screen.width > 100, screen.height > 200 else {
            return CGSize(width: 430, height: 717)
        }
        // 0.0.82 — 画布只有一个来源，就是这一行。0.0.79 在这里加过一个 `full`
        // 分支（整屏画布），0.0.82 撤掉了，原因写在 `AevonAppHook.m` 里那段注释：
        // 记号是持久的，一次判定变成永久政策，最后的表现是「卡片 5:3、画面 9:19.5、
        // 两边各 42 pt 黑边」。用户拍板：主页面按 5:3 真重排优先。
        // 高宽比 = 高 / 宽。5:3 的高度是宽度的 1.667 倍。
        let w = screen.width
        var h = w * fatAspect
        // 矮屏兜底：scene 的 frame 不该高过屏幕。
        h = Swift.min(h, screen.height)
        h = Swift.max(h, 240)
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// 0.0.81 — 画布装进卡片的那个比例。
    ///
    /// 0.0.60~0.0.80 只有一个比例：卡片是画布的等比缩小，两者形状永远相同。于是
    /// 「卡片形状」这件事一直是被画布决定的 —— 哔哩哔哩竖版那一页按整屏 932 排，
    /// 卡片就跟着变成 282×610（9:19.5）。Aevon(72) 的判决是：**卡片的形状不该由
    /// 某个 App 的页面决定**。
    ///
    /// 所以从 0.0.81 起分成两件事：
    ///   · 卡片形状 = 5:3，和别的 App 一样（`plan` 只按 `fatAspect` 算）；
    ///   · 画布怎么装进这张卡 = 等比、取小的那一边、居中（这个函数）。
    ///
    /// 0.0.82 起画布也恒为 5:3（整屏画布那条路撤了），两者形状永远相同，这个函数
    /// 于是回到恒等变换（比例 0.851，`shown` 与 `fill` 相等）。留着它是因为它是
    /// 「画布和卡片不是同一个形状」这一件事的**唯一**落点：哪一天真的又需要装
    /// 一块不一样的画布，装法已经在这里，不需要再发明一次。
    static func fitScale(for source: CGSize, in card: CGSize) -> CGFloat {
        guard source.width > 16, source.height > 16,
              card.width > 16, card.height > 16 else { return 1 }
        return Swift.min(card.width / source.width, card.height / source.height)
    }

    /// 0.0.49 — 卡片下面那层柔光。跟着 card 的 frame 与圆角走。
    private var glow: UIView?
    /// 0.0.45 — 吸附 (docked) size, from the master's 「贴边缩小」.
    ///
    /// The master docks flush against the edge and keeps the picture's aspect;
    /// how small it goes is its 高度系数 taken down to a handle. Three tenths
    /// of the screen height is 280 pt tall and 129 wide here — big enough to
    /// read the app, small enough to be out of the way, and the same shape as
    /// the card it came from.
    private let miniHeightFraction: CGFloat = 0.30
    /// The height the docked card has on this screen, and the floor a corner
    /// resize may not go under — one function so "smallest" means one thing.
    private func miniHeight(in bounds: CGRect) -> CGFloat {
        return bounds.height * miniHeightFraction
    }
    /// `GestureBorderWidth` in her settings, described there as 减小浮窗手势宽度.
    /// The master's own edge band is 30 pt (`_edgeWidth`, legible in the same
    /// constant annotation that gave the height fractions); the *floating
    /// window* band is the one its caption calls 边缘外侧 and it is wider.
    ///
    /// 0.0.35 shipped 40. 0.0.40 cut it to 32, and Aevon(39) answered with
    /// 「移除热区可见性后，四周的手势失效」. 0.0.42 painted the band, gestures
    /// came back, 0.0.44 unpainted it and they died again — and Aevon(43)'s
    /// log finally says why, which is neither visibility nor the app bridge:
    ///
    ///   0.0.43 (working):  card 320x694 at 52,106  → band reached (418, 846)
    ///   0.0.44 (broken):   card 265x575 at 76,207   → band reached (387, 828)
    ///
    /// The band is measured from the card's edge, so a card that shrinks takes
    /// its own hit area with it: the same thumb, the same place on the screen,
    /// now lands 30 pt past the ring and touches the desktop. The painted map
    /// only ever *reported* where the ring was; the defect was the ring's size.
    ///
    /// 60 pt + 6 of slack it is. That is a band a thumb finds without being
    /// told, and it survives the card being resized smaller by the operator.
    private let band: CGFloat = 60
    /// 0.0.41 — 6 pt of tolerance on the *outside*. 0.0.37's Aevon(35) shows a
    /// thumb landing at x=390 on a card whose right edge was 375: 15 pt outside,
    /// comfortably inside a 40 pt band. The same thumb on 0.0.40's 32 pt band
    /// touched nothing. `band` is what the zone map is written in; `slack` is
    /// how far past it a touch still counts, and the two are added once, here,
    /// so the hit area and the zone arithmetic can never drift apart.
    private let slack: CGFloat = 6
    /// The ring's real half-width: the band plus its tolerance.
    private var reach: CGFloat { band + slack }
    /// 快速上滑: a flick, not a drag. 900 pt/s is above a deliberate slow drag and
    /// below the speed a thumb reaches when it is actually swiping away.
    private let flick: CGFloat = 900
    private let pressDelay: TimeInterval = 0.4

    var level: CGFloat { window?.windowLevel.rawValue ?? 0 }

    /// 0.0.63 — 现在交给系统的画布尺寸。看门狗（SceneProbe 的保活时钟）拿它和
    /// scene 真实的 `settings.frame` 对比，被系统改回去时当场重写并记一行 ——
    /// 0.0.61/0.0.62 只在一开一关两个时刻回读，中间那几秒是不是被改回去了，
    /// 日志里从来没有过答案。
    var canvas: CGSize { natural }

    /// Answers a host only when the window is really up and really holds the
    /// view. A nil answer means "activate nothing": a presenter whose view is
    /// not in a window is 0.0.20's black screen, and that is not worth one more
    /// phone.
    ///
    /// 0.0.82 — `bundle:` 参数随「按 App 换画布」一起撤了：画布只有一个来源，
    /// 宿主侧不再需要知道这是谁。
    static func show(_ view: UIView, awaitingFrame: Bool = false,
                     onClose: @escaping (String) -> Void) -> FloatHost? {
        let host = shared
        host.teardown()
        host.onClose = onClose
        guard let window = host.makeWindow() else { return nil }

        window.backgroundColor = .clear
        window.isOpaque = false
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 100)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = false
        guard let root = window.rootViewController?.view else {
            window.isHidden = true
            return nil
        }

        // A card that shows a phone is a card shaped like a phone: the width is
        // chosen, the height follows the picture's own aspect (0.0.24's fixed
        // 320x480 card is what put black bars at the sides).
        // 0.0.60 — 承载面按小胖屏的尺寸重新布局。
        //
        // 原来这里用的是 scene 自己的尺寸（整块屏幕），卡片是它的等比缩小 ——
        // 卡片于是永远和手机一样瘦长（430×932 的 0.62 高 = 267×578），内容只是
        // 变小。母本不是这样：她用 `setResizesHostedContext:` 让承载面跟着窗口
        // 的尺寸走，App 会按这个尺寸**重新排一版**，顶栏、底栏、抖音右侧那一列
        // 都在新布局里 —— 不是从旧布局里裁出来的。
        //
        // `bounds` 是 scene 的逻辑坐标空间：改它等于告诉 App「你的屏幕有这么大」。
        // 只碰 bounds，不碰 frame —— 后者会连同位置一起挪，0.0.22 的黑屏就是
        // 那么来的。transform 在下面单独设。
        // 0.0.62 — 交给系统的是「与手机等宽、高按 5:3 的一块屏幕」，不是卡片本身。
        // 卡片尺寸仍由高度系数决定，但它现在是这块屏幕的**等比缩小**（scale 约
        // 0.80），所以字号与圆角一起按同一个比例变小 —— 见 `fatRender`。
        // 0.0.65 — 画布只有一个来源：屏幕宽度 × 5:3。没有第二个写入口，
        // 「记忆的形状」与开关一起撤了（见 `fatRender`）。
        // 0.0.79 — 只有一个例外：这个 App 上一次把「我的页是整屏高」写在记号里
        // （哔哩哔哩的竖版故事）。那就给它整屏画布，卡片按整屏比例缩 —— 见
        // `wantsFullCanvas` 与 `fatRender` 的 `full` 分支。
        // 0.0.82 — 那个例外撤了：画布恒为 5:3，`render` 与 `hosted` 从此永远相等。
        let source = FloatHost.fatRender(in: window.bounds.size)

        // 0.0.61 — 这一行才是「小胖屏」真正生效的地方。
        //
        // 改下面的 `view.bounds` 只换了画布，App 依旧按整屏排版；Aevon(52) 的日志
        // 把它摊得很清楚：`hosted bounds after=377x628 asked=377x628`（视图确实改
        // 了），`scale factor=1.000`（一比一），于是 430 宽的界面被直接裁进 377 的
        // 框 —— 字大、顶栏偏右、底栏与抖音右侧那一列都在框外。
        //
        // `AevonSceneFrameSet` 把目标记在 C 侧，intercept 钩子在系统下一次更新
        // settings 时把它写进 scene 的 frame（母本的路线），SceneProbe 拿到 scene
        // 后还会主动推一次，不等系统那一拍。
        AevonSceneFrameSet(0, 0, Double(source.width), Double(source.height))

        view.transform = .identity
        view.autoresizingMask = []
        view.bounds = CGRect(origin: .zero, size: source)

        let plan = host.plan(in: window.bounds, source: source)
        // 0.0.60 — 不再裁顶栏。要的是「完整展示」，可见块就是承载面本身。
        // `visible` 这个名字留着：`followContent` / `recenterCard` 都读它。
        let visible = source
        let frame = plan.frame

        let card = UIView(frame: frame)
        // 0.0.81 — 画布装不满卡片时（哔哩哔哩竖版：430×932 按高等比缩进 5:3），
        // 两边会各露出一条。留透明就是把桌面透进来，看上去像卡片没画完；填黑
        // 是「这一页之外」的通用答案，和播放器留边同一套观感。画布正好是 5:3
        // 时（其余所有 App）这一行等于 `.clear`，和以前一模一样。
        card.backgroundColor = .clear
        // 0.0.48 — 白色描边撤掉（Aevon(46) #2「边缘的白色线条太明显」）。
        //
        // 那 2 pt 是 0.0.24 留下的：当时卡片里可能是空的，需要一个框说明「这是一
        // 个窗口」。现在卡片里永远是真实画面，画面自己就是边界；再画一条白线，
        // 等于给一张有内容的图套个相框。圆角保留（它是有用的，见 `applyCorner`），
        // 边框不保留。
        card.clipsToBounds = true
        card.isUserInteractionEnabled = true
        host.card = card
        host.content = view
        host.natural = source
        host.visible = visible
        host.screenCorner = FloatHost.deviceCorner()
        // 0.0.60 — 裁切量恒为 0。`cropTop` 这个量还留着，因为 `followContent`
        // 与 `recenterCard` 都按它对齐中心：0 就是「不用对齐」，两条路径都正确。
        host.cropTop = 0
        host.applyCorner()
        host.applyBars()

        // 承载面保持 scene 自己的坐标空间，整块缩放 —— 改 `frame` 会重写那个
        // 空间，0.0.22 的空白卡片就是那么来的。`bounds` 已经在上面对准小胖屏
        // 尺寸了（那一步让 App 重新布局），这里只负责把它摆在卡片中间。
        //
        // 0.0.60 — `scale` 初始就是 1.000：卡片的尺寸就是承载面的尺寸，一比一。
        // 之后拖大拖小走的是 transform，`bounds` 不再变 —— 一个窗口在手上被拉
        // 扯的时候不该让 App 每一帧都重排一次界面。
        view.center = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        view.transform = CGAffineTransform(scaleX: plan.scale, y: plan.scale)
        card.addSubview(view)

        // 0.0.58 — 冷启动不再盖图标。
        //
        // 0.0.57 盖的是「图标 + 名字」。它不是黑屏，但也不是那个 App —— 用户
        // 看到的是「点了微信，出来一张微信的卡片封面」，那是应用商店的观感，
        // 不是系统该有的观感（Aevon(52) 的原话：这样不好看）。
        //
        // 母本没有这一步，原因在它的选择子表：`launchApplicationWithIdentifier:
        // suspended:` 根本不在 `__objc_selrefs` 里，它走的是
        // `_activateBundleID:requestID:isTrusted:options:source:originalSource:
        // withResult:` 与 `_createSceneWithDefinition:...` —— 系统自己的激活路
        // 径，App 从诞生那一瞬就是「该画」的状态，第一帧不需要谁去激活。
        // 我们这条挂起启动的路做不到这一点（见 SceneProbe 的唤醒段），所以
        // 能改的不是「画得更好」，而是**不让空窗被看见**：
        //
        //   卡片先建好、但 alpha 为 0 —— 桌面上什么都不多出来；
        //   第一帧到的那个节拍淡入；三秒还没到就强制露出来，让操作者至少能关掉。
        //
        // 这比「先给一块深色板再换成画面」少一次亮度的硬切换：那一次切换本身
        // 就是被投诉的那个「闪」。
        if awaitingFrame {
            host.awaitingFrame = true
            host.frameAt = CACurrentMediaTime()
            card.alpha = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak host] in
                host?.revealContent("timeout")
            }
        }
        // 0.0.49 — 光晕在卡片**下面**。描边撤掉之后，深色壁纸上的卡片边界看不出来
        // （Aevon(47) #2）；母本的做法不是画线，而是给卡片加一层柔光 —— 二进制里
        // 有 SwiftUI 的 `_ShadowEffect` 与 `_BlurEffect`，没有 border 相关的具体值。
        // 所以这里是 `layer.shadow`，不是 border：模糊半径大、透明度低，只负责把
        // 卡片从同样深的背景里托起来，不构成一条可见的边。
        //
        // 单独一层而非直接给 card 加阴影：card 自己 `masksToBounds = true`（画面要
        // 被圆角裁掉），阴影会被一起裁掉。放在下面当兄弟，才画得出来。
        let glow = UIView(frame: plan.frame)
        glow.backgroundColor = .clear
        glow.isUserInteractionEnabled = false
        glow.layer.shadowOffset = .zero
        glow.layer.shadowOpacity = 1
        // 0.0.59 — 光晕必须与卡片同进同出。
        //
        // 0.0.58 只把 `card.alpha` 置 0，漏了这一个兄弟层：卡片透明的一两秒里，
        // 屏幕上仍然有一圈阴影在，形状和位置都与卡片一样。Aevon(58) 说的
        // 「悬浮窗先出现」就是它 —— 不是窗口，是窗口的影子。然后卡片淡入、
        // 画面跳进来，第二下就是「闪」。
        if host.awaitingFrame { glow.alpha = 0 }
        root.addSubview(glow)
        host.glow = glow
        root.addSubview(card)

        host.window = window
        // 0.0.47 — 手势环搬到 band 窗口（statusBar+1）。卡片留在这一层，所以
        // 里头的点击滑动照旧；伸手的那一圈在一个不会被任何 App 窗口盖住的层。
        host.installGrip(on: host.makeBand() ?? root)
        host.installGestures()

        // 0.0.60 起是「与手机等宽、高按 5:3」的日志口径。`hosted=` 是下发承载面
        // 的逻辑尺寸，`card=` 是它在屏幕上的尺寸；两者除一个 scale 之外相等就是
        // 「App 按这个尺寸重新布局」。0.0.82 起 `render=` 不再有第二种可能：
        // 0.0.79 那个 `full=0/1` 的读数随整屏画布一起撤了，这一行里 `render=`
        // 与 `hosted=` 必须永远是同一个数；不一样的版本，就是又有人换过画布。
        let fatA = String(format: "win: fat scene ratio=%.3f screen=%.0fx%.0f render=%.0fx%.0f",
                          FloatHost.fatAspect,
                          window.bounds.width, window.bounds.height,
                          source.width, source.height)
        let fatB = String(format: " hosted=%.0fx%.0f card=%.0fx%.0f at %.0f,%.0f held=%d",
                          source.width, source.height,
                          card.bounds.width, card.bounds.height,
                          card.frame.origin.x, card.frame.origin.y,
                          host.awaitingFrame ? 1 : 0)
        Log.write(fatA + fatB)
        // 0.0.61 — 逻辑尺寸的证词。上面那行说的是「画布多大」，这一行说的才是
        // 「App 以为自己有多大」。两行都读到同一个数，小胖屏才真的成立。
        Log.write("win: scene frame asked=" + String(format: "%.0fx%.0f", source.width, source.height)
                  + " screen=" + String(format: "%.0fx%.0f", window.bounds.width, window.bounds.height))
        // 一次性的证词：presenter 有自己的尺寸管理，万一它把 `bounds` 改回屏幕
        // 尺寸，这一行会直接说出来 —— 「小胖屏没生效」和「App 不肯按新尺寸重排」
        // 是两件事，只有这一个读数能把它们分开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak view] in
            guard let view = view else { return }
            Log.write(String(format: "win: hosted bounds after=%.0fx%.0f asked=%.0fx%.0f",
                             view.bounds.width, view.bounds.height,
                             source.width, source.height))
        }
        Log.write("win: scale factor=" + String(format: "%.3f", plan.scale)
                  + " shown=" + String(format: "%.0fx%.0f",
                                       visible.width * plan.scale, visible.height * plan.scale)
                  + " fill=" + String(format: "%.0fx%.0f",
                                      card.bounds.width, card.bounds.height)
                  + " card_corner_pt=" + String(format: "%.0f", card.layer.cornerRadius))
        // 0.0.81 — 画布装进 5:3 之后两边各留多少。
        //
        // 0.0.82 起画布恒为 5:3，两边必然是 0（取整误差 ≤ 0.5 pt，这条不打印）。
        // 留着它是因为它是「卡片和画布不是一个形状」唯一的读数：哪一天这一行又
        // 打出 42，就说明画布又被谁换成了整屏 —— Aevon(73) 的哔哩哔哩就是这个数。
        let barSide = Swift.max(0, (frame.width - visible.width * plan.scale) / 2)
        if barSide > 0.5 {
            Log.write(String(format: "win: letterbox side=%.0fpt flat=%d canvas=%.0fx%.0f",
                             barSide, 1, source.width, source.height))
        }
        // 0.0.64 — 开窗这一拍就说清「边角拖动现在是什么语义」，并且把圆角的
        // 三个输入都摆在同一行：`mode` 来自设置，`canvas` 是交给系统的形状，
        // `corner` 是按卡宽算出来的那个数。
        host.logResize()
        // Where the ring is, so the next log can be read against the code instead
        // of against a memory. Two `let`s: one long concatenation of format calls
        // is a type-checker timeout, and 0.0.30 lost a build to it.
        let ring = "win: grip ring band=" + String(format: "%.0f", host.band)
        let cell = " cell=" + String(format: "%.0f", FloatHost.cell(in: card.bounds.size).width)
        // 0.0.46 — the room left on each side, printed with the ring. A band
        // narrower than `reach` is a band the thumb cannot find, and that is
        // exactly what 0.0.45 could not show: `room=l57 r8 t56 b84` would have
        // ended the round in one line.
        let room = " room=" + String(format: "%.0f/%.0f/%.0f/%.0f",
                                     card.frame.minX,
                                     window.bounds.width - card.frame.maxX,
                                     card.frame.minY,
                                     window.bounds.height - card.frame.maxY)
        // 0.0.47 — 环实际铺到哪儿，和圆角一起打印。`inset` 是环相对卡片的内嵌量
        // （卡片贴边时那一边会小于 60），`corner` 是缩放后的屏幕圆角。
        let fit = " inset=" + String(format: "%.0f/%.0f", host.bandInset.x, host.bandInset.y)
            + " corner=" + String(format: "%.0f", card.layer.cornerRadius)
        Log.write(ring + cell + room + fit
                  + " 外侧 (四边 拖动, 左右 点吸附, 底中 上滑关, 左下 缩放, 右下 缩放/长按复位)")
        return window.isHidden ? nil : host
    }

    /// Records what the operator just did with the card.
    ///
    /// Called at the end of a move and nowhere else: an in-flight drag would be a
    /// disk write forty times a second on SpringBoard's main thread, for a value
    /// nobody can read until the finger lifts.
    ///
    /// 0.0.40 — the drag no longer snaps to an edge. Snapping and 吸附 stopped
    /// being the same thing the moment 吸附 became a tap: a card pulled hard
    /// against the screen for being nudged near it, while a card that becomes a
    /// 停靠小窗 only on a deliberate tap, are two answers to one word. The card
    /// now stays exactly where the finger left it, and that is what is stored.
    ///
    /// While docked, only the mini's own frame is updated. Writing that to the
    /// file would make a temporary size look like the operator's chosen one.
    private func remember(in bounds: CGRect) {
        guard let card = card, bounds.width > 0, bounds.height > 0 else { return }
        if miniFrame != nil {
            miniFrame = card.frame
            return
        }
        var placement = CardLayout.loadRuntime()
        let origin = card.frame.origin
        let normalized = CGPoint(x: origin.x / bounds.width, y: origin.y / bounds.height)
        placement.edge = origin.x + card.bounds.width / 2 < bounds.width / 2 ? .left : .right
        if placement.edge == .left {
            placement.left = normalized
        } else {
            placement.right = normalized
        }
        placement.heightFraction = card.bounds.height / bounds.height

        let ok = CardLayout.save(placement)
        let side = placement.edge == .left ? "left" : "right"
        let at = String(Int((normalized.x * 100).rounded())) + "% / "
            + String(Int((normalized.y * 100).rounded())) + "%"
        let tall = " h=" + String(Int((placement.heightFraction * 100).rounded())) + "%"
        Log.write("win: card remembered " + side + " at " + at + tall
                  + (ok ? "" : " (write failed)"))
    }

    /// The hosted view belongs to the system. It leaves with the card and never
    /// with the window: holding a presentation view after the presenter is gone
    /// keeps a scene alive that should have been reclaimed.
    static func hide() {
        shared.teardown()
    }

    private func teardown() {
        guard let window = window else {
            bandWindow?.isHidden = true
            bandWindow = nil
            onClose = nil
            return
        }
        // 0.0.68 — 收窗时**不碰**承载视图。
        //
        // 0.0.67 在这里写过 `content.bounds = UIScreen.main.bounds.size` 与
        // `transform = .identity`，想复位 Aevon(58) 的「关掉浮窗后全屏打开抖音整体
        // 偏下」。那两个属性确实是我们改过的，但 `content` 不是我们的对象 ——
        // `_UIScenePresentationView` 下面挂着 `_UIContextLayerHostView` 和那个 App
        // 的 scene。在 presenter 还活着的时候替它写 bounds，是让系统按「整屏」去
        // 重排一个逻辑尺寸仍是 717 的场景；真机结果是应用打不开、桌面黑屏，与
        // 0.0.65 那次同形。
        //
        // 我们现在做的只有「把它从卡片上摘下来」，剩下的交给 `deactivate` /
        // `invalidate`。代价是那条「退出后偏下」还没修（本轮明确不修），收益是
        // 不再有任何一行代码去写别人的视图。
        for sub in card?.subviews ?? [] { sub.removeFromSuperview() }
        grip?.removeFromSuperview()
        glow?.removeFromSuperview()
        glow = nil
        card?.removeFromSuperview()
        grip = nil
        shield = nil
        awaitingFrame = false
        card = nil
        content = nil
        visible = .zero
        cropTop = 0
        pan = nil
        press = nil
        tap = nil
        miniFrame = nil
        ringProbe = 0
        rawProbe = 0
        rawSeen = 0
        rawActive = false
        rawPress?.cancel()
        rawPress = nil
        lastTouchStamp = 0
        lastTouchPhase = -1
        lastTouchEaten = false
        bandInset = .zero
        onClose = nil
        // The band's window goes with it. It is full-screen and one level below
        // the summon bar; leaving it up would be a transparent sheet over the
        // desktop for as long as SpringBoard lives.
        bandWindow?.isHidden = true
        bandWindow = nil
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    private func makeWindow() -> FloatWindow? {
        if let scene = mainScene() {
            let window = FloatWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            return window
        }
        return FloatWindow(frame: UIScreen.main.bounds)
    }

    /// 0.0.47 — 手势面所在的那一层。
    ///
    /// 母本自己的证据（Stheno 0.1.23）：Preference 的文案里有
    /// `StatusBarEmbeddedWindow = 嵌入状态栏窗口`，类表里有
    /// `_TtC6Stheno21UIStatusBarWindowHook`，`SthenoWindow` 又自己实现了
    /// `-hitTest:withEvent:`。三件事合起来是一句话：母本不把浮窗的手势面放在
    /// 普通层级的窗口里，它挂到系统最上层去。
    ///
    /// 我们这边的证据一样硬：0.0.46 的几何是对的（环 399x710，四边各留 66），
    /// 但 Aevon(44)/(45) 两份日志里，卡片所在的那个窗口一共只收到**一个**触摸
    /// —— 就是 ✕ 关闭键。触摸根本没到窗口，几何再准也没有机会生效。所以手势面
    /// 搬上来，卡片留在下面：内容照样能点能滑，伸手的那一圈在一个 App 窗口盖
    /// 不到的高度。
    private func makeBand() -> UIView? {
        guard let scene = mainScene() else { return nil }
        let window = BandWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .clear
        window.isOpaque = false
        // 竖条搬到 statusBar+2（见 RingHost.start），比这一层高一级：卡片开着
        // 的时候，右侧的环正好压在竖条原来的位置上，竖条必须在上面才抢得到手指。
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        let root = BandRoot(frame: window.bounds)
        root.backgroundColor = .clear
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let controller = UIViewController()
        controller.view = root
        window.rootViewController = controller
        window.isHidden = false
        window.probe = { [weak self] point, hit in
            guard let self = self, self.ringProbe < 20 else { return }
            self.ringProbe += 1
            Log.write("win: band probe " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " -> " + hit)
        }
        bandWindow = window
        Log.write("win: band window up level=" + String(Int(window.windowLevel.rawValue)))
        return root
    }

    /// The card is the picture's shape, so there is no leftover to show as a
    /// black bar. Width is chosen first (capped by the screen) and the height
    /// follows; the screen caps the height in the other direction.
    ///
    /// 0.0.39 — the card comes back where it was left: height from
    /// `HeightFraction`, width from the scene's aspect, origin from the stored
    /// corner for the current edge, clamped on screen.
    private func plan(in bounds: CGRect, source: CGSize) -> (frame: CGRect, scale: CGFloat) {
        guard bounds.width > 64, bounds.height > 200, source.height > 16 else {
            return (CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight), 1)
        }
        let placement = CardLayout.loadRuntime()
        // 0.0.81 — 卡片的形状不再跟着画布走。以前 `ratio = source.width /
        // source.height`，于是「画布是什么形状，卡片就是什么形状」；哔哩哔哩
        // 要 932 的画布，卡片就成了 9:19.5，用户看到的是「小胖屏对它无效」。
        // 现在卡片永远是 5:3，画布按 `fitScale` 装进去（等比、居中）。
        let ratio = 1.0 / FloatHost.fatAspect

        var h = bounds.height * placement.heightFraction
        var w = h * ratio
        let widest = bounds.width - margin * 2
        if w > widest {
            w = widest
            h = w / ratio
        }
        // The tall guard from 0.0.24 stays: a short screen with a tall scene
        // still has to leave room to see what is behind the card.
        // 0.0.45 — 96, not 160: at 160 the master's own 85 % height was being
        // clipped to 772 pt on a 932 screen, which reintroduced the strip.
        let tallest = bounds.height - 96
        if h > tallest {
            h = tallest
            w = h * ratio
        }
        // 0.0.62 — 不放大。卡片高过承载面高时 scale > 1，画面是插值出来的，
        // 字会变糊；高度系数调到 80 % 时正好踩到这条（717 × 0.8 = 573，勉强
        // 还没到，但没有这行就等于把「能不能放大」交给了滑条）。缩放比落在
        // 0<scale≤1 这一侧，圆角与字号才都只有「变小」这一个方向。
        if h > source.height {
            h = source.height
            w = h * ratio
        }
        let saved = placement.origin(for: placement.edge)
        var x = saved.x * bounds.width
        var y = saved.y * bounds.height
        // 0.0.46 — the card may not use the last `reach` of the screen.
        //
        // The band lives *outside* the card, so the two are in direct
        // competition for the same pixels: 0.0.45's card was 365 pt wide on a
        // 430 pt screen and sat 8 pt from the right edge, which means the right
        // band was 8 pt wide. Aevon(44) read that as 「四周的手势依旧是失效」
        // and it is neither a hit-test bug nor an app-bridge bug — the band was
        // simply not there. Whatever the card's size, it now leaves `reach` on
        // every side the screen has room for.
        //
        // 0.0.67 — **while it has no room, it keeps the operator's place.**
        //
        // The `else` branch used to centre the card, and that was the whole of
        // Aevon(58)'s 「缩放时会自动挪位置」: the fat canvas is 430 wide, the band
        // claim is 66 per side, so any card wider than 298 pt fell into the
        // else branch and had its remembered x thrown away. Every card here is
        // 350-371 wide — the branch was not an edge case, it was the only case.
        // Aevon(58) shows it three times over: remembered 12 % (=52 pt) came
        // back at 30, 10 % (=43) came back at 34, 9 % (=39) landed on 38 — the
        // last one only because centring happened to agree with the memory.
        //
        // A card that wide has already eaten the band's room; `bandRect` shrinks
        // the ring to whatever is actually left, so centring buys nothing and
        // costs the operator their place. Keep the place, clamp on screen.
        let room = reach
        if w + room * 2 <= bounds.width {
            x = Swift.min(Swift.max(room, x), bounds.width - w - room)
        } else {
            x = Swift.min(Swift.max(0, x), Swift.max(0, bounds.width - w))
        }
        // Clamp as a rectangle, not as two numbers: a width change from a
        // rotation must not leave the right edge 40 pt outside the screen.
        if h + room * 2 <= bounds.height {
            y = Swift.min(Swift.max(0, y), bounds.height - h - room)
        } else {
            y = Swift.min(Swift.max(0, y), Swift.max(0, bounds.height - h))
        }
        return (CGRect(x: x, y: y, width: w, height: h),
                FloatHost.fitScale(for: source, in: CGSize(width: w, height: h)))
    }

    // MARK: - close
    //
    // 0.0.54 — 右上角那颗 ✕ 撤掉了（Aevon 的要求：它压在画面上，和 App 自己
    // 的顶栏右下角凑在一起，又挡内容又不好看）。关窗的路没有变少，只是换成
    // 手势：底边中段快速上滑仍然关闭（`dragEnd`），另外还有十分钟上限兜底。
    // 这里留着 `requestClose` —— 它现在是**唯一**一条关窗入口的出口，把
    // 「谁关的」写进日志，比从一个控件数组里猜要可靠。

    private func requestClose(_ reason: String) {
        let hook = onClose
        onClose = nil
        Log.write("win: close requested by " + reason)
        DispatchQueue.main.async { hook?(reason) }
    }

    // MARK: - ring

    /// The ring is the card's frame grown by `reach` on all four sides, with the
    /// card's own rect declared as a hole. Nothing about it is special: it has no
    /// background, it draws nothing, it exists to be touched.
    ///
    /// 0.0.47 — 手势环：卡片四周一圈，厚度 `reach`，但**按屏幕截断**，一路铺到
    /// 屏幕边缘。
    ///
    /// 0.0.46 用的是 `card.frame.insetBy(dx: -66, dy: -66)`。卡片居中时四周各
    /// 剩 82 pt，环只吃 66，靠屏幕边的最后 16 pt 是死区 —— 而「从屏幕边缘往里
    /// 划」正是伸手的第一个动作，那一划正好落在死区里。
    private func installGrip(on root: UIView) {
        guard let card = card else { return }
        let shape = bandRect(for: card)
        let grip = GripView(frame: shape.frame)
        grip.backgroundColor = .clear
        grip.isUserInteractionEnabled = true
        grip.hole = shape.hole
        root.addSubview(grip)
        self.grip = grip
        syncGrip()
    }

    /// 环的 frame、卡片在环里的位置、以及环相对卡片的四边内嵌量。三者出自同
    /// 一次计算，所以「环在哪」和「zone 怎么算」不可能各说各话。
    private func bandRect(for card: UIView) -> (frame: CGRect, hole: CGRect, inset: CGPoint) {
        let bounds = window?.bounds ?? UIScreen.main.bounds
        let left = Swift.min(reach, Swift.max(0, card.frame.minX))
        let right = Swift.min(reach, Swift.max(0, bounds.maxX - card.frame.maxX))
        let top = Swift.min(reach, Swift.max(0, card.frame.minY))
        let bottom = Swift.min(reach, Swift.max(0, bounds.maxY - card.frame.maxY))
        let frame = CGRect(x: card.frame.minX - left,
                           y: card.frame.minY - top,
                           width: card.frame.width + left + right,
                           height: card.frame.height + top + bottom)
        let hole = CGRect(x: left, y: top,
                          width: card.frame.width, height: card.frame.height)
        return (frame, hole, CGPoint(x: left, y: top))
    }

    /// 0.0.47 — 圆角。
    ///
    /// 母本的数据：`DeviceEnv` 有 `cornerRadius` 字段，二进制 `__cstring` 里有
    /// `_displayCornerRadius` 这个键，`ReflectManager` 有 `finalCardCorner` ——
    /// 也就是说圆角不是拍出来的常数，取的是**设备自己的屏幕圆角**，再按卡片
    /// 的缩放比缩一遍，并且和 frame 一起被动画。
    ///
    /// 这里照做：卡片是 430x932 的画面按 0.62 缩小，屏幕圆角 55 就落成 34。
    /// 0.0.62 — 圆角再收一档。
    ///
    /// 之前是「设备圆角 × 视图缩放比」。缩放比从 1.000 掉到 0.80 之后，圆角
    /// 确实从 55 变成 44，但**它占卡片宽的比例一点没变**（55/430 与 44/345 都是
    /// 12.8 %）—— 所以「太圆」不会因为缩放而改善，得单独收比例。
    ///
    /// `cornerTune` 把 12.8 % 拉到 11.5 %：345 宽的卡片从 44 落到 40。这是母本
    /// `ReflectManager.finalCardCorner` 那层意思（设备圆角 × 卡片缩放比）之外的
    /// 一次人为收敛 —— 她的卡片永远接近整屏，不需要这一档，我们的不是。
    ///
    /// 0.0.64 — 两个真机反馈把这一档夹在中间：0.0.61 的 44（12.8 %）「太圆」，
    /// 0.0.63 的 34（10.1 %）「太方」。取中点偏上 11.5 %：337 宽的卡片落 39。
    private let cornerTune: CGFloat = 0.90

    /// 0.0.64 — 圆角**只由卡片的短边走**，不再由「卡片高 / 画布高」推。
    ///
    /// 0.0.63 的写法是 `deviceCorner * (cardH / visibleH) * tune`，而那正是
    /// 「缩放时四角会变成直角」那条反馈的成因，日志里数得出来：12:17:28 画布
    /// 换到 430×716，之后一路往下拖，卡片被拖到 363×279 时 `cardH / 716` 只剩
    /// 0.39 —— 圆角算出来 16.7 pt，占 363 宽只有 4.6 %，看着就是直角。
    /// 抬手之后画布跟着换，圆角又弹回 10 %，于是「一缩放就方、一松手又圆」。
    ///
    /// 圆角在观感上由**卡片自己的宽度**支配（0.0.62 就是这一条），那就直接按
    /// 宽度算：`屏幕圆角 × (卡宽 / 屏宽) × tune`，卡宽不变圆角就不变。竖着压扁
    /// 一张卡不再改变它的圆角。几何缩放关掉之后这条更关键：画布从此不动，
    /// 若还按 `cardH / 画布高` 算，圆角会随着卡片变矮一路缩水并且再也不回来。
    private func applyCorner() {
        guard let card = card, natural.width > 1 else { return }
        let corner = screenCorner > 1 ? screenCorner : FloatHost.deviceCorner()
        let share = corner / natural.width * cornerTune
        // 短边：竖着的卡片是宽度（和 0.0.62 同一个数），压扁的卡片是高度，
        // 两者都不会超过半张卡 —— 再大就是胶囊，不是圆角。
        let side = Swift.min(card.bounds.width, card.bounds.height)
        let radius = Swift.max(6, Swift.min(side * share, side / 2))
        card.layer.cornerRadius = radius
        card.layer.cornerCurve = .continuous
        card.layer.masksToBounds = true
    }

    /// The screen's own corner radius, asked for at runtime. roothide's SpringBoard
    /// answers `_displayCornerRadius`; a device that does not gets the value every
    /// full-screen iPhone since the X has used, which is close enough to look right.
    private static func deviceCorner() -> CGFloat {
        let selector = NSSelectorFromString("_displayCornerRadius")
        if UIScreen.main.responds(to: selector),
           let value = UIScreen.main.value(forKey: "_displayCornerRadius") as? NSNumber,
           value.doubleValue > 1 {
            return CGFloat(value.doubleValue)
        }
        return 55
    }

    /// Every frame change goes through here. A ring that lags its card by one
    /// event is a ring the finger misses by one band.
    private func syncGrip() {
        guard let card = card, let grip = grip else { return }
        let shape = bandRect(for: card)
        grip.frame = shape.frame
        grip.hole = shape.hole
        bandInset = shape.inset
        // 光晕、圆角、环三者必须同一次事件里一起走。慢一帧就是「卡片动了、光圈
        // 还留在原地」。
        applyGlow()
    }

    /// 0.0.49 — 卡片边缘的柔光。
    ///
    /// 深色模式给白、浅色模式给黑，两者都只在很低的透明度上：目的是让卡片从
    /// 和它一样深的背景里分出来，而不是给卡片画一圈灯。半径取圆角的六成左右，
    /// 这样光从圆角里透出来的形状和卡片本身的连续曲率一致。
    private func applyGlow() {
        guard let card = card, let glow = glow else { return }
        glow.frame = card.frame
        let radius = card.layer.cornerRadius
        let dark = card.traitCollection.userInterfaceStyle == .dark
        // 0.22 / 0.16 — 两次真机反馈之间的取值：0.35 已经能看出「发光」，0.10 在
        // 深色壁纸上又看不出来。深色的白稍强，因为白色比黑色更需要靠亮度争边界。
        glow.layer.shadowColor = (dark ? UIColor.white : UIColor.black).cgColor
        glow.layer.shadowOpacity = dark ? 0.22 : 0.16
        glow.layer.shadowRadius = Swift.max(10, Swift.min(radius * 0.7, 22))
        glow.layer.shadowPath = UIBezierPath(roundedRect: glow.bounds,
                                            cornerRadius: radius).cgPath
    }



    /// The bottom band's middle third — the cell that closes on a flick and
    /// moves otherwise. The rest of the bottom band is 边角. The top band is its
    /// own zone: the master's caption puts the whole perimeter under gestures
    /// (「浮窗手势区域为边缘外侧」), and a perimeter with one dead edge is what
    /// three rounds of 「四边手势失效」 were actually reporting.
    private func zoneFor(_ point: CGPoint) -> Zone {
        guard let card = card else { return .bottomRight }
        let size = card.bounds.size
        if point.y > size.height {
            let cell = FloatHost.cell(in: size)
            if point.x >= cell.minX && point.x <= cell.maxX { return .bottomMiddle }
            return point.x < cell.minX ? .bottomLeft : .bottomRight
        }
        if point.y < 0 { return .top }
        return point.x < 0 ? .left : .right
    }

    // Not private: GripView (same file, different type) paints the heat map
    // with the very same cell arithmetic, and one number must not fork in two.
    static func cell(in size: CGSize) -> CGRect {
        let third = size.width / 3
        return CGRect(x: third, y: 0, width: third, height: size.height)
    }

    private func name(_ zone: Zone) -> String {
        switch zone {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottomMiddle: return "bottom-middle"
        case .bottomLeft: return "bottom-left"
        case .bottomRight: return "bottom-right"
        }
    }

    /// Ring coordinates back to the card's own, which is the space the zones and
    /// the geometry are written in. A point outside the card comes back negative
    /// or past the size, and that is precisely how a band is recognised.
    private func cardPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - bandInset.x, y: point.y - bandInset.y)
    }

    // MARK: - gestures

    private func installGestures() {
        guard let grip = grip else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        grip.addGestureRecognizer(pan)
        self.pan = pan

        // 长按 is now one cell only: 边角's 重启, wired to a geometry reset.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = pressDelay
        press.allowableMovement = 12
        press.delegate = self
        grip.addGestureRecognizer(press)
        self.press = press

        // 0.0.40 — one tap on a side band docks the card. It used to be a double
        // tap on 边中 that minimised, which meant aiming twice at a band and then
        // finding the way back behind the same band again.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDockTap(_:)))
        tap.delegate = self
        grip.addGestureRecognizer(tap)
        self.tap = tap
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let grip = grip else { return true }
        let zone = zoneFor(cardPoint(gesture.location(in: grip)))
        if gesture === tap {
            return zone == .left || zone == .right
        }
        if gesture === press {
            // Only 边角: the sides' long press is nothing at all now, and a press
            // that begins disables the pan, so allowing it there would cost the
            // move gesture its finger for 0.4 s.
            return zone == .bottomRight
        }
        return true
    }

    /// 0.0.48 — 手势逻辑从识别器里拆了出来：同一段代码现在有两个入口。
    ///
    ///   1. `GripView` 上的 UIPanGestureRecognizer（原来的路，留着当兜底）
    ///   2. `-[UIApplication sendEvent:]` 送来的原始触摸（见 `rawTouch`）
    ///
    /// 两条路互斥：原始触摸在应用层被吞掉时，UIKit 根本不会把它分发给任何视图，
    /// 识别器也就不会响。所以两个入口共用 `zone` / `resizeStart` 这一份状态没有
    /// 二义 —— 同一次触摸只可能由其中一条跑完。
    private func dragBegin(at start: CGPoint) {
        guard let card = card else { return }
        zone = zoneFor(start)
        panStep = .zero
        // Which band the finger found. If the operator reports "it does not
        // work" again, this line says whether the touch arrived and which
        // zone it was counted as — two very different defects.
        Log.write("win: gesture grab zone=" + name(zone)
                  + " at " + point(start))
        // 0.0.43 — a corner drag resizes; every other band moves. The anchor is
        // the opposite corner, read once here: a zone is which cell the finger
        // landed in, not a thing that changes mid-drag.
        if zone.isCorner {
            resizeStart = card.frame
            // 0.0.69 — 锚点由格子决定，不再由手指落在卡片中线哪一侧推出来：
            // 左下角拖 = 右上角不动，右下角拖 = 左上角不动。
            resizeFromLeft = zone == .bottomLeft
            logResize()
        } else {
            resizeStart = nil
        }
    }

    /// 0.0.65 — 一行说清这次缩放用的是哪块画布。0.0.64 的 `mode=` 撤了：
    /// 现在只有一种缩放（等比例），模式这个量不存在了。
    private func logResize() {
        guard let card = card else { return }
        Log.write(String(format: "win: resize canvas=%.0fx%.0f card=%.0fx%.0f corner=%.0f",
                         natural.width, natural.height,
                         card.bounds.width, card.bounds.height,
                         card.layer.cornerRadius))
    }

    /// `total` is the finger's travel since it landed, in the window's space —
    /// never in the card's or the ring's, because both are being moved and
    /// resized by this very gesture and their rulers stretch.
    private func dragMove(total: CGPoint, velocity: CGPoint) {
        guard let card = card, let window = window else { return }
        let dx = total.x - panStep.x
        let dy = total.y - panStep.y
        panStep = total
        if zone.isCorner, let start = resizeStart {
            // 边角拖动 = 等比例缩放（0.0.43 起；0.0.65 起只剩这一种）。
            //
            // 0.0.63/0.0.64 在这里分过两条路：宽度跟手指（改窗口比例、抬手换画布
            // 让 App 重排）与宽度由高度推出来（普通缩放）。Aevon(57) 判了第一条
            // 没用，于是这里只留下一条：**宽度永远由高度和按下时的形状决定**，
            // 画布（scene 的 settings.frame）在整场缩放里不动。
            //
            // 这也是最省的一条：App 从头到尾不知道窗口变过，没有一次重排，
            // 画面只是被 transform 放大缩小 —— 拖动是真跟手。
            let shortest = miniHeight(in: window.bounds)
            let tallest = window.bounds.height - margin * 2
            let widest = window.bounds.width - margin * 2
            var h = Swift.min(tallest, Swift.max(shortest, start.height + total.y))
            let ratio = start.width / Swift.max(start.height, 1)
            var w = h * ratio
            // 顶到左右边界时反解高度，形状不变 —— 宽度先到就先停，不是把卡片
            // 压成另一条比例。
            if w > widest {
                w = widest
                h = Swift.max(shortest, w / ratio)
            }
            var frame: CGRect
            if resizeFromLeft {
                frame = CGRect(x: start.maxX - w, y: start.minY,
                               width: w, height: h)
            } else {
                frame = CGRect(x: start.minX, y: start.minY,
                               width: w, height: h)
            }
            // 0.0.67 — 缩放这一路**不夹**，也不再每帧重算圆角。
            //
            // 夹这一下就是 Aevon(58) 的「抖动」：`clamped` 的底部预留量取决于
            // **高度**（`under = frame.height + reach*2 <= bounds.height ? reach : 0`），
            // 高度是这一手势正在改的量，于是卡片一涨、`maxY` 一落，y 被往上顶；
            // 手一松或者往下拖，高度回落、y 又被放回来 —— 卡片自己在跳。
            // 缩放的分支里 x/y 本来就是常量（锚点是对角），唯一会动的只有宽高，
            // 而宽高在上面已经被 `widest` / `tallest` 挡住了，没有出界的可能。
            //
            // 圆角同理：拖大拖小时 `side = min(w, h)` 每帧都变，`cornerRadius`
            // 每帧都写一次等于每帧重建一次裁剪路径，而卡片底下是远程 scene 层 ——
            // 观感就是边缘在抖。拖动中不动圆角，抬手时一次算准（`dragEnd`）。
            card.frame = frame
            followContent(updateCorner: false)
            syncGrip()
        } else {
            // All four cells move. 0.0.40 removed the two that resized, so a
            // drag on the band is a drag on the band, wherever it started;
            // 0.0.43 gave the corners their own meaning back, so a drag on
            // a corner is a resize and this branch is the other three.
            var frame = card.frame
            frame.origin.x += dx
            frame.origin.y += dy
            card.frame = clamped(frame, in: window.bounds)
            syncGrip()
        }
    }

    private func dragEnd(total: CGPoint, velocity: CGPoint) {
        guard let card = card, let window = window else { return }
        if zone.isCorner, resizeStart != nil {
            resizeStart = nil
            // 画布不动，也就没有重排要付：只把画面按新尺寸摆正、把圆角按新
            // 宽度重算一次（圆角跟着卡宽，不跟着卡高）。
            followContent()
            syncGrip()
            Log.write("win: card resized to " + point(card.frame.origin)
                      + " size=" + size(card.bounds.size))
            logResize()
            remember(in: window.bounds)
            return
        }
        if zone == .bottomMiddle {
            // 边中区域快速上滑关闭. Two readings, either one closes.
            //
            // Travel first. 0.0.36 read speed alone, and Aevon(35) recorded four
            // attempts at `up=-159 / 0 / -199 / -2327` — not one of them
            // positive, on a phone where the operator was swiping up. A velocity
            // sample is the last frame or two of the finger; a thumb that reaches
            // its target and settles flips the sign without ever going back down.
            // Travel is the whole path and cannot flip. Speed stays as the second
            // reading, because a short hard flick barely travels and is still a
            // flick.
            let lift = -total.y
            let up = -velocity.y
            let byTravel = lift > 50 && abs(total.y) > abs(total.x)
            let bySpeed = up > flick && up > abs(velocity.x)
            if byTravel || bySpeed {
                Log.write("win: gesture edge-middle flick up=" + String(Int(up))
                          + " dy=" + String(Int(total.y)) + " -> close")
                requestClose("edge swipe up")
                return
            }
            Log.write("win: gesture edge-middle not a flick up=" + String(Int(up))
                      + " vx=" + String(Int(velocity.x))
                      + " dy=" + String(Int(total.y)))
        }
        Log.write("win: card moved to " + point(card.frame.origin)
                  + " size=" + size(card.bounds.size))
        remember(in: window.bounds)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let grip = grip else { return }
        switch gesture.state {
        case .began:
            dragBegin(at: cardPoint(gesture.location(in: grip)))
        case .changed:
            // `nil` = 本手势所在窗口的坐标系。两层都是全屏、原点重合，而 band
            // 那一层在整个拖动过程中不动，是唯一稳定的尺子。
            dragMove(total: gesture.translation(in: nil), velocity: gesture.velocity(in: nil))
        case .ended, .cancelled:
            dragEnd(total: gesture.translation(in: nil), velocity: gesture.velocity(in: nil))
        default:
            break
        }
    }


    /// 边角长按 = 重启 (母本文案「边角区域滑动缩放, 长按重启」). Since 0.0.39 the
    /// plan reads the remembered placement, so resetting the frame alone would
    /// restore the very numbers the operator wanted gone — the remembered
    /// placement has to go first, or "restart" is a no-op.
    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let window = window else { return }
        switch gesture.state {
        case .began:
            // 0.0.69 — 只有右下角是「重启」。左下角这一格不响应长按：母本的
            // `GestureIntroduction` 里「长按」只作为「切换横竖」出现，而 Aevon(59)
            // 明确要把左下角留给横屏手势。识别器的 delegate 已经挡了一层，这里
            // 再判一次是因为 `zone` 在抬手前可能被另一条路改过。
            guard zone == .bottomRight else { return }
            // A press that becomes a drag must not also drag the card.
            pan?.isEnabled = false
            if resetToPlan(in: window.bounds) {
                Log.write("win: gesture long press right corner, 重启 as geometry reset")
            }
        case .ended, .cancelled, .failed:
            pan?.isEnabled = true
        default:
            break
        }
    }

    /// 吸附 — one tap on a side band. Docked is `miniFrame != nil`, and that is
    /// the only thing that says so: a second flag would be a second answer.
    @objc private func handleDockTap(_ gesture: UITapGestureRecognizer) {
        guard let grip = grip else { return }
        dock(zone: zoneFor(cardPoint(gesture.location(in: grip))))
    }

    /// 0.0.48 — the body of the tap, callable without a recognizer: the raw
    /// touch path lands here too, because a tap is a touch that never moved.
    private func dock(zone landed: Zone) {
        guard landed == .left || landed == .right else { return }
        guard let card = card, let window = window else { return }
        if miniFrame != nil {
            undock()
            return
        }
        guard natural.height > 16 else { return }
        miniFrame = card.frame
        // 0.0.45 — 贴边缩小, the master's own words for this state. The height
        // is the only free number (the picture decides the width), and the card
        // goes flush against the edge it was docked from — an inset mini is a
        // mini whose whole point (being out of the way) it fails at.
        // 0.0.54 — 比例取可见区（裁掉顶栏之后），见 `dragMove` 同一处。
        // 0.0.81 — 小窗也按卡片自己的形状走（5:3），不再取画布比例：画布可能是
        // 整屏高的（哔哩哔哩），而「停靠小窗」是卡片的一个状态，不是画布的状态。
        let ratio = 1.0 / FloatHost.fatAspect
        let height = miniHeight(in: window.bounds)
        let width = height * ratio
        let side: CardLayout.Edge = landed == .left ? .left : .right
        let x = side == .left ? 0 : window.bounds.width - width
        let y = Swift.min(Swift.max(card.frame.minY, margin),
                          Swift.max(margin, window.bounds.height - height - margin))
        card.frame = CGRect(x: x, y: y, width: width, height: height)
        followContent()
        installShield()
        syncGrip()
        Log.write("win: card docked " + (side == .left ? "left " : "right ")
                  + size(card.bounds.size) + " at " + point(card.frame.origin))
    }

    // MARK: - 应用层触摸（0.0.48）

    /// 0.0.67 — 同一条事件只处理一次。
    ///
    /// Aevon(58) 的日志里每一拍都是成对的：`ring: bar raw down … #1` 紧跟
    /// `#2`（同一个坐标），`win: touch seen at 347,792` 两行一模一样，
    /// `win: gesture grab zone=…` 也一样。也就是说 `-[UIApplication sendEvent:]`
    /// 这一条事件被投递了两次，而两次都进了我们的入口 —— `dragBegin` 被调两遍
    /// （`resizeStart` 被重设）、`barTouch` 的计数被加两次。
    ///
    /// 为什么这版才显形不重要，能不能挡住才重要：`UITouch.timestamp` 对同一条
    /// 事件是同一个数，对不同事件不同。同相位 + 同时间戳 = 同一条事件，直接
    /// 回上一次的答案（被吞的继续被吞，没吞的继续不吞）。
    ///
    /// 顺带修掉的是圆盘：`summon bar` 的按下计数一直是双倍，选中判定也跟着
    /// 走两遍。
    private var lastTouchStamp: TimeInterval = 0
    private var lastTouchPhase = -1
    private var lastTouchEaten = false

    func touchEntry(phase: Int, at screen: CGPoint, stamp: TimeInterval) -> Bool {
        if stamp > 0, stamp == lastTouchStamp, phase == lastTouchPhase {
            return lastTouchEaten
        }
        lastTouchStamp = stamp
        lastTouchPhase = phase
        let eaten = rawTouch(phase: phase, at: screen, stamp: stamp)
        lastTouchEaten = eaten
        FloatHost.touchIn += 1
        if eaten { FloatHost.touchEaten += 1 }
        // 0.0.92 — 每秒结算一行：「手指进来了多少、被我们吞掉了多少」。
        //
        // Aevon(82) 的卡屏（页面滑不动、点不动）只有两种可能：要么我们吞了触摸，
        // 要么 App 自己不吃。原来的 `win: touch seen` 只记前 12 条按下事件，
        // 之后一片空白 —— 分不出这两种。这一行把两个数放在一起：
        //   `in=8 eat=0` ⇒ 手指进来了、我们一条都没吞 ⇒ 问题在 App 侧（或场景）；
        //   `in=8 eat=7` ⇒ 是我们吞的，接下来只要看 zone 就够了。
        FloatHost.settleTouchCounter(at: stamp)
        return eaten
    }

    /// 每秒一次。`stamp` 是 `UITouch.timestamp`（系统时钟），和日志时间轴同源，
    /// 所以不用再取一次 Date —— 两次取时间在这条路径上是白花。
    private static func settleTouchCounter(at stamp: TimeInterval) {
        if touchAt == 0 { touchAt = stamp; return }
        if stamp - touchAt < 1.0 { return }
        let n = touchIn
        let e = touchEaten
        touchIn = 0
        touchEaten = 0
        touchAt = stamp
        // 没手指、也没吞过：这一秒什么都不用说。
        guard n > 0 || e > 0 else { return }
        // 一整条字面量（不是拼接）：交付前的审计要在二进制里 grep 到它，
        // 相邻字面量拼出来的串在源码里根本搜不到 —— 这个坑记在项目纪律里。
        Log.write(String(format: "win: touch in=%d eat=%d", n, e))
    }

    /// 0.0.92 — 这一秒进来的触摸数 / 被我们吞掉的数（见 `settleTouchCounter`）。
    private static var touchIn = 0
    private static var touchEaten = 0
    private static var touchAt: TimeInterval = 0

    /// 环上的原始触摸。`phase` 用 UITouchPhase 的数值：0 began / 1 moved /
    /// 3 ended / 4 cancelled。返回 true 表示这条事件被浮窗吃掉。
    ///
    /// 为什么要绕到这一层：Aevon(44)/(45)/(46) 三份日志里，卡片外面**一个触摸
    /// 都没有进过我们的任何窗口** —— `win: event hit` 整场只有 ✕ 那一条，
    /// 0.0.47 独立窗口那版的 `win: band probe` 也只有 ✕ 那一条；而卡片里的 ✕
    /// 一直好用。也就是说「窗口收不收得到触摸」这件事本身不可靠，环的几何从来
    /// 不是瓶颈（0.0.44-0.0.47 都在改几何）。
    ///
    /// `-[UIApplication sendEvent:]` 是唯一一个「不管命中哪个窗口都会经过」的
    /// 入口，所以浮窗的四个边从这里拿手指，不再指望某个窗口被问到。
    func rawTouch(phase: Int, at screen: CGPoint, stamp: TimeInterval) -> Bool {
        // 竖条先问一次（0.0.49）。它自己知道自己的地盘，不在地盘里就回 false，
        // 不影响下面任何一行；卡片开着时先问它，正是为了「换 App 的路不被浮窗
        // 的环堵死」。
        if AevonRingGrip.barTouch(phase: phase, at: screen, stamp: stamp) { return true }
        guard let card = card, let window = window else {
            // 卡片在手势中途被关掉：这一路已经把 began 吞了，收尾也必须吞，否则
            // UIKit 会收到一根它从没见过的手指的结束事件。
            let was = rawActive
            rawActive = false
            rawPress?.cancel()
            rawPress = nil
            return was
        }
        let frame = card.frame
        let local = CGPoint(x: screen.x - frame.minX, y: screen.y - frame.minY)
        switch phase {
        case 0:
            if rawSeen < 12 {
                rawSeen += 1
                Log.write("win: touch seen at " + point(screen)
                          + " card=" + point(frame.origin))
            }
            // 系统手势的地盘不抢：屏幕最下面 12 pt 是 home 条，最上面 10 pt 是
            // 状态栏下拉。环是圆的，少这一条边不影响任何人伸手。
            guard screen.y < window.bounds.maxY - 12,
                  screen.y > 10 else { return false }
            // 竖条的地盘也不抢：卡片开着的时候换 App 的路不能被我自己的环堵死。
            guard !AevonRingGrip.summonRect.contains(screen) else { return false }
            guard ringHolds(local, size: card.bounds.size) else { return false }
            rawActive = true
            rawStart = screen
            rawLast = screen
            rawMoved = false
            rawStamp = stamp
            rawVelocity = .zero
            dragBegin(at: local)
            if rawProbe < 20 {
                rawProbe += 1
                Log.write("win: raw touch grab zone=" + name(zone)
                          + " at " + point(local))
            }
            // 边角长按 = 复位。这条路没有 UILongPressGestureRecognizer 可用
            // （事件根本没进 UIKit），所以按住不动这件事自己计时。
            if zone == .bottomRight {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.rawPressFired()
                }
                rawPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + pressDelay, execute: work)
            }
            return true
        case 1:
            guard rawActive else { return false }
            let total = CGPoint(x: screen.x - rawStart.x, y: screen.y - rawStart.y)
            if !rawMoved, abs(total.x) + abs(total.y) > 6 {
                rawMoved = true
                rawPress?.cancel()
                rawPress = nil
            }
            let dt = Swift.max(stamp - rawStamp, 0.008)
            rawVelocity = CGPoint(x: (screen.x - rawLast.x) / CGFloat(dt),
                                  y: (screen.y - rawLast.y) / CGFloat(dt))
            rawLast = screen
            rawStamp = stamp
            if rawMoved { dragMove(total: total, velocity: rawVelocity) }
            return true
        case 3, 4:
            guard rawActive else { return false }
            rawActive = false
            rawPress?.cancel()
            rawPress = nil
            if phase == 4 {
                Log.write("win: raw touch cancelled by the system")
                return true
            }
            let total = CGPoint(x: screen.x - rawStart.x, y: screen.y - rawStart.y)
            if rawMoved {
                dragEnd(total: total, velocity: rawVelocity)
            } else if zone == .left || zone == .right {
                dock(zone: zone)
            }
            return true
        default:
            return rawActive
        }
    }

    private func rawPressFired() {
        guard rawActive, !rawMoved, zone == .bottomRight, let window = window else { return }
        // 0.0.69 — 只有真的动了才写这一行。已经是默认尺寸时 `resetToPlan` 回
        // false，日志里就只剩它自己那句 `already default`。
        if resetToPlan(in: window.bounds) {
            Log.write("win: raw long press corner, 重启 as geometry reset")
        }
    }

    /// 手指是否落在环上：卡片之外，且离卡片边缘不超过 `reach`。卡片坐标系，
    /// 和 `zoneFor` / `cardPoint` 用的是同一个。
    private func ringHolds(_ local: CGPoint, size: CGSize) -> Bool {
        let outside = local.x < 0 || local.y < 0
            || local.x > size.width || local.y > size.height
        guard outside else { return false }
        return local.x >= -reach && local.x <= size.width + reach
            && local.y >= -reach && local.y <= size.height + reach
    }

    // MARK: - 冷启动封面

    /// 冷启动的 App 要几百毫秒才画得出第一帧，这段空窗里卡片是透明的，
    /// 露出来的是窗口后面的黑。母本的办法不是等，是先放一个封面上去。
    ///
    /// 第一帧到了（或三秒超时）：把卡片露出来。
    ///
    /// 0.0.58 —— 这一步以前叫 `revealCover`，作用是撤掉一层图标板。现在没有
    /// 板要撤：卡片自己从 alpha 0 上来，所以只有「什么时候」还有意义。
    ///
    /// 淡入而不是直接置 1。画面自己浮现像系统在放大图标；卡片弹出来像被塞了
    /// 一个窗口 —— 同一个 0.16 秒，两种观感。
    ///
    /// 0.0.59 —— 「闪」这一条修在这里。
    ///
    /// 0.0.58 的 0.16 秒淡入是**没有前提**的：它跟着保活时钟（稳态 200 ms 一拍）
    /// 判断 `contentState == 2`，而那是「scene 认为有内容」，比「这一帧真的上了
    /// 屏」早。于是淡入的前半段画面还是黑的，后半段画面才来 —— 一次渐变里夹着
    /// 一次跳变，眼睛看到的就是闪。
    ///
    /// 现在两件事一起改：谁来 reveal 交给 `SceneProbe` 的 50 ms 观察器（连续两拍
    /// 满足才动手，见 `watchFirstFrame`），这里只管「已经能画了，所以浮现」。
    /// 光晕同步，否则卡片透明而影子还在。
    func revealContent(_ why: String) {
        guard awaitingFrame else { return }
        awaitingFrame = false
        let ms = (CACurrentMediaTime() - frameAt) * 1000
        Log.write(String(format: "win: first frame shown after %.0fms (%@)",
                         ms, why as NSString))
        guard let card = card else { return }
        let glow = self.glow
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState],
                       animations: {
                           card.alpha = 1
                           glow?.alpha = 1
                       },
                       completion: nil)
    }

    /// 首帧观察器问的那一个问题。`revealContent` 有 guard，这里只负责回答
    /// 「还有没有人在等」—— 观察器每 50 ms 醒一次，卡片露出来之后就该停。
    var waitingForFrame: Bool { awaitingFrame }

    /// The way out of 停靠小窗: a tap anywhere on its picture. The scene view
    /// would swallow that tap and forward it to the app, so a transparent shield
    /// goes above it — the same trick as the ✕ used to be, a sibling drawn over
    /// the hosted view. 0.0.54 — there is no ✕ to stay below any more, so the
    /// shield goes straight on top of the picture.
    private func installShield() {
        guard let card = card, shield == nil else { return }
        let view = UIControl(frame: card.bounds)
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addTarget(self, action: #selector(undock), for: .touchUpInside)
        card.addSubview(view)
        shield = view
    }

    @objc private func undock() {
        guard let card = card, let window = window, let saved = miniFrame else { return }
        miniFrame = nil
        card.frame = clamped(saved, in: window.bounds)
        followContent()
        shield?.removeFromSuperview()
        shield = nil
        syncGrip()
        Log.write("win: card undocked " + size(card.bounds.size)
                  + " at " + point(card.frame.origin))
    }

    // MARK: - geometry

    /// The content keeps the card's size for one reason only: it is the scene's
    /// own coordinate space, scaled. Re-centring without re-scaling is how a
    /// resize leaves the picture in the old corner.
    ///
    /// 0.0.54 — 顶部被裁掉 `cropTop` 源点，所以中心也要跟着上移半个裁切量，
    /// 否则缩小一次之后顶部那一条又会滑回卡片里。
    private func followContent(updateCorner: Bool = true) {
        guard let card = card, let content = content, visible.height > 16 else { return }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        content.center = CGPoint(x: card.bounds.midX,
                                 y: card.bounds.midY - cropTop * scale / 2)
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        // A resized card is the same device at another scale, so the corner is
        // the same screen corner at another scale. Leaving the old radius on a
        // shrunk card reads as a rounded rectangle that has been sanded down.
        //
        // 0.0.64 — 圆角不再读上面那个 `scale`（那是「画面缩放比」，跟着卡片
        // 高度走）。见 `applyCorner`：观感上的圆角只由卡宽决定。
        //
        // 0.0.67 — 拖动的每一帧传 false：圆角在 `dragEnd` 里一次算准。
        if updateCorner { applyCorner() }
        applyBars()
    }

    /// 画布在这张卡片里有没有留边。有就填黑，没有就透明 —— 一个判断，两个
    /// 调用点（开窗、每次缩放之后），所以卡片不会出现「缩一下底色变了」。
    private func applyBars() {
        guard let card = card else { return }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        let shown = CGSize(width: visible.width * scale, height: visible.height * scale)
        let bars = shown.width < card.bounds.width - 0.5 || shown.height < card.bounds.height - 0.5
        let wanted: UIColor = bars ? .black : .clear
        if card.backgroundColor != wanted { card.backgroundColor = wanted }
    }

    // MARK: - 0.0.73 承载面的位置看门狗

    /// 「第一次打开内容尺寸不对，必须手动缩放一下」的真正成因。
    ///
    /// Aevon(63) 的两张截图（同一面卡，354x590 与 376x627，缩放比 0.823 / 0.874）
    /// 把形状量出来了 —— 用卡内坐标对齐到 430x717 版式：
    ///
    ///   首开：顶栏文字在卡内 74.6 pt，文案首行 524.5 pt；
    ///   缩放后：顶栏 63.4 pt，文案 463.3 pt，两者比值 1.13 ≈ 1/0.874。
    ///
    /// 74.6 / 524.5 与 430x717 版式里的 72.5 / 530 **一比一**吻合。也就是说首开那张
    /// 不是「另一种排版」，而是**内容按 1:1 画、被卡片从右下裁掉**：右侧那一列图标
    /// （内容 x 380..420）和整条底栏（y 634..717）都落在 354x590 的框外 —— 这正是
    /// 截图里「没有右列、没有底栏、文案被切」的形状，也解释了为什么它在任何 App 上
    /// 都一样：裁的是我们的承载面，不是别人的界面。
    ///
    /// 谁把 `transform` 抹掉的：`_UIScenePresentationView` 由 `_UIScenePresenter`
    /// 托管，每次 scene 的 settings 被写（`AevonSceneFrameSet`、轻推、还原都是写它），
    /// 系统就按 scene 的 frame 重设一次它的 `frame`：原点 (0,0)、尺寸 430x717、
    /// transform 单位阵。`show` 里那两行写在 `presenter.activate` 之前，activate
    /// 之后每一次 settings 写入都会再抹一次，而 `reassertCanvas` 只写 `bounds`
    /// —— 于是最后一次轻推还原之后，卡片就停在 1:1 那一版上。
    ///
    /// 角拖动之所以能救回来：`followContent` 把这两个量又写了一遍。
    ///
    /// 所以修法不是再猜一个比例，而是让这两个量每次被抹掉之后自己回来。只碰我们
    /// 自己的承载视图，不碰 App 的窗口，也不碰系统的任何测量。
    @discardableResult
    func reapplyPlacement(_ why: String) -> Bool {
        guard let card = card, let content = content, visible.height > 16 else { return false }
        let scale = FloatHost.fitScale(for: visible, in: card.bounds.size)
        let center = CGPoint(x: card.bounds.midX,
                             y: card.bounds.midY - cropTop * scale / 2)
        let at = content.transform
        let off = abs(at.a - scale) > 0.004 || abs(at.d - scale) > 0.004
            || abs(content.center.x - center.x) > 0.5
            || abs(content.center.y - center.y) > 0.5
        guard off else { return false }
        content.transform = CGAffineTransform(scaleX: scale, y: scale)
        content.center = center
        // 前 12 次各写一行：这一条如果真的每拍都要重写，说明还有别的东西在抹它，
        // 日志会直接说出频率；稳定下来之后就不再占版面。
        if placementLogs < 12 {
            placementLogs += 1
            Log.write("win: placement put back " + String(format: "%.3f", scale)
                      + " was=" + String(format: "%.3f", at.a)
                      + " (" + why + ")")
        }
        return true
    }

    /// `重启`, as much of it as a window can do by itself: back to the frame the
    /// card was built with, with the remembered placement cleared first.
    ///
    /// 0.0.69 — 返回「真的做了没有」。Aevon(59)：卡片本来就在默认的 5:3 尺寸上
    /// 长按，什么都不该发生 —— 原来的实现仍然清记忆、重算、重设 frame，虽然
    /// 落地数值一样，但 `CardLayout.reset()` 把用户记住的位置抹掉了，下一次开
    /// 窗就换了地方。所以「已经默认」必须在这里早退，而且早退要在清记忆之前。
    @discardableResult
    private func resetToPlan(in bounds: CGRect) -> Bool {
        guard let card = card, natural.height > 16, bounds.width > 64 else { return false }
        // 0.0.65 — 形状不再存盘，也就没有「复位形状」这件事：画布永远是
        // `fatRender` 算出来的那一块，复位只把卡片摆回开窗时的位置与大小。
        // 0.0.54 — 复位要和 `show` 算同一件事：按原始比例布局，再把高度减掉
        // 顶栏。直接用 `visible` 去 plan 会得到另一条比例（scale 变大、卡片变
        // 宽），复位一次窗口就胖一圈 —— 这是最容易在真机上被当成「新 bug」的
        // 那种不一致。
        let base = self.plan(in: bounds, source: natural)
        var frame = base.frame
        frame.size.height = Swift.max(80, base.frame.height - cropTop * base.scale)
        // 1.5 pt 是「同一个尺寸」的容差：`fatRender` 四舍五入、屏幕高度系数
        // 取整，都可能让同一个默认值落成 347.4 与 347。停靠中（`miniFrame`
        // 非 nil）永远不算默认，长按要能把它还原回来。
        if miniFrame == nil,
           abs(card.frame.width - frame.width) < 1.5,
           abs(card.frame.height - frame.height) < 1.5 {
            Log.write("win: long press corner, already default " + size(card.bounds.size)
                      + " — no action")
            return false
        }
        CardLayout.reset()
        card.frame = clamped(frame, in: bounds)
        miniFrame = nil
        shield?.removeFromSuperview()
        shield = nil
        followContent()
        syncGrip()
        Log.write("win: card reset to " + size(card.bounds.size)
                  + " at " + point(card.frame.origin))
        return true
    }

    // MARK: - 0.0.69 激活之后再交一次画布尺寸

    /// 承载面的尺寸在 `show` 里就写好了 —— 但那一步发生在 `presenter.activate`
    /// **之前**。
    ///
    /// Aevon(59) 的第一条（「每一次打开时内容尺寸不对，必须手动缩放一下才显示正确
    /// 的顶栏底栏」）和上一版遗留的第二条是同一件事，判据是这个调用顺序，不是猜：
    ///
    ///   · `show` 里的 `view.bounds = source`（932 → 717）跑在 `activate` 前一行；
    ///   · 日志里 `view cls=_UIScenePresentationView … natural=430x932` 之后紧跟
    ///     `hosted bounds after=430x717` —— **视图**确实换了尺寸；
    ///   · 而真机上「手动缩放一下」改的正是这个尺寸：`followContent` 每帧重写
    ///     `transform`/`center`，承载上下文随之重排一次，App 才开始按 717 排版。
    ///
    /// 也就是说：尺寸写在了 presenter 还没接管的时候，那一次 resize 没有被当成
    /// 「App 的窗口变了」。这里补的正是那一次，而且只碰我们自己的承载视图 ——
    /// 同一个对象、同一个进程、1 pt 的真实变化。绝不下沉到 App 的窗口去
    /// （0.0.67 那么做毁过一台手机）。
    func reassertCanvas() {
        guard let content = content, natural.height > 16 else { return }
        let target = CGRect(origin: .zero, size: natural)
        content.bounds = CGRect(x: 0, y: 0, width: natural.width, height: natural.height + 1)
        // 两次写在同一个 runloop 里会被合并成一次布局，App 看不到「变过」。
        // 0.02 s 之后写第二次，中间隔一次提交。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self = self, let content = self.content else { return }
            content.bounds = target
            self.followContent()
            Log.write("win: canvas re-asserted " + self.size(self.natural)
                      + " after activate")
        }
    }

    // MARK: - 0.0.72 替操作者做掉「手动缩放一下」

    /// 卡片还在：`card` 与窗口都非空。给延迟回调用的判据 —— 0.45 s 之内可能
    /// 又关又开一面新卡，那时候不该再往旧 scene 上写。
    var isUp: Bool { card != nil && window != nil }

    /// A card that can be dragged off the screen can only be brought back by
    /// closing it, so the edges are a wall, not a suggestion.
    ///
    /// 0.0.46 — the wall is `reach` thick, not `margin`. `margin` is 8 pt and a
    /// drag that parked the card 8 pt from the left edge left an 8 pt band
    /// there — the operator's own next drag then "did nothing". The top keeps
    /// none of it: the top strip answers no gesture at all, so reserving room
    /// above the card would only be a gap nobody can use.
    private func clamped(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        var result = frame
        let side = frame.width + reach * 2 <= bounds.width ? reach : 0
        let under = frame.height + reach * 2 <= bounds.height ? reach : 0
        let maxX = max(side, bounds.width - result.width - side)
        let maxY = max(0, bounds.height - result.height - under)
        result.origin.x = min(max(result.origin.x, side), maxX)
        result.origin.y = min(max(result.origin.y, 0), maxY)
        return result
    }

    private func point(_ p: CGPoint) -> String {
        String(format: "%.0f,%.0f", p.x, p.y)
    }

    private func size(_ s: CGSize) -> String {
        String(format: "%.0fx%.0f", s.width, s.height)
    }

    /// `UIApplication.shared` is a force-unwrapped accessor. Inside SpringBoard
    /// it is normally valid, and "normally" is not worth a phone: go through the
    /// runtime and fall back to a screen-sized window when there is no app yet.
    private func mainScene() -> UIWindowScene? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let meta = NSClassFromString("UIApplication") as? NSObject.Type,
              meta.responds(to: selector),
              let unmanaged = meta.perform(selector),
              let application = unmanaged.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return application.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// The gesture ring: the card's frame grown by the band, with the card's own
/// rect punched out and the top strip punched out too.
///
/// It exists because a hosted scene view owns its touches. Aevon(33) put the
/// recognizers on the card and got ninety seconds of silence — the presentation
/// view forwarded every touch in the picture to the app, and the ✕ disc worked
/// only because it is a sibling drawn above it. Outside the card there is no
/// scene, no remote window and nothing to forward to.
///
/// `hole` is what keeps the picture honest. Touching inside the card returns nil
/// from hitTest, so the touch goes to the card, to the presentation view, and to
/// the app — tapping, scrolling and liking inside the floating window behave like
/// a real window.
///
/// 0.0.47 — 这一圈住进了自己的窗口（`FloatHost.makeBand`），所以它不再和卡片
/// 抢同一个窗口的命中，也不再有「被某个兄弟视图挡在前面」这种可能。
final class GripView: UIView {
    /// The card's rect in this view's own coordinates.
    var hole: CGRect = .zero
    /// The first few touches are written down. If a report ever says "the edge
    /// still does nothing", this line separates "the touch never arrived" from
    /// "it arrived in a zone that does not do that".
    ///
    /// 0.0.41 — four was too few. Aevon(39)'s log holds exactly one touch per
    /// card (the ✕), because the operator's four attempts at the band came
    /// after it and the counter had already stopped. Eight now, and the window
    /// below matches.
    private var proven = 0   // 0.0.45 — 8 → 20; Aevon(43) spent all four band
                             // attempts inside the first eight touched slots

    // 0.0.44 — the heat map is invisible again, and this time the geometry
    // stays exactly where it is.
    //
    // 0.0.42 painted it because Aevon(40) could not say whether a thumb that
    // landed nowhere had missed the ring or the ring had missed the thumb. That
    // question is answered: Aevon(41)/(42) show `gesture grab zone=right`,
    // `bottom-middle` and `bottom-corner` arriving, docking, resizing and
    // flick-closing. Aevon(42) asks for the colour to go away — while the four
    // zones stay, because they are what the fingers find.
    //
    // So: no fill, no `draw`. The zones are `point(inside:)` and the zone
    // arithmetic below, which do not need to be visible to work. It is one
    // subclass with one property and no pixels.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return !hole.contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard proven < 20, let touch = touches.first else { return }
        proven += 1
        Log.write("win: grip touch at " + String(format: "%.0f,%.0f", touch.location(in: self).x,
                                                 touch.location(in: self).y)
                  + " #" + String(proven))
    }
}

/// A window that is only answerable where its content is. Everything else falls
/// through to the app underneath, which is what makes a floating card usable
/// while a full-screen app is running.
final class FloatWindow: UIWindow {
    /// The first few touches, printed as they enter the window and before any hit
    /// testing of our own. Two reports in a row have ended with "the gesture does
    /// not fire" and an empty probe, and an empty probe means either the touch
    /// never reached this window or it reached it and missed the ring.
    /// `sendEvent` is the one place that can tell those apart.
    private var seen = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The bare root view is not a thing to answer with: letting it take the
        // touch costs the desktop its icons and gains nothing, because it has no
        // recognizers and no controls on it.
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }

    override func sendEvent(_ event: UIEvent) {
        if seen < 20, let touch = event.allTouches?.first, touch.phase == .began {
            seen += 1
            let point = touch.location(in: self)
            let who = hitTest(point, with: event)
                .map { String(cString: object_getClassName($0)) } ?? "nil"
            Log.write("win: event hit #" + String(seen)
                      + " at " + String(format: "%.0f,%.0f", point.x, point.y)
                      + " -> " + who)
        }
        super.sendEvent(event)
    }
}

/// 0.0.47 — 手势面的窗口。层级 statusBar+1：任何 App 的窗口都在它下面，所以
/// 「浮窗外侧」这一圈不会因为某个窗口盖在上面而收不到触摸。
///
/// `hitTest` 只回答一件事：命中环（`GripView`）就返回环，别处一律 nil —— 桌面
/// 图标、卡片里的 App 都还归别人。前 20 次提问写进日志：点在哪、答的哪个类。
/// 下一份日志因此能一句话分开「窗口没收到触摸」和「收到了但环判错」，这正是
/// 0.0.44-0.0.46 三轮里始终分不开的那两件事。
final class BandWindow: UIWindow {
    var probe: ((CGPoint, String) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        let answer = (hit === self || hit === rootViewController?.view) ? nil : hit
        probe?(point, answer.map { String(cString: object_getClassName($0)) } ?? "nil")
        return answer
    }
}

/// 这一层的根视图，和竖条那层一样：自己什么都不接，接住的只有环。一张全屏且
/// 会答话的透明视图，就是一张桌面点不动的透明纸。
final class BandRoot: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 0.0.48 — `-[UIApplication sendEvent:]` 的落点（钩子在 Sources/AevonScene.m）。
///
/// `@_cdecl` 只有一个理由：这个函数必须能被 C 直接调用。钩子跑在每一个事件上，
/// 它不该为了调一行 Swift 去建桥、查类、拼 block —— 三个 double 和一个小整数就
/// 是全部。
///
/// 返回 1 = 这条事件已被浮窗吃掉，不要把原事件再交下去。
@_cdecl("AevonFloatTouch")
public func AevonFloatTouch(_ phase: Int32, _ x: Double, _ y: Double, _ stamp: Double) -> Int32 {
    return FloatHost.shared.touchEntry(phase: Int(phase),
                                       at: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                       stamp: TimeInterval(stamp)) ? 1 : 0
}
