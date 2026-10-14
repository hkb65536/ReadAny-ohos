import { common } from '@kit.AbilityKit';
import { curves, display, SymbolGlyphModifier, window } from '@kit.ArkUI';
import { bookParser, ReadPageComponent, readerCore } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CFI_ORDINAL_UNKNOWN,
  decodeSpineLocator,
  InkBoatError,
  isEpubCfi,
  isSpineLocator,
  spineOrdinalFromCfi,
  SyncErrorKind,
} from 'core';
import type { SpineLocator } from 'core';
import type { Books } from 'data';
import {
  clampFontSize,
  clampLineHeight,
  copySettings,
  defaultReaderSettings,
  MAX_FONT_SIZE,
  MIN_FONT_SIZE,
  ReaderStore,
} from 'data';
import type { ReaderSettings, ReadingPosition } from 'data';
import {
  FLOATING_BAR_BOTTOM_MARGIN,
  FLOATING_BAR_CLEARANCE,
  FLOATING_BAR_MASK_HEIGHT,
  FLOATING_BAR_SIDE_MARGIN,
  FLOATING_BAR_WIDTH,
  MIN_TAP_TARGET,
  paletteFor,
  RADIUS_CARD,
  RADIUS_CHIP,
  RADIUS_CONTROL,
  RADIUS_IMAGE,
  RADIUS_SHEET,
  readerAppearance,
  SPACE_L,
  SPACE_M,
  SPACE_S,
  SPACE_XS,
  topBarMaterialOption,
  TYPE_BODY,
  TYPE_CAPTION,
  TYPE_SUBTITLE,
  TYPE_TITLE,
} from '../theme/Theme';
import type { ReaderAppearance, ThemeMode } from '../theme/Theme';
import { MOTION_ON_KEY, Motion } from '../theme/Motion';
// The bottom bar's floating presentation is an HDS feature: it is the control that carries the
// 沉浸光感 material, the capsule container and the gradient mask. See `bottomBar`.
import { BlurStrategy, hdsMaterial, HdsTabs } from '@kit.UIDesignKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatReader';

/** How long a transient confirmation stays on screen. */
const TOAST_VISIBLE_MS: number = 2200;

/**
 * `PageDataInfo.pageOffset` before the kit has reported a page.
 *
 * Also the kit's own sentinel for "the page before this resource's first page": on the
 * device, a page that belongs to the tail of the previous chapter is reported as
 * `pageOffset: -1` (`resourceIndex` pointing at the neighbouring resource). The two
 * cases are the same to this screen — there is no page number to print — so one
 * constant covers both. See `pageIndicator`.
 */
const PAGE_OFFSET_UNKNOWN: number = -1;

/**
 * Width reserved for the page indicator, in vp.
 *
 * Fixed rather than measured so the centred chapter title does not shift left and right
 * as the number of digits changes ("第 2 页" → "第 10 页").
 */
const PAGE_INDICATOR_WIDTH: number = 64;

/**
 * Height of the reader's floating top bar, in vp.
 *
 * `Navigation`'s own title-bar height in its default (Mini-equivalent) presentation is 56 vp,
 * and the bar this replaces measured the same: `MIN_TAP_TARGET` (48) plus `SPACE_XS` above and
 * below. Nothing is derived from it — the bar is an overlay of the page `Stack` and holds no
 * content of its own (`topBar`) — so the two facts agreeing is a convenience rather than a
 * dependency.
 *
 * **It is the bar's own content height, not the box it is drawn in.** Since r104 those are two
 * numbers: this one is what places the capsule (`TOP_BAR_CAPSULE_TOP_GAP`) and
 * `TOP_BAR_BOX_HEIGHT` is what the `Navigation` and its title bar are asked for. Keeping them
 * apart is exactly what lets the box grow for the shadow without the capsule moving — centring
 * the capsule in the grown box instead would move it down by half the increment.
 */
const TOP_BAR_HEIGHT: number = 56;

/**
 * Height of the floating **capsule** inside the top bar, in vp.
 *
 * The bar stays `TOP_BAR_HEIGHT` tall — it is a `Navigation`, and that is the title bar's own
 * height — but the bar no longer *is* the surface. The capsule is the surface, and it is
 * deliberately shorter than the bar so the bar keeps a visible edge above and below it: the
 * capsule is now pinned to the box's top with a named gap (`TOP_BAR_CAPSULE_TOP_GAP`), which is
 * the same number centring used to give it.
 *
 * `MIN_TAP_TARGET` rather than a smaller number, and that is a constraint rather than a
 * preference: `topBarRow` draws a 返回 whose `constraintSize({ minHeight: MIN_TAP_TARGET })` is
 * 48 vp, and a capsule shorter than its own control would either clip it or force it to shrink
 * below the tap-target guidance this project asserts. So the capsule is exactly one tap target
 * tall and the bar is what is left over.
 */
const TOP_BAR_CAPSULE_HEIGHT: number = MIN_TAP_TARGET;

/**
 * How far the capsule sits below the **top edge of the box it floats in**, in vp.
 *
 * **Derived, and this is the line that keeps the capsule still while the box grows.** Until
 * r104 the capsule was centred in a `TOP_BAR_HEIGHT`-tall box, so this gap *was*
 * `(TOP_BAR_HEIGHT - TOP_BAR_CAPSULE_HEIGHT) / 2`. Centring is no longer usable: the box is
 * `TOP_BAR_BOX_HEIGHT` (80 vp) and centring in it would move the capsule down by half the
 * increment — 12 vp — which is the one thing this round must not do. The capsule's top edge is
 * measured at `136 px = 40.3 vp` on the reference device (`topInsetVp` 36 + this 4) and it has
 * to stay there.
 *
 * Written as the expression rather than as `SPACE_XS` so the relationship survives: a later
 * round that changes `TOP_BAR_CAPSULE_HEIGHT` gets the matching top gap for free instead of one
 * more constant to keep in step. `SPACE_XS` (4) is what it evaluates to at the values above.
 */
const TOP_BAR_CAPSULE_TOP_GAP: number = (TOP_BAR_HEIGHT - TOP_BAR_CAPSULE_HEIGHT) / 2;

/**
 * Corner radius of that capsule, in vp. **Derived from the height, never written down.**
 *
 * 完全圆头 — a fully rounded head — is radius = height / 2, and deriving it is the only way the
 * two cannot drift. A hard-coded 28 (half of the *bar*'s 56) would be the bar's radius: the
 * moment the capsule's height moved, 28 would draw a rounded rectangle instead of a capsule.
 *
 * **It is load-bearing beyond the shape.** 「材质渲染区域与组件可视区域不一致」 is a documented
 * defect of `systemMaterial` — the material paints its surface over the component's *layout*
 * box, not its visible box — and the documented remedy is exactly `borderRadius`
 * (沉浸光感常见问题 · 材质渲染区域与组件可视区域不一致: 「通过 width、height、borderRadius 接口
 * 控制组件可视区域与材质渲染区域一致」, whose own example is a 100x40 Capsule `Progress` given a
 * radius of half its height). Without this line the capsule's material would be a 328 x 48
 * rectangle with a rounded component drawn on top of it.
 */
const TOP_BAR_CAPSULE_RADIUS: number = TOP_BAR_CAPSULE_HEIGHT / 2;

/**
 * Room left inside the top bar's box **below the capsule** for the bar's own shadow, in vp.
 *
 * **This is the shadow fix (r104), and its cause is measured rather than inferred.** On the
 * device the top bar's paint stopped **dead** at `y = 311 px` — the 56 vp box's bottom edge,
 * `36 + 56 = 92 vp = 310.5 px` — with the shadow's mean |Δ| holding flat at 10–11 for the 15 px
 * below the capsule and then going `y=311: 1.55 → y=312: 0.00`. The **same frame's bottom bar is
 * the control** and its shadow decays smoothly (`10.57 → 9.87 → … → 2.59`), reaching noise about
 * **26.4 vp** below its own capsule. A blurred shadow cannot be at full strength at a boundary
 * and exactly zero one pixel later, so the box's edge was cutting it.
 *
 * **Which edge: the BOTTOM one.** Above the capsule the change does taper (dying within ~1.5 px
 * of the box's top edge) and the top-side shadow is ~4× weaker — that is the material's own
 * downward offset — so growing the box *upward* would not have helped. A top-anchored box grows
 * downward naturally, which is what this is.
 *
 * **It is a clearance, not a measurement**, for exactly the reason the bottom bar's own
 * `BOTTOM_BAR_SHADOW_ROOM` says so of itself: no document publishes the material's shadow reach,
 * and the reach varies with the device's compute level and the user's 沉浸光感 setting. What the
 * measurement above *does* fix is a floor — the shadow was still decaying at 26 vp, so the box
 * wants at least `4 + 48 + 26 = 78 vp`, and `SPACE_L` (24) puts it at 80.
 *
 * **It is also the whole cost of the change, stated rather than hidden.** The box *is* the band
 * that belongs to the bar while the bars are shown, so every vp here is a vp of the page that
 * does not turn a page while the bar is up (56 → 80 vp, i.e. 24 vp). While the bars are hidden
 * the top bar is `HitTestMode.BLOCK_DESCENDANTS` with `opacity` 0 — not hit-testable — so the
 * band costs nothing, and hidden is the default. This is the one knob that trades "more room for
 * the shadow" directly against "more page the bar eats", and it is the number to lower first if
 * the band reads badly on a device.
 */
const TOP_BAR_SHADOW_ROOM: number = SPACE_L;

/**
 * Height of the box the floating top bar is drawn in, in vp.
 *
 * **Not `TOP_BAR_HEIGHT` since r104.** `TOP_BAR_HEIGHT` is the bar's own content height — what
 * places the capsule — and this is what the bar is *drawn* in. The extra 24 vp are all **below**
 * the capsule, because the box is top-anchored (`.position({ left: 0, top: this.topInsetVp })`)
 * and the capsule is pinned `TOP_BAR_CAPSULE_TOP_GAP` from the box's **top**; growing this number
 * therefore adds nothing above the capsule and cannot move it by a pixel. That is also why the
 * persistent title's anchor is derived from `TOP_BAR_HEIGHT` rather than from this constant: see
 * `persistentTitleAnchorVp`.
 *
 * **Both places that ask the framework for a height use this constant and must stay equal** —
 * the `Navigation`'s own `.height(...)` and `NavigationTitleOptions`' `height` inside
 * `.title({ … })`. Which of the two nodes holds the clip cannot be told apart from the
 * measurement (they are the same 56 vp today, and that is exactly where the paint stops), so
 * growing both is the only version of the fix that is correct either way.
 *
 * A taller custom title bar is officially supported rather than a trick: the FAQ's
 * `MaterialScopeAdaptExample` passes its own `@State titleHeight: number = 140` — 2.5× the
 * default — to `.title({ builder, height: this.titleHeight }, { barStyle: BarStyle.STACK })`, so
 * the height is a free app-chosen number.
 *
 * The bottom bar answers the same question the same way (`BOTTOM_BAR_BOX_HEIGHT` is its clearance
 * plus its own `BOTTOM_BAR_SHADOW_ROOM`), so the two bars now read as one arrangement.
 *
 * **It is not a layout event.** The top bar is a `position`-anchored overlay sibling of the page
 * layer, and the page box's size comes from `layoutWeight(1)` and from no child at all, so this
 * height — like the bar's visibility — cannot reach the pagination box. The r100/r102 structural
 * assertions still hold; see the `build()` element-tree checks.
 */
const TOP_BAR_BOX_HEIGHT: number = TOP_BAR_HEIGHT + TOP_BAR_SHADOW_ROOM;

/**
 * How far the persistent chapter name's **box** sits from the page box's left edge, in vp.
 *
 * **`27` is Reader Kit's own `paddingLeft`, which is the body text's layout origin** — the kit's
 * `setPageConfig` log for this configuration prints `"paddingLeft":27, "paddingRight":27` (quoted
 * in `resolveViewPort`), so putting the title's box here aligns it with the text **box-to-box**,
 * which is the structurally right thing and what the user asked for (「和左边的文字对齐」).
 *
 * **Deliberately not on this project's `SPACE_` scale** (24 / 32): it is a platform metric being
 * matched, not a spacing decision, and rounding it to `SPACE_L` would put the title 3 vp to the
 * left of the text.
 *
 * **`103 px = 30.52 vp`, not 27 vp, is where the body's ink actually starts.** Measured over 24
 * body lines on the reference device: continuation lines start at 103–106 px, indented first
 * lines at 224–227 px (so the minimum is the true left edge), and the right ink edge is a hard
 * `1215 px = 360 vp`. The ~3.5 vp between the layout origin and the ink is the title's own glyph
 * bearing: putting the title's box *at* the ink edge would push its ink ~3.5 vp right of the
 * text's. So the box goes at the layout origin and **`103 px` is the post-change verification
 * target, not the input**.
 */
const PERSISTENT_TITLE_LEFT: number = 27;

/**
 * How far the persistent chapter name's box stops short of the page box's **right** edge, in vp.
 *
 * The overlay used `SPACE_L` on both sides so a long chapter name ellipsised inside the page
 * rather than running to the screen's edges; only the left inset changed this round, so the right
 * one keeps the theme constant it always had. The two are different numbers on purpose: the left
 * one is a metric being matched, this one is breathing room.
 */
const PERSISTENT_TITLE_RIGHT: number = SPACE_L;

/**
 * How far each floating bar travels on its way in, in vp.
 *
 * The bars slide in from **their own edge of the screen**: the top bar starts `-BAR_SLIDE_OFFSET`
 * (above where it rests) and the bottom bar starts `+BAR_SLIDE_OFFSET` (below), both settling at
 * `0`. 30 vp is the value the user approved (「动画就用方案3」, whose description was
 * `translate y = ∓(30vp) → 0`), and it is a *sub*-capsule travel on purpose: the capsule is 48 vp
 * tall, so the bar is still partly on screen at the start of the slide and the motion reads as
 * the bar arriving rather than as it falling in from nowhere.
 *
 * **`translate` is one of the four properties this may use.** It is a render-time transform and
 * takes no part in layout, which is the hard constraint here: `height`, `padding`, `margin`,
 * `layoutWeight` and anything else that can move the page layer are forbidden, because the two
 * bars are `position`-anchored siblings of the page `Stack` and the kit's measured page box must
 * be byte-identical whether they are shown or hidden. Animating a layout property would
 * re-paginate the reading text, which the user ruled out (「文字的显示范围保持这样不变就行了」).
 */
const BAR_SLIDE_OFFSET: number = 30;

/**
 * The spring the bars' slide-in runs on: `curves.springMotion(response, dampingFraction)`.
 *
 * `response` is the spring's own response time in **seconds** and `dampingFraction` its damping
 * coefficient (`@ohos.curves.d.ts`: 0 is undamped and oscillates forever, `0 < ζ < 1` is
 * underdamped and overshoots, 1 is critical, above 1 is overdamped). The pair below is the one
 * the user approved, and it is a **slight** overshoot by construction: at ζ = 0.85 the first
 * overshoot is `exp(-πζ/√(1-ζ²)) ≈ 0.63%`, i.e. about `0.19 vp` on a 30 vp travel — under one
 * pixel at 3.375 px/vp, so what the eye reads is a smooth settle rather than a bounce. That is
 * the honest arithmetic, and it is why lowering `dampingFraction` is the one-line refinement if
 * the user wants the bounce to be visible after installing (ζ = 0.7 gives ≈4.6%, ≈1.4 vp).
 *
 * **`duration` is inert beside this curve and that is documented, not an oversight.**
 * `AnimateParam.duration`: 「curve配置 springMotion、responsiveSpringMotion、interpolatingSpring
 * 曲线时，duration不生效，动画持续时间由弹簧曲线自身的物理参数…决定」. `BAR_SLIDE_DURATION_MS` is
 * still passed because it is the number the approved option named and because it is what any
 * future non-spring curve would use — but the timing on screen comes from these two numbers.
 *
 * The parameters are constants rather than literals at the `animateTo` call so the audit can pin
 * them as a pair, and so the spring is one decision instead of a number that appears once and is
 * then copied.
 */
const BAR_SLIDE_RESPONSE: number = 0.45;
const BAR_SLIDE_DAMPING: number = 0.85;

/**
 * The `duration` handed to `animateTo` for the bars' slide, in ms. Inert under the spring above
 * — see it for the citation — and kept because it is the approved option's own number and what a
 * change of curve would start from.
 */
const BAR_SLIDE_DURATION_MS: number = 400;

/**
 * Room left inside the bottom bar's box for the bar's own shadow, in vp.
 *
 * **The shadow is real; its reach is unmeasured.** The material paints a shadow of its own
 * (`applyShadow` defaults to true — 沉浸光感常见问题 · 同时设置shadow属性和沉浸式系统材质后
 * 阴影效果不符合预期), and no document publishes how far it reaches. So this is a *clearance*,
 * not a measurement: a generous multiple of the one scale the platform's floating surfaces do
 * publish, i.e. a floor rather than an answer. Any value at or above the real reach removes the
 * cut; no value here is derived from a number anyone measured.
 *
 * **It does cost something, and this is the only place that cost is visible.** The box's height
 * is also the band that belongs to the bar while the bars are shown (`bottomBar` states the
 * consequence), so every vp added here is a vp of the page the bar takes while it is up. Hidden,
 * the bar is not hit-testable (`opacity` 0 + `HitTestMode.BLOCK_DESCENDANTS` since r104) and the
 * band costs nothing. This constant is therefore the one
 * knob that trades "more room for the shadow" directly against "more page the bar eats", and it
 * is the number to lower first if the band reads badly on a device.
 */
const BOTTOM_BAR_SHADOW_ROOM: number = SPACE_L;

/**
 * Height of the box the floating bottom bar is drawn in, in vp.
 *
 * **Not `FLOATING_BAR_CLEARANCE` on its own, and that is the whole of the change made for the
 * clipped shadow.** 96 is a *content* clearance — the shell's own "how much room does a scrolling list
 * need so the floating capsule does not cover its last row" — and it happens to be exactly the
 * content the bar paints: the 56 vp capsule, its 8 vp bottom margin and the 32 vp gradient mask
 * above it (56 + 8 + 32 = 96). So as a *container* height it had zero slack, and everything the
 * bar paints outside that content — the material's own shadow (`applyShadow` is on by default,
 * per the SDK's `ImmersiveOptions`) — was cut off at the box edge. Adding the shadow's own room
 * is what stops the cut.
 *
 * **That mechanism is the leading reading, not a measurement, and the clipper is not in this
 * file.** Nothing here sets `clip`, and ArkUI does not cut an overflowing child at its parent's
 * bounds by default — so *if* the box's edge is where the shadow stopped, the edge doing the
 * cutting lives inside `HdsTabs`, whose floating-bar implementation owns the material
 * (`FloatingTabBarStyle`, `tabs.d.ts:824`; its `systemMaterial` is `@since 26.0.0`,
 * `tabs.d.ts:895`). The arithmetic above is consistent with that reading and the change is safe
 * either way, because it cannot move the capsule — but only a device measurement settles it. One
 * alternative the same screenshot cannot exclude is that the hard edge the user saw was the
 * gradient mask's own boundary rather than a shadow at all.
 *
 * Growing the box **upward** is deliberate and it is why the capsule cannot move: the box is
 * bottom-anchored (`.position({ left: 0, bottom: 0 })`) and the capsule is placed
 * `FLOATING_BAR_BOTTOM_MARGIN` from the *bottom* of the box, so the extra height is all added
 * above the capsule and the capsule's distance from the screen's bottom edge is untouched.
 */
const BOTTOM_BAR_BOX_HEIGHT: number = FLOATING_BAR_CLEARANCE + BOTTOM_BAR_SHADOW_ROOM;

/**
 * The reader sheets' **shared minimum height**, as a percentage of the sheet's own maximum.
 *
 * Every one of the four modes opens at this height and cannot be dragged below it, so the
 * four sheets are one system at rest — which is what the previous round was buying with a
 * fixed `height` — while a drag upward can take any of them to the second detent
 * (`SheetSize.LARGE`). "统一最小高度" is the user's own wording for that split, and it is the
 * reference's arrangement: ClashBox's settings sheet is
 * `detents: [BIND_SHEET_CONTAINER_HEIGHT, SheetSize.LARGE]` with a single shared constant
 * (`entry/src/main/ets/pages/MorePage.ets:154-155`, `common/entity/Constants.ets:19`).
 *
 * The value is unchanged from the fixed height it replaces, but **its base is not, since r101**:
 * the sheet's maximum height is the window less the sheet's top safe-area inset, and full screen
 * (see `applySystemAppearance` in `Index.ets`) removes that inset. A percentage rather than a vp
 * literal is the deliberate part of the answer: "half of the height the sheet actually has" is a
 * relationship, so the four sheets stay one system at rest at whatever the box is, and they
 * re-open at half of it after a rotation or on another device. The consequence, stated rather
 * than discovered: with the status bar hidden the sheets open at 50 % of the full window, which
 * is about 29 vp taller than they opened before — the status bar's own half.
 */
const SHEET_MIN_HEIGHT: string = '50%';

/**
 * The detent tuple every reader sheet is opened with: one shared floor, one draggable step.
 *
 * A method rather than an inline array so the floor has a name and so
 * `tools/verify-reader-chrome.mjs` can assert the *mechanism* rather than a literal: the
 * check requires the tuple's **first** entry to be `SHEET_MIN_HEIGHT` (the opening height and
 * therefore the floor — 「元组中第一个高度为初始高度」) and its last to be
 * `SheetSize.LARGE` (a real step to drag to). A one-entry tuple would pin the sheet and a
 * different first entry would silently change the floor for all four sheets at once.
 */
function sheetDetents(): [SheetSize | Length, (SheetSize | Length)?] {
  return [SHEET_MIN_HEIGHT, SheetSize.LARGE];
}

/**
 * How far a **top-anchored** avoid-area rect reaches down from the screen's top edge, in px.
 *
 * `window.Rect` carries both `top` and `height` and does not promise `top === 0`, so the extent is
 * the far edge rather than the height alone — for the top bands of `TYPE_SYSTEM` and `TYPE_CUTOUT`
 * the two are the same number. Clamped at 0 rather than trusted: "the window cannot describe an
 * avoid area here" must mean a bar at the screen's top edge, never a bar drawn above the screen.
 */
function topBandPx(rect: window.Rect): number {
  return Math.max(0, rect.top + rect.height);
}

/**
 * Height of a **bottom-anchored** avoid-area rect, in px.
 *
 * The gesture bar is the only bottom band this screen reads, and its own height is the whole
 * distance to clear (`SCBGestureNavBar14` = `[0, 2754, 1320, 94]`, i.e. 94 px on the reference
 * device), so there is no `top` term here.
 */
function bottomBandPx(rect: window.Rect): number {
  return Math.max(0, rect.height);
}

/**
 * How many times one open request may be re-issued before the app leaves it alone.
 *
 * Re-issuing is what makes a clobbered open self-healing rather than fatal: the hand trace
 * shows the framework's `$$` write-back landing 5–10 ms *after* `onDisappear` begins, so a
 * `true` written near the end of an exit can be overwritten by the framework finishing the
 * dismissal it had already decided on (`.diag/r95-hand-trace.txt` seq 356 → 361; the same
 * pairing appears at 182→187, 201→206, 262→267 and 281→286).
 *
 * It is bounded rather than open-ended because the retry is driven by a `@Watch` on the very
 * variable it writes: a framework that persisted in writing the value back would otherwise be
 * answered forever. Three is enough for the write-back plus one scheduling slip, and the
 * bound is what keeps "self-healing" from becoming a state fight.
 */
const SHEET_MAX_RAISE_ATTEMPTS: number = 3;


/**
 * Reader page built on Reader Kit.
 *
 * Reader Kit owns pagination, the spine, the table of contents and the page-turn
 * animation. This component only wires it to the app's data and reports position
 * changes back.
 *
 * Constraints that shaped this, from the kit's own documentation:
 *  - **No emulator support.** It only runs on a real device, so a compile is the
 *    only check available off-device.
 *  - **Local files only.** It cannot stream from a URL, so a book must be fully
 *    downloaded before it can be opened. That is consistent with the sync design,
 *    which treats a book as either present locally or metadata-only.
 *  - **`init()` must be called before the other controller methods.** Calling
 *    `startPlay` first fails.
 *  - `themeColor` must be 6-digit hex; an alpha channel is not accepted. That constraint is
 *    met by construction now: the page colours are `readerAppearance(this.themeMode)`, whose
 *    `background`/`foreground` are the palette's own 6-digit values. See the class note on
 *    `themeMode` for why the page follows the application theme at all.
 */

/** Callbacks the page provides. */
export interface ReaderCallbacks {
  onPositionChanged: (position: ReadingPosition) => void;
  onOpenFailed: (message: string) => void;
  onReady: (chapterCount: number) => void;
  /** A settings change the host should persist. */
  onSettingsChanged: (settings: ReaderSettings) => void;
  /**
   * Create a bookmark at the reader's current page.
   *
   * Page-level rather than a text range: Reader Kit exposes no selection API, so
   * there is no character range available to record. The label is what makes the
   * bookmark findable later.
   */
  onAddBookmark: (spineIndex: number, domPos: string, label: string, chapterTitle: string) => Promise<void>;
  /** Create a note anchored to the current page. */
  onAddNote: (spineIndex: number, domPos: string, title: string, content: string, chapterTitle: string) => Promise<void>;
  /**
   * Leave the reader.
   *
   * The host decides what "leave" means; this component only reports that the user
   * asked. It is a callback rather than an internal flag because the reader does not
   * own whether it is displayed — the shell does.
   */
  onBack: () => void;
}

/**
 * One row of the table of contents.
 *
 * `spineIndex` is resolved here rather than at tap time so a catalog entry whose
 * href matches no spine item is visible as non-navigable in the list, instead of
 * failing when the user taps it.
 */
export interface TocEntry {
  catalogId: number;
  name: string;
  /** 0 for top level; used for indentation. */
  level: number;
  href: string;
  spineIndex: number;
  /** False when the href matched no spine item. */
  navigable: boolean;
}

/**
 * Which of the reader's four sheets is being shown.
 *
 * Selected explicitly, because the reader has **one** sheet host. `sheetOpen` carries
 * why.
 *
 * `SETTINGS` is the newest member and it is not an exception to the single-host rule: 设置
 * used to be an inline panel drawn above the bottom bar (`settingsBar`), and it is now the
 * fourth `ReaderSheetMode` — the same presentation form as the other three, through the same
 * one `bindSheet`. That is why it is a case here rather than a second binding.
 */
enum ReaderSheetMode {
  TOC = 'toc',
  BOOKMARK = 'bookmark',
  NOTE = 'note',
  SETTINGS = 'settings',
}

// ==== DIAG-SHEET-BEGIN ====
// TEMPORARY DIAGNOSTIC — sheet dismissal probe, r95. **Every line it emits starts with
// `SHEETPROBE`**, and every line carries a monotonic sequence number and a millisecond
// offset from the first probe line, so the *ordering* of a late callback against a fresh
// open is unambiguous. Grep the device log for `SHEETPROBE` to get the trace and nothing
// else:
//
//   hilog -x | Select-String 'SHEETPROBE'
//
// Two tags are watchers rather than call sites, because a value nobody logged is a value that
// has to be inferred: `WATCH sheetOpen-changed` fires for **every** write to `sheetOpen`,
// whoever made it (the `$$` write-back included), and `WATCH blur-changed` does the same for
// the blur gate since r98. The write sites themselves (`openReaderSheet-wrote-true`,
// `x-button-close`, `onWillDismiss-*`, `watch-re-raise`, `lifecycle-*`) are logged by hand.
//
// Delete by running `node .diag/strip-sheet-probe.mjs`, which cuts exactly these blocks plus
// the lines it marks `// DIAG-SHEET`. This is a *separate* probe from the material one, kept
// separate so the material probe's byte-identity proof and its four anchors are untouched.
let SHEET_PROBE_T0: number = 0;
function sheetProbeNow(): number {
  if (SHEET_PROBE_T0 === 0) {
    SHEET_PROBE_T0 = Date.now();
  }
  return Date.now() - SHEET_PROBE_T0;
}
// ==== DIAG-SHEET-END ====

