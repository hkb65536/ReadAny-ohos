/**
 * Immersive material options, built behind an API-level guard.
 *
 * `systemMaterial` is **never a free-standing component attribute on a popup**. It is
 * valid as a universal attribute only inside a `Navigation`/`NavDestination` title bar
 * or a horizontal `Tabs` bottom `TabBar` with `barPosition: BarPosition.End`; everywhere
 * else the framework discards it and logs
 *
 *     Material inactive: out of scope. Use component in navigation title bar or Tabbar.
 *
 * Popup-class surfaces are served by their **options object** instead — for this app's
 * `bindMenu` that is `MenuOptions.systemMaterial`, inherited from `ContextMenuOptions`
 * (`common.d.ts:15594`; `MenuOptions extends ContextMenuOptions` at `common.d.ts:15637`).
 * That route is in the framework's page-wide list and needs no app-level switch.
 *
 * So what this module produces is an *option object*, not an attribute, and the callers
 * differ in where they put it. Availability is guarded by `canApplyImmersiveMaterial()`
 * and callers branch rather than interpolating a maybe-value, because an option object
 * cannot be created as an expression inside a component call in ArkTS — the object is
 * produced by a function and the *call* is what is guarded. On an API-24 device the
 * branch holding the API-26 call is never taken, so the missing option never reaches
 * the framework.
 */

import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

/** API level immersive material was introduced at. */
export const API_IMMERSIVE_MATERIAL: number = 26;

/** The running device's API level, read once. */
const API_LEVEL: number = readApiLevel();

function readApiLevel(): number {
  try {
    const value: number = deviceInfo.sdkApiVersion;
    return Number.isNaN(value) ? 0 : value;
  } catch (err) {
    // Treated as the oldest supported device: the fallbacks are always correct.
    return 0;
  }
}

/**
 * True when the immersive material option object can be constructed.
 *
 * Checks the API level *before* touching the 26-only API, so an older runtime never
 * evaluates the option and the codebase needs no version-alias mechanism.
 */
export function canApplyImmersiveMaterial(): boolean {
  return API_LEVEL >= API_IMMERSIVE_MATERIAL;
}

/**
 * Build the material option.
 *
 * Called from inside a guarded builder only. Returns an opaque type so this
 * module's signature does not pull the API-26 type into files compiled against
 * API 24.
 */
export function immersiveMaterialOption(): Object {
  return new uiMaterial.ImmersiveMaterial({
    // `REGULAR` thickness maps onto the system's material level; the framework still
    // adapts it to the user's chosen level and the device's power state.
    style: uiMaterial.ImmersiveStyle.REGULAR,
  });
}

