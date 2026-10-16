/**
 * Shared layout metrics for the list-and-card skeleton.
 *
 * These are the numbers ClashBox defines in `common/entity/Constants.ets` (verified
 * against that file, not guessed): page-title type, list spacing, the card box, the row's
 * icon and chevron, the trailing scroll space and the default animation duration. They
 * live here so `ui/ListRow.ets` and, from phase 4 on, every page that lays out a list uses
 * one copy of each.
 *
 * ## Relationship to `Theme.ets`
 *
 * `Theme.ets` is the *design-system* module (type scale, spacing scale, radii, palettes,
 * capability gates). This file is the *skeleton* module: the concrete box metrics a row
 * or a page title is built from. The two overlap in exactly two places, and both are
 * handled explicitly rather than by adding a second number that can drift:
 *
 *  - `TAB_CONTENT_TITLE_FONT_SIZE` is the same metric as `Theme.ets`'s `TYPE_TITLE_LARGE`
 *    (30 fp). It is therefore **not** re-declared as a literal; it is derived from
 *    `TYPE_TITLE_LARGE`, so the page title cannot end up at two sizes.
 *  - `BORDER_RADIUS_CARD` is **the same number as** `Theme.ets`'s `RADIUS_CARD` (16), and is
 *    now an alias of it rather than a second literal. It used to be 20 on the strength of
 *    ClashBox's `RowStyle`, which disagreed with this project's own `Theme.ets`; the
 *    HarmonyOS corner-radius spec settled it — a list row is a *content container*, i.e. 16vp.
 *    One `export const` reference, so the two cannot drift apart again. What remains here is
 *    the name ClashBox gives the metric, which is the name the row skeleton reads.
 *
 * Nothing else here duplicates a name that already exists in `Theme.ets`; the constants
 * that merely happen to share a value with something in `Theme.ets` (for example
 * `LIST_ITEM_HEIGHT` = `TAB_CONTENT_TITLE_HEIGHT` = 56) are separate metrics that share a
 * number by coincidence, and are documented as such.
 *
 * Note on the ClashBox names: upstream spells some of these differently
 * (`BORDER_RADIUS_20`, `CONTENT_END_OFFSET_150`, `ANIMATION_DURATION_300`, and
 * `LIST_ITEM_PADDING` as a `Padding` object with only `left`/`right`). The names here are
 * the role-based ones this project's plan settled on, so a name does not have to be
 * changed when a value is; the values are identical.
 */

import { RADIUS_CONTROL, RADIUS_CARD as THEME_RADIUS_CARD, TYPE_TITLE_LARGE } from './Theme';

// ---------------------------------------------------------------------------
// Page title
// ---------------------------------------------------------------------------

/**
 * Page title font size in fp.
 *
 * Derived from `Theme.ets`'s type scale rather than written as `30` a second time: this is
 * the same metric under the name ClashBox gives it, and two literals would eventually
 * disagree.
 */
export const TAB_CONTENT_TITLE_FONT_SIZE: number = TYPE_TITLE_LARGE;

/**
 * Page title bar height in vp.
 *
 * A fixed height, not a minimum: the title bar is the anchor the scrolling list collapses
 * against, so it has to be a known number rather than whatever the text measures.
 */
export const TAB_CONTENT_TITLE_HEIGHT: number = 56;

// ---------------------------------------------------------------------------
// List and card
// ---------------------------------------------------------------------------

/** Gap between two rows of a list, in vp. */
export const LIST_SPACE: number = 10;

/**
 * Height of one list row, in vp.
 *
 * The nominal row height. `LIST_ITEM_MIN_HEIGHT` is the floor that is actually applied:
 * a row with a two-line title is allowed to grow past this, and forcing `height` would
 * clip it.
 */
export const LIST_ITEM_HEIGHT: number = 56;

/**
 * Minimum height of a card, in vp.
 *
 * Applied as `constraintSize({minHeight})`, so the card is at least this tall and taller
 * when its content needs it. ClashBox uses the same floor on its card style.
 */
export const LIST_ITEM_MIN_HEIGHT: number = 53;

/**
 * Card padding, in vp, on all four sides.
 *
 * ClashBox's constant is a `Padding` with only `left`/`right` set; here it is a plain
 * number applied to all sides, which is what its card style actually renders (its rows
 * carry vertical padding from elsewhere). Kept as a number so it can be passed straight to
 * `.padding()`.
 */
export const LIST_ITEM_PADDING: number = 12;

