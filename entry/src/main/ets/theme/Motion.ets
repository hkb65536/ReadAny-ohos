/**
 * The app's motion system: one place that decides how everything moves.
 *
 * A port of ClashBox's `common/utils/Animation.ets` (249 lines, one singleton
 * `customAnimationUtil`) onto this app's plumbing. The reference file was read, not
 * guessed at; the three ideas worth copying are all in it:
 *
 * 1. **Every method returns `null` when the user has switched animation off.** A
 *    component given `null` does not animate at zero length — it simply appears. That
 *    is a different thing from a 0 ms animation, and it is why the off setting is a
 *    real switch rather than a very fast one.
 *
 * 2. **The timing lives on the `TransitionEffect` itself**, via `.animation({ … })`,
 *    rather than wrapping the state change in `animateTo`. The docs say a transition
 *    carrying its own `animation()` needs no `animateTo`, and a self-describing effect
 *    composes: `combine()` merges the parts into one effect with one timing instead of
 *    nesting two animation contexts.
 *
 * 3. **The curve is `curves.springMotion()`, not an ease.** The spring settles with a
 *    little physical overshoot. `Curve.FastOutSlowIn` accelerates and stops dead, which
 *    reads as mechanical. Every method that moves something therefore takes the spring;
 *    only a pure fade has nothing to overshoot and uses a plain ease.
 *
 * ## Where the setting lives
 *
 * `AppearanceStore` owns it on disk (the same `preferences` file the theme mode uses).
 * At runtime it lives in `AppStorage` under the two keys below, which is what makes it
 * observable: a component that declares
 *
 *     @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;
 *
 * re-renders when the setting changes, so `.clickEffect(...)` and
 * `.transition(transitionOrIdentity(...))` re-evaluate. `Motion` itself reads `AppStorage`
 * directly, so a call site passes no settings object — unlike ClashBox, which threads
 * its `UIConfig` through all 185 call sites.
 *
 * `index` is the stagger input, exactly as in the reference: pass the loop index and
 * rows arrive in sequence rather than all at once. Pass `0` for a single element.
 *
 * ## What is deliberately not ported
 *
 *  - `isSlideSwitch`, `getFloatButtonTransition` and the three floating-button
 *    transitions: this app has no floating action button.
 *  - `isSlideScaleBig` / `isSlideScaleBigMove` / `isSlideScaleSmall`: unused corners of
 *    the reference, and each would need a call site invented for it to be tested.
 *  - The reference's `isON.toggleAnim` flag (suppresses a row transition while a switch
 *    is being flipped). This app's settings rows do not flip a switch in place inside an
 *    animating list, so there is nothing for it to suppress; adding it would be dead
 *    state. If a settings row ever grows an inline switch, this is where that flag goes.
 */

import { curves } from '@kit.ArkUI';

// ---------------------------------------------------------------------------
// Storage keys
// ---------------------------------------------------------------------------

/**
 * `AppStorage` key for the on/off switch. A boolean, because that is what the switch is.
 *
 * The keys are exported so a component can bind to them with `@StorageLink` without
 * keeping a second copy of the string — the same reason `FLOATING_BAR_CLEARANCE` is
 * exported rather than written out at each call site.
 */
export const MOTION_ON_KEY: string = 'inkboatAnimationOn';

/** `AppStorage` key for the selected speed, as an index into `ANIMATION_OPTIONS`. */
export const MOTION_SPEED_INDEX_KEY: string = 'inkboatAnimationSpeedIndex';

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------

/** Default speed index: 1 = 正常 (300 ms). See `ANIMATION_OPTIONS`. */
export const DEFAULT_ANIMATION_SPEED_INDEX: number = 1;

/** Whether animation is on before any setting has been read. On, so nothing changes
 *  for a user who never opens the animation setting. */
export const DEFAULT_ANIMATION_ON: boolean = true;

/**
 * The per-row stagger, in ms, for the two `index`-based methods.
 *
 * `SCALE_STAGGER` is the reference's `i*10+30` and `ICON_STAGGER` its `i*10+50`. The
 * first row therefore starts 30 ms in and each later row 10 ms after the one before it,
 * which is short enough that a twelve-row list has finished arriving in about a fifth of
 * a second — long enough to read as sequence rather than as a single render.
 */