/**
 * A start position a tapped annotation resolved to, in the reader's own coordinate
 * system.
 *
 * Declared here rather than reusing core's `SpineLocator` for the *constructed* value:
 * an interface imported from another module can be used as a parameter or return type
 * but an object literal may not implement it here (`docs/arkts-constraints.md` §2.0).
 * `decodeSpineLocator` still returns core's type and its fields are copied across.
 */
interface AnnotationStart {
  spineIndex: number;
  domPos: string;
}

/** A settings copy with the font size nudged, clamped to the supported range. */
function adjustedFontSize(base: ReaderSettings, delta: number): ReaderSettings {
  const next: ReaderSettings = copySettings(base);
  next.fontSize = clampFontSize(next.fontSize + delta);
  return next;
}

@Component
export struct ReaderView {
  @Prop bookId: string;
  /** Absolute sandbox path of the book file. */
  @Prop filePath: string;
  @Prop title: string;
  @Prop initialSpine: number;
  @Prop initialDomPos: string;
  /**
   * `books.current_cfi`: the position a ReadAny client left, in the only coordinate
   * system that client can express.
   *
   * Consulted **only** when `initialSpine` is negative — a `(spineIndex, domPos)`
   * pair, local or synced, is the reader's own coordinate and always wins. A CFI can
   * do no better than the chapter, which `spineIndexFromCfi` explains at the point of
   * use.
   */
  @Prop initialCfi: string;
  /**
   * The locator of the annotation the user tapped to get here, or empty for an
   * ordinary open.
   *
   * **This is an override, not a seed.** It is not combined with the stored position
   * and it does not pass through `resolveOpenPosition`: when it resolves, it wins
   * outright, because the whole point of tapping a bookmark is to go *there* rather
   * than to where the book was last left. When it does not resolve, the stored
   * position above is what the reader opens at — `annotationStart` explains which
   * locators resolve and what each form can honestly restore.
   *
   * Resolved here rather than in the shell because the mapping from a CFI's spine
   * ordinal to the kit's spine index needs `getSpineList()`, which exists only after
   * this component has parsed the book.
   */
  @Prop initialLocator: string;
  @Prop settings: ReaderSettings;
  /**
   * The application theme. **The reader's page colours come from here and nowhere else.**
   *
   * The reader used to carry its own `themeColor` / `fontColor` / `nightMode` and a 夜间
   * toggle, so the page was painted from a second source that nothing connected to
   * `themeMode`: `applySystemAppearance()` recoloured the window while the page stayed
   * cream, and the sepia theme showed a white reader with light-mode text even in dark mode.
   *
   * Now the page is `readerAppearance(this.themeMode)`, which derives background and text
   * from one palette in one call — so the two cannot disagree — and the reader has no theme
   * control of its own. That is what ReadAny does: its reader has no theme setting, it reads
   * the application theme off the document root and re-applies on a `data-theme` change
   * (`packages/app/src/components/reader/FoliateViewer.tsx:111-119`, `:944-968`).
   *
   * A `@Prop`, so the change propagates here if the shell's theme changes while a book is
   * open, and `@Watch`ed because the kit needs the new colours *pushed* through
   * `setPageConfig` — a re-render repaints the bars but cannot re-colour the kit's page.
   */
  @Prop @Watch('onThemeModeChanged') themeMode: ThemeMode;
  @Prop callbacks: ReaderCallbacks;

  @State private loading: boolean = true;
  /**
   * Effective reader settings, held locally.
   *
   * **Typography and the reader's own two choices — no colours.** Appearance comes from
   * `themeMode` through `pageColors()`, so there is no colour field here to fall out of step
   * with the theme. What is local is what a tap has to apply on the same frame it happens:
   * routing every font-size tap through the host would make the page lag one frame behind
   * the button.
   */
  @State private live: ReaderSettings = defaultReaderSettings();
  /** Empty until the kit reports the first page. */
  @State private chapterTitle: string = '';
  /**
   * The reader's chrome follows the application theme.
   *
   * Subscribed rather than read once: `Motion.clickEffect()` answers "off" by returning
   * `null`, and a component only re-evaluates that answer when the value it read changes.
   * That is why the gate below is `this.animationOn ? … : null` and why this field is a
   * `@StorageLink` — the same shape `ListRow` uses.
   */
  @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;
  /**
   * Page index within the current spine item, straight from `PageDataInfo.pageOffset`.
   *
   * **0-based**, and `-1` when the kit reports its "before this resource" sentinel. That
   * base is a runtime observation, not a documented one — the SDK's own comment says only
   * "page offset of current read page to whole resource" — so `pageIndicator` never
   * prints a number it cannot justify. See the capability note above `pageIndicator`.
   */
  @State private pageOffset: number = PAGE_OFFSET_UNKNOWN;
  @State private errorText: string = '';
  /** True once `init()` resolved; before that the controller refuses other calls. */
  @State private controllerReady: boolean = false;

  /**
   * Whether the reader's two floating bars are on screen. **Its only writer is the middle tap
   * zone** (`tapZones` → `toggleBars`).
   *
   * The bars are hidden at rest and stay exactly where the reader put them: there is no
   * auto-hide timer and no tap-outside-to-dismiss, so this boolean is the whole of the bars'
   * state machine. See `toggleBars` for why it cannot drift from `sheetOpen`, and `build` for
   * why an appearance or disappearance here is not a layout event for the kit.
   */
  @State private barsVisible: boolean = false;

  /**
   * The top bar's system material, built **once**, or `undefined` for the opaque bar.
   *
   * A field rather than a call at the attribute, for two reasons: `topBarTitle` has to
   * *branch* on whether a material exists (ArkTS cannot apply an attribute conditionally in one
   * component call), so a call in the branch's condition and another in its argument would
   * build two different objects per render — and the 沉浸光感 power guidance is explicit that
   * changing material parameters, or re-creating the material, makes the framework recompute
   * it (「频繁修改style、materialColor等材质参数…都会触发材质效果重新计算」,
   * 沉浸光感功耗优化). `topBarMaterialOption()` is the one gate: it answers `undefined` on a
   * pre-26 runtime, on a device that reports no immersive support, and on a device whose
   * material level would paint the surface from the *system's* palette instead of this app's.
   */
  private topBarMaterialObject: Object | undefined = topBarMaterialOption();

  /**
   * The controller the component hands back.
   *
   * **Not** the instance created here. The official example assigns the callback's
   * `data` back over the field, which means the panel builds its own controller and
   * the passed-in one is only a placeholder. Keeping the original would leave every
   * later call — `startPlay`, `setPageConfig`, `flipPage`, `releaseBook` — talking to
   * an object the rendered panel never registered.
   */
  private controller: readerCore.ReaderComponentController =
    new readerCore.ReaderComponentController();
  private handler: bookParser.BookParserHandler | undefined = undefined;
  private settingsApplied: boolean = false;
  private lastReportedSpine: number = -1;
  private lastReportedDomPos: string = '';

  // --- current page, for the toolbar ---------------------------------------
  @State private currentSpine: number = 0;
  @State private currentDomPos: string = '';
  /**
   * The index the kit uses for its first spine item.
   *
   * Read from `getSpineList()` rather than assumed to be `0`: `SpineItem` carries its
   * own `index`, and a book whose spine does not start at zero would otherwise open
   * at an arbitrary point — or fail.
   */
  private firstSpineIndex: number = 0;
  /**
   * Ordinal of each spine index, and the spine length.
   *
   * Needed for progress: `resourceIndex` is the *spine index*, not an array
   * position, so `(resourceIndex + 1) / length` is only correct when the indices
   * happen to be a contiguous run starting at zero. A book with a gap in its spine
   * would report progress past its end. The map turns an index into its position.
   */
  private spineOrdinals: Map<number, number> = new Map<number, number>();
  /**
   * Spine indices in reading order: `spineOrder[i]` is the index of the i-th spine
   * item, i.e. the index at ordinal `i`.
   *
   * Kept as well as `spineOrdinals` because the two answer different questions and
   * neither can be derived from the other without assuming what the map exists to
   * avoid assuming: `spineOrdinals` turns an index into a progress ordinal, and this
   * turns an ordinal — from a CFI, or from the first-item lookup — back into the
   * index `startPlay` takes.
   */
  private spineOrder: number[] = [];
  private spineCount: number = 0;
  /** Table of contents, built once after the book is parsed. */
  @State private toc: TocEntry[] = [];
  /**
   * The reader's **single** sheet: whether one is up, and which one.
   *
   * **One `bindSheet` per component, not three.** `build()` used to chain three of them on
   * this root element — one per boolean — and they do not give three sheets. The framework
   * keeps one sheet host per component, and the three bindings fight over it, so the
   * *presence* came from one binding while the *content* came from whichever binding had
   * re-run most recently. On the device that is exactly what happened: a tap on 目录 or
   * 书签 presented nothing at all, while a tap on 笔记 opened a sheet whose content was
   * 添加笔记, then 添加书签, then 目录, depending on which of the other entries had been
   * tapped before it. Nothing was wrong with the sheet content — the 目录 sheet, when it did
   * appear, listed the real chapters and jumped correctly — only with the binding.
   *
   * So the content is state (`sheetMode`) selected by `openReaderSheet`, and there is
   * exactly one binding left to get wrong with. `AnnotationsPage` has always had this
   * shape: one `bindSheet`, on its root container.
   *
   * The `@Watch` is **structural, not instrumentation**: it is the only place a write made by
   * the framework's `$$` binding can be seen, and `onSheetOpenSettled` uses that to repair an
   * open the framework overwrote. `.diag/strip-sheet-probe.mjs` therefore leaves the attribute
   * on; only the watcher's log line belongs to the probe.
   */
  @State @Watch('onSheetOpenWatch') private sheetOpen: boolean = false;
  /**
   * Whether the page behind the sheet is frosted — the gate for the hand-rolled 毛玻璃.
   *
   * ## Why the blur needs its own boolean
   *
   * The blur used to be read straight off `sheetOpen` (`this.sheetOpen ? Thin : NONE`), and
   * that is exactly the bug the user reported: **the frosted mask outlives the sheet on the
   * drag path only.** The hand trace
   * measures why (`.diag/r95-hand-trace.txt`, 11 of 11 closes identical). The framework's
   * binding writes `sheetOpen` back at the **end** of the dismissal it authored —
   * `onDisappear` at **+592 ms**, its write arriving **5–10 ms** later (seq 182 → 187,
   * 201 → 206, 262 → 267, 281 → 286, 356 → 361) — so a blur derived from `sheetOpen` *is* the
   * framework's exit tail. The circular × never showed it because that close is the app's own
   * write: `finishSheetClose` clears `sheetOpen` immediately, so the blur goes with it. Same
   * close, two timings, because only one of the two is written by this component.
   *
   * So the blur is gated on the **same moments the app already writes** — the open, and both
   * dismissal decisions — instead of waiting for a binding write that is late by construction.
   * `sheetBlur` is a **render gate, not a presence flag**: `sheetOpen` stays the one variable
   * that says whether the reader has a sheet up (and the one the framework's `$$` binding
   * owns), and nothing branches on `sheetBlur` except the blur attribute.
   *
   * ## How the two are kept from drifting
   *
   *  - Every write of `sheetOpen` is accompanied by a write of `sheetBlur` in the **same
   *    frame** — true in `openReaderSheet` and in `finishSheetClose` — so "the sheet is up and
   *    the page is not blurred" is not a state the app rests in.
   *  - The drag's write is in `onSheetWillDismiss`, at the decision point, and **not** in
   *    `onWillDisappear` or `onDisappear`. Both of those are too late to look right:
   *    `onWillDisappear` fires *after* the exit animation has begun and the SDK reference
   *    explicitly forbids it — 「不允许在onWillDisappear函数中修改状态变量，可能会导致组件行为
   *    不稳定」 — while `onDisappear` fires 590 ms in, which keeps the mask for the whole exit
   *    tail, i.e. the very complaint. `onWillDismiss` is the dismissal *decision*, which is the
   *    point the × already acts at, and it is the point the reference acts at too: ClashBox
   *    clears its own gate there (`ClashBox/entry/src/main/ets/pages/Index.ets:388`, beside
   *    `DismissSheetAction.dismiss()` at `:392`).
   *  - `sheetBlur` is **raised in exactly the two places `sheetOpen` is**: the open itself, and
   *    the repair in `onSheetOpenSettled`. That second one is r98 and it is the whole of r98's
   *    fix. A clobbered open was repaired for `sheetOpen` and **not** for this gate, so a late
   *    dismissal from the previous cycle left `sheetOpen` true — the repair had re-raised it —
   *    and the gate false, i.e. **a sheet on screen with no frost behind it**, which is the
   *    user's report (「如果关掉立马打开，遮罩会出现异常」). Raising both on the same transition is
   *    what keeps the two from drifting, and it is bounded by the same
   *    `SHEET_MAX_RAISE_ATTEMPTS` because it is the same repair. See `sheetCycle`.
   *  - the clear in `onWillDismiss` is told which cycle it belongs to, so a **late** dismissal —
   *    one arriving after the open that superseded it — does not clear the gate of the sheet
   *    that is now up. That is `sheetDismissalIsStale`, and it reads the cycle fields rather
   *    than the gate, so the gate stays a render gate.
   *  - `onDisappear` is still the **unconditional last word**. It is the framework saying the
   *    sheet is gone, it runs after `onWillDismiss` on every path the trace has, and it stays
   *    unconditional because "a frosted page with no sheet" is the one failure this gate must
   *    not have. See `sheetDismissalIsStale` for why it is the one clear that is not gated.
   *
   * `tools/verify-reader-chrome.mjs` asserts the property rather than the shape: the gate is a
   * state field, every write site is named, the raise sites are the same three sites
   * `sheetOpen`'s are, and the field is read in exactly one place outside the removable probe.
   *
   * That last sentence is about where a blur may be *cleared from*, and it is deliberately
   * separate from the single-writer property that governs `sheetOpen`: `sheetOpen = false`
   * still appears exactly once, in `finishSheetClose`. `onSheetWillDismiss` writes no presence
   * state at all — only this render gate.
   */
  // ==== DIAG-SHEET-BEGIN ====
  // The blur gate's own watcher exists **only** for the hand trace: it is the one line that
  // makes every write to `sheetBlur` visible as itself, whoever made it, exactly as
  // `onSheetOpenWatch` does for `sheetOpen`. It is removable, and the strip has to put the
  // declaration below back without it, because nothing in the fix depends on it.
  // ==== DIAG-SHEET-END ====
  @Watch('onSheetBlurProbe')
  @State private sheetBlur: boolean = false;
  /** Which sheet `sheetOpen` presents. Only `openReaderSheet` sets it. */
  @State private sheetMode: ReaderSheetMode = ReaderSheetMode.TOC;
  /**
   * Which dismissal/re-open cycle `sheetOpen` is in. **This is the whole fix.**
   *
   * ## What the hand trace shows (`.diag/r95-hand-trace.txt`)
   *
   * The exit is a **fixed ~590 ms** — measured 11 times out of 11 closes, 589/593/594/597/
   * 599/600, and *identical* for the × and for the drag. It is not a signal an app can wait
   * for, because of where the framework puts its own write-back of `$$`:
   *
   *   seq 182 `onDisappear-enter` (the exit has ended) → seq 187 WATCH `now=false`
   *   seq 262 `onDisappear-enter`                      → seq 267 WATCH `now=false`
   *   seq 281 `onDisappear-enter`                      → seq 286 WATCH `now=false`
   *   seq 356 `onDisappear-enter`                      → seq 361 WATCH `now=false`
   *
   * (Four of the five pairs; the fifth is seq 201 `onDisappear-enter` → seq 206 WATCH
   * `now=false`. Every pair is 5–10 ms apart. These numbers are the r95 trace on disk, checked
   * against it rather than carried over: r97 cited `265→267`, `320→322` and `358→361` here, and
   * on this trace those index an `openReaderSheet-enter`, an `onAppear-acked` and an
   * `openReaderSheet-wrote-true` — i.e. the numbers had drifted off the lines they were meant
   * to name, while the *claim* they support is correct and is what the pairs above show.)
   *
   * So the write-back lands **after the exit has already ended**, and the framework then runs
   * its still-live dismissal against the sheet the app has raised in the meantime — a **new**
   * `onWillDismiss` (`reason=3`), seq **348** in the trace, 590 ms after that sheet's own
   * `onWillAppear`. That is the "appears and closes again", and it is why r95's deferral
   * changed nothing about it. It is also what r98 is for: that late callback clears the blur
   * gate unless it is told which cycle it belongs to. See `sheetDismissalIsStale`.
   *
   * The r95 mechanism held the open until `onDisappear` and replayed it there. The trace shows
   * the replay ran 12 times and never survived, and the user's own report names the cost of
   * that design: **「现在关了再开有点不跟手，会让人感觉有延迟」** — the tap went quiet for the
   * length of an exit animation.
   *
   * ## The fix: stop fighting the framework over the variable
   *
   * The drag path was asymmetric because **this component wrote `sheetOpen = false` inside
   * the framework's own dismissal** (`onSheetWillDismiss`), at the one moment the framework
   * was mid-decision. Every other close — the ×, `onBackPress`, a catalog jump — writes the
   * boolean from a frame the framework is not using, which is exactly why the × never had this
   * bug. The drag now does the same thing: the app's close write moves to
   * `finishSheetClose()`, and `onWillDismiss` calls `action.dismiss()` and **nothing else**.
   *
   * With the app no longer writing during the dismissal:
   *
   *  - a tap writes `sheetOpen = true` **immediately** — there is no held request and no
   *    replay, so nothing the user does is deferred;
   *  - if the framework is still exiting and clobbers that write, the `@Watch` below sees the
   *    transition back to `false` and re-raises, once per raise attempt, up to
   *    `SHEET_MAX_RAISE_ATTEMPTS`. A clobber is therefore self-healing rather than fatal.
   *
   * The trade is stated plainly rather than discovered: an open issued **inside** the ~590 ms
   * exit hands off to the re-raise, so it is bounded below by the remainder of that exit.
   * An open issued after it is instant. What is *not* traded any more is a tap that goes
   * unanswered for 590 ms while the app sits on the request by policy.
   */
  private sheetCycle: number = 0;
  /** The cycle `onAppear` last acknowledged a shown sheet in, or `-1` while none is up. */
  private sheetShownCycle: number = -1;
  /** The cycle a close was *initiated* in; `-1` before the first close. */
  private sheetCloseCycle: number = -1;
  /**
   * The cycle a `true` write is outstanding for, or `-1` when nothing is outstanding.
   *
   * "Outstanding" means: the app has asked for this sheet in this cycle and the framework has
   * **not shown it** — `onAppear` has not fired for this cycle. It is cleared by `onAppear`,
   * which is the acknowledgement, and by every close. That distinction is what keeps the
   * re-raise honest: after a real dismissal the intent has been answered (the sheet was up) or
   * withdrawn (the app closed it), so the framework's `false` is left alone.
   */
  private sheetIntentCycle: number = -1;
  /** How many times this cycle has tried to raise. Bounded by `SHEET_MAX_RAISE_ATTEMPTS`. */
  private sheetRaiseAttempts: number = 0;
  /**
   * Whether the app's own close is still in flight — set by `finishSheetClose`, cleared by
   * `onAppear` (the sheet is going up) and by `onDisappear` (the exit has finished).
   *
   * It is **not** a guard on anything any more, and that is deliberate: r95 read it in
   * `openReaderSheet` and held the open until it cleared, which is what made a quick re-open
   * wait out a whole exit animation. Nothing about opening consults it now.
   *
   * It is also **not** set from `onWillDismiss`. The framework's dismissal is not the app's,
   * and marking it as the app's is what made an open wait for a framework callback it could
   * not see the end of. What survives is one honest fact — "the app asked for this close" —
   * which is what the probe prints and what makes a `dismissing=true` line unambiguous in the
   * trace.
   */
  private dismissing: boolean = false;
  // ==== DIAG-SHEET-BEGIN ====
  /** Sequence number for the sheet probe's lines. */
  private sheetProbeSeq: number = 0;
  // ==== DIAG-SHEET-END ====
  /**
   * Why the last tap in the 目录 sheet did not move the reader, drawn *inside* that sheet.
   *
   * Not `flash()`: the transient message is part of this component's page column, so it sits
   * **under** the sheet overlay and a tap that refused to jump would still look like nothing
   * happened. A refused jump is exactly the "silent no-op" this fix is about, so its
   * explanation has to be drawn where the tap was. Cleared by `openReaderSheet`, so a fresh
   * sheet never opens carrying the previous refusal.
   */
  @State private tocNotice: string = '';
  /**
   * The bookmark composer's label field — **kept unused, deliberately.**
   *
   * The 书签 sheet is an empty state for now (`bookmarkSheet`), so nothing reads this field
   * and nothing writes it back to `onAddBookmark`. It is left in place rather than deleted
   * because the bookmark plumbing behind it — the `onAddBookmark` callback, the store's
   * `createBookmark` and the table's sync — is verified working and is needed for the round
   * that fills the sheet in, and that round will want this field back. The reader's unused
   * state is a smaller cost than a deletion that has to be undone; the compiler does not warn
   * on an unused `@State`, and the sheet presentation is the only thing that changed.
   */
  @State private bookmarkLabel: string = '';
  /** The note composer's two fields — kept unused for the same reason as `bookmarkLabel`. */
  @State private noteTitle: string = '';
  @State private noteContent: string = '';
  /** Transient confirmation for an action with no visible result of its own. */
  @State private toastText: string = '';
  /** Pending auto-hide timer for `toastText`; -1 when none is scheduled. */
  private flashTimer: number = -1;

  aboutToAppear(): void {
    this.settingsApplied = false;
    this.live = copySettings(this.settings);
    // The two bars are placed by the window's avoid areas, not by the page box. Read once, here,
    // so the first reveal is already in the right place. See `resolveAvoidInsets`.
    this.resolveAvoidInsets();
  }

  /**
   * The application theme changed while a book is open: push the new page colours to the kit.
   *
   * A re-render is enough for everything this file draws — the bars, the panel and the track
   * all read `pageColors()` — but the kit's page is painted by `setPageConfig`, so it has to
   * be told. `applySettings` refuses before `controllerReady`, which is correct rather than a
   * gap: `initialize()` applies the config itself, from the same `pageColors()`, so the first
   * page is already painted with the current theme.
   *
   * In today's navigation the picker is on the shelf and the reader owns the window, so this
   * cannot fire yet. It exists so that "the theme changed" is handled where the kit's copy of
   * the colours lives, instead of leaving a stale page behind the first time a theme control
   * becomes reachable from inside a book.
   */
  onThemeModeChanged(): void {
    this.applySettings(this.live);
  }

  /**
   * Handle the system back gesture.
   *
   * Layered deliberately: an open sheet is closed first, and only when the reader is the
   * topmost surface does back leave the book. Without this the back gesture exits the
   * application from inside a book, which reads as a crash to the person using it.
   *
   * Since 设置 became the fourth `ReaderSheetMode` there is exactly one overlay to close
   * here. The second branch this used to carry was the inline 字号 panel's own boolean,
   * which no longer exists: the sheet's × and the system back gesture now close the
   * settings sheet through the same `sheetOpen`.
   *
   * Returning `true` consumes the event; `false` lets the framework continue.
   */
  onBackPress(): boolean {
    if (this.sheetOpen) {
      this.finishSheetClose();
      this.onSheetProbe('onBackPress-close', this.sheetOpen); // DIAG-SHEET
      return true;
    }
    if (this.errorText.length > 0) {
      // The book failed to open, so there is no reading session to return to; leaving
      // is the only sensible action.
      this.callbacks.onBack();
      return true;
    }
    this.callbacks.onBack();
    return true;
  }