/**
 * Corner radius of a list card, in vp.
 *
 * This used to be 20 on the strength of ClashBox's `RowStyle`, which disagreed with this
 * project's own `Theme.ets` (12). The HarmonyOS corner-radius spec settles it: a list row
 * is a **content container**, which the spec puts at **16vp**. 20vp is reserved for buttons,
 * menus and tabs — things you tap — and 12vp is not one of the five spec values at all.
 *
 * Aliased to `Theme.RADIUS_CARD` rather than repeated, so there is exactly one number and
 * the two files cannot drift apart again. Phase 4 applied it across the pages: the annotation
 * card, the theme-picker card and the two `SyncSettingsPage` panels all use `RADIUS_CARD`
 * (16) now, and the theme-picker swatch moved to `RADIUS_IMAGE` (8) because it is a preview
 * tile rather than a card.
 */
export const BORDER_RADIUS_CARD: number = THEME_RADIUS_CARD;

/** Corner radius of a tappable control (button, menu, tab), per the same spec. */
export const BORDER_RADIUS_CONTROL: number = RADIUS_CONTROL;

// ---------------------------------------------------------------------------
// Row internals
// ---------------------------------------------------------------------------

/**
 * Font size of a row's leading symbol, in vp.
 *
 * Matches the bottom-tab icon size in the platform's tab-bar spec. `Index.ets` used to
 * carry a module-private `SETTINGS_ICON_SIZE` with this same value; it was deleted when the
 * settings rows moved onto `ui/ListRow.ets`, so this is now the only copy.
 */
export const ROW_ICON_SIZE: number = 24;

/** Font size of a row's trailing chevron, in vp. */
export const ROW_CHEVRON_SIZE: number = 28;

// ---------------------------------------------------------------------------
// Popup menu (菜单)
// ---------------------------------------------------------------------------

/**
 * Width of a book's action menu, as a multiple of one shelf card.
 *
 * **A deliberate departure from the menu design guidance's fixed phone width**, written
 * down as one so it does not read as a lost constant. That page
 * (https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/menu-0000001957001877)
 * says 「泛手机统一宽度为固定 224vp」, and this menu *was* exactly that: the same fixed
 * 224 vp, applied to both of the `Menu`'s surface branches. It is not any more, and the
 * reason is the content rather than the guidance — the guidance's 224 vp is the width of a
 * **list** menu, and this menu holds one 删除 row. At 224 vp that row occupied under a
 * third of the surface, so the popup read as a panel floating over the shelf instead of as
 * *this book's* menu. Sizing it off the grid makes it the size of the object it belongs to.
 *
 * The guidance's value is not deleted: `MENU_WIDTH_UNMEASURED` below is still 224 vp, but
 * only as the width used before the grid has reported its area.
 *
 * ## Why this is a ratio and not a number
 *
 * Because the number is computed at build time from the grid the menu opens over —
 * `ShelfPage.cardWidth()` reads the same padding, the same gap and the same column count
 * the `Grid` itself is given — so the menu cannot drift from the shelf the next time one of
 * those changes. A hardcoded 168 would be correct exactly until the grid moved.
 *
 * The arithmetic, for the phone this was measured on (1320 px at 3.375 px/vp, i.e. 391.1 vp
 * of page width, which `shelfColumnsForWidth` puts at 3 columns):
 *
 *   grid content = 391.1 − 2 × 16 (SHELF_GRID_PADDING)  = 359.1 vp
 *   less the gaps = 359.1 − 2 × 12 (SHELF_COLUMNS_GAP)  = 335.1 vp
 *   one card      = 335.1 / 3                           = 111.7 vp
 *   menu          = 1.5 × 111.7                         = 167.6 vp
 *
 * ≈ 168 vp against the guidance's 224 — a quarter narrower, and still wide enough for the
 * row it holds. Measured off that device's own screenshot at the installed 224 vp, the
 * row's ink is 73 vp from the menu's left edge: a 17 vp leading inset, a 15 vp trash glyph,
 * a 10 vp gap and the 31 vp 「删除」 label — 90 vp if the trailing inset mirrors the leading
 * one. Against 168 vp that leaves ~78 vp of slack, so the label cannot truncate and the
 * glyph cannot collide with it.
 */
export const MENU_WIDTH_CARD_RATIO: number = 1.5;

