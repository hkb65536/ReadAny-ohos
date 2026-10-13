/**
 * Theme tokens and capability degradation.
 *
 * The app targets API 26 but installs from API 24, so every 7.0-only visual
 * feature has to be optional. This module is the single place that answers "what
 * can this device actually do", so no screen has to ask.
 *
 * The version gate is `deviceInfo.sdkApiVersion`, not `canIUse`. `canIUse` answers a
 * *syscap* question ("does this system capability exist"), which says nothing about
 * the API level an attribute was introduced at — and immersive material is gated on
 * the latter.
 *
 * Fallback order for a translucent surface:
 *
 *   1. Immersive material (API 26+, and only when the device reports support)
 *   2. `backgroundBlurStyle` (API 9+, the pre-26 look)
 *   3. Opaque colour
 *
 * Step 3 exists for a reason: blur is a GPU cost, and a low-end device with a large
 * list behind a translucent bar is slower than one with a flat colour. A theme that
 * degrades to an opaque surface is still a correct theme.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
// The 26-only material module, imported once here so the version gate lives in a
// single place. Accessing the namespace is safe on older runtimes; only building
// the option object is not, which is why that is a function call.
import * as immersive from './ImmersiveSurface';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatTheme';

/** API level immersive material was introduced at. */
export const API_IMMERSIVE_MATERIAL: number = 26;

/**
 * The device's API level.
 *
 * Read once at module load: it cannot change while the process lives, and reading
 * it per call would put a device-info query in every render path.
 */
const API_LEVEL: number = readApiLevel();

function readApiLevel(): number {
  try {
    const value: number = deviceInfo.sdkApiVersion;
    return Number.isNaN(value) ? 0 : value;
  } catch (err) {
    // A device that refuses this query is treated as the oldest supported one,
    // which is the safe direction: the fallbacks are always correct, only plainer.
    return 0;
  }
}

export function apiLevel(): number {
  return API_LEVEL;
}

/**
 * How the shell's surface was drawn.
 *
 * Reported in the self-test block, because a silent fallback and a material that
 * renders as nothing look identical on screen.
 */
export enum SurfaceStyle {
  /** API 26+ material; the only option that follows the system's material level. */
  IMMERSIVE = 'immersive',
  /** Pre-26 standard blur. */
  BLUR = 'blur',
  /** No translucency; the safe answer everywhere. */
  OPAQUE = 'opaque',
}

/** Blur radius for the pre-26 path, in vp, when a caller chooses to draw one. */
export const FALLBACK_BLUR_RADIUS: number = 12;

// ---------------------------------------------------------------------------
// Design tokens
//
// Values taken from the HarmonyOS design guidance rather than invented:
//
//  - The type scale uses `HarmonyOS Sans`, which is the system face; naming it
//    explicitly means a user font override still resolves.
//  - Dark-mode body text targets a contrast ratio above 5:1 but below the ~17.6:1
//    guidance ceiling. That is why the night palette is a warm near-black with an
//    off-white text colour rather than `#000000`/`#FFFFFF`, which exceeds the
//    ceiling and reads as harsh on an OLED panel.
//  - Tap targets are 48vp, the guidance minimum.
// ---------------------------------------------------------------------------

/** System font family. */
export const FONT_FAMILY: string = 'HarmonyOS Sans';

/** Type scale in fp, from the guidance's phone column. */
export const TYPE_TITLE_LARGE: number = 30;
export const TYPE_TITLE: number = 20;
export const TYPE_SUBTITLE: number = 16;
export const TYPE_BODY: number = 14;
export const TYPE_CAPTION: number = 12;

/** Minimum interactive size in vp. */
export const MIN_TAP_TARGET: number = 48;

/** Corner radii in vp. */
/**
 * Corner radii, from the HarmonyOS design specification.
 *
 * https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/corner-radius-parameter-0000002556468705
 *
 * The spec defines five general-purpose values and two rules: **同层统一** (controls of the
 * same kind must share one radius) and **层级正相关** (the higher an element sits in the
 * hierarchy, the larger its radius).
 *
 *   4vp   标签与角标          labels, badges, small status marks
 *   8vp   图片与图标          images, icons, small containers
 *   16vp  卡片与内容容器      cards, content containers
 *   20vp  按钮、菜单、选项卡  buttons, menus, tabs — anything you tap
 *   32vp  半模态与弹出框      sheets, dialogs, top-layer surfaces
 *
 * These are named by *role* rather than by number so a call site says what the element is
 * and the number can follow the spec if it changes. That is also why `RADIUS_*_CARD` is
 * now 16 and not the 12 it used to be: 12 is not one of the five, and a list row is a
 * content container.
 */
