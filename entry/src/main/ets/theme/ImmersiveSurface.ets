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