/**
 * The menu width used before the grid has reported its area, in vp.
 *
 * The menu guidance's own phone width, kept **only** as the fallback for the frame in which
 * there is no geometry to derive a card from — the measured path supersedes it on the first
 * layout pass. It is unreachable in practice: the only control that opens this menu is the
 * `⋯` inside the grid, so by the time a menu can be built the grid has been measured. It
 * exists so that a popup is never built at a width derived from zero.
 */
export const MENU_WIDTH_UNMEASURED: number = 224;

/**
 * Diameter of the ⋯ control that opens a book's menu, in vp.
 *
 * The reference's control is a small circular chip sitting on the cover's bottom-right
 * corner; 32vp is that chip at a size the icon inside it can breathe at.
 */
export const MENU_TRIGGER_SIZE: number = 32;

/**
 * Font size of the `⋯` glyph inside that chip, in vp.
 *
 * The reference draws its `⋯` at 18; at 32 vp the chip has 7 vp of padding around it,
 * which is what keeps the three dots from touching the corner radius.
 */
export const MENU_TRIGGER_GLYPH_SIZE: number = 18;

/**
 * Touch target of that control, in vp.
 *
 * `MIN_TAP_TARGET`: a 32vp chip is below the 48vp guidance minimum, so the chip is drawn
 * inside a transparent box of this size and the *box* carries the tap handler. The
 * visible control stays the reference's small chip; the target a finger actually has to
 * hit is the guidance's 48.
 */
export const MENU_TRIGGER_TOUCH: number = 48;

/**
 * How far *inside* the cover's bottom-right corner the control sits, in vp.
 *
 * The sign is the whole point and it lives at the call site, not here: the control's box is
 * aligned to the cover `Stack`'s bottom-right corner, so this value has to be applied as a
 * **negative** offset. r108 and earlier applied a positive one (`MENU_TRIGGER_SIZE / 2`),
 * which is the shape ReadAny's card uses — the chip's centre on the cover's bottom edge —
 * and which on the device put 10 vp of the 32 vp chip onto the title line 6 vp below the
 * cover and pushed 32 vp of the 48 vp tap box out of the cover entirely. The user's report
 * on that build: 「书籍的操作按钮会超出书籍封面的范围，和文字重叠」.
 *
 * 8 vp is the same gap the menu opens with (`MENU_TRIGGER_GAP`), so the control's inset and
 * its popup's gap are one number's worth of air rather than two.
 *
 * **Containment is arithmetic, and `verify-book-menu.mjs` evaluates it.** The binding
 * dimension is the cover's *width* — it is `aspectRatio(0.7)`, so its height is
 * `width / 0.7`, i.e. 1.43× wider than tall. The box is inside the cover at a given card
 * width exactly when `MENU_TRIGGER_INSET + MENU_TRIGGER_TOUCH <= card width`
 * (8 + 48 = 56 vp). The check re-derives the card width from the shelf's own padding, gap
 * and column breakpoints and holds that inequality at every breakpoint and at the reference
 * phone's width.
 */
export const MENU_TRIGGER_INSET: number = 8;

/**
 * Gap between the `⋯` control and the menu it opens, in vp.
 *
 * The reference's own number: it positions its popup at `anchor.y + anchor.height + 8`
 * (`packages/app-expo/src/components/library/BookCardActionSheet.tsx:158`).
 */
export const MENU_TRIGGER_GAP: number = 8;

// ---------------------------------------------------------------------------
// Reading progress on the cover
// ---------------------------------------------------------------------------