export const RADIUS_LABEL: number = 4;
export const RADIUS_IMAGE: number = 8;
export const RADIUS_CARD: number = 16;
export const RADIUS_CONTROL: number = 20;
export const RADIUS_MODAL: number = 32;

/** Kept as aliases so existing call sites keep compiling unchanged. */
export const RADIUS_CHIP: number = RADIUS_CONTROL;
export const RADIUS_SHEET: number = RADIUS_MODAL;

/** Spacing scale in vp. */
export const SPACE_XS: number = 4;
export const SPACE_S: number = 8;
export const SPACE_M: number = 16;
export const SPACE_L: number = 24;
export const SPACE_XL: number = 32;

/**
 * The reader's page palette used to live here as eight `READER_*` constants — a warm cream
 * day theme and a warm near-black night theme, chosen to match the reader's own
 * `ReaderSettings` and deliberately *not* the three app palettes.
 *
 * That was the defect. Two theme systems, nothing connecting them: `applySystemAppearance()`
 * re-coloured the window from `themeMode` while the page went on painting `#FFF7F3EC`, so
 * the sepia theme showed a white reader and dark mode never produced light text. The
 * reader's page colours are now **derived from the application theme** — see
 * `readerAppearance`, below the palettes, which is the one place background and text are
 * decided together.
 */

/**
 * Responsive breakpoints in vp.
 *
 * The guidance's `sm`/`md`/`lg`/`xl` thresholds are not published as numbers, so
 * these are chosen from the device widths that actually matter for this app: a
 * phone in portrait, a phone in landscape or a foldable's inner screen, and a
 * tablet. A single-column shelf on a wide screen wastes the space; four columns on
 * a narrow one makes unreadable covers.
 */
export const BREAKPOINT_MEDIUM: number = 600;
export const BREAKPOINT_LARGE: number = 840;

// ---------------------------------------------------------------------------
// Floating bottom tab bar
// ---------------------------------------------------------------------------

/**
 * Side margin of the floating tab capsule, from the bottom-tab design spec.
 *
 * The spec gives the capsule a 56 vp height and requires it to clear the screen edge.
 * Its width is deliberately not set here: the spec says HDS computes it per breakpoint,
 * and overriding that with values read off a table would be the worse guess.
 */
export const FLOATING_BAR_SIDE_MARGIN: number = 16;
/**
 * Background for a surface that may be drawn by the system material.
 *
 * `systemMaterial` controls a component's background, border and shadow, and the docs
 * say not to use it alongside `backgroundColor`. So the colour is only set when there
 * is no material to draw:
 *
 *  - material present  -> `Color.Transparent`, and the system paints the surface
 *  - material absent   -> the caller's themed colour, and the component looks normal
 *
 * Passing `Color.Transparent` rather than omitting the call is deliberate: an explicit
 * transparent background is what lets the material show through, whereas a component
 * that still carries its own opaque colour would hide it.
 */
export function surfaceBackground(material: Object | undefined, fallback: ResourceColor): ResourceColor {
  return material === undefined ? fallback : Color.Transparent;
}

/**
 * Bottom padding a scrollable area needs so the floating tab bar does not cover it.
 *
 * The floating bar **overlaps** the content, so anything scrolling underneath it needs
 * this much bottom padding or its final row is hidden under the capsule — reachable by
 * neither scroll nor tap. The spec's own numbers: 56 vp capsule + 16 vp margin = 72,
 * rounded up to 96 for the safe-area inset a device may add below the bar.
 *
 * Defined once and imported by every scroll owner. Three copies of "the same" number is
 * how one of them ends up stale.
 */
export const FLOATING_BAR_CLEARANCE: number = 96;
/**
 * Distance from the floating capsule to the bottom of the tab area.
 *
 * The spec's 悬浮式 default height is 56 vp; this is the breathing room below it, on
 * top of the system's own safe-area inset.
 */
export const FLOATING_BAR_BOTTOM_MARGIN: number = 8;

/**
 * Height of the gradient mask above the floating bar.
 *
 * The spec: "渐变颜色层建议较底部内容最顶边高 16 vp" — the fade should reach about
 * 16 vp above the top edge of the bar. 32 gives the fade enough room to read as a fade
 * rather than a hard band, which is what `HdsTabsBackgroundStyle.maskHeight` measures.
 */