  aboutToDisappear(): void {
    // Cancel the transient-message timer before anything else: a pending timer would
    // fire after this component is gone.
    if (this.flashTimer !== -1) {
      clearTimeout(this.flashTimer);
      this.flashTimer = -1;
    }
    // Releasing matters: the kit holds the parsed book and its fonts, and leaking
    // it would keep the file locked and the memory allocated for the next book too.
    try {
      this.controller.releaseBook();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'releaseBook failed: %{public}s', JSON.stringify(err));
    }
    try {
      this.controller.off('pageShow');
    } catch (err) {
      // Ignored: nothing is subscribed if initialization failed.
    }
  }

  /**
   * Initialize the kit.
   *
   * Order is load-bearing: parse the book, hand the parser to the controller,
   * `init`, `startPlay`, then apply the page config. Applying the config before
   * `startPlay` is accepted, but the first pagination would use the kit's defaults
   * and the page would visibly reflow once the real font size arrived.
   */
  private async initialize(): Promise<void> {
    // Reader Kit is a system capability, not part of the base framework, and it is
    // split across **two** of them:
    //
    //   SystemCapability.Reader.ReaderService.BookParser   → bookParser
    //   SystemCapability.Reader.ReaderService.ReaderCore   → ReadPageComponent, readerCore
    //
    // Both are required. `SystemCapability.Reader.ReaderService` on its own is only the
    // namespace prefix, **not a capability a device declares** — checking it would
    // always answer false and disable the reader everywhere. An earlier version of
    // this guard made exactly that mistake.
    //
    // Checked first so an unsupported device gets one clear sentence instead of a blank
    // panel or a crash inside the kit. Both are documented for phone, tablet and 2in1
    // since API 16 — well below this module's `compatibleSdkVersion` of 24 — so the
    // expectation is that they are present; this branch exists so that if one is not,
    // the reason is visible.
    //
    // `canIUse` is the right test here, and the distinction is worth stating because
    // the two are easy to confuse: `canIUse` answers "does this device have the
    // capability", while version gating elsewhere in this module uses
    // `deviceInfo.sdkApiVersion` to answer "what API level is this". A new API level
    // does not imply a capability.
    const hasParser: boolean = canIUse('SystemCapability.Reader.ReaderService.BookParser');
    const hasReaderCore: boolean = canIUse('SystemCapability.Reader.ReaderService.ReaderCore');
    if (!hasParser || !hasReaderCore) {
      const missing: string = !hasParser && !hasReaderCore
        ? 'BookParser 与 ReaderCore'
        : (!hasParser ? 'BookParser' : 'ReaderCore');
      this.fail(
        `这台设备不提供 Reader Kit 阅读能力（缺少 SystemCapability.Reader.ReaderService.`
        + `${missing}），无法在应用内打开书籍。`,
      );
      return;
    }

    try {
      this.handler = await bookParser.getDefaultHandler(this.filePath);
    } catch (err) {
      this.fail(`无法解析这本书：${messageOf(err)}`);
      return;
    }

    try {
      // **`init()` FIRST.** The SDK marks `registerBookParser` as throwing
      // `1016900002 - Read Page Component is not initialized` (readerComponent.d.ets:286,
      // on the declaration at :294), exactly like `startPlay` (:242) and
      // `setPageConfig` (:271). Only `init` (:223) is exempt.
      //
      // This screen used to call `registerBookParser` before `init`, which threw on the
      // first call and surfaced to the user as "阅读器初始化失败：Read Page Component is
      // not initialized." — the reader never opened on a device. The file's own header
      // already said "init() must be called before the other controller methods"; the
      // code did not follow it. Order is the whole bug.
      const context: common.UIAbilityContext = this.getUIContext()
        .getHostContext() as common.UIAbilityContext;
      await this.controller.init(context);
      this.controllerReady = true;

      this.controller.registerBookParser(this.handler);
      this.controller.on('pageShow', (info: readerCore.PageDataInfo): void => {
        this.handlePageShow(info);
      });

      // The spine index is taken from the kit, not assumed to start at 0. `SpineItem`
      // carries its own `index`, and the official example starts from
      // `spineList[0].index`; `0` is only the fallback for an empty spine.
      // After `registerBookParser`, because the spine list comes from the parser.
      this.indexSpine();
      this.firstSpineIndex = this.spineCount > 0 ? this.spineIndexAt(0) : 0;

      this.controller.setPageConfig(this.toKitSettings(this.live));
      this.settingsApplied = true;

      // A tapped annotation wins; then a stored position; then the book's own first
      // spine item, or the chapter a peer's CFI names.
      //
      // The `>= 0` test is the contract of `emptyPosition()`: spine index `0` is a
      // real position (the first spine item) and must not read as "nothing stored".
      // That confusion is what made this fallback dead code — the empty position
      // used to carry `spineIndex: 0`, so the test was always true and a fresh
      // install always started at spine 0 with an empty `domPos`.
      //
      // The annotation branch is separate from the seed test, and it falls back *into*
      // it: an unusable annotation locator (unparsable, or naming a spine item this
      // book does not have) leaves `annotationStart` returning undefined, so the stored
      // position below is used — which is what this screen did before annotations were
      // navigable at all. It must not drop through to the first-page fallback: "we
      // cannot use the bookmark" and "there is no position" are different facts, and
      // conflating them is the bug this whole area exists to fix.
      const fromAnnotation: AnnotationStart | undefined = this.initialLocator.length > 0
        ? this.annotationStart(this.initialLocator)
        : undefined;
      if (fromAnnotation === undefined && this.initialLocator.length > 0) {
        hilog.warn(DOMAIN, TAG,
          'annotation locator unusable for this book, opening at the stored position: %{public}s',
          this.initialLocator);
      }
      if (fromAnnotation !== undefined) {
        await this.controller.startPlay(fromAnnotation.spineIndex, fromAnnotation.domPos);
      } else if (this.initialSpine >= 0) {
        await this.controller.startPlay(this.initialSpine, this.initialDomPos);
      } else {
        const fromCfi: number = this.spineIndexFromCfi();
        // `startPlay` is the only positioning call the kit has: no goToPage, no
        // seek, no setLocator, and `setPageConfig` carries layout only.
        await this.controller.startPlay(fromCfi >= 0 ? fromCfi : this.firstSpineIndex, '');
      }

      let chapters: number = 0;
      try {
        chapters = this.handler.getSpineList().length;
      } catch (err) {
        chapters = 0;
      }
      this.callbacks.onReady(chapters);
      this.loading = false;
    } catch (err) {
      // A failure here is fatal for this screen; the shell shows the message and
      // the user can back out.
      this.fail(`阅读器初始化失败：${messageOf(err)}`);
    }
  }

  /**
   * Record each spine item's index and its ordinal position.
   *
   * Built once per book. `getSpineList()` is documented to return the spine in
   * reading order, so the array position is the ordinal.
   */
  private indexSpine(): void {
    const ordinals: Map<number, number> = new Map<number, number>();
    const order: number[] = [];
    let count: number = 0;
    try {
      const spineList: bookParser.SpineItem[] = this.handler !== undefined
        ? this.handler.getSpineList()
        : [];
      for (let i = 0; i < spineList.length; i++) {
        const index: number = spineList[i].index;
        // Pushed even when the index is unusable, so an array position keeps meaning
        // one ordinal for every consumer: `spineIndexForOrdinal` then rejects that
        // one entry rather than having every later entry shift by one.
        order.push(index);
        if (!Number.isNaN(index)) {
          ordinals.set(index, i);
        }
      }
      count = spineList.length;
    } catch (err) {
      count = 0;
    }
    this.spineOrdinals = ordinals;
    this.spineOrder = order;
    this.spineCount = count;
    this.toc = this.buildToc();
  }

  /**
   * Build the table of contents.
   *
   * Each entry's spine index comes from matching its href against the spine's own
   * hrefs, rather than from `catalogId`: the two come from different parts of the
   * package document and are not guaranteed to agree, and the spine is what
   * `startPlay` takes.
   */
  private buildToc(): TocEntry[] {
    const entries: TocEntry[] = [];
    if (this.handler === undefined) {
      return entries;
    }
    let catalog: bookParser.CatalogItem[] = [];
    let spineList: bookParser.SpineItem[] = [];
    try {
      catalog = this.handler.getCatalogList();
      spineList = this.handler.getSpineList();
    } catch (err) {
      return entries;
    }

    for (const item of catalog) {
      const href: string = item.href !== undefined ? item.href : '';
      const spineIndex: number = matchSpineIndex(href, item.idRef, spineList);
      entries.push({
        catalogId: item.catalogId,
        name: item.catalogName,
        level: item.catalogLevel !== undefined ? item.catalogLevel : 0,
        href: href,
        spineIndex: spineIndex,
        navigable: spineIndex >= 0,
      });
    }
    return entries;
  }

  /**
   * Jump to a catalog entry.
   *
   * `getDomPosByCatalogHref` gives the DOM position within the spine item, which is
   * the second half of the locator `startPlay` needs; without it the jump would land
   * at the start of the chapter, which for a long chapter is the wrong page.
   *
   * The two ways this can refuse — no parser, or an entry the catalog has but the spine
   * does not — both say so rather than returning quietly. A row that swallows its tap is
   * indistinguishable from a broken feature, which is how the whole 目录 entry was
   * experienced before this was fixed.
   */
  private async jumpToCatalog(entry: TocEntry): Promise<void> {
    if (this.handler === undefined) {
      // A row that does nothing when tapped cannot be told apart from a broken entry, so
      // both of these refusals say something — and they say it in the sheet, because the
      // sheet is drawn over the transient message.
      this.tocNotice = '正文还没准备好，稍后再试。';
      return;
    }
    if (!entry.navigable) {
      this.tocNotice = '这一条在目录里有，但正文里没有对应位置，无法跳转。';
      return;
    }
    this.tocNotice = '';
    this.finishSheetClose();
    let domPos: string = '';
    try {
      domPos = this.handler.getDomPosByCatalogHref(entry.href);
    } catch (err) {
      // Falling back to the start of the spine item is still a correct jump.
      domPos = '';
    }
    try {
      await this.controller.startPlay(entry.spineIndex, domPos);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'startPlay failed: %{public}s', JSON.stringify(err));
    }
  }

  /** The spine index at an ordinal position, or `0` for "no such position". */
  private spineIndexAt(ordinal: number): number {
    const index: number = this.spineIndexForOrdinal(ordinal);
    return index >= 0 ? index : 0;
  }

  /**
   * Resolve a 0-based spine ordinal to the kit's spine index, or -1 when this book
   * has no such position.
   *
   * The **list position is the ordinal**, not `SpineItem.index`. `getSpineList()` is
   * documented to return the spine in reading order, while `SpineItem.index` is only
   * the value `startPlay` takes — and that value is not guaranteed to be a
   * contiguous run from zero. Mapping by `index` would therefore be off by the
   * difference for a book whose spine starts at one, and the result would be a wrong
   * chapter with nothing reported.
   *
   * -1 is returned rather than 0 because index 0 is a real spine item; a caller that
   * could not distinguish them would open the first chapter and call it a match.
   */
  private spineIndexForOrdinal(ordinal: number): number {
    if (!Number.isInteger(ordinal) || ordinal < 0 || ordinal >= this.spineOrder.length) {
      return -1;
    }
    const index: number = this.spineOrder[ordinal];
    return Number.isInteger(index) && index >= 0 ? index : -1;
  }

  /**
   * Where a tapped annotation says to open, or `undefined` when its locator cannot be
   * used for this book.
   *
   * **Two locator forms, with different precision — stated rather than smoothed over.**
   *
   *  - **`spine:{n}:{domPos}` — this client's own form, and it restores exactly.**
   *    Written by `AppCore.createBookmarkAt` / `createNoteAt` via `encodeSpineLocator`,
   *    where `n` is the Reader Kit spine index the page reported (`info.resourceIndex`)
   *    and `domPos` is the kit's own opaque position string (`info.startDomPos`). Both
   *    halves are the kit's own coordinates, so they are handed to `startPlay`
   *    unchanged. The index is still checked against *this* book's spine: a locator
   *    synced from another device can name an index this file does not have.
   *  - **An EPUB CFI — chapter-accurate only.** `spineOrdinalFromCfi` extracts the
   *    spine step and `spineIndexForOrdinal` maps that ordinal through the parser's
   *    real `getSpineList()` order, so the *chapter* is exact (a range CFI is reduced
   *    to its start location, §3.4, which is where the annotation is anchored). The
   *    position **inside** the chapter is not recoverable and is not invented here:
   *    everything after the `!` is a CFI path into an XHTML document, while
   *    `startPlay` wants a Reader Kit `domPos` — an opaque string only the kit mints,
   *    with no grammar in the SDK, no constructor, and no CFI bridge anywhere in
   *    `@hms.core.readerservice.*`. So the CFI case returns an empty `domPos` and the
   *    jump lands at the top of the chapter. A person tapping a synced bookmark gets
   *    the right chapter and may have to page a little; they do **not** get a
   *    fabricated page number, which is the failure mode this refuses.
   *
   * `undefined` covers everything unusable — a locator that does not parse, a
   * `page:{N}` marker, or a spine step/index past the end of this book's spine (a
   * stale CFI from another edition, which is real: the file and the row sync
   * independently). The caller then keeps the stored reading position. Returning the
   * first spine item, or clamping to the last one, would present a guess as the
   * annotation's position and would be indistinguishable in a log from a jump that
   * worked.
   */
  private annotationStart(locator: string): AnnotationStart | undefined {
    if (isSpineLocator(locator)) {
      const decoded: SpineLocator | undefined = decodeSpineLocator(locator);
      if (decoded === undefined) {
        return undefined;
      }
      // The index must be one of this book's own spine indices. `spineOrder` is the
      // parser's list-position order, i.e. exactly the indices `startPlay` accepts,
      // so it is the list to test against rather than the number alone.
      if (!Number.isInteger(decoded.spineIndex) || decoded.spineIndex < 0
        || this.spineOrder.indexOf(decoded.spineIndex) < 0) {
        return undefined;
      }
      return { spineIndex: decoded.spineIndex, domPos: decoded.domPos };
    }
    if (isEpubCfi(locator)) {
      const ordinal: number = spineOrdinalFromCfi(locator);
      if (ordinal === CFI_ORDINAL_UNKNOWN) {
        return undefined;
      }
      // The book-CFI mapper, reused rather than re-derived: two copies of `N/2 - 1`
      // is how an off-by-one gets in.
      const index: number = this.spineIndexForOrdinal(ordinal);
      if (index < 0) {
        return undefined;
      }
      return { spineIndex: index, domPos: '' };
    }
    return undefined;
  }

  /**
   * The spine index a peer's CFI points at, or -1 when it cannot be used.
   *
   * **Chapter-accurate, not page-accurate.** A CFI from a ReadAny client also names
   * a position inside the spine item (`!/4/88`, or the start of a range), but Reader
   * Kit paginates to a `domPos` that only the kit can mint: the SDK defines no
   * grammar for it, exposes no constructor, and has no CFI concept at all
   * (`@hms.core.readerservice.*` contains no `cfi`). The honest ceiling is therefore
   * the chapter, which is what this returns; the reader opens at `startPlay(index,
   * '')` and stops there rather than guessing a page.
   *
   * The arithmetic is EPUB CFI 1.1 §3.1.1: element steps are even from 2, and the
   * leading step references `<spine>`, so a CFI's `/6/N` gives the 0-based ordinal
   * `N/2 - 1`. `spineOrdinalFromCfi` does the parsing and rejects anything that is
   * not a usable spine pointer; both failures below are logged, because "opened at
   * page 1" and "opened at the CFI's chapter" must not look the same in a log.
   */
  private spineIndexFromCfi(): number {
    if (this.initialCfi.length === 0) {
      return -1;
    }
    const ordinal: number = spineOrdinalFromCfi(this.initialCfi);
    if (ordinal === CFI_ORDINAL_UNKNOWN) {
      hilog.warn(DOMAIN, TAG, 'unusable book CFI, opening at the first page: %{public}s',
        this.initialCfi);
      return -1;
    }
    const index: number = this.spineIndexForOrdinal(ordinal);
    if (index < 0) {
      // A spine step past the end of this book's spine means the CFI came from a
      // different edition — a real case, since the file and the row can be updated
      // independently. It is ignored rather than clamped to the last spine item:
      // chapter 1140 of another edition is no evidence about this book's last
      // chapter, and clamping would present a guess as a position. The log keeps it
      // distinguishable from a book with no position at all.
      hilog.warn(DOMAIN, TAG,
        'book CFI is beyond this spine (chapter %{public}d of %{public}d), opening at the first page',
        ordinal + 1, this.spineOrder.length);
      return -1;
    }
    return index;
  }

  /**
   * Fraction read, from a spine index.
   *
   * Uses the ordinal rather than the index itself; see `spineOrdinals`. An index the
   * map does not know is treated as the end, which is the safe direction for a
   * progress bar — it never claims more progress than the reader has.
   */
  private progressFor(spineIndex: number): number {
    if (this.spineCount <= 0) {
      return 0;
    }
    const ordinal: number | undefined = this.spineOrdinals.get(spineIndex);
    if (ordinal === undefined) {
      return 1;
    }
    return Math.min(1, (ordinal + 1) / this.spineCount);
  }

  private fail(message: string): void {
    this.errorText = message;
    this.loading = false;
    this.callbacks.onOpenFailed(message);
  }

  /**
   * Handle a page change.
   *
   * `pageShow` fires for every page, including the first, so this is both the
   * progress source and the page-header source. Reporting is deduplicated by
   * `(spineIndex, domPos)` because the kit re-emits for the same page when the
   * window resizes, and each duplicate would otherwise be a database write.
   */
  private handlePageShow(info: readerCore.PageDataInfo): void {
    if (info.state === readerCore.PageState.OPEN_BOOK_FAIL) {
      this.fail('打开书籍失败，文件可能已损坏');
      return;
    }
    if (info.state !== readerCore.PageState.PAGE_ON_SHOW) {
      return;
    }

    this.chapterTitle = this.resolveChapterTitle(info.resourceIndex, info.pageHeaderContent);
    // `pageFooterContent` is deliberately not shown. It is documented as "page num
    // displayed at footer of current read page" (readerComponent.d.ets:416), i.e. a string
    // the *book* supplies for its own footer, not a page number the kit computed: it is
    // empty for every page of the test book on the device. The page indicator is built
    // from `pageOffset` instead, which is a number in the same coordinate system the kit
    // lays pages out in.
    this.pageOffset = info.pageOffset;
    // The reading-progress percentage is deliberately **not** kept here any more. The bottom bar
    // lost its progress row this round (it carries the four entries and nothing else), and a
    // `@State` maintained for a read-out that no longer exists is dead state — the fraction the
    // app persists and syncs is computed below, from `progressFor`, at the one place it is
    // actually used. See `progressFor`.
    // Updated before the dedup guard below: the toolbar must always act on the page
    // currently on screen, even when the event itself is a duplicate the progress
    // reporter is right to skip.
    this.currentSpine = info.resourceIndex;
    this.currentDomPos = info.startDomPos;

    const spineIndex: number = info.resourceIndex;
    const domPos: string = info.startDomPos;
    if (spineIndex === this.lastReportedSpine && domPos === this.lastReportedDomPos) {
      return;
    }
    this.lastReportedSpine = spineIndex;
    this.lastReportedDomPos = domPos;

    // Progress is spine position, not a character count: the kit reports a page
    // number within the current spine item but not a total across the book, and a
    // fabricated total would drift from what the other clients display.
    const fraction: number = this.progressFor(spineIndex);

    this.callbacks.onPositionChanged({
      spineIndex: spineIndex,
      domPos: domPos,
      fraction: fraction,
      chapterTitle: this.chapterTitle,
      updatedAt: Date.now(),
    });
  }

  /**
   * The chapter name for a spine item, from the table of contents this screen already
   * built.
   *
   * **Why the TOC and not `pageHeaderContent`.** The kit's header string is a *running
   * head*, which for a book whose XHTML carries no running-head markup is the book title:
   * on the device it reads "牧神记" on every page of 牧神记, while the chapter the page
   * belongs to is 第16章 庙中幼女. Putting that string in the centre of the top bar would
   * reproduce the duplicated book title this redesign exists to remove.
   *
   * This is the **same** chapter data the reader already resolves for bookmarks, notes and
   * the 目录 sheet — `this.toc`, built once by `buildToc()` through `matchSpineIndex` — so
   * it is not a second mapping. The header string is kept as the fallback, because a spine
   * item the catalog does not name (front matter, a cover) is a real case and the running
   * head is better than nothing; the book title is the last resort.
   *
   * **Known limit, stated rather than hidden:** the first navigable entry for the spine
   * item wins. When one XHTML file holds several catalog entries (parts within a chapter),
   * later entries in that file are not distinguished, because the only thing that could
   * order them inside the file is the opaque `domPos`, which has no documented grammar to
   * compare (`getDomPosByCatalogHref` mints it; nothing says how to sort it).
   */
  private resolveChapterTitle(spineIndex: number, headerContent: string): string {
    for (const entry of this.toc) {
      if (entry.navigable && entry.spineIndex === spineIndex && entry.name.length > 0) {
        return entry.name;
      }
    }
    if (headerContent.length > 0) {
      return headerContent;
    }
    return this.title;
  }

  /**
   * The page-within-chapter indicator: `第 N 页`.
   *
   * ## Why there is no denominator
   *
   * The layout this screen was asked to match shows `2/6`. That denominator does not
   * exist in Reader Kit, and this is the whole of the evidence, re-verified against the
   * shipped declarations:
   *
   *  - The page callback carries `PageDataInfo` and nothing else
   *    (`@hms.core.readerservice.readerComponent.d.ets:308`,
   *    `public on(type: 'pageShow', callback: Callback<PageDataInfo>)`).
   *  - `PageDataInfo` declares exactly: `pageHeaderContent`, `pageFooterContent`,
   *    `startDomPos`, `endDomPos`, `state`, `resourceIndex`, `pageOffset` — plus
   *    `nodeType`/`dataId` from `PageDatabaseBean` (`:404-486`, `:361-393`). There is no
   *    page count, no chapter length, no "is this the last page" flag. The kit knows that
   *    internally — its own device log tags each page `isBottom` — but it is not part of
   *    the API.
   *  - The controller has no other query surface at all: `init`, `startPlay`, `flipPage`,
   *    `setPageConfig`, `releaseBook`, `registerBookParser`, `on/off('pageShow')`,
   *    `on/off('resourceRequest')` (`:210-351`).
   *
   * So a denominator would have to be invented, and it would be wrong in a way nobody
   * could see. This prints the numerator alone, which is a number the kit really reports.
   *
   * ## Why it is `pageOffset + 1`
   *
   * `pageOffset` is 0-based within the spine item. The declaration's comment
   * (`:466`, "page offset of current read page to whole resource") names the reference
   * frame but not the base, so the base was observed on the device instead: the kit's own
   * log identifies pages as `readerDataId_<resource>_<pageOffset>_<n>` and flipping back
   * through a chapter produced `…_2__4`, `…_1__3`, `…_0__7` with `pageOffset` 2, 1, 0 —
   * zero is the first page of the resource.
   *
   * `-1` is the kit's sentinel for "the page before this resource's first page", which
   * happens at a chapter boundary: the same log shows `…_-1__8` with `pageOffset: -1` and
   * `resourceIndex` pointing at the *previous* resource. Printing `第 0 页` there would be a
   * fabricated number, so the indicator is empty for exactly that one case rather than
   * wrong. Carrying the previous value forward was the alternative and is worse: it would
   * present a stale number as the current one.
   */
  private pageIndicator(): string {
    if (this.pageOffset < 0) {
      return '';
    }
    return `第 ${this.pageOffset + 1} 页`;
  }

  // -------------------------------------------------------------------------
  // Reader colours
  //
  // **One source: the application theme.** Every colour on this screen — the page, both
  // floating bars, the four sheets, the chip and every text tone — is a
  // field of `readerAppearance(this.themeMode)`. That function derives background and text
  // from a single `ThemePalette` in one call, so a sepia page with light-mode text cannot
  // be expressed; and this file carries no colour literal of its own, which is what makes
  // that checkable (`tools/verify-themes.mjs`).
  //
  // The reader used to have a second, reader-only set of colours (the `READER_*` day/night
  // constants in `Theme.ets`, plus `ReaderSettings`'s own `themeColor`, `fontColor` and
  // `nightMode`, switched by a 夜间 toggle). That is the bug this replaced: two stores for
  // one concept, and only one of them followed the theme. ReadAny has no reader theme
  // setting at all — see the note on `themeMode`.
  // -------------------------------------------------------------------------

  /** The page's colours for the current application theme. Never `undefined`. */
  private pageColors(): ReaderAppearance {
    return readerAppearance(this.themeMode);
  }

  /**
   * The page background — `ReaderSetting.themeColor`, and the colour both bars are painted.
   *
   * A method rather than a stored field so it cannot drift from `themeMode`: an earlier
   * version kept the page colour in `ReaderSettings`, where a stored value and the theme
   * could disagree forever without anything noticing.
   */
  private pageBackground(): string {
    return this.pageColors().background;
  }

  /** Primary chrome text: the page's own text colour. */
  private chromeText(): string {
    return this.pageColors().foreground;
  }

  /** Secondary chrome text (the page indicator). */
  private chromeMuted(): string {
    return this.pageColors().muted;
  }

  /**
   * The opaque chrome surface: the transient confirmation chip.
   *
   * A step off the page colour, and that is its job — an element painted the page's own tone
   * reads as nothing. It had a second caller until this round: the bottom bar's progress track.
   * That row is gone (the bar carries the four entries and nothing else), so the chip is the
   * only fill left, and the accessor stays because the chip still needs it.
   *
   * **The four sheets used to use it too, and no longer do.** They take the palette's
   * `background` for their body since r94 (`sheetCard`), which is the page tone rather than
   * this chrome tone, because `background` is the surface the palette's text roles are measured
   * against: `foreground` on it is the reader's own page pair, and `chromeMuted()` on it is the
   * tone `readerAppearance` derives for the page. A sheet carries a title, a summary line and
   * two empty states, so it needs the surface those tones were derived for.
   *
   * The two floating bars deliberately do **not** use it. The top bar is painted by its system
   * material or, on the paths that have none, `pageBackground()`; the bottom bar is painted by
   * the HDS floating style, whose gradient mask is the page colour. Neither is this accessor's.
   */
  private chromeSurface(): string {
    return this.pageColors().surface;
  }

  /**
   * The sheets' surface, and the surface their text is measured against.
   *
   * **It is the palette's `background`** — the page/body tone — not `card`. That is the whole
   * of r94's surface change: the sheets used to be painted `card` (a white body in light and a
   * near-white one in sepia) with a `cardSubtle`/`card` row inside them, which is the *inverse*
   * of how the rest of the app is built. The user compared the reader's 设置 sheet against the
   * app's 设置 tab on the device and asked for one scheme — 「把这两个地方的配色统一成背景灰内容
   * 白。其他三个sheet的背景色也统一成灰」 — and the app's own settings page is that scheme:
   * `palette.background` for the page, `palette.card` for every card on it.
   *
   * So the reader's four sheets now take the page role for their body and the card role for the
   * row inside them (`sheetRow`), in all three themes. `paletteFor` is the same table
   * `readerAppearance()` reads, and the reader's own page is `palette.background` too — so the
   * sheet body and the reading page are literally the same colour, and while a sheet is up the
   * page behind it is frosted (`sheetBlurStyle`), which is what keeps the sheet's edge
   * readable. Measured on the device in r92 under 护眼: the blurred region outside the sheet ran
   * `CBC5B7`→`B0A99F` against the sheet's own `F6EBD7` (hex written without `#` because
   * `verify-themes` scans this file for colour literals and cannot tell a comment from one).
   *
   * This is **not** a second colour source: the page, both bars and both chrome surfaces still
   * come from `pageColors()`. `paletteFor` is called here rather than on the reader's page tones
   * because the card/body roles do not exist in `ReaderAppearance` — adding them there would
   * have widened the reader's appearance for one surface.
   */
  private sheetCard(): string {
    return paletteFor(this.themeMode).background;
  }

  /**
   * The palette's edge role — and since r94 it really is an **edge** again, in three places.
   *
   * It is the 1 vp hairline on the settings row (`settingsRow`), the fill of the header's round
   * × chip (`sheetHeader`), and the fill of the row's icon tile and stepper buttons
   * (`sheetRowControl`). The role is the same in all four uses: a fill or a line one step off
   * the surface underneath it, from the palette rather than a second colour source.
   *
   * r93 removed the first of those four — the row's hairline — and r94 put it back because the
   * user's device check rejected the borderless surfaces (「还是保留边框吧，护眼模式下确实看不清」).
   * The measured separations are in `settingsRow`.
   */
  private sheetCardEdge(): string {
    return paletteFor(this.themeMode).border;
  }

  /**
   * The fill of a **row inside a sheet** — the settings row, and the surface its text is
   * measured against.
   *
   * The sheet body is `sheetCard()` (`palette.background`, a grey) and the row is
   * `palette.card` — white in light, a 1E1E1E-level grey in dark, a warm cream in sepia, i.e.
   * the palette's raised-surface role in each theme. **r94 inverted both halves of this pair.**
   * Until then the body was `card` and the row was `cardSubtle`, a token that existed only to be
   * "one step off `card`" — see `Theme.ets`, which no longer defines it, because with the body
   * grey and the row `card` it had no caller left. (Hex values are not written here: this file
   * is scanned whole for colour literals, comments included.)
   *
   * The reference does exactly this and always did: ClashBox paints its sheet
   * `app.color.background` (a grey) and every row `app.color.container_background` (white)
   * — `Constants.ets:19` and `settingsListItem.ets:58`. r92 could not follow it because it kept
   * the body on `card`, and with `card` already pure white in light there was no lighter tone
   * for a row to take. Moving the *body* to the page tone is what makes the reference's
   * direction expressible, which is the argument for doing it this way rather than by inventing
   * a third tone.
   *
   * The row/body step is 1.143:1 (light), 1.124:1 (dark) and **1.047:1 (sepia)** — the same
   * three figures the app's own settings cards measure against their page, because it is now the
   * same pair. Sepia's 1.047:1 is the figure the user's device check overruled as *sufficient
   * on its own*: it is why the row carries the hairline as well (see `settingsRow`), and why
   * `tools/verify-themes.mjs` asserts the edge rather than treating this fill as the whole
   * separation.
   */
  private sheetRow(): string {
    return paletteFor(this.themeMode).card;
  }

  /**
   * The fill of a **control that sits on a row** — the settings row's icon tile and the two
   * stepper buttons.
   *
   * The row is `sheetRow()` (`card`) since r94, so the palette's `muted` control fill would
   * read on it again — it measures 1.112:1 (light), 1.161:1 (dark) and 1.177:1 (sepia) against
   * the row, all above the 1.05:1 this project calls a visible fill. It is nevertheless the
   * palette's **edge** role that fills these, for two reasons: it is stronger on every theme
   * (1.271 / 1.319 / 1.447:1 against the row), and it is the role the header's × chip already
   * uses on the body — so the sheet's small fills stay one role rather than splitting into
   * "controls use muted, the chip uses border", which is two answers to one question.
   *
   * The theme's own text on that fill measures 15.66 / 11.59 / 7.84:1, so the `A` glyph and the
   * `A-` / `A+` labels clear the 4.5:1 floor with room to spare.
   *
   * **The five fill figures above were re-derived in r93** with the same WCAG routine and the
   * values this palette ships; until then the light ones read 1.063:1 and 1.199:1 — a
   * measurement of an earlier light `cardSubtle` candidate (the same abandoned value the r92
   * build stamp's header quoted). **The `muted` figures and the three "against the row" figures
   * were re-derived again in r94**, because the surface under these controls changed from
   * `cardSubtle` to `card`. They are corrected rather than deleted because a comment carrying
   * numbers nobody re-derives is how the values it describes drift.
   */
  private sheetRowControl(): string {
    return this.sheetCardEdge();
  }

  /**
   * The sheets' **secondary text on a card row** — the settings row's own subtitle line.
   *
   * This is the palette's surface-text key, and the row is the surface it was measured on:
   * `mutedForeground` on `card` is 4.88:1 (light), 6.38:1 (dark) and 4.61:1 (sepia), all above
   * this project's 4.5:1 floor.
   *
   * **Why it is a separate accessor from the body's secondary text.** The body's secondary text
   * is `chromeMuted()` — see the note on `emptySheetState` for why the r92 `sheetMuted()` role
   * was deleted and what the two candidates measure — because the body is the page tone and
   * `chromeMuted()` is the tone derived for the page. On a `card` row that tone is the wrong
   * one: it is an alpha over the surface underneath, and the row's surface is not the page. So
   * the row takes the palette's opaque surface-text key instead, which is the key the rest of
   * the app's cards use. Two roles, each defined for the surface it is painted on, rather than
   * one role stretched over both.
   */
  private sheetRowMuted(): string {
    return paletteFor(this.themeMode).mutedForeground;
  }

  /**
   * The blur the reading area wears while a sheet is up: **毛玻璃, not 沉浸光感**.
   *
   * ## What this is, and what it is not
   *
   * It is a plain frosted-glass blur of the reading surface, drawn in response to a sheet. It is
   * **not** 沉浸光感: that is a system material with a light source, a diffusion and a level the
   * system picks, and this app reaches it only through `HdsTabs`'s `systemMaterialEffect` and the
   * book menu's options object. Naming this one 沉浸光感 in code or in a comment would be the
   * mistake this project has already recorded, so it is 毛玻璃/背景模糊 throughout.
   *
   * ## Why it is drawn here and not by the sheet
   *
   * This SDK offers no option for the region **outside** a sheet. `SheetOptions` carries
   * `blurStyle`, and that is the *sheet's own* background (`common.d.ts:11810`, "Defines sheet
   * background blur Style"); `maskColor` tints the scrim; `BindOptions` (`:11284`) is
   * backgroundColor plus four lifecycle callbacks and nothing else. So the blur has to be painted
   * by the page beneath, and that is what the reference does too: ClashBox holds
   * `isEnableIndexForegroundBlur` (declared `entry/src/main/ets/pages/Index.ets:179`), sets it in
   * each sheet's `onWillAppear`/`onWillDismiss`, and paints
   * `.foregroundBlurStyle(... ? BlurStyle.Thin : BlurStyle.NONE, {...})` on its page container
   * (`:359`).
   *
   * ## The gate, and the strength
   *
   * `NONE` at rest, so the reading surface is untouched and the blur is a response to the sheet
   * rather than a permanent GPU cost — the same gate the reference uses. This method exists as a
   * method rather than as an inline ternary so `tools/verify-reader-chrome.mjs` can assert the
   * mechanism: a literal `BlurStyle.Thin` at the attribute would be just as correct on a device
   * and impossible to check for a gate.
   *
   * ## Why `sheetBlur` and not `sheetOpen`
   *
   * Reading the blur off `sheetOpen` is what made the blur outlive the sheet on a drag-close:
   * that variable is written back by the framework's binding at the **end** of its exit, so a
   * blur derived from it *is* the exit tail (`.diag/r95-hand-trace.txt`: `onDisappear` at
   * +592 ms, the binding's write 5–10 ms after it). `sheetBlur` is written at the same moments
   * the app writes the open and accepts a dismissal, so both exits clear the frost at the frame
   * their animation starts — which is what the × has always done. See `sheetBlur` for the full
   * account, including why the two variables cannot drift.
   *
   * `scale` is left at its default of 1.0, which is the strongest blur this option accepts
   * ("1.0 indicates the highest blur degree", `BlurStyleOptions.scale`); there is no `opacity`
   * field on `ForegroundBlurStyleOptions` to set strength instead (`common.d.ts:6988`, an empty
   * extension of `BlurStyleOptions`).
   */
  private sheetBlurStyle(): BlurStyle {
    return this.sheetBlur ? BlurStyle.Thin : BlurStyle.NONE;
  }

  /** Apply a settings change to the live reader. */
  private applySettings(next: ReaderSettings): void {
    if (!this.controllerReady) {
      return;
    }
    try {
      this.controller.setPageConfig(this.toKitSettings(next));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setPageConfig failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * Translate app settings into the kit's `ReaderSetting`.
   *
   * **The two page colours are read from one place, together.** `fontColor` and
   * `themeColor` below are `pageColors().foreground` / `.background` — the same palette, in
   * the same call — so a page background from one theme with text from another, which the
   * old two-store arrangement could produce, is not expressible. Both are 6-digit, which is
   * what the kit requires of `themeColor` and documents for `fontColor` (Huawei's
   * `ReaderSetting` table: "对于16进制颜色值，只支持6位颜色值，不支持透明度").
   *
   * **The kit does not honour all of this, and that is measured rather than assumed.** In the
   * day path (`nightMode: false`) it applies `themeColor` and paints its *own* black ink,
   * ignoring `fontColor`; in the night path it paints its own dark base and light ink. So on
   * a sepia page the ink comes out black rather than the palette's warm brown. The numbers,
   * the in-image control that proves it is the kit and not the platform or the JPEG, and why
   * no workaround was taken are recorded on `readerAppearance` in `theme/Theme.ets` — this
   * file carries no hex of its own, which the theme audit asserts. What this function must
   * keep doing is hand over the theme's pair: that is the documented interface, and it is
   * what `nightMode: colors.isDark` buys light text in dark mode.
   *
   * `viewPortWidth`/`viewPortHeight` come from the component's measured size rather
   * than the window: the kit paginates to this box, and passing the window size
   * would paginate for a page that is larger than the area it is drawn into.
   *
   * They must nonetheless be **device pixels** and must never be zero — see
   * `resolveViewPort`. The official example passes the reading area in px
   * (`viewPortWidth: 1260, viewPortHeight: 2720`), and the kit scales the box it is
   * given up to the component's real size, so an undersized box magnifies the page.
   */
  private toKitSettings(settings: ReaderSettings): readerCore.ReaderSetting {
    const viewPort: ReaderViewPort = this.resolveViewPort();
    const colors: ReaderAppearance = this.pageColors();
    const config: readerCore.ReaderSetting = {
      fontName: '',
      fontSize: clampFontSize(settings.fontSize),
      fontWeight: settings.fontWeight,
      fontColor: colors.foreground,
      fontPath: settings.fontPath,
      lineHeight: clampLineHeight(settings.lineHeight),
      // The kit's own rendering mode, read *from* the theme rather than set independently:
      // it is how the kit is told which of the two colour pairs it is being handed.
      nightMode: colors.isDark,
      themeColor: colors.background,
      themeBgImg: settings.themeBgImg,
      flipMode: settings.flipMode,
      scaledDensity: 1,
      viewPortWidth: viewPort.width,
      viewPortHeight: viewPort.height,
    };
    return config;
  }

  /** Measured size of the reading area, kept so the config can be rebuilt. */
  @State private viewWidth: number = 0;
  @State private viewHeight: number = 0;

  // --- the window's avoid areas, and the two bars that move for them (r102) ----------
  //
  // **These two numbers move the BARS and nothing else.** The page layer's measured box — the
  // one `onAreaChange` reports, `resolveViewPort` scales and `setPageConfig` paginates — is not
  // read, written or padded by anything in this section, and the user asked for exactly that:
  // 「文字的显示范围保持这样不变就行了」. The bars are `position`-anchored overlays of the page
  // `Stack`, so moving them is invisible to the box by construction. The cost is stated where it
  // is real: a bar that sits lower (top) or higher (bottom) covers a little more of the first or
  // last line while it is up — and the bottom bar's box, which is the band that belongs to the
  // bar while it is shown, grows by the gesture-bar inset.

  /**
   * How far the floating top bar is held below the screen's top edge, in vp.
   *
   * Zero until the window answers, and zero is also the correct answer for a device whose window
   * reports no top avoid area at all — see `resolveAvoidInsets`. The bars are hidden at rest, so
   * this arriving one frame late is not something the reader can see.
   */
  @State private topInsetVp: number = 0;

  /**
   * How far the floating bottom bar's capsule is lifted to clear the gesture navigation bar, in vp.
   *
   * Added to `FLOATING_BAR_BOTTOM_MARGIN` for the capsule's own anchor and to
   * `BOTTOM_BAR_BOX_HEIGHT` for the box it floats in; see `bottomBarMarginVp` and
   * `bottomBarBoxHeight`.
   */
  @State private bottomInsetVp: number = 0;

  /**
   * Read the window's avoid areas, once, and keep the two numbers the bars are placed by.
   *
   * ## Why this exists
   *
   * `Index.applySystemAppearance` puts the window in full screen and hides the status bar, so the
   * layout no longer avoids anything. The status bar is a *system UI element* and going away is
   * fine; **the camera cutout is a hole in the screen and does not go away with it**, so a top bar
   * placed at `top: 0` is drawn under the lens. That is the user's report, verbatim: 「我的屏幕上
   * 还有前置摄像头的挖孔，我想让顶栏在挖孔的下面」. The same full-screen change leaves the bottom bar
   * sitting on the gesture bar (「底栏要稍微上移一点，避让系统导航条」).
   *
   * ## Where the numbers come from
   *
   * `window.Window.getWindowAvoidArea(type)` returns a `window.AvoidArea` — `visible` plus four
   * `Rect`s (`leftRect`/`topRect`/`rightRect`/`bottomRect`) — and the rects are **in px**
   * (`@ohos.window.d.ts`, `interface Rect`: "Left boundary of the rectangle, in px. The value
   * must be an integer"). There is **no** `getWindowAvoidAreaSync` in this SDK and no vp-typed
   * overload of it: the method is already synchronous, it takes one `AvoidAreaType` and it returns
   * px, so the px→vp step is this side's to make (`this.getUIContext().px2vp`) — rounded **up**, to
   * the next whole vp, because a clearance may not stop short and because an integer is what both
   * the log line and `.diag/r102-capture.ps1` read.
   *
   * The types this screen reads, with their enumeration:
   *
   *  - **`TYPE_CUTOUT = 1`** (`@since 7`) — "Cutout area", i.e. the punch hole itself. A cutout at
   *    the top of the screen is reported through `topRect`, which is the shape the official
   *    沉浸式 sample handles (沉浸式窗口 · `immersive-window-feature`, `handleCutoutAvoidArea`).
   *  - **`TYPE_SYSTEM = 0`** (`@since 7`) — "Default area of the system. It contains the status bar
   *    and three-button navigation bar." This is the documented proxy for a punch hole and the
   *    fallback when the cutout type reports nothing: `window-faqs` · 如何获取状态栏高度 —
   *    「主窗口全屏时，可以通过 getWindowAvoidArea() 获取到包含状态栏的避让区域」.
   *  - **`TYPE_NAVIGATION_INDICATOR = 4`** (`@since 11`) — "Bottom navigation bar", the gesture
   *    bar: 27.9 vp on the reference device (`SCBGestureNavBar14` = `[0, 2754, 1320, 94]`).
   *
   * **No runtime guard on any of the three**, and that is the deliberate part: 7 / 7 / 11 are all
   * far below this app's `compatibleSdkVersion` 24, so unlike `uiMaterial.ImmersiveMaterial`
   * (`@since 26.0.0`, which `topBarMaterialOption` guards for API-24 devices) a version check here
   * would be dead code that reads as a live floor. (The SDK's other avoid-area member,
   * `TYPE_FLOAT_NAVIGATION = 5`, **is** `@since 26.0.0` — and is not read here for that reason as
   * well as because a float-navigation area is not this screen's problem.)
   *
   * **The top inset is a maximum, not a choice between the two.** A punch hole is normally *inside*
   * the status-bar band, so the cutout's own height can be smaller than the band; taking the larger
   * of the two is what the official sample does
   * (`Math.max(topAvoidHeight, cutoutAvoidArea.topRect.height)`) and it is the safe direction —
   * clearing the taller of the two always clears both. `top + height` rather than `height` alone
   * because the rect is not guaranteed to start at the screen's top edge; a top-anchored band has
   * `top === 0` and the two are then the same number.
   *
   * **Both raw values are logged**, in px and in the unit they were converted from: if a device
   * answers 0 for both, the bars stay exactly where r101 put them and the log is the evidence —
   * this is a measurement this round could not take on the device, and guessing a constant here
   * would push the bar down over the text on every device that has nothing to clear.
   *
   * **Read once, not subscribed.** The values are not live: the window publishes changes through
   * `on('avoidAreaChange')`, and wiring that is a separate behaviour rather than a second read —
   * a rotation re-paginates through the measured box anyway, and a landscape cutout is reported on
   * the *left* edge, which is a different inset than the one this screen places a top bar by.
   *
   * A failure is log-and-continue: the insets stay 0, which is the pre-r102 geometry and leaves the
   * reader fully usable.
   */
  private resolveAvoidInsets(): void {
    try {
      const context: common.UIAbilityContext = this.getUIContext()
        .getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context)
        .then((win: window.Window): void => {
          const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
          const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const gesture: window.AvoidArea =
            win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          const cutoutTopPx: number = topBandPx(cutout.topRect);
          const systemTopPx: number = topBandPx(system.topRect);
          const gesturePx: number = bottomBandPx(gesture.bottomRect);
          // **Rounded up, deliberately, and not only for the log.** `px2vp` returns a fraction
          // (195 px / 3.375 = 57.78 vp) and an inset is a *clearance*: the next whole vp is the safe
          // direction, where the nearest one can be a fraction of a px short of the band it clears.
          // It also keeps the two values integers, which is what the log line below formats them as
          // (`%{public}d`) and what `.diag/r102-capture.ps1` reads back out.
          this.topInsetVp = Math.ceil(this.getUIContext().px2vp(Math.max(cutoutTopPx, systemTopPx)));
          this.bottomInsetVp = Math.ceil(this.getUIContext().px2vp(gesturePx));
          hilog.info(
            DOMAIN,
            TAG,
            'avoid areas: cutout top %{public}d px, status bar top %{public}d px, gesture bar %{public}d px'
              + ' -> top inset %{public}d vp, bottom inset %{public}d vp',
            cutoutTopPx,
            systemTopPx,
            gesturePx,
            this.topInsetVp,
            this.bottomInsetVp,
          );
        })
        .catch((err: Object): void => {
          hilog.warn(DOMAIN, TAG, 'avoid areas unavailable: %{public}s', String(err));
        });
    } catch (err) {
      // No UI context yet, or no host window: the insets stay 0 and the reader is usable.
      hilog.warn(DOMAIN, TAG, 'avoid areas not read: %{public}s', String(err));
    }
  }

  /**
   * The capsule's distance from the bottom of its box, in vp: the design's own margin **plus** the
   * gesture bar's inset.
   *
   * Returned as a number and formatted with its unit at the call site, because
   * `HdsTabsFloatingStyle.barBottomMargin` must be a **unit-bearing string** — HDS parses it with a
   * unit parser and silently drops a bare number (`ParseProp failed parse property barBottomMargin`),
   * a trap this project has already hit once.
   */
  private bottomBarMarginVp(): number {
    return FLOATING_BAR_BOTTOM_MARGIN + this.bottomInsetVp;
  }

  /**
   * Height of the box the floating bottom bar is drawn in, in vp, **including the gesture bar**.
   *
   * `BOTTOM_BAR_BOX_HEIGHT` is the box for a bar sitting on the screen's bottom edge: the 56 vp
   * capsule, its 8 vp margin and the 32 vp gradient mask above it (96, the shell's own clearance),
   * plus `BOTTOM_BAR_SHADOW_ROOM` for the material's shadow. Lifting the capsule by the gesture
   * inset adds exactly that many vp of painted content *inside* the box — the mask still has to
   * reach the screen's bottom edge, or the bottom strip of the screen would carry un-faded text
   * under the gesture bar — so the box has to grow by the same amount.
   *
   * **This is where the cost of the change is visible**, and it is the same cost `bottomBar`
   * documents for the box's height in general: the box *is* the band that belongs to the bar while
   * the bars are shown, so the band grows by the inset (27.9 vp on the reference device, i.e. from
   * 120 to 148 vp). Hidden, the bar is not hit-testable — `opacity` 0 with
   * `HitTestMode.BLOCK_DESCENDANTS` since r104 — and the band costs nothing — and hidden
   * is the default. `tools/verify-reader-chrome.mjs` asserts both halves of that: the band is the
   * box, and the box is the clearance plus the inset.
   */
  private bottomBarBoxHeight(): number {
    return BOTTOM_BAR_BOX_HEIGHT + this.bottomInsetVp;
  }

  /**
   * The reading area in device pixels: the box the kit paginates into.
   *
   * **This is load-bearing, not cosmetic.** The kit lays the book out inside the box
   * it is given and then *scales that box up* to the `ReadPageComponent`'s real size.
   * So a box smaller than the component magnifies the page. Passing zero is worse
   * than it looks, because the kit does not reject it: it substitutes a tiny internal
   * default. That is what shipped, and it is why the reader showed one or two
   * enormous glyphs per page instead of text.
   *
   * Verified on a real device — Reader Kit's own log for this configuration:
   *
   *     ReaderKit_ReaderKitView: setPageConfig width is 115.85185185185185
   *       height is: 178.96296296296296
   *     pushConfigTask config= { ..., "paddingLeft":27, "paddingRight":27,
   *       "paddingTop":68, "paddingBottom":48, "deviceWidth":115.85,
   *       "deviceHeight":178.96, "contentWidth":61, "contentHeight":62,
   *       "viewPortWidth":0, "viewPortHeight":0 }
   *
   * `contentWidth` is `deviceWidth` minus the horizontal padding, so the kit was
   * paginating a **61x62** content box: about three characters per line and two lines
   * per page at `fontSize: 18`. The `lineSize: 0` seen on every page and the ~11x
   * oversized glyphs both follow from that.
   *
   * The measured area wins. Before the first layout callback — or if it never yields
   * a usable number, which is how the zero got there — the window is the fallback:
   * the same order of magnitude, and never zero.
   */
  private resolveViewPort(): ReaderViewPort {
    let density: number = 1;
    let screenPx: ReaderViewPort = { width: 0, height: 0 };
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      density = screen.densityPixels > 0 ? screen.densityPixels : 1;
      screenPx = { width: Math.round(screen.width), height: Math.round(screen.height) };
    } catch (err) {
      // `getDefaultDisplaySync` may throw. Without it the window size is unknown, but
      // a measured reading area is still enough to paginate correctly.
      hilog.warn(DOMAIN, TAG, 'display unavailable: %{public}s', JSON.stringify(err));
    }

    if (this.viewWidth > 0 && this.viewHeight > 0) {
      return {
        width: Math.round(this.viewWidth * density),
        height: Math.round(this.viewHeight * density),
      };
    }

    if (screenPx.width > 0 && screenPx.height > 0) {
      // Worth a log line: reaching this branch on a device means the layout callback
      // is not delivering, and the reader is paginating to the window rather than to
      // the page. The page will be usable but a little too tall.
      hilog.info(
        DOMAIN,
        TAG,
        'reading area not measured; paginating to the window: %{public}dx%{public}d px',
        screenPx.width,
        screenPx.height,
      );
      return screenPx;
    }

    // Last resort, and deliberately not zero: a zero viewport is what made the kit
    // paginate a 61x62 box in the first place. A nominal portrait page is wrong in
    // detail but keeps the book readable.
    hilog.error(DOMAIN, TAG, 'no viewport available; using a nominal fallback page');
    return { width: 1080, height: 1920 };
  }

  /** Flip to the next or previous page. */
  private turnPage(next: boolean): void {
    if (!this.controllerReady) {
      return;
    }
    try {
      this.controller.flipPage(next);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'flipPage failed: %{public}s', JSON.stringify(err));
    }
  }

  /** Apply a settings change to the live reader and tell the host to persist it. */
  private updateSettings(next: ReaderSettings): void {
    this.live = next;
    this.applySettings(next);
    this.callbacks.onSettingsChanged(next);
  }

  /**
   * The 目录 sheet's second line: how many entries there are, and how many cannot be jumped
   * to.
   *
   * `this.toc.length` is the array `buildToc()` actually returned — never a chapter count
   * from the local database. `books.total_chapters` is synced from ReadAny and is not read
   * from this book's own navigation document, so it cannot stand in for this number; a book
   * whose catalog the kit under-reports shows a small count here rather than being silently
   * short. The second number matters for the same reason: an entry the catalog has but no
   * spine item matches is still listed (in the tertiary colour) and still tappable, and it
   * now says so when tapped. Counting it here means the shortfall is visible before the tap.
   *
   * Empty string when there is no catalog: the empty state below already says that, and a
   * "共 0 条" above it would be noise.
   */
  private tocSummary(): string {
    if (this.toc.length === 0) {
      return '';
    }
    let unreachable: number = 0;
    for (const entry of this.toc) {
      if (!entry.navigable) {
        unreachable++;
      }
    }
    const total: string = `共 ${this.toc.length} 条`;
    return unreachable === 0
      ? total
      : `${total} · ${unreachable} 条在正文里没有对应位置`;
  }

  /**
   * The reader's single sheet: whichever mode `openReaderSheet` last set.
   *
   * A `@Builder` that only delegates, because the thing it replaces — one `bindSheet` per
   * feature — is what made two of the three entries dead. The TOC is the `else` rather than
   * an empty branch: only `openReaderSheet` sets `sheetOpen` and it always sets the mode
   * first, so the fallback is unreachable; an empty `@Builder` would be a second way to
   * present a blank panel, which is the failure this whole change is about.
   *
   * All four modes are named and the TOC is the `else`, so the host can never present an
   * empty panel. Each sheet draws the shared `sheetHeader` itself rather than the host drawing
   * chrome around them: the header has to sit **on** the sheet's own surface, and a wrapper
   * here would have had to give the header its own background — which is the stray band this
   * change removes.
   */
  @Builder
  private readerSheet() {
    if (this.sheetMode === ReaderSheetMode.BOOKMARK) {
      this.bookmarkSheet()
    } else if (this.sheetMode === ReaderSheetMode.NOTE) {
      this.noteSheet()
    } else if (this.sheetMode === ReaderSheetMode.SETTINGS) {
      this.settingsSheet()
    } else {
      this.tocSheet()
    }
  }

  /**
   * The header every sheet in the reader wears: a large title at the left, a circular × at
   * the right, on the sheet's own surface.
   *
   * **One builder for all four modes** rather than one per sheet, because the alternative is
   * four headers that drift: a title size that changes in three of them, a close button that
   * dismisses in two. The mode picks the title through `sheetTitle()`, so the header cannot
   * disagree with the content under it.
   *
   * ## This row is the sheet's drag surface, and that is why the split exists
   *
   * With `detents` back (see `bindSheet`'s note), dragging **this row** resizes the sheet and
   * dragging **the content below it** scrolls the list instead. Neither behaviour is coded
   * here: it is the platform's documented split for a 底部弹窗 — 「在标题栏区域滑动时：上滑时短滑
   * 向上切换至相邻较大档位……下滑时短滑向下切换至相邻较小档位」 against 「在内容区域滑动时：内容
   * 处于中间位置（可上下滚动）上/下滑时，优先滚动内容」 (半模态面板 · 交互规则, the same
   * document the 320 vp floor comes from). It works out because the sheet's pan recogniser is
   * on the sheet and this header contains **no scrollable**, so the header's drag reaches it
   * unopposed, while a drag that starts on a `List` is claimed by that list first — which is
   * exactly the pair the user measured on the reference build (a slow upward drag on the header
   * moved the top edge 240 px; a drag in the content scrolled a row and left the top edge
   * alone). So the header's own layout is what buys the split: a header that scrolled, or a
   * `List` that started above the title, would lose it.
   *
   * ## Why it is needed at all — the stray band
   *
   * The sheet used to have no header of its own, and in the 目录 sheet the title row was the
   * first thing drawn *inside* the scroll column. Two surfaces were therefore visible above
   * the content: the platform's own drag-bar strip, and the sheet container, which
   * `BindOptions.backgroundColor` defaults to **`Color.White`** (`common.d.ts:11295`; the doc
   * block above it at `:11287` reads "Default value: **Color.White**") — the platform default,
   * not the app's theme. So in 护眼 and 深色 the top of the sheet was a light strip on a themed
   * page, which is the inconsistent background that was reported. Measured from a sepia
   * device screenshot of that build: the centre column above the sheet's first content pixel
   * sampled a light grey band (`C1C2C4`, JPEG ±2 per channel; the hex is written without its
   * `#` because `verify-themes` scans this whole file for colour literals and cannot tell a
   * comment from one). The fix is threefold — a themed sheet background, no system drag bar,
   * and this header — and `.bindSheet` below records it.
   *
   * ## The two text tones, and why they are two
   *
   * The title is `chromeText()` — the theme's own `foreground` — and on the sheet body that is
   * the reader's page pair, so it measures exactly what the reading page does: 17.43:1 (light),
   * 17.18:1 (dark) and 10.84:1 (sepia).
   *
   * The summary line under it is `chromeMuted()`, the theme's foreground at 70 %, and that is a
   * **change from r92**. It used to be the palette's `mutedForeground`, which was correct while
   * the body was `card` (4.88 / 6.38 / 4.61:1). With the body on `palette.background` — the same
   * tone as the reader's page — the same key measures 4.27:1 (light) and 4.40:1 (sepia), both
   * **under** this project's 4.5:1 floor, while `chromeMuted()` measures 7.29 / 8.74 / 4.67:1
   * there. Sepia's 4.67:1 is the tight one of the three and it is not new: it is the figure the
   * reader's own page indicator has always used, because `chromeMuted()` is derived for exactly
   * this surface. `emptySheetState` carries the same table.
   *
   * ## The × is the sheet's one exit
   *
   * It writes `sheetOpen = false` and nothing else, which is the *same* dismissal the system
   * back gesture performs (`onBackPress`) and the same one the 目录 row-jump performs. There
   * is deliberately no second close path: a sheet that tracked its own visibility could
   * desynchronise from `sheetOpen`, and that is what made 目录 present nothing before.
   *
   * The chip is the palette's edge role (`sheetCardEdge()`) on the sheet body: that is the
   * palette's own "this tone reads against the surface" role, and it is the only key in the
   * table that gives a soft circle on the body in all three themes — measured on the body
   * 1.113:1 (light), 1.483:1 (dark) and 1.383:1 (sepia). The obvious alternative, `muted`, is
   * *not*: on a `background` body it is 1.027:1 in light, i.e. no circle at all. The glyph is
   * the theme's own text colour on it. It is a `Text` and not a symbol glyph because a symbol's
   * modifier class is not an ArkUI ambient declaration — it has to be imported from
   * `@kit.ArkUI`, which would modify a pre-existing import line and end the byte-identity proof
   * the diagnostic strip script carries.
   */
  @Builder
  private sheetHeader(title: string) {
    Row({ space: SPACE_S }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(TYPE_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.chromeText())
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // The sheet's second line, when it has one. 目录 puts its count here; an empty
        // bookmarks sheet puts nothing here. See `sheetSummary`.
        //
        // `chromeMuted()` and not `mutedForeground`: the body is `palette.background` since
        // r94, i.e. the same tone as the reader's page, so the secondary tone derived for text
        // **on the page** is the correct one and is the only one that clears the 4.5:1 floor
        // here. `mutedForeground` on this body measures 4.27:1 (light) and 4.40:1 (sepia) —
        // both under it. See this builder's own note for the measured pairs.
        if (this.sheetSummary().length > 0) {
          Text(this.sheetSummary())
            .fontSize(TYPE_CAPTION)
            .fontColor(this.chromeMuted())
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // A 48 vp tap target holding a 36 vp chip, which is the guidance's minimum pressable
      // area around a visibly smaller control — the same relationship the bottom entries have
      // to their own labels. The chip is the palette's edge role: the body is the page tone,
      // and this is the one key in the table that still reads as a soft circle on it
      // (1.113:1 light, 1.483:1 dark, 1.383:1 sepia). `muted` would not — 1.027:1 in light.
      Stack() {
        Column()
          .width(36)
          .height(36)
          .borderRadius(RADIUS_CONTROL)
          .backgroundColor(this.sheetCardEdge())
        Text('✕')
          .fontSize(TYPE_SUBTITLE)
          // **`lineHeight` equal to the tap target is what centres this glyph.** A `Text` is a
          // `Stack` child with its own ascent/descent, so `Alignment.Center` centres the *box*
          // and leaves the ink sitting on the box's baseline — visually high. Giving the line
          // the full 48 vp makes the box the glyph is centred in the same box the `Stack`
          // centres, and the ink lands in the middle. `textAlign` does the same horizontally.
          .lineHeight(MIN_TAP_TARGET)
          .textAlign(TextAlign.Center)
          .fontColor(this.chromeText())
      }
      .width(MIN_TAP_TARGET)
      .height(MIN_TAP_TARGET)
      .alignContent(Alignment.Center)
      .clickEffect(this.animationOn ? Motion.clickEffect() : null)
      .onClick((): void => {
        // The × path, and it is the *same* path as the drag now: `finishSheetClose` is the
        // one place the app writes `sheetOpen = false`, and it is never called from inside
        // the framework's own dismissal. A tap during the exit is no longer "held" — nothing
        // about opening a sheet is deferred any more. See `sheetCycle`.
        this.finishSheetClose();
        this.onSheetProbe('x-button-close', this.sheetOpen); // DIAG-SHEET
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // Generous top padding, then the body's own top inset: the title is the first thing on
    // the sheet, so it needs to clear the sheet's top edge by more than a list row would.
    .padding({ left: SPACE_M, right: SPACE_M, top: SPACE_L, bottom: SPACE_M })
    // The sheet's surface, and the same colour `.bindSheet` is given — so the header, the
    // body and the sheet container are one tone and there is no band anywhere in the sheet.
    .backgroundColor(this.sheetCard())
  }

  /**
   * The sheet's name, for its header.
   *
   * Derived from `sheetMode` rather than passed down from each builder, so the header cannot
   * be handed a title that disagrees with the mode the host selected — and so a new mode is a
   * compile error here rather than a header with a stale title.
   */
  private sheetTitle(): string {
    if (this.sheetMode === ReaderSheetMode.BOOKMARK) {
      return '书签';
    }
    if (this.sheetMode === ReaderSheetMode.NOTE) {
      return '笔记';
    }
    if (this.sheetMode === ReaderSheetMode.SETTINGS) {
      return '设置';
    }
    return '目录';
  }

  /**
   * The sheet header's optional second line, from the mode.
   *
   * Only 目录 has one, and it is the count `tocSummary()` already produced: the number of
   * entries the kit actually returned plus how many of them name no spine position. It used
   * to be a separate row between the title and the list; it is the title's subtitle now,
   * which is where it belongs — it describes the list, not a section of its own. Nothing is
   * dropped: the book title was never part of this sheet (it is not drawn here at all), and
   * the chapter name lives in the top bar, which stays visible above the sheet.
   *
   * The other three return an empty string, and `sheetHeader` skips the line entirely rather
   * than drawing an empty one, so a short sheet's header stays short.
   */
  private sheetSummary(): string {
    return this.sheetMode === ReaderSheetMode.TOC ? this.tocSummary() : '';
  }

  /**
   * The 目录 sheet: the shared header, the count, and the chapter list.
   *
   * The count is now the header's own subtitle (`sheetSummary`) rather than a row between the
   * title and the list — it describes the list, and it no longer costs the list a row of
   * height. Everything else is the feature as it was: the real catalog, the jump, and the two
   * visible states (`tocNotice` for a refused jump, and the empty state below).
   */
  @Builder
  private tocSheet() {
    Column({ space: 0 }) {
      this.sheetHeader(this.sheetTitle())

      if (this.tocNotice.length > 0) {
        // In the sheet, above the list: this is the explanation of the tap that just
        // refused to jump, and it has to be where the tap was — see `tocNotice`.
        Text(this.tocNotice)
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .width('100%')
          .padding({ left: SPACE_M, right: SPACE_M, bottom: SPACE_S })
      }

      if (this.toc.length === 0) {
        // **A visible empty state, not a blank panel.** A sheet that presents with nothing
        // in it is indistinguishable from a feature that does not work — which is how this
        // entry was experienced. `Reader Kit` derives the chapter title in the top bar from
        // the book, so a book with no catalog at all is a real possibility; it says so here.
        Text('这本书没有目录信息')
          .fontSize(13)
          .fontColor(this.chromeText())
          .padding({ left: SPACE_M, right: SPACE_M, top: SPACE_XS })
        Text('正文和阅读进度不受影响，仍可正常翻页。')
          .fontSize(TYPE_CAPTION)
          .fontColor(this.chromeMuted())
          .padding({ left: SPACE_M, right: SPACE_M, top: 6, bottom: SPACE_M })
      } else {
        List() {
          ForEach(this.toc, (entry: TocEntry) => {
            ListItem() {
              Row() {
                Text(entry.name)
                  .fontSize(TYPE_BODY)
                  // Indented by nesting depth. Capped at four levels: deeper nesting
                  // is rare, and unbounded indentation pushes the text off a phone.
                  .padding({ left: Math.min(entry.level, 4) * 14 })
                  // `chromeMuted()` for the entries the kit returned with no usable spine
                  // position — the body is the page tone since r94, and this is the page's own
                  // secondary tone. It is also the only role that clears 4.5:1 there.
                  .fontColor(entry.navigable ? this.chromeText() : this.chromeMuted())
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              // 48vp minimum, per the guidance.
              .constraintSize({ minHeight: MIN_TAP_TARGET })
              .alignItems(VerticalAlign.Center)
              .padding({ left: SPACE_M, right: SPACE_M })
              .onClick((): void => {
                this.jumpToCatalog(entry);
              })
            }
          }, (entry: TocEntry) => `${entry.catalogId}-${entry.href}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    // **The sheet's own surface, and the same tone the header is painted.** The sheet
    // container's colour is set in `.bindSheet` for the region the content does not cover;
    // this is the region it does. See `sheetHeader` for the band the two used to disagree on.
    .backgroundColor(this.sheetCard())
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /**
   * The 书签 sheet: an empty state, deliberately.
   *
   * It used to be a form that created a bookmark at the current page. That is not what this
   * sheet is for — see the note on `onEntryBookmarks` — so the presentation is an empty state
   * until the real list is specified. The *data* path is untouched and still works: the
   * `onAddBookmark` callback, `createBookmark` in the store and the sync of the bookmark table
   * are all exactly as they were, and nothing here reads or writes any of them. The label
   * field that fed the callback is gone from the screen and the field itself is left in place,
   * unused, rather than deleted — the round that fills this sheet in will want it back.
   */
  @Builder
  private bookmarkSheet() {
    Column({ space: 0 }) {
      this.sheetHeader(this.sheetTitle())
      this.emptySheetState('还没有书签', '在阅读时添加书签，会显示在这里。')
    }
    .width('100%')
    .backgroundColor(this.sheetCard())
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /**
   * The 笔记 sheet: an empty state, deliberately. See `bookmarkSheet` — same situation, same
   * untouched data path (`onAddNote` and the note composer's two fields are left in place and
   * unused).
   */
  @Builder
  private noteSheet() {
    Column({ space: 0 }) {
      this.sheetHeader(this.sheetTitle())
      this.emptySheetState('还没有笔记', '在阅读时添加笔记，会显示在这里。')
    }
    .width('100%')
    .backgroundColor(this.sheetCard())
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /**
   * The reader sheets' shared empty state: a centred medium-weight line over a secondary one.
   *
   * The same shape `AnnotationsPage` uses for 还没有标注 — medium title, secondary body,
   * centred — so the reader's two empty sheets read as the same app as the annotation list
   * rather than as a third treatment.
   *
   * The body's tone is `chromeMuted()` since r94, and the reason is a contrast measurement
   * rather than a preference: the sheet body is `palette.background` — the reader's page tone —
   * and the two candidate secondary tones on it measure
   *
   *   - `mutedForeground` (the r92 choice, when this body was `card`): 4.27:1 light,
   *     7.16:1 dark, **4.40:1 sepia** — under this project's 4.5:1 floor in two themes;
   *   - `chromeMuted()`, the theme's own 70 % foreground (the page's secondary tone, and what
   *     the annotation list would measure against *its* page): 7.29 / 8.74 / **4.67:1** — over
   *     the floor in all three.
   *
   * So the sheets no longer have a `sheetMuted()` accessor at all; the body's text is the
   * page's own secondary tone because the body **is** the page's own tone, and the settings
   * row's subtitle takes the palette's surface-text key on the row it actually sits on
   * (`sheetRowMuted`). Sepia's 4.67:1 is the tight one of the three and is the same figure the
   * reader's page indicator has always used — it is a pre-existing accepted pair, not a new
   * margin invented here, but it is the number to watch if this palette ever moves.
   *
   * `layoutWeight(1)` is what centres it: the column above it and the header take their
   * intrinsic height, and this takes everything left over, which is what puts the text in the
   * middle of the sheet rather than just under the header.
   */
  @Builder
  private emptySheetState(title: string, body: string) {
    Column({ space: SPACE_S }) {
      Text(title)
        .fontSize(TYPE_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.chromeText())
      Text(body)
        .fontSize(TYPE_CAPTION)
        .fontColor(this.chromeMuted())
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding(SPACE_L)
  }

  /**
   * Show a short confirmation, then clear it.
   *
   * The previous timer is cancelled first. Without that, two actions in quick
   * succession leave two timers running, and the earlier one clears the later
   * message early — the second confirmation disappears almost immediately.
   *
   * The timer is also cancelled on teardown: a pending timer would otherwise fire
   * after the component is gone and write to its state.
   */
  private flash(message: string): void {
    if (this.flashTimer !== -1) {
      clearTimeout(this.flashTimer);
    }
    this.toastText = message;
    this.flashTimer = setTimeout((): void => {
      this.flashTimer = -1;
      this.toastText = '';
    }, TOAST_VISIBLE_MS);
  }

  /**
   * The persistent chapter name (常驻章节名) — a third floating overlay of the page.
   *
   * ## Why it is not in the top bar
   *
   * Because the top bar is hidden while the bars are down, and the title has to be visible then:
   * that is what 常驻 means. So it is its own overlay, a sibling of the page layer inside the page
   * `Stack`, declared **before** `topBar()` and `bottomBar()` so a revealed bar draws over it
   * rather than the reverse — the same ordering rule the bars and the zones already obey.
   *
   * ## Exactly one chapter name is on screen at any moment
   *
   * The user's rule: **when the bars are shown the persistent title hides**, because the top bar
   * carries a richer version of the same string (the chapter name plus the page within the
   * chapter). `chapterOverlayVisible` states that as `!topBarVisible()`, so the two are
   * complementary *by construction* rather than by two conditions that have to agree, and the
   * invariant holds on all three of the top bar's states:
   *
   *  - bars down (the default) → `topBarVisible()` is false → the persistent title is up;
   *  - bars up → `topBarVisible()` is true → the persistent title is `Visibility.None`;
   *  - the failure screen, where `errorText` forces the top bar up for its 返回 → the persistent
   *    title is down. `chapterTitle` is empty there in any case, so the two statements do not
   *    even have a string to disagree about.
   *
   * The hidden state is `Visibility.None`, which is **not hit-testable**, and the visible state is
   * wrapped in `HitTestMode.Transparent` besides — so this overlay can never take a tap from the
   * three zones underneath it, whichever way the invariant is pointing. (This overlay keeps
   * `Visibility`, unlike the two bars: it does not animate, and nothing about its placement needs
   * a frame in which it is still rendered.)
   *
   * ## Where it sits, and why it had to move (r104)
   *
   * The user: 「常显的章节名称也有点问题，现在正好显示在前置摄像头的挖孔里，看不到。我想把它移到顶部导
   * 航栏的左下角，和左边的文字对齐」. The first half is **measured**: the title's ink was at
   * `y 58–94 px, x 545–776 px` — centred on `660.5`, the exact screen centre — and the punch hole
   * is `120 px` deep, so it really was inside the lens. (The hole's left/right extent was never
   * measured, only its 120 px depth, so the ~120 px circle centred on x=660 is inference rather
   * than a result.) Getting out of the hole is the point of this round; the alignment is the
   * other half of what the user asked for.
   *
   * **Horizontally** the box goes at `PERSISTENT_TITLE_LEFT` (27 vp — Reader Kit's own
   * `paddingLeft`, i.e. the body text's layout origin) and the `Text` is `TextAlign.Start`. See
   * that constant for why it is the *box* and not the *ink* that is placed there, and for the
   * `103 px` post-change verification target.
   *
   * **Vertically** it is `persistentTitleAnchorVp()` — a derived expression, never a literal.
   * That method carries the derivation and the reason it is invariant to `TOP_BAR_SHADOW_ROOM`;
   * the short version is that anchoring to the bar's own 56 vp band keeps the title in the gap
   * above the first line of body text, while anchoring to the grown drawing box would put it on
   * top of that line.
   *
   * **It is implemented as a container height, not as `padding({ top })`.** A top padding would
   * have to know the `TYPE_CAPTION` line box's height to put the text's *bottom* at the anchor,
   * and **ArkUI publishes no font metric for that**. So the anchor is a container of exactly the
   * derived height with `justifyContent(FlexAlign.End)` and `alignItems(HorizontalAlign.Start)`:
   * bottom-aligned and left-aligned, with no font metric needed at all. The outer column stays
   * `height('100%')` and pinned, so this is still a full-size `position`-anchored sibling of the
   * page layer and still cannot be a layout event for the kit's measured box.
   *
   * **Residual, stated rather than guessed.** Bottom-aligning puts the `Text`'s *line box* bottom
   * at the anchor, so the **ink** lands ~2–4 vp above it: measured today, with `padding.top` =
   * `SPACE_M` (16 vp = 54 px), the ink starts at 56–58 px, i.e. about 2 px of leading. If the
   * intent is ink-bottom-at-the-edge then the container wants the anchor **+ ~3 vp**. That is a
   * one-screenshot refinement for the user to settle after installing — **there is no device this
   * round**, so it is recorded rather than baked in.
   *
   * ## Tone, and why it is not a chip
   *
   * `chromeMuted()` — the page's own secondary tone, the one the page indicator in the top bar
   * already wears (7.29 / 8.74 / 4.67:1 in light / dark / sepia, all above this project's 4.5:1
   * floor; sepia's 4.67 is the tightest and is not new here). It is the right role because the
   * title lands in the **empty band above the first line of live text**, so it needs no opaque
   * backing. That band used to be described as Reader Kit's reserved 页眉 band (68 vp); what is
   * *measured* is that the first body line's ink starts at `y 328 px = 97.2 vp`, so the anchor at
   * `92 vp = 310.5 px` leaves about 18 px of clear page above the text — tighter than the old
   * centred placement, and still tight enough to be legible without a surface behind it.
   * `chromeSurface()` + `chromeText()` — the toast chip's pattern — is what a title that *could*
   * overlap the text would need, and it is deliberately not spent here.
   * `sheetRowMuted()`/`mutedForeground()` are out of the question: both are derived for a sheet's
   * `card` row, not for the page.
   */
  @Builder
  private chapterOverlay() {
    Column() {
      // The anchor band. Its height is the whole placement mechanism; see this builder's note.
      Column() {
        Text(this.chapterTitle)
          .fontSize(TYPE_CAPTION)
          .fontColor(this.chromeMuted())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // `Start`, not `Center`: the title moved from the page's centre to the text's left edge.
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .height(this.persistentTitleAnchorVp())
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Start)
      // The left inset is the text's own layout origin (`PERSISTENT_TITLE_LEFT`) and the right one
      // is breathing room so a long name ellipsises inside the page; the two are separate
      // constants because they are separate reasons.
      .padding({ left: PERSISTENT_TITLE_LEFT, right: PERSISTENT_TITLE_RIGHT })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    // Pinned like the two bars: an overlay of the page, never a band of it.
    .position({ left: 0, top: 0 })
    // Belt and braces with the sibling order — `Transparent` means this overlay cannot consume a
    // tap that the zones below it would otherwise get. `Text` itself carries no handler.
    .hitTestBehavior(HitTestMode.Transparent)
    .visibility(this.chapterOverlayVisible() ? Visibility.Visible : Visibility.None)
  }

  /**
   * Where the persistent chapter name's **line-box bottom** sits, in vp from the page box's top
   * edge — which is the screen's top edge, because the window is full screen.
   *
   * **A derived expression, never a literal, and the derivation is the point.** It is the bottom
   * edge of the top bar's **own `TOP_BAR_HEIGHT` band** — `topInsetVp + TOP_BAR_HEIGHT` — which is
   * the measured `92 vp = 310.5 px` the bar's paint used to stop dead at, and which is what
   * 「左下角」 most literally names: the bottom-left corner of the top navigation bar.
   *
   * **It is invariant to `TOP_BAR_SHADOW_ROOM` deliberately.** The drawing box grew 56 → 80 vp
   * this round for the shadow, and a title anchored to the *grown* box would have been pushed
   * 24 vp down — from `310 px` to `392 px` — and `392 px` is **on top of the first line of body
   * text** (measured ink `y 328–385 px`). So naming `TOP_BAR_HEIGHT` here rather than
   * `TOP_BAR_BOX_HEIGHT` is the difference between the title sitting in the clear page above the
   * text and sitting in the text. Neither number is a literal: both are the named constants, so a
   * later change to either moves the title with it.
   *
   * Reading `this.topInsetVp` is why the reader has a fourth read of that field, and the audit
   * count that guards it was updated for this one — see `tools/verify-reader-chrome.mjs`. It is a
   * **bar** metric (the bar's own bottom edge), it is read outside `build()`, and it reaches
   * neither `resolveViewPort()` nor `toKitSettings()`, so it cannot move the pagination box.
   */
  private persistentTitleAnchorVp(): number {
    return this.topInsetVp + TOP_BAR_HEIGHT;
  }

  /**
   * Whether the persistent chapter name is on screen: **exactly when no top bar is.**
   *
   * The `!` is the whole mutual-exclusion rule — see `chapterOverlay`. It reads `topBarVisible()`
   * rather than `barsVisible` on purpose: the failure screen is a state where the top bar is up
   * without `barsVisible` being true, and a title left up there would be a second chapter-name
   * surface, which is the one thing this rule forbids. `barsVisible` still has exactly **one**
   * writer (`toggleBars`); this is a reader of a reader.
   */
  private chapterOverlayVisible(): boolean {
    return !this.topBarVisible();
  }

  /**
   * The reader's top bar — **floating**, hidden until the middle tap zone reveals it.
   *
   * ## Why it is a `Navigation` title bar and nothing else
   *
   * The bar carries the 沉浸光感 system material — the design spec's own prescription for a
   * component 悬浮 at the top is `ULTRA_THIN` (「当组件在顶部悬浮时，推荐使用 ULTRA_THIN 枚举参数」,
   * 沉浸光感 · 场景规范) — and `systemMaterial` is **not a free-standing attribute**. The
   * framework honours it only on a component inside a `Navigation`/`NavDestination` title bar or
   * a horizontal `Tabs` bottom `TabBar` with `barPosition: BarPosition.End`, and discards it
   * everywhere else with `Material inactive: out of scope. Use component in navigation title bar
   * or Tabbar.` — a line this project has already measured on a `Menu`. So the top bar is drawn
   * *inside a title bar*, and the `Navigation` around it is a **material host, not a navigation
   * container**: no content, no `NavPathStack`, no destination.
   *
   * The container inside `topBarTitle` is what carries the material, which is the shape the
   * official 正例 uses — 「在Navigation标题栏中为局部容器设置沉浸式系统材质，材质生效且面积可控」
   * (沉浸光感功耗优化) — and since r101 that container is a **capsule**, so the material's area is
   * one 328 x 48 surface rather than a full-width 391 vp x 56 bar and certainly not a page, which is
   * the same guide's first rule (「控制材质使用面积」).
   *
   * ## Why it is an overlay rather than a band
   *
   * The `Navigation` is `TOP_BAR_BOX_HEIGHT` tall (`TOP_BAR_HEIGHT` plus the shadow's room, since
   * r104), pinned to the top of the page `Stack` by
   * `position`, and it holds no content. The kit paginates into the page `Stack`'s measured box,
   * so a bar that occupied layout space would move that box when it appeared — the trap
   * `bottomBar` used to carry a paragraph about, and the one that re-paginated a page in front
   * of a reader who had already started reading. A bar that is a **sibling overlay** of the kit
   * inside that same `Stack` cannot: the `Stack`'s size is `layoutWeight(1)` × `width('100%')`
   * and does not depend on any child, so the box is identical whether the bar is up, down, or
   * never shown. `tools/verify-reader-chrome.mjs` asserts that structure rather than trusting
   * this paragraph.
   *
   * `barStyle(BarStyle.STACK)` is the material guide's recommendation for a title bar
   * (「建议设置沉浸光感时，使用 barStyle 为 STACK 样式，以便 Navigation 内容区延伸至标题栏区域，
   * 获得沉浸光感的最佳体验」) and `BarStyle.STACK` is documented as "the title bar … is overlaid
   * on top of the content area" (`navigation.d.ts:1915`). It is belt-and-braces here, because
   * this `Navigation` has no content area to extend into: what keeps the bar off the layout is
   * the `position` above.
   *
   * ## The four attributes that are not cosmetic
   *
   *  - **`hideBackButton(true)`** — the bar's own 返回 is drawn by `topBarRow`, and the
   *    framework's built-in back control would be a second one. Setting `title` is also what
   *    keeps the title bar itself displayed in spite of it (`navigation.d.ts:1396`).
   *  - **`title`'s `backgroundColor: Color.Transparent`** — the bar stops painting a band, so
   *    the capsule inside it is the only surface. See the call for the layering citation.
   *  - **`expandSafeArea([], [])`** — `Navigation` expands into the safe area by default
   *    (`navigation.d.ts:1385`), and with `position` set the SDK applies `position` first and
   *    the expansion second (`common.d.ts:17239`), which would let this 80 vp overlay draw
   *    outside the box it was measured into. Empty arrays mean "expand nothing"
   *    (`common.d.ts:17216`).
   *  - **`opacity` + `translate` + `hitTestBehavior`** — since r104 this is what "hidden" means;
   *    see the call. `Visibility.None` cannot animate, and `HitTestMode.BLOCK_DESCENDANTS` is
   *    what keeps "not hit-testable" true for the whole subtree.
   */
  @Builder
  private topBar() {
    Navigation() {
      // Deliberately empty. This `Navigation` exists for its title bar, which is the only
      // surface the framework accepts a system material on.
    }
    .width('100%')
    .height(TOP_BAR_BOX_HEIGHT)
    .hideBackButton(true)
    // `barStyle` is a field of `NavigationTitleOptions`, not a `Navigation` attribute
    // (`navigation.d.ts:2324` is the only `title` overload and it takes the options object), so
    // it travels with the title rather than beside it.
    //
    // **`backgroundColor: Color.Transparent` is what makes the bar stop being a band.** A system
    // material's visual layer sits *under* `backgroundColor` and `backgroundBlurStyle`
    // (沉浸光感常见问题 · 背景色或背景模糊遮挡材质效果: 「沉浸光感的视觉层级位于组件的
    // backgroundColor、backgroundBlurStyle 等属性之下。如果同时设置了不透明的背景色或背景模糊
    // 样式，这些属性会覆盖在材质层之上，导致材质效果被遮挡不可见」), so a title bar still carrying
    // its own full-width background would paint that slab *over* the capsule's material — which is
    // exactly the full-width bar the user reported. `NavigationTitleOptions.backgroundColor` is
    // `navigation.d.ts:1718`, and the field is on the **options object**, not a `Navigation`
    // attribute.
    //
    // The scope provider stays the full-width `Navigation`: making the bar transparent changes
    // what it *paints*, not what it *serves*. `systemMaterial` is still honoured only inside a
    // `Navigation`/`NavDestination` title bar, so the material's home does not move when the
    // surface does — the capsule is a child **inside** this title builder.
    .title({ builder: this.topBarTitle, height: TOP_BAR_BOX_HEIGHT },
      { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
    .expandSafeArea([], [])
    // Pinned, so the bar is an overlay of the page and never a band of it. See this builder's
    // note: this is the whole of why the measured page box cannot move.
    //
    // **`top` is the cutout inset, not 0 (r102).** The status bar is hidden but the camera's punch
    // hole is not a status bar, so the bar has to start below the window's own top avoid area or it
    // is drawn under the lens. `topInsetVp` is 0 until the window answers and 0 on a device with no
    // top avoid area — which is the same geometry as before this change. See `resolveAvoidInsets`.
    .position({ left: 0, top: this.topInsetVp })
    // --- hidden, since r104, is `opacity` + hit-testing rather than `Visibility` -----------
    //
    // **`Visibility.None` was the old spelling and it cannot animate.** A component that is not
    // rendered has no property values to interpolate: an `animateTo` that flipped
    // `barsVisible` would make the bar *appear* at its final position instead of sliding in,
    // because the "from" frame never exists. So the bar stays `Visibility.Visible` and "hidden"
    // becomes the pair below, which is what the state machine now means by it.
    //
    // `HitTestMode.BLOCK_DESCENDANTS` — **not `None`, and the difference is the whole
    // equivalence.** `@ohos` `enums.d.ts` declares `None` as 「The node itself does not respond to
    // the hit test and **does not block the hit test of child nodes**, sibling nodes, and ancestor
    // nodes」 and `BLOCK_DESCENDANTS` (`@since 20`, so it needs no API guard at this project's
    // `compatibleSdkVersion` 24) as 「The node itself does not respond to the hit test, and **all
    // its descendants** (children, grandchildren, and more) also do not respond… It does not
    // affect the hit test of ancestor nodes」. The interactive parts of this bar are **children**
    // — the 返回 `Button`, and inside the capsule — so `None` on the `Navigation` alone would
    // leave a hidden bar's 返回 tappable, which `Visibility.None` did not. `BLOCK_DESCENDANTS`
    // takes the whole subtree out and touches neither siblings nor ancestors, which is exactly
    // `Visibility.None`'s hit-test semantics. The invariant is therefore "hidden ⇒ not
    // hit-testable", unchanged, and the audit still guards it.
    //
    // The pair is also why the band costs nothing at rest: hidden is the default, and a hidden
    // bar neither paints nor takes a tap.
    .opacity(this.topBarVisible() ? 1 : 0)
    .translate({ y: this.topBarVisible() ? 0 : -BAR_SLIDE_OFFSET })
    .hitTestBehavior(this.topBarVisible() ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
  }

  /**
   * Whether the top bar is on screen.
   *
   * Two facts, and only one of them is the reader's: the middle tap zone's `barsVisible`, and
   * "the book failed to open". **The second is not a second writer of the first** — `barsVisible`
   * still has exactly the one writer `toggleBars` — it is this *render* condition, and it exists
   * because 返回 is drawn by `topBarRow`: without it, a book that fails to open would be a screen
   * with no way out except the system back gesture. The failure screen has no tap zones either
   * (there is no page to turn), so the bar there is not a thing the reader can dismiss.
   */
  private topBarVisible(): boolean {
    return this.barsVisible || this.errorText.length > 0;
  }

  /**
   * The title bar's content: the **capsule**, and the one place the reader's material lives.
   *
   * ## The capsule, and why the bar around it is invisible
   *
   * Since r101 the bar is a full-width `Navigation` title bar that **paints nothing**
   * (`NavigationTitleOptions.backgroundColor(Color.Transparent)`; see `topBar`) with a capsule
   * floating inside it — `FLOATING_BAR_WIDTH` wide since r102, which is the bottom bar's own
   * width rather than the shell's full content width. The user asked for 完全圆头 — a fully rounded
   * head — and the radius is derived from the capsule's own height, never written down: see
   * `TOP_BAR_CAPSULE_HEIGHT` (one tap target, because the 返回 inside it is) and
   * `TOP_BAR_CAPSULE_RADIUS` (= height / 2, and load-bearing for the material's paint area).
   *
   * **No nested material, and no stacked blur.** The power guide forbids both explicitly
   * (「避免材质嵌套」: 「同一子树中只需在最外层设置一次沉浸式系统材质，内层节点不应再设置」;
   * 「避免与模糊效果叠加」: 「沉浸式系统材质自带的材质滤镜（materialFilter）已包含背景模糊效果，
   * 再叠加 backgroundBlurStyle、backgroundEffect 等模糊属性属于重复处理」). So there is exactly
   * one `systemMaterial` in this file, it is on this capsule, `NavigationTitleOptions` carries
   * **no** `systemMaterial` for this bar, and the capsule carries no `backgroundBlurStyle`,
   * `backgroundEffect` or `backgroundBlurStyle`-family attribute.
   *
   * **Two branches, because an attribute cannot be applied conditionally in one component
   * call** — the same shape `ShelfPage.menuOptions` uses for its menu. The difference between
   * them is only who paints the surface:
   *
   *  - **the material**, when `topBarMaterialOption()` returned one. A material takes over the
   *    background, border and shadow, and the SDK advises against setting those beside it, so
   *    this branch sets no `backgroundColor` at all;
   *  - **the page colour**, on the three paths that gate refuses: a pre-26 runtime (the whole
   *    reason this needs a guard — `uiMaterial.ImmersiveMaterial` is `@since 26.0.0`, and on an
   *    API-24 device the namespace does not exist), a device that reports no immersive-material
   *    support, and a device whose material level is the low-compute one that paints the surface
   *    from the *system's* palette instead of this app's. All three are
   *    `topBarMaterialOption()`'s to answer, and all three are why this branch has to exist: the
   *    fallback is a correct opaque bar, not a missing one.
   *
   * **An API-24 device therefore shows an opaque capsule**: the same three elements, painted
   * `pageBackground()` — the page's own colour — with no material, no translucency and no
   * system tint, **in the requested capsule shape at the requested radius**. The material is
   * what degrades, not the design; the branch is why that sentence is true.
   *
   * The material is **`THIN` since r104**, not the `ULTRA_THIN` the spec prescribes for 顶部悬浮:
   * the user directed that the top bar follow the bottom bar (「以底栏为准」), and `THIN` is what
   * that bar's HDS policy actually resolves to. `immersiveTopBarMaterialOption` carries the whole
   * of that reasoning and its cost.
   *
   * **Neither thickness's spec companion is implemented, and each is missing for its own reason.**
   * `ULTRA_THIN`'s is 渐变模糊 and it is deliberately not done: a material's `materialFilter`
   * already contains the background blur, and stacking a blur on a material is repeated work the
   * power guide forbids (「沉浸式系统材质自带的材质滤镜（materialFilter）已包含背景模糊效果，再叠加…
   * 属于重复处理」, 沉浸光感功耗优化 · 避免与模糊效果叠加). `THIN`'s is **渐变颜色蒙层**, which is
   * *unavailable* rather than skipped: a `Navigation` title bar offers no mask parameter, and the
   * gradient mask the bottom bar has comes from `HdsTabs`' `barFloatingStyle`. Both are recorded
   * as departures rather than left to be rediscovered.
   */
  @Builder
  private topBarTitle() {
    // Two levels, and the split is the change: the outer column is the **box's** content and fills
    // it, the inner column is the **capsule** and is shorter than the bar. A single level could not
    // express "the capsule is not the bar" — it would make `TOP_BAR_HEIGHT` a property of what is
    // drawn inside the bar rather than of the bar. Since r104 the outer column also *pins* the
    // capsule to the box's top instead of centring it, so the box can grow for the shadow without
    // the capsule moving; see the call.
    Column() {
      if (this.topBarMaterialObject !== undefined) {
        Column() {
          this.topBarRow()
        }
        // **The capsule's width is the bottom bar's width (r102), and it is stated as a width
        // rather than as a pair of margins.** It used to be `width('100%')` inset by
        // `FLOATING_BAR_SIDE_MARGIN` on each side — the shell's full content width, which is much
        // wider than the floating bar floating below it. The user: 「顶栏的宽度就和底栏一样就够了」.
        // `FLOATING_BAR_WIDTH` is the number HDS gives that bar (`HdsTabsFloatingStyle.barWidth`,
        // ≥4 cells: 328 vp maximum) and the bottom bar is pinned to the same constant, so the two
        // cannot drift apart; the column below centres this one.
        //
        // **The margin is removed rather than kept beside the width.** Both at once would mean a
        // 328 vp capsule that is *also* inset 16 vp from the box it no longer needs insetting from:
        // the width would no longer be the width on screen, and the two bars would differ by 32 vp
        // for a reason nobody could see in either number.
        //
        // And not an inset through the title bar's own padding: `NavigationTitleOptions.paddingStart`/
        // `paddingEnd` (`navigation.d.ts:1791`, `:1814`) are inert for this bar — they act on the
        // framework's title row, and a custom `builder` with `hideBackButton(true)` has no such row.
        .width(FLOATING_BAR_WIDTH)
        .height(TOP_BAR_CAPSULE_HEIGHT)
        .justifyContent(FlexAlign.Center)
        // Load-bearing, not cosmetic — see `TOP_BAR_CAPSULE_RADIUS`.
        .borderRadius(TOP_BAR_CAPSULE_RADIUS)
        .systemMaterial(this.topBarMaterialObject)
      } else {
        Column() {
          this.topBarRow()
        }
        // The same width as the material branch, and for the same reason: what degrades on a
        // pre-26 device is the surface, not the geometry.
        .width(FLOATING_BAR_WIDTH)
        .height(TOP_BAR_CAPSULE_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .borderRadius(TOP_BAR_CAPSULE_RADIUS)
        // No `Color.Transparent` on this branch, and that is the whole difference between the
        // two: this one **is** the surface. An API-24 device gets the requested capsule with an
        // opaque fill in the page's own colour.
        .backgroundColor(this.pageBackground())
      }
    }
    .width('100%')
    .height('100%')
    // **`Start` plus an explicit top gap, not `Center`, since r104 — and this is the line that
    // keeps the capsule still.** The box is `TOP_BAR_BOX_HEIGHT` (80 vp) while the capsule is
    // `TOP_BAR_CAPSULE_HEIGHT` (48), and the extra 24 vp is the shadow's room *below* the
    // capsule. Centring would put half of that increment — 12 vp — above the capsule as well and
    // move it down by 12 vp, which is the one visible regression this round could introduce: the
    // capsule's top edge is measured at `136 px` and must stay there. Pinning it
    // `TOP_BAR_CAPSULE_TOP_GAP` from the box's top leaves every added vp below it.
    .justifyContent(FlexAlign.Start)
    .padding({ top: TOP_BAR_CAPSULE_TOP_GAP })
    // Explicit rather than inherited: this column is what centres a capsule that is now **narrower
    // than the bar** (`FLOATING_BAR_WIDTH` instead of the full width), so the alignment is load
    // bearing in a way it was not when the capsule filled the space by itself. Horizontal only:
    // the vertical placement is the `Start` above.
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * The top bar's three elements: 返回 · chapter title (centred) · page within the chapter.
   *
   * **Exactly three elements**, and the book title is deliberately absent: the shell used to
   * draw its own row above this component with back + book title, and this component then drew
   * the header string — the book title again — underneath it. That duplication is what this bar
   * removes; the chapter name is drawn here because it arrives with `pageShow`, which only this
   * component subscribes to.
   *
   * The title is centred within the space the two side elements leave, which is how it can
   * truncate with an ellipsis instead of running under them. The two sides are close in width (a
   * two-character 返回 and a fixed-width indicator), so the title sits within a few vp of the
   * true centre; a `Stack` would centre it exactly and let a long title collide with both side
   * controls, which is the worse trade.
   *
   * The vertical padding is the title bar's business now, not this row's: the container in
   * `topBarTitle` is `TOP_BAR_BOX_HEIGHT` tall and pins this row to its top, so the bar's height
   * is a constant the layout can be reasoned about instead of a sum of paddings and glyph
   * metrics — and the row does not move when the box grows for the shadow.
   */
  @Builder
  private topBarRow() {
    Row({ space: SPACE_XS }) {
      Button('返回')
        .fontSize(TYPE_BODY)
        .backgroundColor(Color.Transparent)
        .fontColor(this.chromeText())
        .borderRadius(RADIUS_CONTROL)
        .constraintSize({ minHeight: MIN_TAP_TARGET })
        .clickEffect(this.animationOn ? Motion.clickEffect() : null)
        .onClick((): void => {
          // `onBackPress` owns the layered rule (a sheet closes before the book does);
          // this is the same exit it performs once no panel is open.
          this.callbacks.onBack();
        })
      Text(this.chapterTitle)
        .fontSize(TYPE_CAPTION)
        .fontColor(this.chromeText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
      Text(this.pageIndicator())
        .fontSize(TYPE_CAPTION)
        .fontColor(this.chromeMuted())
        .textAlign(TextAlign.End)
        .maxLines(1)
        // Reserved so the centred title does not shift as the page number gains a digit.
        .constraintSize({ minWidth: PAGE_INDICATOR_WIDTH })
    }
    .width('100%')
    .padding({ left: SPACE_S, right: SPACE_M })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * The screen's three tap zones: left third = previous page · middle = reveal/hide the bars ·
   * right third = next page.
   *
   * ## The geometry is the measured one
   *
   * Three equal `layoutWeight(1)` columns of a full-width row, so the boundaries are the thirds
   * of whatever width the page area has. Measured on the device, the kit's gesture node spans
   * `x 0–1320 px` of a 1320 px screen, so the thirds are `0–440 / 440–880 / 880–1320 px` and the
   * equal-weight row lands on exactly those boundaries.
   *
   * The row spans the whole page area, and the vertical extent is where this differs from the
   * measurement: the kit's node was `y 319–2464 px` while the legacy bars took the top and bottom
   * bands, and those bands are gone — the page `Stack` is now the whole screen and the bars float
   * over it. So the zones cover the full page, which is what "the middle zone reveals the bars"
   * needs: the reader taps the middle of the page, not the middle of a band.
   *
   * ## Why `HitTestMode.Transparent`, and why that is not a preference
   *
   * Measured on the device: with `HitTestMode.Transparent` on this overlay the kit still receives
   * the whole drag — the overlay got `Down → 19 × Move → Up` **and** the kit got
   * `onActionStart`/`onActionEnd` and turned the page — while with `HitTestMode.Default` on the
   * same overlay the kit's hit-test collection stops at the overlay and **the swipe dies**.
   * Swiping still turns pages through the kit's own gesture, so `Transparent` is the only mode
   * that can be used here.
   *
   * ## Why the sides call `flipPage` themselves
   *
   * Because this overlay's `onClick` **wins** the gesture arena against the kit's own
   * tap-to-turn: measured, the arena gives the tap to whichever recogniser meets its condition
   * first, and the overlay is the one that does. A left/right tap that did not turn the page
   * itself would therefore be a tap that does nothing at all. `turnPage` stays the reader's one
   * `flipPage` call site and keeps its `controllerReady` guard.
   *
   * The middle zone is the **only** thing that writes `barsVisible`; the outer two turn a page
   * and touch no state, which is the approved state machine. There is no auto-hide and no
   * tap-outside-to-dismiss, so a reader who reveals the bars keeps them until they say otherwise
   * — including while 目录 / 书签 / 笔记 / 设置 are open, which the sheet composes *above* this
   * component's tree.
   */
  @Builder
  private tapZones() {
    Row() {
      Column()
        .layoutWeight(1)
        .height('100%')
        .onClick((): void => {
          this.turnPage(false);
        })
      Column()
        .layoutWeight(1)
        .height('100%')
        .onClick((): void => {
          this.toggleBars();
        })
      Column()
        .layoutWeight(1)
        .height('100%')
        .onClick((): void => {
          this.turnPage(true);
        })
    }
    .width('100%')
    .height('100%')
    // Mandatory, not stylistic: see this builder's note. `Default` here kills the kit's swipe.
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * Show or hide the two floating bars. **The only writer of `barsVisible`.**
   *
   * ## How this cannot drift from `sheetOpen`
   *
   * They are two independent facts and neither is derived from the other: `sheetOpen` is whether
   * the reader's one sheet host is presenting, and it is the variable the framework's `$$`
   * binding writes back; `barsVisible` is whether two overlays are painted. Nothing reads both,
   * nothing writes both, and no branch combines them:
   *
   *  - the four sheet entry handlers do not touch `barsVisible`;
   *  - no sheet callback (`onAppear`, `onDisappear`, `onWillDismiss`, `finishSheetClose`) touches
   *    it either — the only other thing that reaches the bars' visibility is `topBarVisible`,
   *    which reads the *failure* state and not the sheet's;
   *  - a sheet is composed by the framework above this component's tree, so opening one covers
   *    the bars rather than moving or hiding them.
   *
   * `tools/verify-reader-chrome.mjs` asserts that as a count — one writer, in this method, and
   * none of the sheet's callbacks among them.
   *
   * ## The slide-in (r104), and why the write happens inside the animation closure
   *
   * The user chose the spring slide: 「动画就用方案3」, described to them as
   * `animateTo({ duration: 400, curve: curves.springMotion(0.45, 0.85) })` with
   * `顶栏/底栏: translate y = ∓(30vp) → 0` and `opacity: 0→1`. So this is an **explicit**
   * animation (`animateTo`) rather than a `TransitionEffect`: the two bars stay
   * `Visibility.Visible` and their `translate`/`opacity` are *derived from `barsVisible`* in
   * `topBar`/`bottomBar`, so flipping the boolean inside the closure is the whole driver. There is
   * no second state variable, no `onFinish` callback and no three-state `Visibility` — a separate
   * "am I animating out" flag would be a second source of truth for the bars' visibility, which
   * this project has already paid for once (the four rounds of `sheetOpen`/`sheetBlur` cycle
   * machinery).
   *
   * **`animationOn` is the gate, and "off" means no tween at all rather than a zero-length one.**
   * The setting is the same `@StorageLink(MOTION_ON_KEY)` that drives `.clickEffect(...)`
   * everywhere else, so the whole app's motion switches together and this cannot drift from the
   * settings page. When it is off the assignment is made directly, outside any animation context,
   * and the bars **snap**: `animateTo` is skipped, not handed `duration: 0`.
   *
   * **Only `opacity` and `translate` move.** That is a hard constraint, not a style choice: the
   * bars are `position`-anchored siblings of the page layer, and the kit's measured page box must
   * be byte-identical whether they are shown or hidden. `height`, `padding`, `margin`,
   * `layoutWeight` and every other layout-affecting property are therefore off limits — animating
   * one would re-paginate the text, which the user ruled out
   * (「文字的显示范围保持这样不变就行了」). `opacity` and `translate` are both render-time only.
   */
  private toggleBars(): void {
    // One assignment site, reached from both paths, so `barsVisible` keeps exactly the one
    // textual writer the audit counts — and so the animated and un-animated paths cannot diverge.
    const apply: () => void = (): void => {
      this.barsVisible = !this.barsVisible;
    };
    if (!this.animationOn) {
      apply();
      return;
    }
    this.getUIContext().animateTo({
      // Inert beside a spring curve, and documented as such — see `BAR_SLIDE_DURATION_MS`.
      duration: BAR_SLIDE_DURATION_MS,
      curve: curves.springMotion(BAR_SLIDE_RESPONSE, BAR_SLIDE_DAMPING),
    }, apply);
  }

  // --- the progress row is gone ---------------------------------------------
  //
  // The bottom bar used to carry a percentage label and a display-only `Progress` track above
  // the four entries. The user asked for the row to go, and this round is where it went: the bar
  // is the four entries and nothing else.
  //
  // The capability it was an honest rendering of has not changed, and it is worth keeping the
  // reason on the record so the row is not re-invented as a *control*:
  //
  //  - Reader Kit has **no seek**. The controller's whole surface is `init`, `startPlay`,
  //    `flipPage(isNext: boolean)`, `setPageConfig`, `releaseBook`, `registerBookParser` and the
  //    two `on/off` pairs (`readerComponent.d.ets:210-351`). `flipPage` takes one boolean and no
  //    count (`:257`), so a page target cannot be expressed at all;
  //  - the only thing a release *could* do is jump to a chapter through
  //    `startPlay(spineIndex, domPos)`, plus `getDomPosByCatalogHref` for the position inside it
  //    (`bookParser.d.ts:118`). That is real and `jumpToCatalog` uses it — but it is
  //    chapter-granular, so a slider that accepted a drag would land somewhere visibly coarser
  //    than where the finger stopped;
  //  - "call `flipPage` N times" remains unimplemented, and `tools/verify-reader-chrome.mjs`
  //    keeps asserting that.
  //
  // What went with the row is `progressPercent`, its `@State`, and the label that printed it:
  // the fraction the app persists and syncs is `progressFor`, computed where it is used, and a
  // second copy maintained for a read-out that no longer exists would be dead state.

  /**
   * The reader's bottom bar — the HDS **floating** bar carrying the four entries.
   *
   * ## The shape is measured, not chosen
   *
   * Four **real** `TabContent`s, each carrying a `BottomTabBarStyle`, inside an `HdsTabs` in the
   * floating presentation. Every part of that sentence is a device result:
   *
   *  - a single `TabContent` with a custom `tabBar` builder **does not work** — the material is
   *    accepted (no `Material inactive: out of scope`) and the builder's content is never laid
   *    out, so the bar comes back empty;
   *  - `.barHeight('auto')` makes the bar disappear entirely;
   *  - the floating presentation needs **four** conditions together — `barFloatingStyle`,
   *    `barOverlap(true)`, `vertical(false)` and `barPosition(BarPosition.End)` — and
   *    `barSideMargin`/`barBottomMargin` must be **unit-bearing strings**, because HDS silently
   *    drops a bare number (`ParseProp failed parse property barSideMargin`);
   *  - with that shape on this device the material is accepted, the four cells render with
   *    icons, each is hit-testable, a tap opens the right sheet, and `false` from
   *    `onContentWillChange` stops the selection from moving.
   *
   * The material parameters are the shell's own, field for field (`Index.shellTabs` is the one
   * place in this app where a material demonstrably renders on this device): `IMMERSIVE` at
   * `ADAPTIVE`, which is the spec's 底部悬浮 answer as the framework implements it — the
   * adaptation guide states that a floating bottom tab bar defaults to `THIN`, the style the
   * spec prescribes for 底部悬浮, and the `gradientMask` in the page colour is the spec's
   * 渐变颜色蒙层. `BlurStrategy.ADAPTIVE` follows the system's own policy on whether to blur
   * rather than forcing it on.
   *
   * ## The four cells are entries, not tabs
   *
   * `index: 0` is fixed and `onContentWillChange` refuses every switch, so the bar has no second
   * state to reach. All four `TabContent`s paint the same nothing (`emptyBarPage`), so even a
   * switch that slipped past the refusal could not change what is on screen. The dispatch lives
   * in `onTabBarClick` because `BottomTabBarStyle` carries no `onClick` of its own; the four
   * handlers it calls are unchanged, each still carrying its own `if (this.loading) return;`
   * guard, so the window before the first page is on screen is inert rather than absent.
   *
   * The icons are `chromeText()` for **both** the selected and the unselected state, and that is
   * not a shortcut: cell 0 is permanently the selected one (the selection cannot move), so the
   * alternative — the shell's `primary`/`mutedForeground` pair — would paint 目录 differently
   * from the other three for no reason the reader could act on. The label's colour is **not**
   * settable here: `LabelStyle` carries font, size, weight, overflow and line limits and no
   * colour field, so the four labels wear the platform's own tab-label tone. That is exactly what
   * the shell's working bar does.
   *
   * ## Why the box is `BOTTOM_BAR_BOX_HEIGHT` tall, and what that costs
   *
   * The `HdsTabs` is a bottom-anchored overlay of the page `Stack`, **120 vp** tall:
   * `FLOATING_BAR_CLEARANCE` (96) plus `BOTTOM_BAR_SHADOW_ROOM` (24). Both halves have a job.
   *
   *  - **96 is the shell's own number** — the room the shell reserves under its floating bar for
   *    this very component — so the reader and the shell still agree on how much the bar needs.
   *    It is also, exactly, what the bar paints: the 56 vp capsule, `FLOATING_BAR_BOTTOM_MARGIN`
   *    (8) and `FLOATING_BAR_MASK_HEIGHT` (32) above it. That sum is the whole reason 96 is the
   *    wrong *container* height: the box had zero slack, and the material's own shadow
   *    (`applyShadow` defaults to true) was cut off at the box's edge — the user's
   *    「好像有阴影被什么东西截断了」.
   *  - **24 is that slack**, and it is all added **above** the capsule: the box grows upward
   *    from a bottom anchor, and the capsule is placed `FLOATING_BAR_BOTTOM_MARGIN` from the
   *    box's **bottom**, so the capsule does not move by one pixel when this number changes.
   *    Nothing else in the box is painted, so the extra height is invisible.
   *
   * **Since r102 the height is `bottomBarBoxHeight()`, not the constant**: the capsule is lifted
   * by the gesture bar's inset so it clears the system navigation bar (「底栏要稍微上移一点，
   * 避让系统导航条」), which is that many vp of extra painted content *inside* the box — the gradient
   * mask still has to reach the screen's bottom edge. So the box grows by exactly the inset, and
   * that is the one place this change costs a vp of page: see `bottomBarBoxHeight`.
   *
   * It is **not** the whole page, because `Tabs` is a swipeable container: at full height its
   * content region would take the reader's page-turn swipes away from the kit. The cost is stated
   * rather than hidden: **while the bars are shown**, a tap inside the box belongs to the bar and
   * does not turn a page. While they are hidden the bar is not hit-testable, which is not
   * hit-testable, so the band behaves as if the bar were not there — and hidden is the default.
   * Growing the box from 96 to 120 vp widened that band by 24 vp; the gesture inset widens it by
   * the inset again (27.9 vp on the reference device, so 120 → 148 vp). Both increments cost
   * nothing while the bars are down.
   *
   * ## Why the bar's width is stated rather than left to HDS
   *
   * `barFloatingStyle.barWidth` is pinned to `FLOATING_BAR_WIDTH` on all three breakpoint tiers,
   * and the top bar's capsule is pinned to the same constant. HDS's own default for a four-cell
   * floating bar *is* that number (设计规范 · HdsTabs · `barWidth`: 「页签个数大于等于4时，页签栏
   * 最大宽度不超过328vp」), so this states the value instead of recomputing it — and it is what makes
   * "the two bars are the same width" a property of the code rather than of two independent
   * layouts that happen to agree on this screen.
   */
  @Builder
  private bottomBar() {
    HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
      this.bottomBarEntries()
    }
    .width('100%')
    .height(this.bottomBarBoxHeight())
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .vertical(false)
    .barFloatingStyle({
      // Unit-bearing **strings**, not numbers: HDS silently drops a bare number here
      // (`ParseProp failed parse property barSideMargin`), a trap this project has hit.
      barSideMargin: `${FLOATING_BAR_SIDE_MARGIN}vp`,
      // The same unit-bearing rule, and the value is the design's margin **plus the live gesture
      // bar**: `barBottomMargin` is the capsule's distance from the box's bottom edge, which is
      // the screen's bottom edge, so clearing a 27.9 vp navigation bar means adding 27.9 vp here.
      barBottomMargin: `${this.bottomBarMarginVp()}vp`,
      // One width for both of the reader's bars. All three tiers are set so the width does not
      // move with the breakpoint — see this builder's note and `FLOATING_BAR_WIDTH`.
      barWidth: {
        smallWidth: `${FLOATING_BAR_WIDTH}vp`,
        mediumWidth: `${FLOATING_BAR_WIDTH}vp`,
        largeWidth: `${FLOATING_BAR_WIDTH}vp`,
      },
      gradientMask: {
        maskColor: this.pageBackground(),
        maskHeight: FLOATING_BAR_MASK_HEIGHT,
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
      },
      barOpacity: 1,
    })
    // No `barHeight` call at all: the default stands, exactly as in the shell. `'auto'` was an
    // earlier round's single change and it collapsed this bar rather than adapting it.
    // Follow the system's own policy on whether to blur, rather than forcing it on.
    .blurStrategy(BlurStrategy.ADAPTIVE)
    // No `onChange`: the selection is not allowed to move, so a callback for its movement would
    // be dead configuration. `onTabBarClick` is the dispatch, and it fires whether or not a
    // switch is permitted.
    .onTabBarClick((index: number): void => {
      // 0 = 目录, 1 = 书签, 2 = 笔记, 3 = 设置 — the same four entry points the bar carried
      // before this round, through the same handler methods.
      if (index === 0) {
        this.onEntryToc();
      } else if (index === 1) {
        this.onEntryBookmarks();
      } else if (index === 2) {
        this.onEntryNotes();
      } else if (index === 3) {
        this.onEntrySettings();
      }
    })
    .onContentWillChange((currentIndex: number, comingIndex: number): boolean => {
      // These cells are entry points, not tab switches: a tap that moved the selection would be
      // a behaviour regression, not a cosmetic one.
      return false;
    })
    // Bottom-anchored overlay of the page, and the third of the three facts that keep the
    // measured page box independent of the bars. See this builder's note.
    .position({ left: 0, bottom: 0 })
    // --- hidden, since r104, is `opacity` + hit-testing rather than `Visibility` -----------
    //
    // The same conversion as `topBar` carries, and for the same reason: `Visibility.None` is not
    // rendered, so there is no "from" frame for a slide to start in and the bar would pop rather
    // than arrive. It slides in from **below** its resting position (+`BAR_SLIDE_OFFSET`), which
    // is the mirror of the top bar's -`BAR_SLIDE_OFFSET`; see `topBar` for why
    // `HitTestMode.BLOCK_DESCENDANTS` and not `None` is what makes "hidden ⇒ not hit-testable"
    // survive the conversion — the four `HdsTabs` cells live *inside* this node.
    //
    // `translate` is render-only, so this cannot be a layout event for the kit's measured box —
    // which is the hard constraint on what may be animated here.
    .opacity(this.barsVisible ? 1 : 0)
    .translate({ y: this.barsVisible ? 0 : BAR_SLIDE_OFFSET })
    .hitTestBehavior(this.barsVisible ? HitTestMode.Default : HitTestMode.BLOCK_DESCENDANTS)
  }

  /**
   * What each of the four `TabContent`s paints: nothing.
   *
   * One builder shared by all four, so "a switch cannot change what the user sees" is structural
   * rather than a promise. `Color.Transparent` because the bar is a floating capsule over the
   * page: a painted page here would be a slab behind it.
   */
  @Builder
  private emptyBarPage() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
  }

  /**
   * The four entries, exactly: 目录 / 书签 / 笔记 / 设置.
   *
   * There is **no 搜索** entry — search is out of scope — and no fifth cell of any kind. What
   * each one does is unchanged from the bar this replaces, and each is still the closest thing
   * that already exists in this screen rather than invented behaviour:
   *
   *  - **目录** — `onEntryToc`, the TOC sheet (`ReaderSheetMode.TOC`), the complete feature: the
   *    list built by `buildToc` and the jump through `jumpToCatalog`.
   *  - **书签** — `onEntryBookmarks`, the bookmark sheet, an empty state; the bookmark *list*
   *    lives in the shell's 书签笔记 tab (`AnnotationsPage`), which is a separate screen.
   *  - **笔记** — `onEntryNotes`, the note sheet, same situation.
   *  - **设置** — `onEntrySettings`, the reader's 字号 sheet. The app-level settings
   *    (主题/动效/同步) remain on the shelf's 设置 tab.
   *
   * The four share **one** sheet host, differing only in `ReaderSheetMode`; three separate
   * `bindSheet` bindings is what that replaced, and it is what made two of the four entries dead.
   * See `sheetOpen`.
   */
  @Builder
  private bottomBarEntries() {
    TabContent() {
      this.emptyBarPage()
    }
    .tabBar(new BottomTabBarStyle(
      { normal: new SymbolGlyphModifier($r('sys.symbol.list_bullet_circle')) }, '目录')
      .labelStyle({ font: { size: TYPE_CAPTION, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: this.chromeText(),
        unselectedColor: this.chromeText(),
      }))

    TabContent() {
      this.emptyBarPage()
    }
    .tabBar(new BottomTabBarStyle(
      { normal: new SymbolGlyphModifier($r('sys.symbol.bookmark_fill')) }, '书签')
      .labelStyle({ font: { size: TYPE_CAPTION, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: this.chromeText(),
        unselectedColor: this.chromeText(),
      }))

    TabContent() {
      this.emptyBarPage()
    }
    .tabBar(new BottomTabBarStyle(
      { normal: new SymbolGlyphModifier($r('sys.symbol.notepad')) }, '笔记')
      .labelStyle({ font: { size: TYPE_CAPTION, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: this.chromeText(),
        unselectedColor: this.chromeText(),
      }))

    TabContent() {
      this.emptyBarPage()
    }
    .tabBar(new BottomTabBarStyle(
      { normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')) }, '设置')
      .labelStyle({ font: { size: TYPE_CAPTION, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: this.chromeText(),
        unselectedColor: this.chromeText(),
      }))
  }

  // --- the four entry points -------------------------------------------------
  //
  // Each is one line and each is named for its *entry*, not for its action.
  //
  // **Each one refuses to act until the first page is on screen.** The bar itself is drawn
  // from the first frame (see `build()`: holding it back would re-paginate the page when it
  // arrived), so the guard lives here instead. It matters for exactly one of the four —
  // a bookmark or a note taken before the first `pageShow` would be written at
  // `(spineIndex 0, domPos '')`, i.e. the start of the book rather than where the reader
  // is, and `chapterTitle` would be empty. That is a junk row in the annotation list, so it
  // is refused rather than written. The window is the few hundred milliseconds of
  // 「正在排版...」, and the entries look normal throughout: a visibly disabled control would
  // be a worse answer than an inert one for that long.
  //
  // **All four now open the same sheet**, differing only in `ReaderSheetMode`: 设置 was the
  // last hold-out, an inline panel above the bottom bar, and it is a mode like the other
  // three. One `bindSheet` per component is a hard constraint, not a style choice — see
  // `sheetOpen`.

  /**
   * Decide what a pending sheet dismissal means. **Every** reason is allowed through, and that
   * is r94's reversal of r92.
   *
   * ## What r92 did, and why it was wrong
   *
   * r92 refused `SLIDE_DOWN` — the drag-down gesture — on the reasoning that the platform turns
   * a downward drag at the lowest detent into a *dismissal*, so letting it through would make
   * `SHEET_MIN_HEIGHT` a starting point rather than a bound. The user has since said what the
   * gesture should do (「现在以打开的时候的默认高度为最小高度，当在最小高度向下滑的时候就视为
   * 关闭sheet」), and the platform's documented rule is the same thing:
   * 半模态面板 · 「使用嵌套滚动交互」 states the priority for a drag in the content area —
   * 「下滑时，优先向下收缩面板挡位，**如无挡位可收缩，则关闭面板**」 ("on a downward drag, first
   * shrink to a lower detent; **if there is no lower detent, close the panel**"). The refusal
   * deleted that last clause: it made the documented two-step gesture a one-step one and left
   * the sheet impossible to drag away.
   *
   * So the gesture is, with `detents: [SHEET_MIN_HEIGHT, SheetSize.LARGE]`:
   *
   *  1. from `LARGE`, a downward drag **shrinks to `SHEET_MIN_HEIGHT`** — a detent change, which
   *     is not a dismissal and does not come through this callback at all;
   *  2. from `SHEET_MIN_HEIGHT` (the sheet's opening height, and its floor) a downward drag
   *     **dismisses the sheet**, arriving here as `SLIDE_DOWN` with no lower detent to shrink to.
   *
   * Source for (1) and (2): the reference table's `detents` entry — 「面板可跟手滑动切换挡位」
   * — plus the same guide's priority list quoted above, plus the API-12 UX changelog
   * (`bindSheet支持嵌套滚动`), which contrasts the old behaviour (「在最低档下滑无法关闭半模态」)
   * with the new one (「在最低档下滑可以关闭半模态」). Independent device evidence from r92's own
   * measurement points the same way: an upward drag on the *header* moved the top edge from
   * 1492 px to under 200 px and produced no dismissal, i.e. a detent change does not route
   * through this callback.
   *
   * The set of four sheets is not a choice here: **all four go through this one `bindSheet`
   * host**, so this behaviour is global and cannot differ per sheet. The user said 「这三个sheet」
   * — 目录 / 书签 / 笔记, by the reading of their previous message — and 设置 gets the same
   * gesture, because making it per-sheet would take a second `bindSheet` binding, which this
   * project forbids (three bindings on one component is what made two of the four entries dead;
   * see `sheetOpen`).
   *
   * ## The other reasons
   *
   * They are the exits a user already has, and they are unchanged from r92. `TOUCH_OUTSIDE` is a
   * deliberate tap on the scrim, and `PRESS_BACK` is the system back gesture — which InkBoat also
   * handles itself, in `onBackPress`, by writing `sheetOpen = false` before the book is left.
   * Dismissing here as well is not a second close *path* (both go through the same `sheetOpen`);
   * it is the platform's own route being left intact so that a back press that reaches the
   * framework still closes the sheet instead of doing nothing. `SLIDE` (API 20) is the side-swipe
   * reason and cannot occur for a `preferType: SheetType.BOTTOM` sheet, but it is accepted like
   * everything else rather than silently dropped.
   *
   * `CLOSE_BUTTON` cannot occur — `showClose: false` — and the header's own × does not come
   * through here at all: it writes `sheetOpen = false`, which removes the sheet without asking
   * this callback. So the × remains the sheet's one in-sheet exit, exactly as it was.
   *
   * The state is written before the dismissal is requested, so `sheetOpen` is already false on
   * the frame the exit animation starts rather than one frame after it.
   */
  // ==== DIAG-SHEET-BEGIN ====
  /**
   * TEMPORARY DIAGNOSTIC — one line per sheet transition, and the *ordering* is the point.
   *
   * `seq` is monotonic and `t` is milliseconds since the probe's first line, so two lines
   * written in the same millisecond are still ordered. `state` is `sheetOpen` **at the instant
   * the line is written**, which is what separates the writers of that variable:
   *
   *  - the app closing the sheet (every close now goes through `finishSheetClose`, and each
   *    caller logs its own tag: `x-button-close`, `onBackPress-close`, `jumpToCatalog-close`);
   *  - the framework writing it back through `$$` (a line whose value differs from the previous
   *    line with no app-code line in between — the `@Watch` line below).
   *
   * `cycle` is the round's addition and it is the line that makes a late dismissal
   * attributable: `sheetCloseCycle` is the cycle the **last close was initiated in**, so a
   * dismissal arriving after `sheetCycle` has already advanced means the framework is running
   * a dismissal against a sheet the app has re-opened. `dismissing` is the app's own close
   * flag — it is deliberately no longer set from `onWillDismiss`, so a `true` here is always
   * an app-initiated close.
   *
   * Delete with `.diag/strip-sheet-probe.mjs`.
   */
  private onSheetProbe(tag: string, state: boolean): void {
    const shown: string = this.sheetOpen ? 'true' : 'false';
    const before: string = state ? 'true' : 'false';
    hilog.info(DOMAIN, TAG,
      'SHEETPROBE seq=%{public}d t=%{public}dms tag=%{public}s mode=%{public}s before=%{public}s after=%{public}s dismissing=%{public}s up=%{public}s cycle=%{public}d shownCycle=%{public}d closeCycle=%{public}d intentCycle=%{public}d raises=%{public}d',
      this.sheetProbeSeq, sheetProbeNow(), tag, `${this.sheetMode}`, before, shown,
      this.dismissing ? 'true' : 'false', this.sheetShownCycle === this.sheetCycle ? 'true' : 'false', this.sheetCycle, this.sheetShownCycle,
      this.sheetCloseCycle, this.sheetIntentCycle, this.sheetRaiseAttempts);
    this.sheetProbeSeq = this.sheetProbeSeq + 1;
  }
  // ==== DIAG-SHEET-END ====

  // ==== DIAG-SHEET-BEGIN ====
  /**
   * TEMPORARY DIAGNOSTIC — fires on **every** write to `sheetBlur`, whoever made it.
   *
   * The r96/r97 apparatus dated `sheetOpen` only, so the blur gate's own value had to be
   * inferred from the lines around a write. It cannot be inferred: the defect r98 fixes is
   * exactly a write the surrounding lines do not bracket (`openReaderSheet` raises the gate,
   * a **late** `onWillDismiss` from the previous cycle clears it). So the gate is logged the
   * same way `sheetOpen` is, and this line is what makes the mechanism visible in one read.
   *
   * Delete with `.diag/strip-sheet-probe.mjs`.
   */
  onSheetBlurProbe(): void {
    hilog.info(DOMAIN, TAG, 'SHEETPROBE seq=%{public}d t=%{public}dms tag=WATCH blur-changed now=%{public}s mode=%{public}s dismissing=%{public}s up=%{public}s cycle=%{public}d shownCycle=%{public}d closeCycle=%{public}d intentCycle=%{public}d raises=%{public}d',
      this.sheetProbeSeq, sheetProbeNow(), this.sheetBlur ? 'true' : 'false', `${this.sheetMode}`,
      this.dismissing ? 'true' : 'false', this.sheetShownCycle === this.sheetCycle ? 'true' : 'false', this.sheetCycle, this.sheetShownCycle,
      this.sheetCloseCycle, this.sheetIntentCycle, this.sheetRaiseAttempts);
    this.sheetProbeSeq = this.sheetProbeSeq + 1;
  }
  // ==== DIAG-SHEET-END ====

  /**
   * TEMPORARY DIAGNOSTIC — fires on **every** write to `sheetOpen`, whoever made it.
   *
   * This is the line that makes a framework write-back visible as itself rather than inferred.
   * `$$` generates a setter for the bound variable, and `@Watch` is invoked from that setter,
   * so a change this file did not make still lands here. It cannot say *who* wrote — that is
   * what the sequence of the surrounding lines and the `cycle` fields are for — but it says
   * *when*, which is the question ("is a write landing after a fresh open?").
   */
  onSheetOpenWatch(): void {
    // ==== DIAG-SHEET-BEGIN ====
    hilog.info(DOMAIN, TAG, 'SHEETPROBE seq=%{public}d t=%{public}dms tag=WATCH sheetOpen-changed now=%{public}s dismissing=%{public}s up=%{public}s cycle=%{public}d shownCycle=%{public}d closeCycle=%{public}d intentCycle=%{public}d raises=%{public}d',
      this.sheetProbeSeq, sheetProbeNow(), this.sheetOpen ? 'true' : 'false',
      this.dismissing ? 'true' : 'false', this.sheetShownCycle === this.sheetCycle ? 'true' : 'false', this.sheetCycle, this.sheetShownCycle,
      this.sheetCloseCycle, this.sheetIntentCycle, this.sheetRaiseAttempts);
    this.sheetProbeSeq = this.sheetProbeSeq + 1;
    // ==== DIAG-SHEET-END ====
    this.onSheetOpenSettled();
  }

  /**
   * Decide what a change of `sheetOpen` means, whichever side made it — **this is the repair
   * path that lets the open be written immediately.**
   *
   * The hand trace measures the sheet's exit at a **fixed ~590 ms** (11 of 11 closes:
   * 589–600 ms) and shows the framework's `$$` write-back landing **5–10 ms after `onDisappear`
   * begins** (`.diag/r95-hand-trace.txt` seq 182→187, 201→206, 262→267, 281→286, 356→361). So a
   * `true` written while the framework is finishing a dismissal it had already decided on can
   * be overwritten: the app asked, the framework was not listening. The transition back to
   * `false` is the evidence, and `sheetIntentCycle` is the record of the outstanding request.
   *
   * The guard is a conjunction and every term earns its place: the intent is for **this**
   * cycle, the framework has **not shown** a sheet in this cycle, and the close being settled
   * was initiated in an **earlier** cycle. Together they mean "the app asked, the framework
   * answered nothing, and what is closing is not what was asked for". A real dismissal fails
   * the first term (the app cleared the intent when it closed) or the second (the sheet was
   * up, so `onAppear` already acknowledged it), which is what keeps a dismissal a dismissal.
   * `SHEET_MAX_RAISE_ATTEMPTS` bounds the retry so a framework that persisted in writing the
   * value back cannot be answered forever.
   */
  private onSheetOpenSettled(): void {
    if (this.sheetOpen) {
      // Somebody raised the sheet. Nothing is repaired here even when the raise was the app's
      // own: `onAppear` is the acknowledgement that the framework *showed* it, and this
      // transition cannot tell the app's write from the framework's write-back — treating the
      // app's own write as the answer is exactly the mistake that would leave an overwritten
      // open unrepaired. See `sheetIntentCycle`.
      return;
    }
    // An unmet intent to show a sheet in this cycle: the app asked, the framework has not shown
    // one, and the close that is now being settled was initiated in an *earlier* cycle. That is
    // the overwritten open, and the raise is re-issued exactly once per attempt.
    const overwritten: boolean = this.sheetIntentCycle === this.sheetCycle
      && this.sheetShownCycle !== this.sheetCycle
      && this.sheetCloseCycle < this.sheetCycle;
    if (!overwritten || this.sheetRaiseAttempts >= SHEET_MAX_RAISE_ATTEMPTS) {
      // A settled `false` that is **not** an overwritten open is, for the blur's purposes,
      // "no sheet is showing". `sheetBlur` is raised only where the app asks for a sheet, and
      // that ask has been answered by a `false` — so the render gate goes with it. Without
      // this line a rejected open could leave the frost up over a page with no sheet on it,
      // which is the one failure this gate must not have. See `sheetBlur`.
      this.sheetBlur = false;
      return;
    }
    // The repair raises **both** the variables the open writes, in the same order
    // `openReaderSheet` writes them. r96 repaired `sheetOpen` alone, and that asymmetry is
    // r98's defect: the late dismissal the write-back belongs to had already cleared the gate,
    // so the repaired sheet came up with nothing frosted behind it. A raise that re-asserts
    // the binding without the gate is a raise that leaves the two disagreeing. See `sheetBlur`.
    this.sheetBlur = true;
    // A plain assignment to `true`, so the raise this watcher performs is the same event the
    // tap performed — same binding, same transition, same open animation.
    this.sheetRaiseAttempts = this.sheetRaiseAttempts + 1;
    this.onSheetProbe('watch-re-raise (open was overwritten)', this.sheetOpen); // DIAG-SHEET
    this.sheetOpen = true;
  }

  /**
   * Whether the dismissal being decided belongs to a cycle that is no longer the live one.
   *
   * **This is `sheetOpen`'s cycle discipline applied to the blur gate**, and it exists because
   * the framework's dismissal outlives the sheet it was decided for: `onDisappear` begins a
   * fixed ~590 ms in, its `$$` write-back 5–10 ms later, and the framework then re-fires
   * `onWillDismiss` against the sheet the app has raised in the meantime
   * (`.diag/r95-hand-trace.txt` seq 348, 590 ms after that sheet's own `onWillAppear`). A
   * dismissal that arrives against a live sheet is therefore **not** a dismissal of it, and the
   * gate of that sheet must not be cleared by it.
   *
   * It reads the *existing* cycle fields rather than inventing a second notion of "which
   * dismissal is this". Three facts decide it, each phrased from one side:
   *
   *  - `sheetIntentCycle === sheetCycle` — the app has asked for a sheet in this cycle and
   *    `onAppear` has not answered yet. Only an open raises this, and `finishSheetClose` and
   *    `onAppear` are the only things that clear it.
   *  - `sheetShownCycle === sheetCycle` — the framework has acknowledged a sheet in this cycle,
   *    so one is up.
   *  - `sheetCloseCycle !== sheetCycle` — the last close was initiated in an earlier cycle,
   *    i.e. a later open has happened since. This is the same comparison
   *    `onSheetOpenSettled` already uses for the clobbered open.
   *
   * The gate is **only** kept when one of the two "there is a sheet in this cycle" facts holds.
   * A normal dismissal — the drag, the tap outside, the short × that goes through the framework
   * — has neither (`sheetShownCycle` is this cycle and `sheetIntentCycle` is `-1` because
   * `onAppear` answered it), so the frost still clears at the decision point, which is r97's fix
   * and must not be lost.
   *
   * `onDisappear` deliberately does **not** consult this. It is the framework confirming the
   * sheet is gone, and it is the last clear on every path the trace has seen; keeping it
   * unconditional is what makes "a frosted page over no sheet" impossible rather than unlikely.
   */
  private sheetDismissalIsStale(): boolean {
    return (this.sheetIntentCycle !== this.sheetCycle
        && this.sheetShownCycle !== this.sheetCycle)
      || this.sheetCloseCycle === this.sheetCycle;
  }

  // ==== DIAG-SHEET-BEGIN ====
  /**
   * TEMPORARY DIAGNOSTIC — the spring-back callback, registered so the probe can date it.
   *
   * The body stays empty in the sense that matters: it does **not** call
   * `SpringBackAction.springBack()`, so no rebound is played. The call site is kept
   * syntactically empty and this method carries the probe instead, because
   * `verify-reader-chrome.mjs` asserts the attribute is empty and that assertion is not this
   * round's to weaken.
   */
  private onSheetSpringBackProbe(): void {
    this.onSheetProbe('lifecycle-onWillSpringBackWhenDismiss-no-springBack', this.sheetOpen);
  }
  // ==== DIAG-SHEET-END ====

  /**
   * Close the sheet from the app — **the only place this file writes `sheetOpen = false`.**
   *
   * Every close the user has (the ×, the system back gesture, a catalog jump) goes through
   * here, which is what makes the drag and the × the same close: `onSheetWillDismiss` no
   * longer writes the boolean at all. Writing it there was the asymmetry — the one close that
   * wrote `sheetOpen` at the exact moment the framework was mid-decision about that same
   * variable — and it is what let a dismissal survive `onDisappear` and re-fire against the
   * next sheet. See `sheetCycle`.
   */
  private finishSheetClose(): void {
    // Every field the watcher reads is set **before** the write that triggers it. `sheetOpen`
    // is an `@State` with a `@Watch`, so the assignment calls `onSheetOpenSettled` inside this
    // method; writing the boolean first would leave the watcher looking at the previous
    // cycle's intent and it would helpfully undo the close it was asked to perform.
    this.sheetCloseCycle = this.sheetCycle;
    this.sheetIntentCycle = -1;
    this.sheetRaiseAttempts = 0;
    this.dismissing = true;
    // The frost goes with the close the user asked for, in this same frame — the blur must
    // never wait on a binding write the framework makes at the end of its exit. This is also
    // why the line is here and not only in `onSheetWillDismiss`: whether the framework runs
    // its interactive-dismissal callback for an *app*-driven close is its business, and the ×
    // must not depend on the answer. See `sheetBlur`.
    this.sheetBlur = false;
    this.sheetOpen = false;
  }

  private onSheetWillDismiss(action: DismissSheetAction): void {
    hilog.info(DOMAIN, TAG, 'reader sheet: dismiss reason %{public}d accepted', action.reason);
    this.onSheetProbe('onWillDismiss-enter', this.sheetOpen); // DIAG-SHEET
    // **`action.dismiss()` is the whole body's effect, and that is deliberate.** This used to
    // write `sheetOpen = false` as well, one line before the framework's own exit — the only
    // close in the component that wrote the bound variable from inside the framework's
    // dismissal. With the write gone, the drag-close is the same shape as the ×-close: the
    // framework finalises the dismissal it authored, `$$` writes the boolean back, and
    // nothing the app does lands in the middle of that decision. The app's own state is set
    // by `onDisappear`, when the framework says the sheet is gone.
    //
    // **The one thing this body does write is the blur gate, and it is not the variable that
    // caused the bug.** The drag path cleared nothing until the framework wrote `sheetOpen`
    // back — ~600 ms after the user saw the sheet go — so the frost stayed on screen while the
    // sheet did not; the × had never shown it because that close is the app's own write. This
    // is the drag's write, taken at the decision point instead of at the end of the exit. It
    // touches no presence state: `sheetOpen = false` still appears exactly once in this file,
    // in `finishSheetClose`. And the value is part of the dismissal this callback goes on to
    // request (`action.dismiss()` below), so the two cannot disagree — the blur is cleared for
    // the close that is being accepted, not for a close that might not happen.
    //
    // **r98: only for the dismissal that is a dismissal of the sheet that is up.** The
    // framework re-fires this callback for the previous cycle's dismissal against a sheet the
    // app has already re-raised — `reason=3` at +590 ms after that sheet's own `onWillAppear`
    // in the r95 trace — and clearing the gate there is the user's report: the sheet stays
    // (the repair re-raises `sheetOpen`) and the frost does not. `sheetDismissalIsStale` asks
    // the cycle fields whether a sheet belongs to the cycle this callback is deciding in, and
    // leaves the gate alone when one does; `action.dismiss()` is **not** gated, because a
    // late dismissal may not be refused — it is the same framework exit either way.
    if (!this.sheetDismissalIsStale()) {
      this.sheetBlur = false;
    }
    action.dismiss();
    this.onSheetProbe('onWillDismiss-after-dismiss', this.sheetOpen); // DIAG-SHEET
  }

  /** Present one of the reader's four sheets, and say which one in the log. */
  private openReaderSheet(mode: ReaderSheetMode): void {
    // The mode is set *before* the sheet is shown, so the single host builds the right
    // content on the frame it presents rather than a frame later. The notice is cleared
    // here rather than on dismissal so a reopened sheet never shows the previous refusal.
    this.sheetMode = mode;
    this.tocNotice = '';
    this.onSheetProbe('openReaderSheet-enter', this.sheetOpen); // DIAG-SHEET
    // The write happens **now**. r95 held it while a close was in flight and replayed it in
    // `onDisappear`, which the user experienced as 「关了再开有点不跟手…有延迟」: the tap went
    // quiet for a whole exit animation. That deferral is gone. Instead the write is
    // unconditional, and the one failure mode it can have — the framework's `$$` write-back
    // overwriting it as it finishes a dismissal it had already decided on — is repaired by
    // `onSheetOpenSettled`, which fires on that very transition. See `sheetCycle`.
    this.sheetCycle = this.sheetCycle + 1;
    this.sheetIntentCycle = this.sheetCycle;
    this.sheetRaiseAttempts = 0;
    // The app is asking for a sheet, so its own "a close is in flight" flag stops applying.
    // Cleared here rather than in a lifecycle callback so the guard the × reads is released
    // the moment the user asks for the sheet back, not one framework callback later.
    this.dismissing = false;
    // The frost comes up in the same frame the sheet starts presenting. It used to be derived
    // from `sheetOpen`, which is why an open never gained a delay from it and must not gain one
    // now: the two are written together, a line apart, with nothing awaited between them.
    this.sheetBlur = true;
    this.sheetOpen = true;
    this.onSheetProbe('openReaderSheet-wrote-true', this.sheetOpen); // DIAG-SHEET
    // This line stays. The dead 目录 entry was investigated partly from a device where no
    // log appeared for the taps at all, which left "the handler never ran" and "the sheet
    // never presented" indistinguishable from outside. One line per entry tap is the
    // cheapest thing that keeps them apart.
    hilog.info(DOMAIN, TAG, 'reader sheet: %{public}s', `${mode}`);
  }

  /** Entry point: 目录. The TOC sheet — list plus jump. */
  private onEntryToc(): void {
    if (this.loading) {
      return;
    }
    this.openReaderSheet(ReaderSheetMode.TOC);
  }

  /**
   * Entry point: 书签.
   *
   * The sheet is an **empty state** for now (`bookmarkSheet`), because a form that creates a
   * bookmark at the current page is not what this entry is for — the reader's 书签 entry is a
   * place to *see* bookmarks, and the list is not specified yet. The data path behind it is
   * untouched and still works: `ReaderCallbacks.onAddBookmark`, `createBookmark` in the store
   * and the bookmark table's sync are all exactly as they were, and nothing here calls them.
   */
  private onEntryBookmarks(): void {
    if (this.loading) {
      return;
    }
    this.openReaderSheet(ReaderSheetMode.BOOKMARK);
  }

  /** Entry point: 笔记 — an empty state for now, for the same reason as 书签. */
  private onEntryNotes(): void {
    if (this.loading) {
      return;
    }
    this.openReaderSheet(ReaderSheetMode.NOTE);
  }

  /** Entry point: 设置 — the fourth sheet, the same presentation as the other three. */
  private onEntrySettings(): void {
    if (this.loading) {
      return;
    }
    this.openReaderSheet(ReaderSheetMode.SETTINGS);
  }

  /**
   * The 设置 sheet: **one card with one row**, and that is the honest list.
   *
   * ## Why one row
   *
   * 字号 is the reader's only real setting. Its other two choices are not settings at all:
   * the page colours follow the application theme through `pageColors()` and the reader has no
   * theme control (that was the 夜间 toggle, deliberately removed — it is *not* coming back
   * here), and the flip mode is fixed. So a second row would have to invent a control that
   * either does nothing or contradicts the theme, and an empty-looking sheet with invented
   * rows is worse than a short one that is true. The count is one, and the card is sized for
   * one.
   *
   * ## The row
   *
   * The shared card style — the palette's `card` fill, a 1 vp `palette.border` hairline,
   * `RADIUS_CARD`, the same treatment `ListRow`, the annotation cards and every theme row use.
   * Left to right: a rounded-square tile carrying `A` (the control's own letter, so the icon is
   * the thing it changes rather than a generic gear), then the title 字号 over a secondary line
   * giving the real supported range from `MIN_FONT_SIZE`/`MAX_FONT_SIZE`, then the stepper.
   *
   * **r94 put the hairline back, and it is not decoration.** r93 removed it because the fill
   * alone measured above the floor — `cardSubtle` on `card` was 1.083 / 1.194 / 1.080:1 — and
   * r94 changed *which* fill that is: the row is now `card` on a `background` body, i.e. the
   * same pair the app's own settings cards use, and that pair is 1.143:1 (light), 1.124:1
   * (dark) and **1.047:1 (sepia)**. 1.047:1 is the number the user overruled on the device
   * (「还是保留边框吧，护眼模式下确实看不清」), and the app's own cards in that theme got the
   * same hairline back in this round. So the row carries both: the fill says "raised" where the
   * fill is enough, and the 1 vp edge says "here is the boundary" in 护眼, where it is not.
   *
   * The tile and the stepper buttons below still have **fills** of their own (they are objects,
   * not an outline), and they use `sheetRowControl()` — see there for the measured figures and
   * for why they are the edge role rather than `muted` now that the row is a `card`.
   *
   * The stepper is the control that was in the inline panel, moved rather than reimplemented:
   * the same `A-` / value / `A+`, the same `adjustedFontSize` (+/- 2, clamped), the same
   * `updateSettings` — so it still applies to the page on the frame it is tapped and still
   * persists through `onSettingsChanged`. There is no chevron and no value-with-▾ row, because
   * there is nothing for one to open: the reader has no picker, and a chevron that leads
   * nowhere is exactly the invented control this list avoids.
   *
   * The card is the sheet's only child under the header, so it sits at the top of the body
   * rather than centred. A single centred card would read as an empty state, which is what
   * the other two sheets are for.
   */
  @Builder
  private settingsSheet() {
    Column({ space: 0 }) {
      this.sheetHeader(this.sheetTitle())

      this.settingsRow()
    }
    .width('100%')
    .padding({ left: SPACE_M, right: SPACE_M, bottom: SPACE_M })
    .backgroundColor(this.sheetCard())
    .borderRadius({ topLeft: RADIUS_SHEET, topRight: RADIUS_SHEET })
  }

  /**
   * One settings card row. A `@Builder` of its own so the card's treatment is in one place if
   * a second honest row ever exists.
   *
   * This row is the reader's copy of the app's own settings card, and since r94 it is the same
   * object in the same way: `palette.card` on a `palette.background` body, with the palette's
   * 1 vp `border` hairline. Both halves moved in this round — the body from `card` to
   * `background` in `sheetCard`, the row from `cardSubtle` to `card` here — so the fill
   * separation and the hairline's job both changed with them.
   *
   * The measured separations, all recomputed in r94 rather than carried over:
   *
   * | pair | light | dark | sepia |
   * |------|-------|------|-------|
   * | row fill (`card`) on the body (`background`) | 1.143:1 | 1.124:1 | **1.047:1** |
   * | the hairline (`border`) on the row | 1.271:1 | 1.319:1 | 1.447:1 |
   * | the hairline on the body | 1.113:1 | 1.483:1 | 1.383:1 |
   * | the row's title (`foreground`) on the row | 19.91:1 | 15.29:1 | 11.35:1 |
   * | the row's subtitle (`mutedForeground`) on the row | 4.88:1 | 6.38:1 | 4.61:1 |
   *
   * Sepia's 1.047:1 in the first row is the whole reason the second and third rows exist, and
   * it is the figure the user's device check overruled: 1.047:1 is above the 1.045:1 floor r93
   * set, and it is still not a visible boundary on a real screen in 护眼. `verify-themes.mjs`
   * therefore asserts the **hairline** as the separation and keeps the fill figure as a second,
   * weaker assertion — the fill must be there too, it just cannot be the only thing there.
   *
   * The tile and the stepper buttons are `sheetRowControl()` — the palette's edge role — see
   * there for why, and for the `muted` figures that would now also pass.
   */
  @Builder
  private settingsRow() {
    Row({ space: SPACE_M }) {
      // The icon tile: a rounded square, `RADIUS_IMAGE` because that is the spec's role for a
      // small container of an icon — at the card radius a 36 vp square reads as a blob, and it
      // would disagree with every other small tile in the app (the theme row's swatch takes
      // the same radius for the same reason).
      Stack() {
        Column()
          .width(36)
          .height(36)
          .borderRadius(RADIUS_IMAGE)
          .backgroundColor(this.sheetRowControl())
        Text('A')
          .fontSize(TYPE_SUBTITLE)
          // Same centring rule as the header's ×: the line box takes the tile's height, so the
          // glyph is centred in the tile rather than sitting on its baseline.
          .lineHeight(36)
          .textAlign(TextAlign.Center)
          .fontColor(this.chromeText())
      }
      .width(36)
      .height(36)
      .alignContent(Alignment.Center)

      Column({ space: 2 }) {
        Text('字号')
          .fontSize(TYPE_BODY)
          .fontColor(this.chromeText())
          .width('100%')
        Text(`可调范围 ${MIN_FONT_SIZE}–${MAX_FONT_SIZE}`)
          .fontSize(TYPE_CAPTION)
          .fontColor(this.sheetRowMuted())
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // The stepper, in the row rather than in a nested page: it is one control with three
      // parts, and a sub-page with one entry is the shape the brief rules out.
      Row({ space: SPACE_S }) {
        Button('A-')
          .fontSize(TYPE_BODY)
          .backgroundColor(this.sheetRowControl())
          .fontColor(this.chromeText())
          .borderRadius(RADIUS_CONTROL)
          .constraintSize({ minHeight: MIN_TAP_TARGET, minWidth: MIN_TAP_TARGET })
          .clickEffect(this.animationOn ? Motion.clickEffect() : null)
          .onClick((): void => {
            this.updateSettings(adjustedFontSize(this.live, -2));
          })
        Text(`${clampFontSize(this.live.fontSize)}`)
          .fontSize(TYPE_BODY)
          .width(32)
          .textAlign(TextAlign.Center)
          .fontColor(this.chromeText())
        Button('A+')
          .fontSize(TYPE_BODY)
          .backgroundColor(this.sheetRowControl())
          .fontColor(this.chromeText())
          .borderRadius(RADIUS_CONTROL)
          .constraintSize({ minHeight: MIN_TAP_TARGET, minWidth: MIN_TAP_TARGET })
          .clickEffect(this.animationOn ? Motion.clickEffect() : null)
          .onClick((): void => {
            this.updateSettings(adjustedFontSize(this.live, 2));
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(SPACE_M)
    .borderRadius(RADIUS_CARD)
    // The row's own surface: `palette.card` on a `palette.background` body, which is the app's
    // own settings-card pair (see `settingsRow`). The fill says "raised" and the 1 vp hairline
    // below says where the edge is; the fill alone is 1.047:1 against the body in sepia, which
    // is the figure the user's device check rejected as insufficient. r93 had this fill one step
    // off a `card` body with no line at all; r94 has the pair the rest of the app uses and the
    // line the rest of the app uses.
    .backgroundColor(this.sheetRow())
    .borderWidth(1)
    .borderColor(this.sheetCardEdge())
  }

  /**
   * The reader screen: **one page area, and two floating bars over it.**
   *
   * ## The page box cannot move, and that is the structure rather than a promise
   *
   * The outer `Stack` is the overlay layer: it takes the whole window (`layoutWeight(1)` ×
   * `width('100%')`), and its size comes from the column, not from its children. The inner
   * `Stack` is the **page layer** — the kit's panel and the pagination spinner — and it is the
   * box `viewWidth`/`viewHeight` are measured from and the kit paginates into.
   *
   * Both bars are children of the outer `Stack`, `position`-ed to the top and bottom edges, so
   * they are overlays of the page layer and never bands of it. That is the whole of the fix for
   * the trap this screen used to carry: the legacy bottom bar occupied layout space, so holding
   * it back once made the first `setPageConfig` paginate a box ~95 vp too tall and the bar's
   * later arrival re-paginated the page in front of a reader who had already started reading.
   * A bar that is a sibling *overlay* cannot do that — showing and hiding it is not a layout
   * event for the page layer at all, at any moment, not merely "from the first frame".
   * `tools/verify-reader-chrome.mjs` asserts the structure (both bars inside the page `Stack`,
   * both `position`-ed, the measured box taken from the page layer) rather than restating this
   * paragraph.
   *
   * ## The blur is on the page layer, and that is why the layers are separate
   *
   * `foregroundBlurStyle` is the 毛玻璃 drawn behind an open sheet, and it belongs on the **page**
   * only: on the outer stack it would frost the two bars as well, and a material with a blur
   * stacked on it is the repeated work the 沉浸光感 power guidance rules out (「避免与模糊效果
   * 叠加」). `sheetBlurStyle` carries the mechanism, the gate and the naming rule.
   *
   * ## The order of the children is the interaction model
   *
   *   1. the page layer — the kit's panel, and the pagination spinner over it;
   *   2. the transient chip, an overlay since this round so a message can no longer resize the
   *      page. (It is unreachable today — `flash()` has no caller — and this keeps it harmless
   *      if it ever gets one.);
   *   3. the **persistent chapter name** (`chapterOverlay`), an always-on overlay of its own so
   *      the chapter is still named while the bars are down. It is here, before the zones, and
   *      `HitTestMode.Transparent`, so a tap on it is a tap on the zone underneath; and before
   *      both bars, so a revealed bar draws over it. The rule that exactly one chapter name is
   *      on screen at any moment lives in `chapterOverlayVisible`, not in this order;
   *   4. the three tap zones, `HitTestMode.Transparent`, so the kit keeps its drags;
   *   5. the two bars **above** the zones, so a tap inside a bar's own bounds reaches the bar
   *      and is not also a page turn. Material does not affect hit testing — it paints
   *      background, border, blur and shadow and nothing else — so this ordering is the entire
   *      mechanism that gives a bar its own taps. A hidden bar is not hit-testable — `opacity` 0
   *      with `HitTestMode.BLOCK_DESCENDANTS` since r104, which is the same statement
   *      `Visibility.None` used to make for it — so "the bars are down" and "the zones own the
   *      page" are one statement rather than two that have to agree.
   *
   * The failure screen is the one alternative inside that structure: the kit is replaced by the
   * message, the zones and the bottom bar are absent (there is no page to turn and no entries
   * that could act), and the top bar is forced visible by `topBarVisible` — 返回 is drawn by
   * `topBarRow`, so without it a book that failed to open would have no way out but the system
   * back gesture.
   *
   * The bars are the application theme's own tones: the top bar is the system material or
   * `pageBackground()`, the bottom bar is the HDS floating style with the page colour as its
   * gradient mask. See `topBar` and `bottomBar` for why each takes the route it does.
   */
  build() {
    Column() {
      Stack() {
        // --- the page layer: measured, blurred, and the only band there is ---------
        Stack() {
          if (this.errorText.length > 0) {
            Column({ space: 10 }) {
              Text('无法打开这本书')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
              Text(this.errorText)
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .padding(24)
          } else {
            // The kit's own page panel. `readerCallback` fires once the panel has created its
            // controller, which is when `init()` may be called.
            ReadPageComponent({
              controller: this.controller,
              readerCallback: (err: BusinessError, created: readerCore.ReaderComponentController): void => {
                if (err !== null && err !== undefined) {
                  this.fail(`阅读组件创建失败：${messageOf(err)}`);
                  return;
                }
                // Take the controller the panel built. See the field's comment: the instance
                // created above is only what the panel was handed.
                this.controller = created;
                this.initialize();
              },
            })
              .width('100%')
              .height('100%')

            if (this.loading) {
              Column({ space: 10 }) {
                LoadingProgress().width(32).height(32)
                Text('正在排版...')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            }
          }
        }
        .width('100%')
        .height('100%')
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          const width: number = lengthToNumber(newValue.width);
          const height: number = lengthToNumber(newValue.height);
          if (Number.isNaN(width) || Number.isNaN(height) || width <= 0 || height <= 0) {
            return;
          }
          const changed: boolean = Math.abs(width - this.viewWidth) > 1
            || Math.abs(height - this.viewHeight) > 1;
          this.viewWidth = width;
          this.viewHeight = height;
          // Re-applying the config after a resize is what re-paginates: the kit paginates to
          // the viewport it was told about, so a rotation without this leaves the page laid
          // out for the old size. A bar appearing is not a resize and must never reach here.
          if (changed && this.settingsApplied) {
            this.applySettings(this.live);
          }
        })
        // --- the blur outside the sheet (毛玻璃, not 沉浸光感) ------------------
        //
        // On the page layer — the kit's panel and the pagination spinner — and **not** on the
        // overlay layer above it, because a foreground blur there would frost the two bars.
        // The sheet is unaffected either way: it is an overlay the framework composes above
        // this component's tree, which is exactly why the page can be blurred while the sheet
        // stays sharp. The reference blurs its whole page container, bars included; this is the
        // same mechanism applied to the smaller region. `sheetBlurStyle` carries the mechanism,
        // the exhaustive negative for the sheet's own options, and the gate.
        .foregroundBlurStyle(
          this.sheetBlurStyle(),
          { colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT })

        // --- the transient confirmation -------------------------------------------
        //
        // Chrome, so it is drawn sharp (outside the page layer's blur) and under the zones in
        // hit-test terms: the `Text` carries no handler and this wrapper is `Transparent`, so a
        // tap on the chip is a tap on the page. The wrapper is full-size and pinned to the top
        // so the chip sits below the top bar's area rather than moving anything.
        if (this.toastText.length > 0) {
          Column() {
            Text(this.toastText)
              .fontSize(TYPE_CAPTION)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(RADIUS_CHIP)
              .backgroundColor(this.chromeSurface())
              .fontColor(this.chromeText())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .padding({ top: TOP_BAR_HEIGHT, left: SPACE_M, right: SPACE_M })
          .hitTestBehavior(HitTestMode.Transparent)
        }

        // --- the persistent chapter name, the three zones, then the bars over them --
        //
        // The order is the mechanism twice over: the persistent title is **before** `tapZones()`
        // so a tap on it belongs to the zone underneath, and before both bars so a revealed bar
        // draws over it. `chapterOverlayVisible()` already makes the title and the top bar
        // mutually exclusive, so the second of those is never *seen* as a conflict — but the
        // order is still the thing that makes it impossible for a bar to be drawn under it.
        this.chapterOverlay()
        if (this.errorText.length === 0) {
          this.tapZones()
          this.bottomBar()
        }
        this.topBar()
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBackground())
    // **One** sheet, bound at the root so it can appear over the page panel. `sheetOpen`
    // carries why it is one and not three: chaining `bindSheet` per boolean here is what
    // left 目录 and 书签 presenting nothing at all.
    //
    // ## The options, and the band they remove
    //
    //  - **`backgroundColor`** — the one option that must be here. `BindOptions.backgroundColor`
    //    defaults to `Color.White` (`common.d.ts:11295`), so without it the sheet's own
    //    container is the platform's white whatever theme the app is in, and every region the
    //    sheet's content does not paint shows that white. It is set to `sheetCard()`, the same
    //    tone the four sheets and the shared header paint, so the container, the header and the
    //    body are one colour and no seam can exist between them.
    //  - **`detents: [SHEET_MIN_HEIGHT, SheetSize.LARGE]`** — the height is a **draggable
    //    position with a shared floor** again. The tuple is the SDK's whole vocabulary for this
    //    (`SheetOptions.detents`, `common.d.ts:11795` — at most three entries), it takes a
    //    `Length` as well as a `SheetSize`, and the first entry is the one the sheet opens at:
    //    「底部弹窗竖屏生效，元组中第一个高度为初始高度」. So `SHEET_MIN_HEIGHT` is *both* the
    //    opening height and the minimum, which is what "四个 sheet 统一最小高度" asks for and
    //    what the reference does — ClashBox's settings sheet is exactly this shape,
    //    `detents: [BIND_SHEET_CONTAINER_HEIGHT, SheetSize.LARGE]` with
    //    `BIND_SHEET_CONTAINER_HEIGHT = 684` (`entry/src/main/ets/pages/MorePage.ets:154-155`,
    //    `common/entity/Constants.ets:19`), i.e. a shared opening/minimum height and one
    //    draggable detent above it.
    //    **The gesture follows from that tuple, and it is the user's stated intent**: from
    //    `SheetSize.LARGE` a downward drag shrinks the sheet to `SHEET_MIN_HEIGHT`, and from
    //    `SHEET_MIN_HEIGHT` — which is where every sheet *opens* — a downward drag closes it
    //    rather than shrinking further. The platform's rule is 「下滑时，优先向下收缩面板挡位，
    //    如无挡位可收缩，则关闭面板」; r94 stopped refusing that second step. See
    //    `onSheetWillDismiss`, which is where the refusal used to be and where the behaviour is
    //    now recorded.
    //    **`height` moves into the detent value** rather than staying an option: 「底部弹窗时，
    //    当设置detents时，height属性设置无效」. It is the same `'50%'` and the same base — the
    //    sheet's own maximum height, the window less its top safe-area inset — so the sheet
    //    opens where it opened before this change and only the *reach* is new.
    //    A percent rather than `SheetSize.MEDIUM`, and `MEDIUM` is **not** half: it is
    //    documented as 60% of the sheet's window (半模态转场 · SheetSize: "指定半模态高度为半模态
    //    所在窗口的60%"), and the pattern agrees (`sheet_theme.h` `mediumPercent_ = 0.6`,
    //    `MEDIUM_SIZE = 0.6f`). The "half the screen height" line in `common.d.ts:7949` is the
    //    pre-API-11 prose (`MEDIUM_SIZE_PRE = 0.5f`) and no longer describes what ships.
    //  - **`dragBar: false`** — the platform's drag indicator is a capsule drawn on the sheet's
    //    container background, in a strip above the content. That strip is the "横条" that was
    //    reported at the top of 目录: a region of the sheet whose background is the container's
    //    rather than the content's. The custom header supplies the sheet's title *and* its ×
    //    dismiss, so the system bar has nothing left to do; removing it means the header is the
    //    first thing on the sheet. **The drag affordance does not go with it** — `detents` adds
    //    the pan recogniser regardless of `dragBar` — which is why the handle can be off and
    //    the sheet still resizable. See `sheetHeader` for the split that produces.
    //  - **`showClose: false`** — the system's own close button would be a second × beside the
    //    header's, and it carries its own dismissal path. The header's × is the one control.
    //  - **`onWillDismiss`** — registered so the sheet's close is routed through one place, and
    //    **every** reason is accepted. r92 used it to refuse `SLIDE_DOWN`; r94 removed that
    //    refusal because the user asked for the gesture the platform documents —
    //    「在最低档下滑可以关闭半模态」, 「下滑时，优先向下收缩面板挡位，如无挡位可收缩，则关闭面板」.
    //    `onSheetWillDismiss` carries the full reasoning and the two-step behaviour (down from
    //    `LARGE` shrinks to `SHEET_MIN_HEIGHT`; down again, from the floor, dismisses).
    //    `CLOSE_BUTTON` and the header's × do not come through here at all: the × writes
    //    `sheetOpen = false` directly, and `showClose: false` means the system button does not
    //    exist.
    //  - **`onWillSpringBackWhenDismiss: () => {}`** — **still load-bearing after the refusal
    //    was removed, and the SDK reference says why**: 「若不注册该回调函数，但注册shouldDismiss
    //    或onWillDismiss时，则默认在下拉关闭时，**会触发回弹效果**，回弹后再根据shouldDismiss或
    //    onWillDismiss内的回调行为决定半模态是否关闭」 ("if this callback is not registered but
    //    `shouldDismiss`/`onWillDismiss` is, a downward drag triggers the rebound **by default**,
    //    and only after the rebound is the dismissal decided"). So this is not dead code left
    //    over from the refusal: without it, a swipe-down on the sheet would bounce before it
    //    closed. `SpringBackAction.springBack()` is what *asks* for the rebound, so the empty
    //    body means "no rebound, go straight to the decision" — which is also exactly what the
    //    official example does (`示例4（使用关闭回调函数）`, whose comment reads 「没有注册
    //    springBack，下拉半模态页面无回弹行为」). The reference's own name for it is
    //    「半模态页面交互式关闭前控制回弹函数」 — it is in the dismissal path, not the detent path,
    //    so it cannot affect the LARGE→`50%` shrink. The `MorePage.ets:166` registration this was
    //    originally copied from is the same mechanism ("注册回调，防止反向回弹").
    //
    // **No `systemMaterial` here, deliberately.** `SheetOptions.systemMaterial`
    // (`common.d.ts:12155`) is a documented options-object carrier and would be legal — but it
    // "can influence the backgroundColor, border, shadow" of the sheet, which is the one thing
    // this change is fixing, and it is a translucency on the surface the app's own theme has
    // just been told to paint opaquely. A themed opaque surface is the predictable answer; the
    // opportunity is recorded rather than taken. What *is* taken is the blur **outside** the
    // sheet, which this SDK gives no option for at all — `SheetOptions.blurStyle` is the
    // sheet's own background (`common.d.ts:11810`) and `maskColor` only tints the scrim — so it
    // is drawn by `readerPageBlur`, on the page area, exactly as the reference draws it
    // (`ClashBox/entry/src/main/ets/pages/Index.ets:359`, `.foregroundBlurStyle(...)` gated on
    // the sheet being up).
    .bindSheet($$this.sheetOpen, this.readerSheet(), {
      backgroundColor: this.sheetCard(),
      detents: sheetDetents(),
      preferType: SheetType.BOTTOM,
      dragBar: false,
      showClose: false,
      // The two lifecycle callbacks that bound a dismissal, and the correction this round
      // makes to what they mean. `onWillDisappear` fires when the exit animation **starts** and
      // `onDisappear` when it **ends** — the reference's lifecycle table is
      // 「onWillAppear -> onAppear -> onWillDisappear -> onDisappear」 with 「动画开始前」 /
      // 「动画结束后」 on the two ends. r95 read 「需要等动效完全结束后，才可以再次拉起」 as making
      // `onDisappear` the moment a re-open is safe, and held the request until then.
      //
      // **The hand trace falsifies that reading, and this round acts on the falsification.**
      // The exit is a fixed ~590 ms (11 of 11 closes, 589–600 ms — identical for the × and the
      // drag), and the framework's own `$$` write-back lands **5–10 ms after `onDisappear`
      // begins** (seq 182→187, 201→206, 262→267, 281→286, 356→361). A `true` written at
      // `onDisappear` is therefore overwritten ~10 ms later, and the framework goes on to run
      // its still-live dismissal against the sheet that was just raised — the `reason=3`
      // `onWillDismiss-callback` at `seq=348`, 590 ms after `onWillAppear`, which is the
      // reported "appears and closes again".
      //
      // So `onDisappear` is no longer where anything is replayed. It is where the app records
      // that the sheet is gone (`sheetShownCycle`, `dismissing`) and advances nothing else. The
      // re-open repair lives in `onSheetOpenSettled`, driven by the variable transition itself.
      onDisappear: (): void => {
        this.onSheetProbe('lifecycle-onDisappear-enter', this.sheetOpen); // DIAG-SHEET
        this.dismissing = false;
        this.sheetShownCycle = -1;
        // The last word on the frost, and only ever a clear: `onDisappear` is the framework
        // saying the sheet is gone, so if any path left the gate up there is nothing left for
        // it to blur. This is not where the blur is meant to clear — that happens at the
        // dismissal decision, ~590 ms earlier, on both paths — it is the guarantee that a
        // frosted page can never outlive the sheet it belongs to. See `sheetBlur`.
        //
        // **r98 leaves this clear unconditional, and that is the deliberate half of the fix.**
        // It is tempting to gate it with `sheetDismissalIsStale` the way the decision in
        // `onWillDismiss` is. It must not be: a stale `onWillDismiss` is *not* obeyed for the
        // gate (see `sheetDismissalIsStale`), so the cycle in which the gate is kept may have
        // no later clear at all, and this line is what makes "frost over no sheet" impossible
        // rather than unlikely. It runs after the decision on every path the trace has, so it
        // cannot re-frost a sheet that is arriving — the raise it could follow is the repair's,
        // and the repair writes the gate itself, in the same frame, *after* this callback.
        this.sheetBlur = false;
      },
      onWillDismiss: (action: DismissSheetAction): void => {
        this.onSheetProbe(`onWillDismiss-callback reason=${action.reason}`, this.sheetOpen); // DIAG-SHEET
        this.onSheetWillDismiss(action);
      },
      // ==== DIAG-SHEET-BEGIN ====
      // The two remaining `BindOptions` callbacks, registered only so the probe can date the
      // start of the enter/exit animations. They change nothing.
      // ==== DIAG-SHEET-END ====
      onWillDisappear: (): void => {
        this.onSheetProbe('lifecycle-onWillDisappear', this.sheetOpen); // DIAG-SHEET
      },
      onWillAppear: (): void => {
        this.onSheetProbe('lifecycle-onWillAppear', this.sheetOpen); // DIAG-SHEET
      },
      onAppear: (): void => {
        // `onAppear` is the acknowledgement: the framework has shown a sheet, so the intent
        // that asked for it has been answered and must not be re-issued. See `sheetIntentCycle`.
        // (The probe line above it is removable; this is not.)
        this.onSheetProbe('lifecycle-onAppear-acked', this.sheetOpen); // DIAG-SHEET
        this.sheetShownCycle = this.sheetCycle;
        this.sheetIntentCycle = -1;
      },
      // An empty callback, registered for the reason the SDK reference gives: with
      // `onWillDismiss` registered and this callback absent, a downward drag plays the
      // framework's rebound **before** the dismissal is decided. Answering it with no
      // `springBack()` removes that bounce, so the swipe-down goes straight to the close.
      // See the `bindSheet` note above for the quoting and for why this is not dead code now
      // that nothing is refused.
      // ==== DIAG-SHEET-BEGIN ====
      // "Empty" is the body's *semantics* — no `springBack()` is called — and r95 keeps the
      // body one call to `onSheetSpringBackProbe()`, a probe that only writes a log line. The
      // reason it is a method and not inline is that `strip-sheet-probe.mjs` can then cut the
      // method and leave behind the exact body that stood here before this round. The probe
      // script also re-creates the empty body, and `verify-reader-chrome.mjs`'s assertion on
      // this attribute was updated to accept exactly the one probe call and still require the
      // absence of `springBack()` — never a looser match.
      // ==== DIAG-SHEET-END ====
      onWillSpringBackWhenDismiss: (): void => {
        this.onSheetSpringBackProbe();
      },
    })
  }
}

/** The reading area in device pixels, resolved for the kit. Never zero. */
interface ReaderViewPort {
  width: number;
  height: number;
}

/**
 * Coerce an ArkUI `Length` to a number.
 *
 * `Area.width` and `Area.height` are typed `Length`, which admits a unit-suffixed
 * string as well as a number (`openharmony/ets/component/units.d.ts`, "Unit: vp").
 * `Number('360vp')` is `NaN`, and the caller's guard then discards the measurement
 * *silently* — leaving the reader with a zero viewport and no error anywhere. Parsing
 * the leading number keeps that from being invisible.
 */
function lengthToNumber(value: Length): number {
  if (typeof value === 'number') {
    return value;
  }
  const parsed: number = parseFloat(`${value}`);
  return Number.isFinite(parsed) ? parsed : 0;
}

function messageOf(err: Object): string {
  if (err instanceof InkBoatError) {
    return err.message;
  }
  if (err instanceof Error) {
    return err.message;
  }
  return JSON.stringify(err);
}

/**
 * Find the spine index a catalog entry points at.
 *
 * Three signals, most reliable first:
 *  1. an exact href match against a spine item;
 *  2. a match after stripping a fragment, because catalog hrefs routinely carry
 *     `#anchor` and spine hrefs do not;
 *  3. `idRef`, which names a manifest item the spine also references.
 *
 * Returns -1 when nothing matches, which the caller renders as non-navigable rather
 * than guessing a chapter and sending the reader somewhere wrong.
 */
function matchSpineIndex(
  href: string,
  idRef: string | undefined,
  spineList: bookParser.SpineItem[],
): number {
  const wanted: string = href.trim();
  if (wanted.length > 0) {
    for (const item of spineList) {
      if (item.href === wanted) {
        return item.index;
      }
    }
    const withoutFragment: string = stripFragment(wanted);
    if (withoutFragment.length > 0) {
      for (const item of spineList) {
        if (stripFragment(item.href) === withoutFragment) {
          return item.index;
        }
      }
    }
  }
  if (idRef !== undefined && idRef.length > 0) {
    for (const item of spineList) {
      if (item.idRef === idRef) {
        return item.index;
      }
    }
  }
  return -1;
}

/** Remove a `#fragment` and decode percent escapes, for href comparison. */
function stripFragment(href: string): string {
  const hash: number = href.indexOf('#');
  const withoutHash: string = hash >= 0 ? href.substring(0, hash) : href;
  try {
    return decodeURIComponent(withoutHash);
  } catch (err) {
    return withoutHash;
  }
}