/**
 * Thickness of the reading-progress bar drawn along the bottom edge of a book's cover, in vp.
 *
 * The bar used to be a **sibling under the caption** in the cell `Column`,
 * `Progress({ ... type: ProgressType.Linear }).width('100%').height(3)` with no `.style()`. r117
 * moved it into the cover `Stack` at the user's request (「把主界面里显示阅读进度的那个进度条移到
 * 书的封面上，可以再细一点，放在封面的最下面」) and this token is both its height and its stroke.
 *
 * ## The old bar was 4 vp of ink, not 3 — which is why this token has to set the stroke
 *
 * `LinearStyleOptions.strokeWidth` defaults to **4.0 vp**
 * (`ets/component/progress.d.ts`, `LinearStyleOptions`: "Stroke width of the progress indicator.
 * Default value: **4.0vp**"). The old call site set only the component's height, so its **node**
 * was 3 vp — the r108 layout dump measures exactly that, `10.125 px` at 3.375 px/vp — while the
 * indicator actually painted inside it was the 4 vp default, overflowing its own box by 0.5 vp top
 * and bottom. **「可以再细一点」 therefore could not be delivered by shrinking the box**: a bar with
 * `.height(2)` and no `.style()` would still have been drawn 4 vp thick. The token is read twice at
 * the one call site — `.height(COVER_PROGRESS_HEIGHT)` and
 * `.style({ strokeWidth: COVER_PROGRESS_HEIGHT })` — so the box and the ink cannot drift apart, and
 * `verify-book-menu.mjs` asserts both spellings come from this name.
 *
 * ## Why 2
 *
 * Half of the 4 vp that was really on screen, so the request is answered against what the user saw
 * rather than against the node's nominal height. On the reference device that is 6.75 px — still
 * four times a comfortable hairline, and legible as a fraction of a bar 159.6 vp tall. It also has
 * to stay **at or below `MENU_TRIGGER_INSET`**: the `⋯` control's 48 vp tap box is anchored to the
 * cover's bottom-right corner and inset 8 vp inward, so its bottom edge sits `MENU_TRIGGER_INSET`
 * above the cover's bottom edge, and a bar thicker than that would run into it. 2 ≤ 8 leaves 6 vp of
 * clear air, and the inequality is asserted rather than asserted-in-prose.
 *
 * ## It cannot move the row
 *
 * The bar is a child of the cover `Stack`, which is `width('100%')` + `aspectRatio(0.7)`: its height
 * comes from its width, and an overlay adds none. The cover is `RADIUS_IMAGE`-rounded and now
 * `clip(true)` for the bar's sake — a full-width bar flush with the bottom edge would otherwise
 * paint its top row up to ~2.7 vp beyond the rounded silhouette at each end.
 */
export const COVER_PROGRESS_HEIGHT: number = 2;

// ---------------------------------------------------------------------------
// Coverless placeholder
// ---------------------------------------------------------------------------

/**
 * Font size of the title drawn inside a coverless book's placeholder box, in fp.
 *
 * The placeholder used to draw **one** character — `book.title.substring(0, 1)` — at 28 fp.
 * The user asked for the whole title instead at 「字号比现在小一点」, so the size is a step
 * down and the *content* is what grew. r114 took that step to 24 fp; **r115 took a second one,
 * to 12 fp, at the user's request — 「封面上的书名可以再小一点，先取现在的50%我看看。」**
 *
 * ## This is below the large-text exemption, deliberately, and it is a recorded departure
 *
 * `placeholderForeground` on `placeholderSurface` measures 4.636:1 in the light theme,
 * 5.489:1 in dark and **3.916:1 in sepia**. Light and dark clear the project's 4.5:1
 * body-text floor. **Sepia's does not, and it never has.** What made sepia legitimate at
 * 24 fp was the WCAG large-text exemption — 3:1 rather than 4.5:1 — and that exemption is
 * about **font size**. r114 chose 24 fp as the smallest size at which the exemption still
 * applied, and `tools/verify-themes.mjs` asserted it stayed at or above that threshold.
 *
 * **At 12 fp the exemption no longer applies.** The size was reduced at the user's request,
 * knowing the cost: sepia's placeholder pair is now **below** the 4.5:1 floor with no
 * exemption to cover it, so it is a genuine shortfall rather than an exempted one. That is a
 * recorded, deliberate departure and not an oversight. The alternative is a new sepia palette
 * value, which is the user's call and not a code round's — this project has already declined
 * an unrequested palette change once, on the grounds that sepia was never reported as broken.
 *
 * `tools/verify-themes.mjs` carries the departure in exactly this form. The threshold check
 * that used to pin the size *above* 24 fp could not survive the request — its premise is now
 * false by design — so it was re-pointed rather than deleted: it now asserts the size is a
 * named token, that sepia's pair measures below 4.5:1, and that **this paragraph is still
 * here**. The invariant is "the project knows this is below the floor and has recorded why",
 * which is stronger than the old numeric bound: at 24 fp every trace of the *reason* could
 * have been deleted while the number stayed legal.
 *
 * ## What 12 fp buys, in characters
 *
 * The numbers below are the reference device's **measured** ones, not estimates. The layout
 * dump r108 took of the installed build gives one card as 377 × 539 **px** (111.7 × 159.7 vp —
 * 377 / 0.7 = 539 exactly, which is the aspect ratio doing its job), and it gives two line
 * boxes at two different sizes, which is what fixes the font's line-height ratio rather than
 * assuming one: the 12 fp caption's box is 47 px tall (**1.161 em**) and the 28 fp placeholder
 * glyph's box is 111 px tall (1.175 em). At 12 fp the size in question is the one that was
 * measured **directly**, so the ratio used is the 12 fp box's own, 1.161 em; the 28 fp figure
 * is carried as the conservative bound, and both give the same line count below.
 *
 *   inner box (SPACE_XS of padding)  350 × 512 px        (103.7 × 151.7 vp)
 *   one CJK glyph is a full em       12 fp = 40.5 px
 *   characters per line              floor(350 / 40.5)                  = 8
 *   one line box                     1.161 × 40.5                      = 47.0 px
 *                                    (1.175 × 40.5 = 47.6 px, conservative)
 *   lines the box itself could hold  floor(512 / 47.0)                  = 10
 *   lines actually drawn             min(10, PLACEHOLDER_TITLE_LINES)   = 5
 *   capacity                         8 × 5                             = 40 CJK characters
 *
 * **`PLACEHOLDER_TITLE_LINES` is now the binding constraint, not the box.** At 24 fp the box
 * ran out after five lines (floor(512 / 95.2) = 5), so the clamp and the geometry said the
 * same thing; at 12 fp the box fits ten and the clamp is the only thing stopping the block at
 * five. The block is 5 × 47.0 = 235 px inside 512 px, so it is nowhere near clipped and the
 * clamp is not protecting against an over-tall text block — it is only bounding how much of a
 * very long title is shown.
 *
 * 40 characters is more than three times r114's 20 and far more than any title this shelf has:
 * `斗罗大陆2绝世唐门足交传说` is 13 characters and now takes two of the five lines, and
 * `斗罗大陆III龙王传说` is 11 and also takes two. **A future round may well want fewer lines**
 * — five is now generous rather than tight — but r115 did not change the count, because the
 * arithmetic raises no problem and five is still the value that keeps every real title whole.
 *
 * ## What this must not do
 *
 * The cover box is `width('100%')` + `aspectRatio(0.7)`, so its height is width-derived and
 * the grid's row heights depend on it. A **smaller** glyph can only shrink the `Text`'s
 * measured height (476 px → 235 px) against a box that is 539 px either way, so the rows
 * cannot move — but the reason the clamp exists is unchanged, and neither `maxLines` nor the
 * clip may be dropped on the grounds that the text is small now.
 */