export const FLOATING_BAR_MASK_HEIGHT: number = 32;
/**
 * Font size of a bottom tab label.
 *
 * The platform default is sized for a single short word; "书签笔记" is four characters
 * and was crowding the icon. 10 vp keeps the label inside the capsule.
 */
export const TAB_LABEL_SIZE: number = 10;

/**
 * Immersive-light (沉浸光感) material levels offered in settings.
 *
 * `MaterialLevel` is a system enum, so it is mirrored here as a small ordered list
 * rather than exposed directly — the settings page should not depend on the HDS enum
 * for a value it stores as a preference.
 */
export type MaterialLevelChoice = 'adaptive' | 'smooth' | 'gentle' | 'exquisite';

export interface MaterialLevelOption {
  id: MaterialLevelChoice;
  label: string;
  description: string;
}

/**
 * The levels, weakest first.
 *
 * `adaptive` leads because the SDK recommends it: "推荐使用默认值 ADAPTIVE 档位" — the
 * system adjusts the effect to the device's compute budget, which is the difference
 * between a nice material and a hot phone on a weak SoC.
 */
export const MATERIAL_LEVELS: MaterialLevelOption[] = [
  { id: 'adaptive', label: '自适应', description: '由系统按设备算力调节，推荐' },
  { id: 'smooth', label: '轻柔', description: '效果最弱，最省电' },
  { id: 'gentle', label: '柔和', description: '中等强度' },
  { id: 'exquisite', label: '精致', description: '效果最强，较耗电' },
];

export function asMaterialLevel(value: string): MaterialLevelChoice {
  if (value === 'smooth' || value === 'gentle' || value === 'exquisite') {
    return value;
  }
  return 'adaptive';
}

// ---------------------------------------------------------------------------
// Colour themes
// ---------------------------------------------------------------------------

/**
 * The three themes ReadAny ships, ported with their exact colours.
 *
 * `light` and `dark` are the application themes; `sepia` is the reading-friendly warm
 * one. Values come from ReadAny's `packages/app/src/styles/globals.css`:
 *
 *  - `dark` and `sepia` are declared there as hex, and are copied verbatim.
 *  - `light` is declared as `oklch(…)`, so the hex values below were **computed** with
 *    the CSS Color 4 conversion rather than eyeballed. Guessing them would have shifted
 *    every surface slightly and been invisible until the two apps sat side by side.
 *
 * ReadAny's `app-expo` build has a fourth theme, `oled`; the three-theme set is the one
 * this app matches, since `packages/app` is where the ported palette lives.
 *
 * **One deliberate deviation from ReadAny, and only one:** the light `background` is not
 * ReadAny's converted `#FCFCF9`. That value is a near-white, and this app's cards are
 * `#FFFFFF`, so the card/page contrast was 1.03:1 — a card had no visible edge and the
 * surfaces read as one flat sheet (the "看不太清" complaint). The reference app ClashBox
 * greys its page instead: `#F1F3F5` against a white card, 1.11:1. The light page is
 * therefore `#F0F0EC` — the same kind of clearly-grey surface, but keeping this palette's
 * warm cast (`blue = red - 4`, matching `#FCFCF9`/`#F3F3EF`) instead of ClashBox's cool
 * blue-grey. It measures 1.14:1 against the white card, i.e. slightly more separation than
 * the reference. Everything else in the light palette is still the exact oklch conversion;
 * `tools/verify-themes.mjs` asserts this one key against the literal instead.
 */
export type ThemeMode = 'light' | 'dark' | 'sepia';