/**
 * The material for a bar that **floats at the top** of a page: `THIN`.
 *
 * ## This is a deliberate departure from the design specification, and it is user-directed
 *
 * The 沉浸光感 design spec's own prescription for a component 悬浮 at the top is `ULTRA_THIN`:
 * 「当组件在顶部悬浮时，推荐使用 ULTRA_THIN 枚举参数，并结合渐变模糊效果延展顶部内容展示空间」
 * (沉浸光感 · 场景规范). The user asked for the top bar to match the bottom one instead —
 * **「以底栏为准」** — so this file deliberately does not follow that line, and the departure is
 * recorded here rather than made silently.
 *
 * ## Why `THIN` is what "the bottom bar's material" actually is
 *
 * The bottom bar does **not** use `ImmersiveStyle` at all: it sets
 * `systemMaterialEffect: { materialType: hdsMaterial.MaterialType.IMMERSIVE (101),
 * materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE (10) }`, which are HDS **policy** enums, and
 * the FAQ states outright that 「hdsMaterial：不提供与 uiMaterial.ImmersiveStyle 对等的材质厚薄程度样式
 * 配置」. That policy resolves to **`THIN`**, named by two official sources: 组件适配沉浸光感 · 底部页签
 * (「沉浸式系统材质样式默认取值为 THIN」) and 设计规范 · 场景规范 (「当组件在底部悬浮时，推荐使用 THIN
 * 枚举参数」). So `THIN` is the bottom bar's thickness by name, and `ULTRA_THIN` was a different
 * one. `@ohos.arkui.uiMaterial.d.ts:174` declares the order
 * `ULTRA_THIN=0, THIN=1, REGULAR=2, THICK=3, ULTRA_THICK=4`, so this is one enum member.
 *
 * ## Two consequences that belong on the record
 *
 *  - **The paired companion changes with it.** `ULTRA_THIN`'s spec companion is 渐变模糊
 *    (deliberately not implemented here — a material's `materialFilter` already contains the
 *    background blur and stacking another is the repeated work the power guide forbids), while
 *    `THIN`'s is **渐变颜色蒙层**, which a `Navigation` cannot carry: it offers no mask parameter,
 *    and the gradient mask the bottom bar has comes from `HdsTabs`' `barFloatingStyle`. So the
 *    companion is unavailable rather than skipped, and that is the honest cost of matching the
 *    bottom bar.
 *  - **On flat paper the two are already indistinguishable, so this change is invisible on a
 *    blank page.** Measured: page `241,242,237`, top capsule `242,243,238`, bottom capsule
 *    `242,243,238` — the two capsules are byte-identical over flat background today. What the
 *    enum changes is how much of what is **behind** the surface shows through, so it is only
 *    visible where text sits under the bar. `ImmersiveStyle` is also documented as effective
 *    **only on high/mid-compute devices**; on a low-compute device the material paints a
 *    background colour instead and neither thickness is observable.
 *
 * `materialColor` is deliberately **not** set here. On a thin layer the tint is what the filter
 * works with, and the reader's page can be any of three theme tones; leaving it unset lets the
 * framework tint the layer from what is behind it, which is the behaviour a floating reading bar
 * wants. The menu's material sets it because a menu must stay recognisably the app's card.
 *
 * Same guarded contract as `immersiveMaterialOption` above: this is only reached through
 * `topBarMaterialOption` in `Theme.ets`, which checks the API level and the device's support
 * before calling it, so an API-24 device never evaluates the API-26 namespace.
 */
export function immersiveTopBarMaterialOption(): Object {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
  });
}

/**
 * The material for the **shelf's header bar**: the same `THIN` layer as the reader's top bar, with
 * 自动反色 switched on.
 *
 * ## Why it is a second function rather than a parameter on the reader's
 *
 * `immersiveTopBarMaterialOption` above is the reader's material, and the reader's top bar is
 * verified work (r112/r113/r116). It is deliberately left byte-identical, so this round's claim about
 * the reader is that **nothing in its recipe changed** — a claim a defaulted parameter could not make,
 * and one the audit can check by name.
 *
 * ## What `colorInvert` is, and why it is `true` here
 *
 * `ImmersiveOptions.colorInvert` (`@ohos.arkui.uiMaterial.d.ts:380`, `@since 26.0.0`, default
 * **false**) is what makes a material's subtree adapt a colour to the material's own backdrop:
 *
 *   「设置了材质对象的节点的子树是否自动将颜色适配为材质背景色的反色。若为 false，则不会自动反色。
 *     若为 true，则当材质样式满足系统定义的反色条件时才会自动反色。」
 *
 * It is **not** a licence for hardcoded colours to invert. The same reference fixes the whole
 * condition list (沉浸光感常见问题 · 开启自动反色后文字颜色没有变化) and names the resource set that
 * participates — 表1 · 特殊资源值对应的深浅色值 — so a palette constant stays exactly as written.
 * Two of its three conditions are properties of the surface rather than of this app: the device must be
 * high- or mid-compute (`SMOOTH` inverts nothing), and the style must be `THIN` or `ULTRA_THIN`
 * (「材质样式需要为THIN或ULTRA_THIN，在REGULAR、THICK、ULTRA_THICK样式下不生效」 — `THIN` already).
 *
 * ## The one place it is spent, and why that is the documented 正例
 *
 * 沉浸光感 · 功耗优化 gives this exact shape as its **正例** — 「缩小反色范围，仅对需要保证可读性的局部
 * 区域开启反色」, a small local container with 「多数内容不开启反色」 around it — and its 反例 is the
 * opposite (a material over a long list, where 「所有子项颜色都参与计算」). The caller puts this on the
 * header's own bar-filling container, which holds a title, a search field and two 48 vp circles and
 * nothing else; the grid is outside the title bar entirely.
 *
 * Same guarded contract as its two siblings: only reachable through a `Theme.ets` decision function
 * that has already checked the API level and the device's support, so an API-24 device never evaluates
 * the API-26 namespace.
 */