export const PLACEHOLDER_TITLE_SIZE: number = 12;

/**
 * How many lines of that title the placeholder will draw at most, in lines.
 *
 * Set from the measured box rather than from the appetite: at 24 fp, five lines of the
 * device's own measured line box was 5 × 95.2 = 476 px inside the 512 px the padded box
 * offers. That 36 px of slack is what made five the largest count that still left the block
 * centred with air above and below it; four would have left 136 px unused *and* would have
 * truncated a 17-character title the box could actually hold.
 *
 * **r115 left this at five while the glyph halved.** At 12 fp the same five lines are
 * 5 × 47.0 = 235 px, and the box could hold ten — so the clamp, not the box, is now what ends
 * the block (the full arithmetic is on `PLACEHOLDER_TITLE_SIZE`). It is deliberately
 * unchanged: the binding constraint moving does not make the block too tall, and lowering the
 * count would truncate titles the box can hold for a benefit nobody asked for this round.
 *
 * Its other job is structural, and it is why this is a clamp rather than a hope: `maxLines`
 * bounds the `Text`'s **measured** height to that many line boxes, and the placeholder
 * `Column` clips, so a title of any length can neither move the box nor paint outside it. The
 * box cannot move regardless — it is `width('100%')` + `aspectRatio(0.7)`, so its height comes
 * from its width and not from its children (measured: 377 / 0.7 = 539 px) — but the clamp is
 * what keeps the *text* inside the cover rather than merely the cover the right size. **A
 * smaller glyph strengthens this rather than relaxing it**: the block is 476 px at 24 fp and
 * 235 px at 12 fp, against a box that is 539 px either way.
 */
export const PLACEHOLDER_TITLE_LINES: number = 5;

// ---------------------------------------------------------------------------
// Page frame
// ---------------------------------------------------------------------------

/**
 * Default animation duration in ms.
 *
 * `Index.ets` already has a module-private `TAB_SWITCH_DURATION_MS` with the same value for
 * the tab-content transition. That one is local to the shell; this is the default used by
 * transitions added from phase 2 on.
 */
export const ANIMATION_DURATION: number = 300;