/** One theme's colours, named for the role rather than the hue. */
export interface ThemePalette {
  mode: ThemeMode;
  /** Label for the picker. */
  label: string;
  background: string;
  foreground: string;
  card: string;
  cardForeground: string;
  primary: string;
  primaryForeground: string;
  muted: string;
  mutedForeground: string;
  /**
   * The surface a book's **no-cover placeholder** is painted on.
   *
   * This is a role of its own rather than a reuse of `muted`, because `muted` is a
   * *control* fill: the 取消 button in the delete confirmation
   * (`ShelfPage.ets`), the same button in the annotation editor and the unselected
   * annotation filter chip (`AnnotationsPage.ets`) all put `foreground` or
   * `mutedForeground` on it. Those four surfaces want a quiet fill that sits close to
   * the page; the placeholder wants a surface that reads as an object. The two
   * requirements disagree in the light theme, where `muted` (`#F3F3EF`) is only
   * 1.03:1 against the page (`#F0F0EC`) — so a no-cover card was invisible and the
   * grid looked like gaps rather than books (没有封面的时候灰色更明显一点).
   *
   * Changing `muted` itself would have restyled those four controls and still left the
   * placeholder as "whatever the control fill happens to be". Hence a token.
   *
   * Measured per theme against `background` (WCAG relative luminance):
   *   light 1.25:1, dark 1.31:1, sepia 1.12:1. The light figure is the fix; it now
   *   exceeds the white card's own 1.14:1 edge, which is the separation this palette
   *   already treats as "a surface you can see".
   */
  placeholderSurface: string;
  /**
   * The initial letter drawn on `placeholderSurface`.
   *
   * Separate from `mutedForeground` for the same reason the surface is separate from
   * `muted`: darkening the light placeholder to make it visible cost the glyph its
   * legibility (the shared `#70707D` falls to 3.42:1 there), so the glyph darkens with
   * it. Light is 4.64:1 — better than the 4.39:1 the pair measured before this change.
   * Dark and sepia keep their existing values, so nothing about them moves.
   */
  placeholderForeground: string;
  /**
   * **There is deliberately no `cardSubtle` field here any more.** r92 added one — "a quiet fill
   * one step off `card`" — and r94 deleted it, together with its three values and the six
   * assertions in `tools/verify-themes.mjs` that re-derived them. The note stays at the field's
   * old position so that a reader who looks for the token finds out where it went rather than
   * concluding it was never there.
   *
   * It was invented for the reader's settings sheet, where the row and the sheet body were both
   * `card`: pixel-identical in all three themes — measured on a device screenshot — so the row's
   * whole visible extent was a 1 vp hairline around nothing. `cardSubtle` made the row a surface
   * of its own (1.083 / 1.194 / 1.080:1 against `card`, with `mutedForeground` still at
   * 4.51 / 5.34 / 4.94:1 on it). The defect was real and so was the fix.
   *
   * r94 changed **which** of the two surfaces moved. The user asked for the reader's sheets to
   * match the app's own settings page — 「统一成背景灰内容白」, grey body and white content — so the
   * sheet **body** is now `palette.background` and the row inside it is `palette.card`. That is
   * the reference's own construction (ClashBox: grey sheet, white row — `Constants.ets:19`,
   * `settingsListItem.ets:58`), and r92 could not express it because it kept the body on `card`,
   * and `card` is already pure white in the light theme.
   *
   * With the body on the page tone there is no gap left between `card` and `background` for a
   * third surface to fill, and nothing read this key once the row became `card`: a role that is
   * defined but never read is the thing the rest of this file is written to avoid. The row is
   * now bounded by `card` **plus** the 1 vp `border` hairline, which is the treatment the app's
   * own settings cards use and which the user's device check required back in 护眼 (see
   * `ui/ListRow.ets`).
   */
  accent: string;
  accentForeground: string;
  /**
   * The destructive role: a red that means "this removes something".
   *
   * Ported from ReadAny's `--destructive`, because it is the colour its own delete
   * affordances use — the menu's 删除 row and its icon
   * (`packages/app-expo/src/components/library/BookCardActionSheet.tsx:125`) and the
   * dialog's confirm button (`.../BookCard.tsx:624`) — and ReadAny is the reference
   * for this screen. See the palette blocks for the per-theme source values.
   */
  destructive: string;
  /** Text on that red, for a filled destructive button. */
  destructiveForeground: string;
  border: string;
}

/** ReadAny `[data-theme="light"]`, converted from oklch to sRGB — except `background`,
 *  which is deliberately greyer so the white cards read as surfaces. See the note above. */
const LIGHT: ThemePalette = {
  mode: 'light',
  label: '浅色',
  background: '#F0F0EC',
  foreground: '#090909',
  card: '#FFFFFF',
  cardForeground: '#090909',
  primary: '#18181D',
  primaryForeground: '#FCFCFC',
  muted: '#F3F3EF',
  mutedForeground: '#70707D',
  // The one placeholder pair that changes: `muted` above is almost the page colour here
  // (`#F3F3EF` on `#F0F0EC`, 1.03:1), so a coverless card had no surface at all.
  // `#D8D8D8` is the neutral grey that measures 1.25:1 — above the white card's 1.14:1 —
  // and the glyph darkens to `#5C5C66` to hold 4.64:1 on it (the shared `#70707D` would
  // have dropped to 3.42:1). Both are plain greys, not hues, so the placeholder stays a
  // neutral absence-of-a-cover in the same warm-cast family as the rest of this palette.
  placeholderSurface: '#D8D8D8',
  placeholderForeground: '#5C5C66',
  accent: '#F5F5F5',
  accentForeground: '#18181D',
  // `oklch(0.58 0.24 28.48)` and `oklch(0.99 0 0)` from ReadAny's `:root`, converted
  // with the same CSS Color 4 routine as the rest of this palette. The conversion is
  // not eyeballed: running it over this palette's other light values reproduces
  // `#FFFFFF`, `#E4E4E4`, `#F3F3EF` and `#70707D` exactly, which is what makes the two
  // new pairs trustworthy. `tools/verify-book-menu.mjs` re-derives both from ReadAny's
  // source on every run.
  destructive: '#E60006',
  destructiveForeground: '#FCFCFC',
  border: '#E4E4E4',
};