const SCALE_STAGGER: number = 10;
const SCALE_STAGGER_BASE: number = 30;
const ICON_STAGGER: number = 10;
const ICON_STAGGER_BASE: number = 50;
/** The fast variant's stagger (`i*2+10`): a dense grid cannot afford 10 ms per cell. */
const GRID_STAGGER: number = 2;
const GRID_STAGGER_BASE: number = 10;

/** Vertical travel of `riseIn`, in vp. The reference's `translate({y: 50})`. */
const RISE_OFFSET: number = 50;
/** Horizontal travel of `slideIn`, in vp. The reference's `translate({x: 20})`. */
const SLIDE_OFFSET: number = 20;
/** Scale the fast variant starts from. The reference's `{x: 0.7, y: 0.7}`. */
const FAST_SCALE_FROM: number = 0.7;
/** Rotation of `iconIn`, in degrees. The reference's `rotate({angle: 360})`. */
const ICON_ROTATION: number = 360;
/** Press-down scale of the click effect. The reference's `scale: 0.95`. */
const CLICK_SCALE: number = 0.95;
/**
 * Spring parameters for `motionSpring()`, below.
 *
 * `curves.springMotion()` on its own uses the framework defaults (response 0.15 s,
 * damping 0.86) and that is what every effect above uses — it is what the reference uses
 * for the same effects. These two numbers are only for a caller that needs a bare curve
 * rather than a whole `TransitionEffect`, and they are the reference's own explicit
 * `springMotion(0.5, 0.7)`: a slower, less damped spring, which is right for a large
 * element such as a pushed page and wrong for a 24 vp icon.
 */
const SPRING_RESPONSE: number = 0.5;
const SPRING_DAMPING: number = 0.7;

// ---------------------------------------------------------------------------
// The four settings
// ---------------------------------------------------------------------------

/**
 * The four options the setting offers, in the order ClashBox's picker shows them.
 *
 * `off` is an option in the same list rather than a separate switch: ClashBox presents it
 * that way and the choice is right — "no animation" and "instant animation" are the same
 * intention, and a user who wants neither does not have to find a second control.
 */
export enum AnimationSpeed {
  FAST = 0,
  NORMAL = 1,
  SLOW = 2,
  OFF = 3,
}

/** Duration in ms for each option, indexed by the option value. */
export const ANIMATION_DURATIONS: number[] = [100, 300, 500, 0];

/**
 * Playback rate for each option, indexed by the option value — the speed setting's other
 * output, for the one animation the setting cannot reach through `duration`.
 *
 * **Why a second table is needed at all.** Everything the app animates through
 * `Motion.timing(...)` gets the selected duration. The 「书架」 title's collapse cannot: its
 * curve is `curves.springMotion(...)`, and the SDK states plainly (and twice) that with a
 * spring curve 「duration不生效，动画持续时间由弹簧曲线自身的物理参数…决定」 — the animation's
 * length comes from the spring itself, so handing it 100/300/500 would be a number that reads
 * as meaningful and is not. The same reference gives the setting that *does* work on a spring:
 * `AnimateParam.tempo` (`common.d.ts:3439`, **`@since 7`**), 「动画播放速度」, default 1.0,
 * where a larger value plays the same spring faster.
 *
 * So this table is the speed setting expressed in the one unit a spring understands, and it is
 * deliberately **the same three-way choice** the picker already offers: the spring's own length
 * is the "标准" baseline, 快速 plays it at 1.35× and 慢速 at 0.75×. The `off` entry is 0 and is
 * never read — with the switch off `animateTo` is skipped entirely rather than handed a tempo,
 * exactly as it is never handed `duration: 0`.
 */
export const ANIMATION_TEMPOS: number[] = [1.35, 1.0, 0.75, 0];

/**
 * The playback rate for a speed index, defaulting to Normal like `durationForSpeedIndex`.
 *
 * Same clamping contract, and for the same reason: an index written by an older or newer build
 * must not read off the end of the table.
 */
export function tempoForSpeedIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index >= ANIMATION_TEMPOS.length) {
    return ANIMATION_TEMPOS[DEFAULT_ANIMATION_SPEED_INDEX];
  }
  return ANIMATION_TEMPOS[index];
}

/** One row of the picker. */
export interface AnimationOption {
  speed: AnimationSpeed;
  label: string;
  /** Duration in ms. `0` is meaningful only together with `isOn === false`. */
  duration: number;
  /** False for the `off` row, which is what makes it a genuine switch. */
  isOn: boolean;
  description: string;
}

/**
 * The picker's contents.
 *
 * `fast` and `slow` are labelled *relative to* Normal rather than with raw numbers,
 * because "100 ms" means nothing to most people and "比默认更快" does. The duration is
 * still carried on the row so the setting is self-documenting.
 */
