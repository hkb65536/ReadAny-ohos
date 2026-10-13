/**
 * A list row: leading symbol, title, optional subtitle, optional trailing slot, chevron.
 *
 * A port of ClashBox's `skipRowList` (`components/Common/Common.ets:830`) onto this app's
 * palette plumbing. The point of copying the structure rather than re-inventing it is that
 * the reference implementation's numbers were read off a working device: icon 24, title 16
 * Medium, subtitle 14 secondary, chevron 28, min height 53, padding 12.
 *
 * The card radius is the one number deliberately **not** taken from the reference. ClashBox's
 * row is 20; the HarmonyOS corner-radius spec puts a content container at 16, so this row
 * takes `BORDER_RADIUS_CARD` — an alias of `Theme.RADIUS_CARD` — and is 16. See `Tokens.ets`.
 *
 * ## Two deliberate differences from the reference
 *
 * 1. **Colours come from the app palette, not from resources.** ClashBox reads
 *    `$r('app.color.container_background')` and `$r('sys.color.font_secondary')`, which is
 *    only expressible as a light/dark pair. This app has three themes and the sepia one is
 *    not a system mode, so the palette is passed in as a `@Prop` — the same convention
 *    `SyncSettingsPage`, `ShelfPage` and `AnnotationsPage` already use.
 *
 * 2. **This component does not own `onClick`.** In ClashBox the click is attached to the
 *    wrapping `ListItem` so that the whole card — including the gap-free area between the
 *    chevron and the edge — is the hit area. Keeping the handler with the caller also means
 *    a row cannot accidentally become untappable because a component author forgot to
 *    forward an event. Callers attach `.onClick()` at the call site.
 *
 * The trailing slot is a `@BuilderParam` with an empty default, so a plain row needs no
 * boilerplate and a row with, say, a switch or a progress ring can inject one.
 */

import { ThemePalette, TYPE_BODY, TYPE_SUBTITLE } from '../theme/Theme';
import {
  BORDER_RADIUS_CARD,
  LIST_ITEM_MIN_HEIGHT,
  LIST_ITEM_PADDING,
  ROW_CHEVRON_SIZE,
  ROW_ICON_SIZE,
} from '../theme/Tokens';
import { MOTION_ON_KEY, Motion, transitionOrIdentity } from '../theme/Motion';

/**
 * Space between the four cells of the row, in vp.
 *
 * Kept local rather than added to `Tokens.ets`: ClashBox writes this one inline in its
 * `Row({space: 12})`, so there is no upstream constant to name.
 */
const ROW_SPACE: number = 12;

@Component
export struct ListRow {
  /**
   * The active colour theme.
   *
   * Passed in rather than read from `AppStorage` or a resource: the palette is the only
   * thing that can express all three themes, and a row that read the system colour mode
   * would render system greys under sepia. See `theme/Theme.ets`.
   */
  @Prop palette: ThemePalette;
  /** Leading symbol. Required — every row in this skeleton is icon-led. */
  @Prop icon: Resource;
  /** Primary line, 16 fp Medium. */
  @Prop title: string;
  /** Secondary line, 14 fp. Omitted from the layout entirely when empty. */
  @Prop subtitle: string = '';
  /**
   * Optional trailing content, drawn between the flexible space and the chevron.
   *
   * Defaults to the empty builder below. A builder that emits nothing is correct here: a
   * row with no trailing content must not reserve any width.
   */
  @BuilderParam custom: () => void = this.emptyTrailing;
  /**
   * Row position, for the staggered entrance.
   *
   * Pass the loop index so the rows arrive in sequence; leave it at 0 for a single row or
   * for a list of two or three, where the stagger is invisible anyway.
   */
  @Prop index: number = 0;
  /**
   * The animation switch, mirrored from `AppStorage`.
   *
   * Declared even though `Motion` reads the same key itself: `@StorageLink` is what makes
   * this component re-render when the setting changes, so `.clickEffect()` and
   * `.transition()` below are re-evaluated. Without it, turning animation off would only
   * take effect after some unrelated state change forced a rebuild.
   */
  @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;

  /** Draws nothing. The default for `custom`. */
  @Builder
  private emptyTrailing() {
  }

  build() {
    Row({ space: ROW_SPACE }) {
      SymbolGlyph(this.icon)
        .fontSize(ROW_ICON_SIZE)
        .fontColor([this.palette.foreground])

      Column({ space: 4 }) {
        Text(this.title)
          // `TYPE_SUBTITLE`/`TYPE_BODY` from the shared type scale are exactly the 16/14
          // the reference row uses; naming them means a change to the type scale cannot
          // leave this row behind at the old size.
          .fontSize(TYPE_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.palette.foreground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(TYPE_BODY)
            .fontColor(this.palette.mutedForeground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // Absorbs the slack. With the `Column` above at `layoutWeight(1)` this normally
      // measures zero, which is the intent: the trailing slot, when a caller supplies one,
      // sits against the chevron rather than floating in the middle of the row.
      Blank()

      this.custom()

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(ROW_CHEVRON_SIZE)
        .fontColor([this.palette.foreground])
    }
    .width('100%')
    .borderRadius(BORDER_RADIUS_CARD)
    .constraintSize({ minHeight: LIST_ITEM_MIN_HEIGHT })
    .padding(LIST_ITEM_PADDING)
    // The card colour, and the page behind it is `palette.background`. Do **not** replace
    // this with `systemMaterial` — a system material only knows light/dark, so under the
    // sepia palette it paints the row white instead of `#F5EBD7`, and it takes over the
    // background so a selection state cannot be drawn.
    .backgroundColor(this.palette.card)
    // **The hairline is back, and this one is a correction rather than a preference.** r93
    // removed it (「把内容的边框去掉」) on the arithmetic: `card` on `background` measures
    // 1.143:1 (light), 1.124:1 (dark) and 1.047:1 (sepia), and 1.047:1 was accepted as "a
    // surface you can see". On the device that was wrong in the one theme the number was
    // tightest in — sepia's card is 1.047:1 against its page, and a 1.047:1 step with no
    // edge is not a surface you can see, it is a surface you can *just* measure. The user
    // rejected the result after looking at it (「还是保留边框吧，护眼模式下确实看不清」).
    //
    // So the row carries both: the fill marks it as raised on the palettes where the fill
    // is enough, and the 1 vp edge is what makes it visible on the one where it is not.
    // `tools/verify-themes.mjs` no longer asserts the fill figure as the whole separation —
    // it asserts the edge, and it asserts that the fill is still there underneath it.
    .borderWidth(1)
    .borderColor(this.palette.border)
    .alignItems(VerticalAlign.Center)
    // The click feedback, gated on the user's animation setting.
    //
    // Unconditional until phase 2, with the comment above saying so; `Motion.clickEffect()`
    // returns `null` when animation is off, and `clickEffect` is one of the few SDK
    // methods that genuinely accepts `null` — so the row simply stops compressing under
    // the finger rather than compressing in zero milliseconds.
    //
    // This is the reference's `isClickEffect` (90 call sites there), and it is the single
    // most visible thing the switch controls.
    .clickEffect(this.animationOn ? Motion.clickEffect() : null)
    // The row's own staggered entrance. Applied here rather than by each caller so every
    // list in the app arrives the same way; `transition` is not inherited, so a row that
    // did not carry this would still be covered by a *parent* transition, but only as one
    // block instead of a sequence.
    .transition(transitionOrIdentity(this.animationOn ? Motion.scaleIn(this.index) : null))
  }
}
