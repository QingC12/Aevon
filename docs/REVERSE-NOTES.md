# 逆向事实速查（来自母本 Stheno 0.1.23）

本仓库所有设计决策的依据都在这里。数据源：`stheno-逆向分析/`（deb、6 个 dylib、classdump、22 个 section 导出）。

## 一、母本规模

| 项 | 数值 |
|---|---|
| 主库 Swift 类 | 32（其中 21 个是 Hook 类） |
| ObjC 选择子 | 128 |
| 功能键（zh-Hans） | 81 |
| 注入 dylib | 6（主库 + 键盘 + 注入器 + 若干） |

81 个功能键 = 一份现成的需求清单。P7 的设置面板逐键对齐即可。

## 二、承载模型（P1 的核心，不可替换）

```
SpringBoard
 └─ UIScenePresentationManager
     └─ createPresenterWithIdentifier:priority:
         └─ _UIContextLayerHostView   ← 浮窗真正挂载的位置
             └─ 独立 Scene（BackBoard 渲染服务托管）
```

**为什么不能用「在 SpringBoard 里放一个 UIView」替代**：
动画与合成由 BackBoard 渲染服务执行，不经主线程，所以主线程降载时浮窗依然流畅。
一旦换成普通 UIView，后面五层（几何、手势、圆盘、保活、键盘）全部要重写。

二进制命中数（自证，不依赖跨厂商对照）：

- `createPresenterWithIdentifier:priority:` × 4
- `_UIContextLayerHostView` × 4
- `_scene:interceptUpdateWithNewSettings:` × 2
- `_setDeactivationReasons:onScene:withSettings:reason:` × 1

## 三、保活：只改参数，不加写

母本全库 `Assertion` **0 命中**（小写 `assertion` 的 4 处是 Swift 运行时 `$ss17_assertionFailure` 导入符号，与保活无关）。

保活靠的是拦截系统下发的新 settings，在内存里改参数：
**先比对，确实变了才写，写完不复查。**

这条是历史事故的直接结论：每写一次就闪一次，根因就是多余的写回。

## 四、键盘必定要独立桥

- `remoteKeyboardWindowForScreen` × 2 在 `SthenoKeyboard.dylib`
- `KeyboardArbiter` × 4、`BaseKeyboardOffset` × 2、`floatingsHasKeyboard` × 4 在主库

浮窗是独立 Scene，键盘在场景之外，**必须桥接**。母本为此单独出一个注入 UIKit 的库，这不是可选优化。

## 五、跳转链路（P8）

`_openURLCore` 在母本 **0 命中**。走的是：

`__interceptors` + `SS*` 系列开关 + UIKit / SafariViewService 双注入

按 `_openURLCore` 去实现 P8 方向就是错的。

## 六、无法 1:1 的部分

Swift 方法体已被 strip，**不存在逐指令复刻的可能**。
验收口径是：功能 / 交互 / 设置项三层等价 + 双机盲测说不出差别，不承诺帧级一致。

## 七、不复刻的部分

授权体系（`inject.stheno.com` / `validKey`）属于第三方商业资产，不复刻。
81 键里两个激活相关项保留键位、功能隐藏。