export const ANIMATION_OPTIONS: AnimationOption[] = [
  { speed: AnimationSpeed.FAST, label: '快速', duration: 100, isOn: true, description: '入场更利落，适合熟悉界面后使用' },
  { speed: AnimationSpeed.NORMAL, label: '标准', duration: 300, isOn: true, description: '默认速度，与系统动画时长一致' },
  { speed: AnimationSpeed.SLOW, label: '慢速', duration: 500, isOn: true, description: '动作更舒缓，便于看清每一处变化' },
  { speed: AnimationSpeed.OFF, label: '关闭', duration: 0, isOn: false, description: '所有界面动效直接呈现，不再播放' },
];

/**
 * Duration for a speed index, clamped into range.
 *
 * A stored index from an older or newer build must not index off the end of the table:
 * an unknown value falls back to Normal, which is the same value a fresh install gets.
 */
export function durationForSpeedIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index >= ANIMATION_DURATIONS.length) {
    return ANIMATION_DURATIONS[DEFAULT_ANIMATION_SPEED_INDEX];
  }
  return ANIMATION_DURATIONS[index];
}

/**
 * Whether a speed index means "animate".
 *
 * Derived from the option table rather than from a second literal, so `off` cannot drift
 * away from the row the user taps.
 */
export function isAnimationOnForSpeedIndex(index: number): boolean {
  if (!Number.isInteger(index) || index < 0 || index >= ANIMATION_OPTIONS.length) {
    return DEFAULT_ANIMATION_ON;
  }
  return ANIMATION_OPTIONS[index].isOn;
}

/** Narrow an arbitrary number (from storage) to a known option. */
export function asAnimationSpeedIndex(value: number): number {
  if (Number.isInteger(value) && value >= 0 && value < ANIMATION_OPTIONS.length) {
    return value;
  }
  return DEFAULT_ANIMATION_SPEED_INDEX;
}

// ---------------------------------------------------------------------------
// Runtime state
// ---------------------------------------------------------------------------

/**
 * Seed `AppStorage` so both keys exist before any component binds to them.
 *
 * Runs at module load. It does happen before the shell reads the stored preference —
 * `Index.ets` imports this module at the top of the file, which evaluates this body, and
 * `restoreTheme` runs later from `aboutToAppear` — but the ordering that matters is the
 * other one: `@StorageLink` in a component that binds before the restore would otherwise
 * create the key from its own declared default, and the restored value moments later would
 * read as a *change*, playing an animation on the first frame for no reason.
 *
 * `setOrCreate` writes the value when the key is absent and replaces it when present, so
 * this is a seed rather than a guard: `applyAnimationSetting` below is what makes a real
 * value stick.
 */
AppStorage.setOrCreate<boolean>(MOTION_ON_KEY, DEFAULT_ANIMATION_ON);
AppStorage.setOrCreate<number>(MOTION_SPEED_INDEX_KEY, DEFAULT_ANIMATION_SPEED_INDEX);

/**
 * Push a speed index into `AppStorage`, and return the value that was applied.
 *
 * The one writer of the two keys. `Index.ets` calls it once at startup with the value
 * `AppearanceStore` read, and once per tap on the settings page. Persisting is the
 * caller's job (`AppearanceStore.saveAnimationSpeedIndex`), so the screen updates even
 * when storage fails — the same ordering `chooseTheme` uses.
 *
 * The **returned** index is the clamped one, so a caller that asks for a value that is not
 * one of the four options gets told which row is actually in force instead of showing the
 * one it asked for. Callers that have already written the value into storage can also read
 * it back through `currentAnimationSpeedIndex`, which is what `Index.ets` does.
 */
export function applyAnimationSetting(speedIndex: number): number {
  const index: number = asAnimationSpeedIndex(speedIndex);
  AppStorage.setOrCreate<number>(MOTION_SPEED_INDEX_KEY, index);
  AppStorage.setOrCreate<boolean>(MOTION_ON_KEY, isAnimationOnForSpeedIndex(index));
  return index;
}

/** Read the stored speed index straight out of `AppStorage`, for the settings page. */
export function currentAnimationSpeedIndex(): number {
  return AppStorage.get<number>(MOTION_SPEED_INDEX_KEY) ?? DEFAULT_ANIMATION_SPEED_INDEX;
}

// ---------------------------------------------------------------------------
// The singleton
// ---------------------------------------------------------------------------