/** ReadAny `[data-theme="dark"]`, verbatim. */
const DARK: ThemePalette = {
  mode: 'dark',
  label: '深色',
  background: '#121212',
  foreground: '#F5F5F5',
  card: '#1E1E1E',
  cardForeground: '#F5F5F5',
  primary: '#FFFFFF',
  primaryForeground: '#121212',
  muted: '#2A2A2A',
  mutedForeground: '#A0A0A0',
  // Dark was never the problem: `muted` is already 1.31:1 against the page. These tokens
  // carry the values this theme already rendered, so the placeholder here is unchanged —
  // the token exists so the *light* theme can differ without touching them.
  placeholderSurface: '#2A2A2A',
  placeholderForeground: '#A0A0A0',
  accent: '#2A2A2A',
  accentForeground: '#FFFFFF',
  // ReadAny's dark block gives these as hex already.
  destructive: '#E53935',
  destructiveForeground: '#FFFFFF',
  border: '#333333',
};

/** ReadAny `[data-theme="sepia"]`, verbatim. */
const SEPIA: ThemePalette = {
  mode: 'sepia',
  label: '护眼',
  background: '#F0E6D2',
  foreground: '#3D2B1F',
  card: '#F5EBD7',
  cardForeground: '#3D2B1F',
  primary: '#6B4C2A',
  primaryForeground: '#F5EBD7',
  muted: '#E6D9C3',
  mutedForeground: '#7A6652',
  // Sepia was never the problem either: `muted` is 1.12:1 against the page, which reads
  // as a surface because the warm page is dark enough. The values are carried over
  // unchanged, so 护眼 renders exactly as it did before this change.
  placeholderSurface: '#E6D9C3',
  placeholderForeground: '#7A6652',
  accent: '#E6D9C3',
  accentForeground: '#4A3728',
  // Same red as the dark theme — ReadAny gives sepia the identical value — on a warm
  // card, where it measures 3.4:1 against `#F5EBD7`.
  destructive: '#E53935',
  destructiveForeground: '#FAFAFA',
  border: '#D4C4A8',
};

/** The picker's order, matching ReadAny's appearance screen. */
export const THEME_MODES: ThemeMode[] = ['light', 'dark', 'sepia'];

/** The palette for a mode. An unknown mode falls back to `dark`, not to `light`: a
 *  dark default is the safer mistake on an OLED phone at night. */
export function paletteFor(mode: ThemeMode): ThemePalette {
  if (mode === 'light') {
    return LIGHT;
  }
  if (mode === 'sepia') {
    return SEPIA;
  }
  return DARK;
}

