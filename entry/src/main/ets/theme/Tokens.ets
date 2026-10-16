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
// Coverless placeholder
// ---------------------------------------------------------------------------

/**
 * Font size of the title drawn inside a coverless book's placeholder box, in fp.
 *
 * The placeholder used to draw **one** character — `book.title.substring(0, 1)` — at 28 fp.
 * The user asked for the whole title instead at 「字号比现在小一点」, so the size is a step
 * down and the *content* is what grew.
 *
 * ## Why 24 and not less
 *
 * Because of `placeholderForeground` on `placeholderSurface`, which measures 4.636:1 in the
 * light theme, 5.489:1 in dark and **3.916:1 in sepia**. The light and dark pairs clear the
 * project's 4.5:1 body-text floor; sepia's does not, and holding sepia at 4.5:1 would mean
 * changing a palette value — a change this project already declined to make once, on the
 * grounds that sepia was never reported as broken (see the floors block in
 * `tools/verify-themes.mjs`). What keeps sepia legitimate is the WCAG large-text exemption:
 * at 3:1 a *large* glyph is held to the lower floor, and 24 fp is the size at which that
 * exemption is written (18 pt = 24 px in the same convention `verify-themes.mjs` uses to say
 * "the placeholder initial is far larger"). So 24 fp is not a taste preference: it is the
 * smallest size at which this token can move without dragging a palette value with it, and
 * `verify-themes.mjs` now asserts that it stays at or above that threshold.
 *
 * ## What 24 fp buys, in characters
 *
 * The numbers below are the reference device's **measured** ones, not estimates. The layout
 * dump r108 took of the installed build gives one card as 377 × 539 **px** (111.7 × 159.7 vp —
 * 377 / 0.7 = 539 exactly, which is the aspect ratio doing its job), and it gives two line
 * boxes at two different sizes, which is what fixes the font's line-height ratio rather than
 * assuming one: the 12 fp caption's box is 47 px tall (1.161 em) and the 28 fp placeholder
 * glyph's box is 111 px tall (1.175 em). Using the larger of the two, 1.175 em:
 *
 *   inner box (SPACE_XS of padding)  350 × 512 px        (103.7 × 151.7 vp)
 *   one CJK glyph is a full em       24 fp = 81 px
 *   characters per line              floor(350 / 81)                    = 4
 *   one line box                     1.175 × 81                         = 95.2 px
 *   lines that fit                   floor(512 / 95.2)                  = 5
 *   capacity                         4 × 5                             = 20 CJK characters
 *
 * 20 is not a round number chosen in advance; it is what the box holds. It covers every title
 * this round was reported against — `斗罗大陆2绝世唐门足交传说` is 13 characters and
 * `斗罗大陆III龙王传说` is 11 — and a title longer than that is ellipsized after
 * `PLACEHOLDER_TITLE_LINES` lines, which is the stated compromise: the alternative is a
 * smaller glyph, and a smaller glyph costs sepia its contrast exemption (above).
 */
export const PLACEHOLDER_TITLE_SIZE: number = 24;

/**
 * How many lines of that title the placeholder will draw at most, in lines.
 *
 * Set from the measured box rather than from the appetite: five lines of 24 fp at the
 * device's own measured line box is 5 × 95.2 = 476 px inside the 512 px the padded box offers.
 * That 36 px of slack is what makes five the largest count that still leaves the block centred
 * with air above and below it; four would leave 136 px unused *and* would truncate a
 * 17-character title the box can actually hold.
 *
 * Its other job is structural, and it is why this is a clamp rather than a hope: `maxLines`
 * bounds the `Text`'s **measured** height to that many line boxes, and the placeholder
 * `Column` clips, so a title of any length can neither move the box nor paint outside it. The
 * box cannot move regardless — it is `width('100%')` + `aspectRatio(0.7)`, so its height comes
 * from its width and not from its children (measured: 377 / 0.7 = 539 px) — but the clamp is
 * what keeps the *text* inside the cover rather than merely the cover the right size.
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