/**
 * The animation factory.
 *
 * A singleton, mirroring the reference's `export const customAnimationUtil = new
 * AnimationUtil()`, but with one difference: no method takes a settings object. The
 * setting is read from `AppStorage` here, so a call site reads
 * `.transition(Motion.scaleIn(index))` instead of
 * `.transition(customAnimationUtil.isScaleTran(index, this.uiConfig))`.
 *
 * The class is not exported; `Motion` is the only instance, exactly as in the reference.
 */
class MotionUtil {
  /** True when animation is switched on. The gate every method reads. */
  isOn(): boolean {
    return AppStorage.get<boolean>(MOTION_ON_KEY) ?? DEFAULT_ANIMATION_ON;
  }

  /** The selected speed, as an index. */
  speedIndex(): number {
    return AppStorage.get<number>(MOTION_SPEED_INDEX_KEY) ?? DEFAULT_ANIMATION_SPEED_INDEX;
  }

  /**
   * The selected duration in ms.
   *
   * This is the number the tab switch uses as well, so the whole app speeds up and slows
   * down together. `0` means "off": see `Motion.tabSwitchDuration()` for why a tab tap
   * must not actually be given 0.
   */
  duration(): number {
    return durationForSpeedIndex(this.speedIndex());
  }

  /**
   * The selected playback rate, for the one animation a spring curve owns — see
   * `ANIMATION_TEMPOS`, which carries why `duration` cannot serve it.
   *
   * Not `0` when the switch is off: `tempo: 0` means "no animation", which is a different thing
   * from "no animation context", and the app's contract for off is the latter (the assignment is
   * made outside `animateTo`). A caller that is gated on `animationOn` never reaches this with
   * `off` selected; if one did, Normal's rate is the harmless answer.
   */
  tempo(): number {
    const rate: number = tempoForSpeedIndex(this.speedIndex());
    return rate > 0 ? rate : tempoForSpeedIndex(DEFAULT_ANIMATION_SPEED_INDEX);
  }

  /**
   * The timing block handed to `TransitionEffect.animation()`.
   *
   * Kept private-ish (it is public because ArkTS has no `protected` worth using here) so
   * a call site cannot invent a duration that ignores the setting.
   */
  private timing(delay: number, useSpring: boolean): AnimateParam {
    const duration: number = this.duration();
    if (useSpring) {
      return { duration: duration, curve: curves.springMotion(), delay: delay };
    }
    return { duration: duration, curve: Curve.Ease, delay: delay };
  }