/**
 * The reader page's appearance, **derived from the application theme**.
 *
 * This is the single place where the reader's page background and its text colour are
 * decided, and they are decided *together*: both come from one `ThemePalette`, so a sepia
 * page carrying light-mode text — or the reverse, which is worse than the original bug —
 * cannot be expressed here at all.
 *
 * ## Why derived, and not a second store
 *
 * The reader used to own `themeColor` / `fontColor` / `nightMode` and a 夜间 toggle of its
 * own, with nothing connecting them to `themeMode`. So `applySystemAppearance()` re-coloured
 * the window while the page kept painting the reader's own cream, and the sepia theme showed
 * a white reader. That is the same failure as two stores for one concept, and it is fixed the
 * same way: one owner.
 *
 * ReadAny is the reference and does exactly this. Its reader has **no theme setting of its
 * own** — `ViewSettings` (`packages/core/src/types/book.ts:79-93`) carries font and layout
 * and no colour — and it reads the application theme straight off the document root:
 * `getAppTheme()` at `packages/app/src/components/reader/FoliateViewer.tsx:111-115` reads
 * `document.documentElement[data-theme]`, `THEME_COLORS` at `:45-49` maps that theme to
 * `{ bg, fg }`, and a `MutationObserver` on the `data-theme` attribute (`:944-968`) re-applies
 * the page styles when the application theme changes. Its sepia entry is `#f0e6d2` / `#3d2b1f`,
 * which is this palette's `SEPIA` pair verbatim (`globals.css:78-80`). So the reader having no
 * theme control is not an omission in the reference — it is the design, and the 夜间 toggle
 * this app's reader carried was the deviation.
 *
 * ## Per field
 *
 *  - `background` → `ReaderSetting.themeColor`. **6-digit hex**: Reader Kit documents that it
 *    rejects an alpha channel (`ReaderView.ets` header; the SDK only says "theme background
 *    color", so the constraint is taken from Huawei's `ReaderSetting` documentation and the
 *    page header records that it is documentation-derived rather than device-verified). The
 *    palette's `background` is already 6-digit; the reader's old default was `#FFF7F3EC`, an
 *    8-digit value the kit was documented to reject.
 *  - `foreground` → `ReaderSetting.fontColor`, and the reader chrome's primary text.
 *  - `surface` → the opaque chrome surface: settings panel, progress track, toast chip. The
 *    palette's `border` role — the palette's own "this tone reads against the page" value.
 *    Measured against `background`: light 1.11:1, dark 1.48:1, sepia 1.38:1, each at least the
 *    separation of the two reader-only tones this replaces (1.07:1 and 1.09:1), so the 6 vp
 *    progress track stays visible in all three themes.
 *  - `muted` → secondary chrome text: the page indicator, which is the only caller. The
 *    theme's own `foreground` at 70 % (`READER_MUTED_ALPHA`), which keeps it a shade of the
 *    page's text rather than a second hue.
 *  - `isDark` → `ReaderSetting.nightMode`, and nothing else. It is a *consequence* of the
 *    theme, not an independent flag: it tells the kit which of its two rendering modes the
 *    page colours came from. `palette.mode` is read rather than `mode`, so an unknown mode
 *    that fell back to `DARK` also reports dark.
 *
 * ## What the kit actually paints, measured on the device
 *
 * Sampled from `snapshot_display` screenshots (1320x2848, JPEG; the pipeline's own error is
 * ±2 per channel — an ArkUI surface painted the palette's `background` verbatim measured +1,
 * and a surface painted `#121212` measured `#121212`). `chromeText()` is in every one of
 * these images as a control: ArkUI paints it faithfully, so a difference between it and the
 * page is the kit, not the platform, the JPEG or the sampling.
 *
 *  - **Sepia (day path): the background is honoured, the ink is not.** `themeColor`
 *    `#F0E6D2` → page measured `#F2E7D3` (max channel delta 2, the pipeline floor). The
 *    page ink measured a tight cluster at `#010000`–`#080000` — **pure black** — while the
 *    same nominal `#3D2B1F` in the top bar measured `#3A2D1C`/`#382B1A`. So the day path
 *    ignores `fontColor` and paints the kit's own black. Contrast on the sepia page is
 *    therefore ~17:1 rather than the palette pair's 10.84:1: legible, higher than the theme
 *    asks, but not the theme's text colour.
 *  - **Dark (night path): the ink is light, the background is the kit's own.** Page
 *    measured `#0A0A0A` — darker than the `#121212` passed, and *not* a pipeline artefact
 *    (the ArkUI bars painted from the same palette entry measured `#121212` exactly). Ink
 *    measured a cluster centred on `#F5F5F5`, i.e. the value passed — though the kit's own
 *    night ink is also near-white, so this image cannot separate "`fontColor` honoured"
 *    from "kit default" (measured contrast 18.3:1 either way).
 *  - **Light (day path):** `themeColor` `#F0F0EC` → `#F1F2ED`; ink `#000000` against the
 *    `#090909` passed — the same day-path black, invisible here because the light palette's
 *    text is near-black anyway (measured contrast ~18:1).
 *
 * **`isDark` is load-bearing, not decorative.** The night path is what makes the kit paint
 * light ink; with `nightMode: false` and a `#121212` page the text would be black on black.
 * That is why the flag is derived from the theme rather than left at the kit's default
 * `false` — which is what shipped before this fix.
 *
 * The app passes the documented field in the documented form and cannot do better: Reader
 * Kit exposes no stylesheet injection, and baking a text colour into the book's own CSS
 * would be a second source of truth that could not follow the theme — the failure this whole
 * change removes. `docs`-style measurements live in `.diag/measure-reader-page.ps1` and
 * `.diag/ink-histogram.ps1`.
 */