export function immersiveHeaderBarMaterialOption(): Object {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    colorInvert: true,
  });
}

/** Whether the device reports support for the immersive effect. */
export function deviceSupportsImmersiveMaterial(): boolean {
  if (!canApplyImmersiveMaterial()) {
    return false;
  }
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch (err) {
    return false;
  }
}

/** The user's chosen material level, for the diagnostics block. -1 when unreadable. */
export function globalMaterialLevel(): number {
  if (!canApplyImmersiveMaterial()) {
    return -1;
  }
  try {
    return uiMaterial.getGlobalMaterialLevel() as number;
  } catch (err) {
    return -1;
  }
}

/**
 * `uiMaterial.MaterialLevel.SMOOTH`'s numeric value.
 *
 * Written out rather than read from the enum, because reading an enum member needs the
 * API-26 runtime that this module deliberately touches only behind
 * `canApplyImmersiveMaterial()` — a module-load-time enum read would be evaluated on an
 * API-24 device, where the namespace is absent. The declaration order is
 * `EXQUISITE = 0, GENTLE = 1, SMOOTH = 2` (`@ohos.arkui.uiMaterial.d.ts`), and a change
 * to it would be a platform break that this constant's audit check would report.
 */
export const MATERIAL_LEVEL_SMOOTH: number = 2;

/**
 * True when the material level is the low-compute one.
 *
 * **This is the level at which a material stops being a filter and becomes a
 * background colour.** `uiMaterial.d.ts` states it in two places: on high- and
 * mid-level devices the filter and shadow of the material layer are what is affected,
 * while on low-level devices it is `backgroundColor`, `borderColor`, `borderWidth` and
 * `shadow`; and `ImmersiveOptions.materialColor` — the only knob that would put this
 * app's palette *into* the material — "takes effect only for the display effect of
 * devices with high- and mid-level computing power".
 *
 * So at this level a system material repaints the surface in the system's own colour
 * and the app's tint is ignored, which is the defect this project has already hit
 * twice (a system material knows only light from dark, so under sepia it paints the
 * surface white). Callers use this to fall back to the opaque palette instead.
 */
export function materialLevelPaintsBackground(): boolean {
  return globalMaterialLevel() === MATERIAL_LEVEL_SMOOTH;
}

/**
 * The material for a popup menu, with a colour of this app's own.
 *
 * **`THICK`, not `REGULAR`.** THICK is the menu's own documented default, not a
 * preference: the component-adaptation guide gives a menu `THICK` in both of its
 * enablement modes, the API reference's 「示例24（设置菜单的沉浸光感）」 passes `THICK`,
 * and the 沉浸光感 design spec asks for `THICK` of a component that "非常驻在页面之上，
 * 且可能会在任意位置弹出" — which is exactly what a `bindMenu` popup is. `REGULAR` was
 * this file's earlier value and is the guidance's style for regular in-flow content,
 * i.e. the wrong role for a popup. Thicker also means less of the page shows through,
 * which can only help legibility, never hurt it.
 *
 * `materialColor` is the documented way to keep an application's surface recognisable
 * under a material ("used to add a pure color effect for the material filter"), and it
 * is the one knob that survives the low-compute level too, where it *becomes* the
 * `backgroundColor` (API reference, `ImmersiveOptions.materialColor`). The SDK requires
 * it to carry transparency, because a fully opaque colour blocks the filter completely.
 * The caller passes a palette colour with an alpha channel.
 *
 * The enum member is read inside this body rather than at module scope: the body only
 * runs after `canApplyImmersiveMaterial()` has admitted the caller, so an API-24 device
 * never evaluates it. Same guarded contract as `immersiveMaterialOption` above.
 */
export function immersiveMenuMaterialOption(materialColor: ResourceColor): Object {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
    materialColor: materialColor,
  });
}