  /**
   * Press feedback for anything tappable: a `.95` scale while the finger is down.
   *
   * Use on: list rows, settings rows, cards, buttons that are not the primary action.
   * This is the reference's `isClickEffect` (90 call sites there) and the single most
   * visible thing the switch turns off — with it on the whole app feels responsive, with
   * it off the same taps feel inert.
   *
   * Returns `null` when animation is off, which is the documented way to disable it:
   * `clickEffect(value: ClickEffect | null)`.
   */
  clickEffect(): ClickEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return { level: ClickEffectLevel.MIDDLE, scale: CLICK_SCALE };
  }

  /**
   * Scale-and-fade entrance with a per-row stagger. The reference's `isScaleTran`.
   *
   * Use on: rows of a list or a column of cards that arrive together — the settings
   * index, the appearance page's cards, the annotation list. Pass the loop index.
   *
   * `scale({x: 0, y: 0})` is the *from* state, so each row grows out of its own centre
   * rather than flying in; combining it with `OPACITY` stops the growth reading as a
   * zoom, because the row is also fading up.
   */
  scaleIn(index: number): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0, y: 0 }))
      .animation(this.timing(index * SCALE_STAGGER + SCALE_STAGGER_BASE, true));
  }

  /**
   * Scale-and-fade with a much tighter stagger, for a dense grid. The reference's
   * `isScaleTranFast`.
   *
   * Use on: grid cells — the shelf's covers. A book grid can hold thirty cells on a
   * tablet, where the 10 ms per-cell stagger above would still be arriving after a third
   * of a second; 2 ms per cell keeps the whole grid inside one gesture's worth of time.
   * It starts from `0.7` rather than `0` so a cell does not visibly pop out of nothing.
   */
  scaleInFast(index: number): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.scale({ x: FAST_SCALE_FROM, y: FAST_SCALE_FROM })
      .animation(this.timing(index * GRID_STAGGER + GRID_STAGGER_BASE, true));
  }

  /**
   * Fade-and-slide entrance from the right, a small offset. The reference's `isSlideR`.
   *
   * Use on: a row that should read as *added* to a list rather than as part of its first
   * paint — a newly synced book, a note that was just written. The 20 vp travel is
   * deliberately small: `TransitionEffect.SLIDE` moves a whole screen width and is far
   * too heavy for a row inside a scrolling list.
   */
  slideIn(index: number): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.OPACITY
      .animation(this.timing(index, true))
      .combine(TransitionEffect.translate({ x: SLIDE_OFFSET }));
  }

  /**
   * Fade-and-slide entrance upwards, 50 vp. The reference's `isTranslate`, which it uses
   * for tab content.
   *
   * Use on: a whole section arriving — the body of a tab, a page's content block. It is
   * the heaviest of the entrance effects, so it belongs on one element per screen, not on
   * every row.
   */
  riseIn(): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.OPACITY
      .animation(this.timing(0, true))
      .combine(TransitionEffect.translate({ y: RISE_OFFSET }));
  }

  /**
   * Plain fade. The reference's `isOpacity` (13 call sites).
   *
   * Use on: something that should appear without moving — a status line, a result panel,
   * a sheet's contents. This is the one method that uses an ease rather than the spring:
   * a fade has no position to overshoot, and a spring on opacity alone reads as a
   * flicker at the end.
   */
  fadeIn(): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.OPACITY.animation(this.timing(0, false));
  }

  /**
   * A full-width horizontal slide, for something that replaces the screen. The reference's
   * `isSlide`.
   *
   * Use on: a pushed page, or a panel that covers the app. Not on anything inside a
   * scrolling list — `SLIDE` travels a whole screen width, which is right for a page that
   * replaces another and wrong for everything else. The delay is a plain offset here
   * (`{x: 20}`), so `index` is a delay rather than a stagger multiplier, matching the
   * reference.
   */
  pushIn(delay: number): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.OPACITY
      .animation(this.timing(delay, true))
      .combine(TransitionEffect.SLIDE);
  }

  /**
   * Scale-and-rotate entrance for a leading icon. The reference's `isScaleTranIcon`.
   *
   * Use on: a row's leading `SymbolGlyph`, or an icon-only control. The 360° rotation is
   * the point — at 24 vp a pure scale is barely visible, while the rotation gives the
   * icon an unmistakable arrival. It has the longest base delay (50 ms) because in the
   * reference it is applied to a column of icons that should follow the row text in.
   */
  iconIn(index: number): TransitionEffect | null {
    if (!this.isOn()) {
      return null;
    }
    return TransitionEffect.scale({ x: 0, y: 0 })
      .combine(TransitionEffect.rotate({ angle: ICON_ROTATION }))
      .animation(this.timing(index * ICON_STAGGER + ICON_STAGGER_BASE, true));
  }

  /**
   * The edge effect for a scroll container: springy when animation is on, flat when off.
   *
   * The reference gates 14 files on exactly this (`isAnimation ? EdgeEffect.Spring :
   * null`). The SDK's `edgeEffect` on `Scroll`/`List`/`Grid` takes a non-nullable
   * `EdgeEffect`, so the "off" answer is `EdgeEffect.None` rather than `null` — the same
   * intent, expressed the way this API allows. `None` is what stops the list stretching
   * past its end and springing back, which is the only part of a scroll that is an
   * animation.
   */
  edgeEffect(): EdgeEffect {
    return this.isOn() ? EdgeEffect.Spring : EdgeEffect.None;
  }

  /**
   * Duration for the bottom tab switch, in ms.
   *
   * **Never 0.** `HdsTabs` and `Tabs` are given this value, and with `BottomTabBarStyle`
   * the platform default is already 0 — which is the defect the explicit duration was
   * added to fix (a tab tap that teleports is disorienting). So when the user selects
   * 「关闭」 the tab switch degrades to `TAB_SWITCH_MIN_MS` rather than to 0: the user
   * asked for no *decorative* motion, and a tab tap is navigation feedback, not
   * decoration. It is also not the user's speed setting verbatim — see the constant.
   */
  tabSwitchDuration(): number {
    const selected: number = this.duration();
    if (!this.isOn() || selected <= 0) {
      return TAB_SWITCH_MIN_MS;
    }
    return selected;
  }

  /**
   * Whether an indeterminate progress ring should turn.
   *
   * The one part of the sync progress card that is an animation rather than information, so
   * it is the one part the setting has to reach. Answered as a boolean rather than as an
   * effect because `Progress` has no `TransitionEffect` to hand: its whole appearance is
   * static geometry plus, for a ring, a tick count — see `progressTickCount()`.
   *
   * Not a `... | null` method, deliberately: it yields a value a call site passes to
   * `Progress`, not an effect a component drops. The contract — "off makes it stop" — is still
   * owned here, so no page invents its own rule.
   */
  isProgressAnimated(): boolean {
    return this.isOn() && this.duration() > 0;
  }

  /**
   * The ring's tick count: the spinning value when animation is on, `0` when it is off.
   *
   * This is the progress element's equivalent of the `| null` the transition methods return —
   * `Progress` takes a number where a `TransitionEffect` takes an effect, so "no animation" is
   * spelled `PROGRESS_TICK_STATIC` rather than `null`. Keeping the choice here rather than at
   * the call site is what stops a page from picking its own tick count and silently ignoring
   * the setting.
   */
  progressTickCount(): number {
    return this.isProgressAnimated() ? PROGRESS_TICK_LIVE : PROGRESS_TICK_STATIC;
  }
}