export interface ReaderAppearance {
  /** `ReaderSetting.themeColor` — 6-digit hex. */
  background: string;
  /** `ReaderSetting.fontColor` — 6-digit hex. */
  foreground: string;
  /** Opaque chrome surface for the panel, the track and the chip. */
  surface: string;
  /** Secondary chrome text, as `#AARRGGBB`, for ArkUI text only. */
  muted: string;
  /** `ReaderSetting.nightMode`. */
  isDark: boolean;
}

/**
 * Alpha the theme's foreground is applied at for the reader's secondary chrome text.
 *
 * `0xB3` = 70 %. An alpha over the page rather than a palette key, because the reader's
 * caption sits on the **page**, not on a control surface: `mutedForeground` is a
 * control-fill foreground and measures 4.27:1 on the light page and 4.40:1 on the sepia
 * one — both under the 4.5:1 floor this project holds text to — while the tone the reader
 * replaced measured 5.58:1. 70 % of the theme's own foreground measures 7.29:1 (light),
 * 8.74:1 (dark) and 4.67:1 (sepia) over the page, all above the floor.
 * `tools/verify-themes.mjs` re-derives these three figures on every run.
 */
const READER_MUTED_ALPHA: string = 'B3';

/** The reader's page appearance for an application theme. See `ReaderAppearance`. */
export function readerAppearance(mode: ThemeMode): ReaderAppearance {
  const palette: ThemePalette = paletteFor(mode);
  return {
    background: palette.background,
    foreground: palette.foreground,
    surface: palette.border,
    // `substring(1)` is the six digits of the palette colour, so the chrome shade cannot
    // drift from the text colour it is a shade of.
    muted: `#${READER_MUTED_ALPHA}${palette.foreground.substring(1)}`,
    isDark: palette.mode === 'dark',
  };
}

/** Narrow an arbitrary string (from storage) to a known mode. */
/**
 * One line on what each theme is for.
 *
 * Kept beside the palettes rather than in the page, so a theme cannot be added without
 * a description: `themeDescription` is exhaustive over `ThemeMode`, so a new mode is a
 * compile error here instead of a row with no explanation.
 */
export function themeDescription(mode: ThemeMode): string {
  if (mode === 'light') {
    return '明亮底、深色字。适合白天与光线充足的环境。';
  }
  if (mode === 'sepia') {
    return '暖米色底、棕褐字。低蓝光，长时间阅读更舒适。';
  }
  return '深灰底、浅色字。适合夜间与暗光环境，也更省电。';
}
export function asThemeMode(value: string): ThemeMode {
  if (value === 'light' || value === 'sepia' || value === 'dark') {
    return value;
  }
  return 'dark';
}

/** Shelf column count for a given content width. */
export function shelfColumnsForWidth(width: number): number {
  if (width >= BREAKPOINT_LARGE) {
    return 5;
  }
  if (width >= BREAKPOINT_MEDIUM) {
    return 4;
  }
  if (width >= 380) {
    return 3;
  }
  return 2;
}

/**
 * True when the immersive material path may be taken.
 *
 * Both halves are required: the API level is a compile-time gate and the support
 * query is a device fact — a build that has the API can still be running on
 * hardware that reports no material support.
 */
export function immersiveMaterialAvailable(): boolean {
  if (!immersive.canApplyImmersiveMaterial()) {
    return false;
  }
  try {
    return immersive.deviceSupportsImmersiveMaterial();
  } catch (err) {
    return false;
  }
}

/** The device's material level, or -1 when unavailable or unreadable. */
export function deviceMaterialLevel(): number {
  return immersive.globalMaterialLevel();
}

/**
 * The material option to hand to a builder, or `undefined`.
 *
 * Returns `undefined` rather than throwing so a guarded builder can pass the result
 * straight through; an undefined option makes `systemMaterial` a no-op, which is
 * exactly the fallback behaviour wanted.
 */
