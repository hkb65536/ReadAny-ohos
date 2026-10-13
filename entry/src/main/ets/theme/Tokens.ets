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
 * Gap between the `⋯` control and the menu it opens, in vp.
 *
 * The reference's own number: it positions its popup at `anchor.y + anchor.height + 8`
 * (`packages/app-expo/src/components/library/BookCardActionSheet.tsx:158`).
 */
export const MENU_TRIGGER_GAP: number = 8;

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