/**
 * Shortest permitted tab-switch duration, in ms.
 *
 * 120 ms is the shortest that still reads as a transition rather than a cut, and it is
 * what 「关闭」 gets. It is deliberately not 0 and deliberately not the user's chosen
 * speed: an explicit "off" must not make navigation feel broken, and 100 ms (the fast
 * option) is close enough to 120 that the floor costs the fast user nothing.
 */
export const TAB_SWITCH_MIN_MS: number = 120;

/**
 * The progress ring's tick count when animation is on.
 *
 * A `ProgressType.Ring`'s `scaleCount` **is** its animation: the ring has no value to fill and
 * turns by cycling its period count, so this number is literally how fast it moves. 120 is the
 * SDK's own default (`progress.d.ts`, `ProgressStyleOptions.scaleCount`), which is why the sync
 * ring looks like every other spinner in the app.
 */
export const PROGRESS_TICK_LIVE: number = 120;

/**
 * The tick count when animation is off.
 *
 * `0` is the SDK's "no period" spelling for a ring, and it is what `progressTickCount()` returns
 * once `isProgressAnimated()` is false — there is nothing left for the ring to turn through.
 * Deliberately not a very large number: a huge period still animates, just slowly, and the
 * setting asks for no animation at all. With this value the ring paints a static arc.
 */
export const PROGRESS_TICK_STATIC: number = 0;

/**
 * The singleton. The only instance.
 *
 * `export const Motion = new MotionUtil()` mirrors the reference's
 * `export const customAnimationUtil = new AnimationUtil()`.
 *
 * Usage:
 *
 *     .clickEffect(Motion.clickEffect())
 *     .transition(transitionOrIdentity(Motion.scaleIn(index)))
 *     .edgeEffect(Motion.edgeEffect())
 */
export const Motion: MotionUtil = new MotionUtil();

/**
 * Turn any of `Motion`'s nullable effects into something `.transition()` accepts.
 *
 * ## Why this exists at all
 *
 * The reference hands `null` straight to the framework:
 * `.transition(customAnimationUtil.isScaleTran(index, uiConfig))`. That compiles in
 * ClashBox, but it is **not** what this SDK declares: here the signature is
 * `transition(value: TransitionOptions | TransitionEffect)` (common.d.ts:18966) with no
 * `null` in the union, so the literal port does not type-check. Rather than drop the
 * "returns null when off" contract — which is the whole gate, and what the audit checks —
 * the substitution happens here, once, at the point of use.
 *
 * `TransitionEffect.IDENTITY` is the SDK's own "disables the transition effect"
 * (common.d.ts:5319-5329). It is the framework's spelling of the `null` the reference
 * passes, so the on-screen result is identical: with animation off the component appears
 * directly, with no zero-length animation.
 */
export function transitionOrIdentity(effect: TransitionEffect | null): TransitionEffect {
  if (effect === null) {
    return TransitionEffect.IDENTITY;
  }
  return effect;
}

/**
 * The spring used where a caller needs a bare curve rather than a whole effect.
 *
 * Exported because a `TransitionEffect.animation()` call written outside this file would
 * otherwise pick its own curve, which is how an app ends up with two motions that almost
 * match.
 */
export function motionSpring(): ICurve {
  return curves.springMotion(SPRING_RESPONSE, SPRING_DAMPING);
}