export function materialOption(): Object | undefined {
  if (!immersiveMaterialAvailable()) {
    return undefined;
  }
  try {
    return immersive.immersiveMaterialOption();
  } catch (err) {
    // Construction failed on a device that reported support. `undefined` is the
    // correct fallback — the shell renders without a material — but this is the one
    // case where the material path was expected and did not happen, so it is logged
    // rather than passed over. Without a line here, a material that never appears
    // looks identical to one that does not exist on the device.
    hilog.warn(DOMAIN, TAG, 'immersiveMaterialOption failed: %{public}s', String(err));
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// The immersive material of a popup menu (沉浸光感)
// ---------------------------------------------------------------------------

/**
 * Alpha the menu's card colour is applied at when it tints the material.
 *
 * `0xB3` = 70 %. The SDK requires a material colour to carry transparency — "The pure
 * color must have a certain transparency value and cannot be completely opaque.
 * Otherwise, the material filter effect will be completely blocked"
 * (`@ohos.arkui.uiMaterial.d.ts`) — and 70 % is the point that keeps the surface
 * recognisably this app's card in all three palettes while leaving the filter enough to
 * work with. Fully opaque would be simpler and would switch the effect off.
 */
const MENU_MATERIAL_TINT_ALPHA: string = 'B3';

/**
 * A palette colour at the menu's tint alpha, as `#AARRGGBB`.
 *
 * The palettes are stored as `#RRGGBB`, so the alpha channel is prefixed rather than
 * parsed: `substring(1)` is the six digits and no conversion is involved, which means
 * this cannot drift from the palette it is built from.
 */
export function menuMaterialTint(palette: ThemePalette): string {
  return `#${MENU_MATERIAL_TINT_ALPHA}${palette.card.substring(1)}`;
}

/**
 * Alpha of the `⋯` control's chip.
 *
 * `0xD9` = 85 %. The chip sits **on a book cover**, which can be any image at all, so it
 * needs a surface of its own or the dots disappear into a dark or busy cover. The card
 * colour at 85 % is that surface, and it is high enough that the glyph's contrast is the
 * card/foreground contrast the theme audit already measures, not the cover's.
 */
const MENU_TRIGGER_ALPHA: string = 'D9';

/** The `⋯` chip's background: this palette's card colour, at `MENU_TRIGGER_ALPHA`. */
export function menuTriggerBackground(palette: ThemePalette): string {
  return `#${MENU_TRIGGER_ALPHA}${palette.card.substring(1)}`;
}

/**
 * The material a book menu may be painted with, or `undefined`.
 *
 * `undefined` is the answer on three distinct paths, and every one of them ends with
 * the menu painted from the app palette instead — which is why the caller must have an
 * opaque branch and not merely a material one:
 *
 *  1. **The API is absent** (a pre-26 runtime) — `materialOption()` is already
 *     `undefined`.
 *  2. **The device reports no support** (`isImmersiveMaterialSupported`), which is a
 *     device fact independent of the API level.
 *  3. **The device's material level is `SMOOTH`** — the low-compute level. Kept as a
 *     refusal even though the API reference says `materialColor` still lands there (as
 *     the `backgroundColor`), because the declaration file says the opposite — that it
 *     "takes effect only for the display effect of devices with high- and mid-level
 *     computing power" — and no low-compute device is available to settle it. Where the
 *     two documents disagree about hardware we cannot test, the app keeps the surface it
 *     has already verified: the opaque palette card.
 *
 * These three are what "沉浸光感 off" means for this component — the app's own level
 * vocabulary (`MATERIAL_LEVELS`, above) has four levels and no 「关闭」, so there is no
 * user-selectable off state to read. On the two levels that do use the filter path —
 * `EXQUISITE` and `GENTLE` — the material is built with `materialColor` set to the
 * palette's own card colour at 70 % (`menuMaterialTint`), so the sepia surface stays
 * sepia under the material instead of becoming the system's white or black.
 *
 * ## Where the caller must put it
 *
 * The object this returns is **not** for the universal `systemMaterial` attribute. That
 * attribute is out of scope on anything but a Navigation title bar or a bottom TabBar,
 * and the framework discards it on a popup with a log line saying so. It goes in the
 * `bindMenu` call's **options object** instead — `MenuOptions.systemMaterial`, inherited
 * from `ContextMenuOptions` (`common.d.ts:15594`, `:15637`) — which the framework does
 * serve page-wide for 菜单控制. See `ShelfPage.menuOptions`.
 *
 * This is still a popup menu and nothing larger: a page-sized container carrying a
 * material repaints the whole page from the system palette, and a small selection chip
 * carrying one loses the selection state under it. Both were real defects in this app.
 */
export function menuMaterialOption(palette: ThemePalette): Object | undefined {
  if (materialOption() === undefined) {
    return undefined;
  }
  if (immersive.materialLevelPaintsBackground()) {
    return undefined;
  }
  try {
    return immersive.immersiveMenuMaterialOption(menuMaterialTint(palette));
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'menu material failed, using the palette: %{public}s', String(err));
    return undefined;
  }
}
