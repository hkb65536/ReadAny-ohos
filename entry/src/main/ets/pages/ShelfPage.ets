import { InkBoatError } from 'core';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import type { ThemePalette } from '../theme/Theme';
import type { Book, BookSort } from 'data';
import { BookSort as Sort } from 'data';
import {
  FLOATING_BAR_CLEARANCE,
  menuMaterialOption,
  menuTriggerBackground,
  RADIUS_CONTROL,
  RADIUS_IMAGE,
  shelfColumnsForWidth,
  SPACE_M,
  SPACE_S,
  SPACE_XS,
  TYPE_BODY,
  TYPE_CAPTION,
  TYPE_SUBTITLE,
  TYPE_TITLE,
} from '../theme/Theme';
import {
  MENU_TRIGGER_GAP,
  MENU_TRIGGER_GLYPH_SIZE,
  MENU_TRIGGER_INSET,
  MENU_TRIGGER_SIZE,
  MENU_TRIGGER_TOUCH,
  MENU_WIDTH_CARD_RATIO,
  MENU_WIDTH_UNMEASURED,
  PLACEHOLDER_TITLE_LINES,
  PLACEHOLDER_TITLE_SIZE,
} from '../theme/Tokens';
import { MOTION_ON_KEY, Motion, transitionOrIdentity } from '../theme/Motion';

/**
 * The shelf `Grid`'s own horizontal metrics, in vp.
 *
 * Named rather than left as literals at the `Grid`, because the per-book action menu's
 * width is **derived from them**: one card is `(gridWidth − 2 × padding − gap × (columns −
 * 1)) / columns`, and the menu is `MENU_WIDTH_CARD_RATIO` of that. Two copies of "16" and
 * "12" — one on the grid and one in the arithmetic — is exactly how a derived value stops
 * matching the thing it was derived from, which is the failure this naming prevents.
 */
const SHELF_GRID_PADDING: number = 16;
const SHELF_COLUMNS_GAP: number = 12;

/**
 * Shelf: the book grid.
 *
 * Reads through the repository rather than holding books in a global store, so a
 * change made anywhere (import, sync pull, deletion) is visible by reloading
 * rather than by broadcasting an event. Reloading a few hundred rows from SQLite
 * is cheap; keeping two copies of the library in step is not.
 *
 * ## The per-book action menu
 *
 * Each cover carries a `⋯` control on its bottom-right corner, which opens a `Menu`
 * (`bindMenu`) holding this round's single action — 删除. The menu follows the
 * HarmonyOS menu guidance
 * (https://developer.huawei.com/consumer/cn/doc/doccenter-ux-design/menu-0000001957001877)
 * in everything except its width. The guidance's 「泛手机统一宽度为固定 224vp」 is a *list*
 * menu's width; this menu is one row, so it is `MENU_WIDTH_CARD_RATIO` (1.5) × one card of
 * the grid it opens over — computed at build time by `menuWidth()` from the grid's own
 * padding, gap and column count, so it cannot drift from that grid. `theme/Tokens.ets`
 * records the departure and the arithmetic. The rest is the guidance's: the item as
 * leading symbol + label,
 * hairline separators between items (`menuItemDivider`), the destructive entry in the
 * palette's own red, and the 沉浸光感 material handed to the framework through the
 * `bindMenu` **options** object (`menuOptions` / `menuMaterialOption` in
 * `theme/Theme.ets`) rather than as a `systemMaterial` attribute on the `Menu`. The
 * attribute is refused outside a Navigation title bar or a bottom TabBar — the device
 * logs `Material inactive: out of scope` and drops it — while a menu's own options field
 * is served page-wide. `menuOptions` records the log line and the declarations.
 *
 * The `⋯` and the menu are modelled on ReadAny's book-card menu
 * (`packages/app-expo/src/components/library/BookCardActionSheet.tsx`): the control sits on
 * the cover's bottom-right corner, and the menu opens below it, right-aligned to it, which
 * is what places it to the control's lower-left. `Placement.BottomRight` is that position,
 * and the `offset` of 8 vp below the control is the reference's own gap.
 *
 * **The control is inside the cover, not straddling its edge.** The reference hangs half of
 * it over the cover's bottom edge; on the device that put 10 vp of a 32 vp chip on the title
 * line below and pushed the 48 vp tap box 32 vp out of the cover — 「书籍的操作按钮会超出书籍
 * 封面的范围，和文字重叠」. It is now anchored to the cover's bottom-right corner and inset 8 vp
 * *inward* from it, so it is contained at every card width; `coverMenuTrigger` carries the
 * arithmetic.
 *
 * ## Deleting
 *
 * 删除 does not delete anything by itself: it opens the confirmation ReadAny shows,
 * with the same wording and the same checkbox, and the actual work happens in the
 * shell (`onDelete` → `Index.deleteBookFromShelf`), because the file that has to go
 * after the row lives behind `AppCore`. The two modes the checkbox chooses between are
 * ReadAny's two modes, and they are **not** interchangeable — see the confirmation
 * builder below and `Books.softDeleteBook`.
 */
@Component
export struct ShelfPage {
  @Link books: Book[];
  @Prop loading: boolean;
  /**
   * The active colour theme.
   *
   * This page used `this.palette.background`, which follows the *system*
   * colour mode rather than the app's palette. With sepia mapped to a light system mode
   * the page came out white, and with the dark theme it came out pure black — both
   * measurably different from the theme background, which is what the top and bottom
   * strips showed.
   */
  @Prop palette: ThemePalette;
  /**
   * The gesture navigation bar's height in vp, handed down by the shell.
   *
   * The floating tab bar floats **over** this grid, and the grid reserves the bar's painted box at the
   * end of its scroll range: `FLOATING_BAR_CLEARANCE` **plus this inset**, unchanged since r107. The
   * shell is the only place that reads the window (`Index.resolveShellInsets`); this page composes the
   * number it is given with the design clearance rather than looking anything up. 0 is the r106
   * geometry, which is why it is the default.
   *
   * **r109 moved that value, and did not re-derive it.** r107 justified the inset by saying the bar's
   * gradient mask moved up with the capsule; the device contradicts that (the mask is the bottom
   * 32 vp of the tab area — below the capsule — and did not move when `barBottomMargin` went 8 -> 36),
   * so the justification recorded here is deliberately not that one. The value is kept because it is
   * the reserved distance r107 was measured with, and because the fix this round was to move the term
   * out of `padding` (a `Grid` will not draw a child that begins inside a padding band) and into
   * `contentEndOffset`, where the same distance costs nothing visually. `AnnotationsPage`'s copy of
   * this inset was reverted, because a `List` clips at `ContentClipMode.CONTENT_ONLY` and never
   * needed it — see that file.
   */
  @Prop bottomInsetVp: number = 0;
  /** Search text, applied to title and author by the repository query. */
  @Link search: string;
  @Link sort: BookSort;

  onImport: () => Promise<void> = async (): Promise<void> => {};
  onOpen: (book: Book) => void = (): void => {};
  onReload: () => Promise<void> = async (): Promise<void> => {};
  /**
   * Perform an already-confirmed deletion of one book.
   *
   * Injected for the same reason `toFileUri` is: the database write and the file
   * unlink are the data layer's business, and this page must not be the second place
   * that decides the order they run in. `Index.deleteBookFromShelf` is the
   * implementation, and it is written so that the row is committed **before** the file
   * is removed — a page-level reimplementation could get that backwards and lose a
   * book on a crash.
   *
   * `preserveData` is ReadAny's checkbox: `true` keeps the notes, highlights and
   * reading history (a soft delete the desktop can see), `false` removes the book and
   * its annotations for good. The implementation must not throw: this page closes the
   * confirmation when it returns, and a throw would leave the user looking at a
   * dismissed dialog with no idea what happened. Failures are reported by the shell.
   */
  onDelete: (book: Book, preserveData: boolean) => Promise<void> =
    async (book: Book, preserveData: boolean): Promise<void> => {};
  /**
   * Turn a sandbox-relative path into a `file://` URI.
   *
   * Injected rather than reimplemented here: the sandbox root and the directory
   * layout are the storage layer's knowledge, and a second copy of `books/` /
   * `covers/` in the UI would be one more place to update.
   */
  toFileUri: (relativePath: string) => string = (relativePath: string): string => '';

  /** Cover file URIs, keyed by book id, so the grid does not rebuild paths. */
  @State private coverUris: Map<string, string> = new Map<string, string>();
  /**
   * Column count, recomputed from the measured content width.
   *
   * A fixed 3 columns wastes a tablet and cramps a small phone; the breakpoints
   * live in the theme so the shelf and any future grid agree on them.
   */
  @State private columns: number = 3;
  /**
   * The `Grid`'s measured width in vp, its own horizontal padding included.
   *
   * Recorded because the action menu's width is derived from the grid rather than fixed:
   * `cardWidth()` turns this, `columns` and the two metric constants above into one card,
   * and the menu is `MENU_WIDTH_CARD_RATIO` of those. `0` means "not measured yet" — the
   * grid reports its area on the first layout pass, which always precedes the `⋯` that can
   * open a menu.
   *
   * `onAreaChange` reports the component's own box, padding included, and that is also the
   * width `shelfColumnsForWidth` is applied to — so the column count and this number come
   * off one measurement and cannot disagree about which width is meant.
   */
  @State private gridWidth: number = 0;
  /**
   * Which book's action menu is open, by id. Empty means none is.
   *
   * `bindMenu`'s controlled form takes one boolean, so the *open book* is the state and
   * the boolean is derived from it: `this.menuBookId === book.id`. That is what keeps
   * two cells from both believing their menu is open, and it is why the id is stored
   * rather than a `Set` of open menus or a per-cell flag.
   */
  @State private menuBookId: string = '';
  /**
   * The book whose deletion has been asked for and not yet answered.
   *
   * Kept on the page rather than passed to the confirmation builder, because the
   * builder is a method of this component and reads this state directly — which is what
   * keeps the confirmation showing the *current* book and the *current* palette instead
   * of a snapshot taken when a dialog controller was built.
   */
  @State private pendingDelete: Book | undefined = undefined;
  /**
   * Whether the deletion confirmation is showing.
   *
   * Bound separately from `pendingDelete`, exactly as `AnnotationsPage` binds its sheet
   * separately from the item being edited: `bindSheet` takes a boolean, and an object
   * identity is not something it can observe.
   */
  @State private confirmOpen: boolean = false;
  /**
   * 「保留笔记和阅读统计」 — ReadAny's checkbox, and its default.
   *
   * **`true` is the reference's default**, set when the dialog opens and reset to `true`
   * every time a new one opens (`BookCard.tsx:79` initialises it, `:123` resets it).
   * That default is the safer of the two modes and it is not a cosmetic detail: the two
   * modes leave the user's data in completely different states, which is why the
   * checkbox is on screen rather than assumed.
   */
  @State private preserveData: boolean = true;
  /** True while a confirmed deletion is running, so one tap cannot become two. */
  @State private deleting: boolean = false;
  /**
   * The animation switch, mirrored from `AppStorage`.
   *
   * Declared so this component re-renders when the setting changes — that is what
   * re-evaluates the cell transitions and the grid's edge effect below.
   */
  @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;
  /**
   * The menu's material, and the palette it was resolved for.
   *
   * Resolved through the theme module's `menuMaterialOption` rather than built here, and
   * memoised because the answer can only change with the palette. `undefined` is not a
   * failure: it is the opaque path, and both the menu builder and `menuOptions` have a
   * branch for it.
   */
  private menuMaterial: Object | undefined = undefined;
  private menuMaterialMode: string = '';

  aboutToAppear(): void {
    this.refreshCovers();
  }

  /**
   * The material for the menu, resolved once per palette.
   *
   * A memo rather than a call per render: the option object is only a description, but
   * building one for every cell of a thirty-book grid on every render would be work done
   * to throw away. The key is the palette's mode, so switching theme produces a new
   * option tinted with the new palette instead of keeping the old one.
   *
   * Both readers — `menuOptions` and `bookActionMenu` — go through this one function, so
   * the options object and the `Menu` component can never disagree about whether this run
   * has a material. If they could, the menu would be transparent with nothing painting
   * it, or painted twice.
   */
  private menuMaterialFor(): Object | undefined {
    if (this.menuMaterialMode !== this.palette.mode) {
      this.menuMaterial = menuMaterialOption(this.palette);
      this.menuMaterialMode = this.palette.mode;
    }
    return this.menuMaterial;
  }

  /**
   * The trash symbol, in this palette's destructive red.
   *
   * Built in statements rather than as one fluent expression: `SymbolGlyphAttribute`'s
   * methods are declared to return `SymbolGlyphAttribute`, so a chained expression on a
   * `SymbolGlyphModifier` widens to the base type and will not assign back to it.
   */
  private deleteSymbol(): SymbolGlyphModifier {
    const modifier: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash'));
    modifier.fontColor([this.palette.destructive]);
    modifier.fontSize(MENU_TRIGGER_GLYPH_SIZE);
    return modifier;
  }

  /**
   * Open the confirmation for one book.
   *
   * The menu is closed first, which is what the reference does
   * (`BookCardActionSheet.tsx:128-132`): the menu's own `aboutToDisappear` also clears
   * `menuBookId`, and doing it here as well means the state is already correct if the
   * popup's callback is not delivered.
   *
   * The checkbox is reset to its default on every open, not remembered from the last
   * deletion: the reference resets it, and a destructive choice that persists from a
   * previous book is the kind of default a user cannot see.
   */
  private askDelete(book: Book): void {
    this.menuBookId = '';
    this.pendingDelete = book;
    this.preserveData = true;
    this.confirmOpen = true;
  }

  /**
   * Run the deletion the user confirmed, then close the confirmation.
   *
   * `onDelete` owns the ordering of the write and the unlink; this method only owns the
   * sheet's lifecycle. The guard makes a double tap a no-op rather than two deletes.
   */
  private async confirmDelete(): Promise<void> {
    const book: Book | undefined = this.pendingDelete;
    if (book === undefined || this.deleting) {
      return;
    }
    this.deleting = true;
    try {
      await this.onDelete(book, this.preserveData);
    } finally {
      // In `finally` so a shell that does throw cannot leave the confirmation stuck on
      // screen with a dead 删除 button.
      this.deleting = false;
      this.confirmOpen = false;
      this.pendingDelete = undefined;
    }
  }

  /**
   * ArkUI's `Image` needs a `file://` URI, not a sandbox path.
   *
   * `coverUrl` is stored relative to the sandbox so it stays valid across app
   * updates and matches what the sync layer expects; the conversion happens once
   * here rather than on every render.
   */
  private refreshCovers(): void {
    const map: Map<string, string> = new Map<string, string>();
    for (const book of this.books) {
      if (book.coverUrl.length > 0) {
        const uri: string = this.toFileUri(book.coverUrl);
        if (uri.length > 0) {
          map.set(book.id, uri);
        }
      }
    }
    this.coverUris = map;
  }

  @Builder
  private bookCell(book: Book) {
    Column({ space: 6 }) {
      // `BottomEnd` is for the `⋯` below: the cover fills the box either way, so the
      // alignment only decides where the one child that is *not* full-size lands.
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.coverUris.has(book.id)) {
          Image(this.coverUris.get(book.id))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            // A cover is an **image**, which the corner-radius spec puts at 8vp
            // (`RADIUS_IMAGE`). It was a bare `8` — the right number, but with no stated
            // role, so the next reader could not tell it from a coincidence.
            .borderRadius(RADIUS_IMAGE)
        } else {
          // A placeholder rather than nothing: an empty slot makes the grid look
          // broken, and a book with no cover is a normal case.
          //
          // ## The whole title, not its first letter
          //
          // This used to draw **one character** of the title — a single `substring` call, kept
          // deliberately unspelled here because `verify-book-menu.mjs` asserts that form's
          // absence over the raw file, comments included — at 28 fp, one enormous initial per
          // coverless book. The user's report on the installed build is the argument against
          // it: a shelf of coverless books then reads as a wall of letters that does not name
          // anything, and the title below the box is 12 fp and truncated. The full title goes
          // in the cover instead, at `PLACEHOLDER_TITLE_SIZE` — one step down from the old 28,
          // which is what 「字号比现在小一点」 asks for while the *text* is what got longer, and
          // then halved again by r115 on the same request repeated: 「封面上的书名可以再小一点，
          // 先取现在的50%我看看。」 The second step is a deliberate departure from the project's
          // 4.5:1 body-text floor in the sepia theme and is recorded on the token itself.
          //
          // ## Why this cannot move the cover box
          //
          // The box is `aspectRatio(0.7)` and the grid's row heights depend on it, so
          // nothing here may grow it. Two things guarantee that, and neither is a promise:
          //
          //  - `maxLines(PLACEHOLDER_TITLE_LINES)` bounds the `Text`'s own measured height
          //    to that many line boxes, so `justifyContent(FlexAlign.Center)` has a bounded
          //    child to centre, and
          //  - `clip(true)` bounds what can be *painted* to this box even if a font's line
          //    box is taller than the arithmetic in `Tokens.ets` assumed.
          //
          // `padding(SPACE_XS)` is the horizontal half that matters: the `Text` is
          // `width('100%')` of the padded column, and that width is what decides how many
          // characters fit per line (see `PLACEHOLDER_TITLE_SIZE`). The vertical half is
          // slack — the block is centred in it — so the padding is one number rather than
          // an asymmetric object.
          Column() {
            Text(book.title.length > 0 ? book.title : '未命名')
              .fontSize(PLACEHOLDER_TITLE_SIZE)
              // `placeholderForeground`, not `mutedForeground`: the surface below is the
              // placeholder's own and is darker than `muted` in the light theme, which the
              // shared muted text colour does not survive (3.42:1). This pair measures
              // 4.64:1 light / 5.49:1 dark / 3.92:1 sepia — and **since r115 the sepia figure
              // is below the 4.5:1 floor with no large-text exemption covering it**, because
              // the glyph is now 12 fp. That is a recorded, deliberate departure argued on
              // `PLACEHOLDER_TITLE_SIZE`; it is not a bug and not a colour to "fix" here.
              .fontColor(this.palette.placeholderForeground)
              // Centre-aligned because the box is a cover and the title sits on it like a
              // cover's own lettering. It is also what keeps a *full* line off the 8 vp
              // corner arc: a line of n characters is inset by (inner width − n × size) / 2.
              // At r115's size that is eight 12 fp characters, (350 − 324) / 2 = 13 px ≈ 3.9 vp
              // of padding plus the centring slack, not zero — the same inset the four 24 fp
              // characters gave, because eight half-size glyphs are as wide as four full ones.
              .textAlign(TextAlign.Center)
              .maxLines(PLACEHOLDER_TITLE_LINES)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              // Bounded, or the ellipsis silently does nothing: `TextOverflow` needs a
              // width to truncate against.
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .padding(SPACE_XS)
          .clip(true)
          // `RADIUS_IMAGE`, not `RADIUS_CARD`: this is the placeholder that occupies the
          // cover's box, so it must be the same rounded rectangle as the cover it stands
          // in for — a card radius here would make the grid re-shape itself the moment a
          // cover appeared.
          .borderRadius(RADIUS_IMAGE)
          // `placeholderSurface`, not `muted`: this is a *surface* standing in for a
          // cover, and it has to read as one. `muted` is a control fill — the 取消
          // buttons and the filter chip — and in the light theme it is 1.03:1 against
          // the page, which left a coverless card with no visible edge at all.
          // `verify-themes.mjs` measures this pair in all three themes.
          .backgroundColor(this.palette.placeholderSurface)
        }

        this.coverMenuTrigger(book)
      }
      .width('100%')
      .aspectRatio(0.7)

      Text(book.title.length > 0 ? book.title : '未命名')
        // `TYPE_CAPTION`, the theme's caption step, rather than the bare `12` this was:
        // the number was already right, the point is that it is a step of the app's scale
        // and not a coincidence.
        .fontSize(TYPE_CAPTION)
        // `foreground`, and this is a fix rather than a restatement. An unset `fontColor`
        // follows the *system* colour mode, which is the same defect this file's `palette`
        // doc records for `background`: with a dark system mode and the sepia app theme
        // the caption was near-white on a warm page. It matters more now that the line is
        // truncated — a half-shown title the reader cannot read at all is worse than one
        // she can see is only half shown.
        .fontColor(this.palette.foreground)
        // **One line, always.** A title that wrapped to two lines made its **whole grid
        // row** taller than every other row: measured on the reference device (r108), row 1
        // was 683 px against 636 px for rows 2–4, because a `Grid` row is as tall as its
        // tallest cell, so one long title re-spaced a row of three books. `maxLines(1)`
        // with an ellipsis is the user's own prescription (「书名只有一行，超出字数限制用省略号」).
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Bounded, or the ellipsis silently does nothing: `TextOverflow` needs a width to
        // truncate against, and the cell is a `Column` of `width('100%')` with no intrinsic
        // width of its own.
        .width('100%')

      // Progress is shown only when there is some: a 0% bar on every unread book
      // is noise rather than information.
      if (book.progress > 0.001) {
        Progress({ value: book.progress * 100, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onOpen(book);
    })
  }

  /**
   * The `⋯` that opens a book's action menu.
   *
   * ## Position — inside the cover, and why it is now inside
   *
   * A `MENU_TRIGGER_TOUCH` box is aligned to the cover `Stack`'s **bottom-right** corner and
   * then pulled **inward** by `MENU_TRIGGER_INSET` in both axes. The chip is aligned to that
   * box's bottom-right corner too, so chip and box share a corner and the chip ends up
   * `MENU_TRIGGER_INSET` inside the cover's own bottom-right corner.
   *
   * It used to go the other way. r108 and every round before it shifted the box *down* by
   * `MENU_TRIGGER_SIZE / 2` (16 vp), deliberately, so the chip's centre landed on the
   * cover's bottom edge — the shape ReadAny's book card uses. On the installed build the
   * user's report is 「书籍的操作按钮会超出书籍封面的范围，和文字重叠」, and the arithmetic says
   * exactly that: the chip then occupied y ∈ [cover bottom − 16, cover bottom + 16], while
   * the title's first line begins at `cover bottom + 6` (the cell `Column`'s own gap), so
   * 10 vp of a 32 vp chip sat on the title, and the 48 vp tap box escaped the cover by 32 vp
   * of its 48.
   *
   * The fix is a **sign change and an anchor**, not a new number chosen by eye. `Alignment.BottomEnd`
   * already anchors the box to the cover's bottom-right corner, and the cover box is
   * `aspectRatio(0.7)` on a `width('100%')` — so the corner the offset measures from *is* the
   * cover's rendered corner at every card width, which is what an absolute downward
   * displacement could never be. Pulling inward by 8 vp is then inside the cover and stays
   * inside it for every column count (see the containment check in `verify-book-menu.mjs`,
   * which evaluates it at every breakpoint).
   *
   * The arithmetic on the reference device (one card = 111.7 vp wide, so the cover box is
   * 111.7 × 159.6 vp):
   *
   *   chip        32 × 32 vp  → x ∈ [71.7, 103.7], y ∈ [119.6, 151.6]   (8 vp in from both edges)
   *   tap box     48 × 48 vp  → x ∈ [55.7, 103.7], y ∈ [103.6, 151.6]   (fully inside)
   *   overflow    none — the chip's bottom edge is 8 vp **above** the cover's bottom edge,
   *               and the title's first line begins 6 vp **below** it, so the two are 14 vp
   *               apart instead of overlapping by 10.
   *
   * ## The offset is still an `offset`, not a `margin`
   *
   * An offset is a render-time translation and does not take part in layout, which matters
   * here: a margin would change the cover `Stack`'s measured size under `aspectRatio(0.7)`
   * and every cover in the grid would shrink. The inset is small enough for the *anchor* to
   * be the whole story, which is why `Alignment.BottomEnd` is load-bearing rather than
   * decorative.
   *
   * ## Tap target
   *
   * The visible chip is 32 vp, which is below the 48 vp guidance minimum, so the chip
   * sits inside a transparent `MENU_TRIGGER_TOUCH` box and the **box** carries the tap
   * handler. The finger gets the guidance's target; the eye gets the reference's small
   * chip. The inset does not touch this: the box is still 48 vp and it is still the thing
   * that is hit — it has simply moved 8 vp up and left, still over the cover it belongs to.
   *
   * The chip is aligned to that box's *bottom* edge rather than centred in it, and that
   * is what makes the menu's own offset mean what it says below: the popup anchors to the
   * box it is bound to, so with the two bottom edges coincident, `MENU_TRIGGER_GAP` is
   * the gap between the chip and the menu and not the gap plus 8 vp of unused box.
   *
   * ## Opening the menu
   *
   * `bindMenu`'s controlled form (`isShow`) is used rather than the click-triggered one,
   * so the tap only sets state and the popup is the framework's: the content is this
   * component's own builder, positioned `BottomRight` — below the control and
   * right-aligned to it, i.e. opening to the control's lower-left — with the reference's
   * 8 vp gap. `onWillDisappear` clears the id, which is what re-arms the control after
   * the menu is dismissed by a tap outside it; without that, the second tap on the same
   * `⋯` would set an id that is already set and nothing would appear to happen.
   *
   * The press feedback is the app's single click effect, routed through `Motion` and
   * gated on the animation setting: with animation off `Motion.clickEffect()` returns
   * `null` and the chip simply stops compressing.
   */
  @Builder
  private coverMenuTrigger(book: Book) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        // `sys.symbol.more` is the platform's three-dot symbol; the reference draws the
        // same glyph. It is not `sys.symbol.ellipsis` — that name is not in the symbol
        // table (`toolchains/id_defined.json`), and the compiler rejects an unknown one.
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(MENU_TRIGGER_GLYPH_SIZE)
          .fontColor([this.palette.foreground])
      }
      .width(MENU_TRIGGER_SIZE)
      .height(MENU_TRIGGER_SIZE)
      // A control you tap, so `RADIUS_CONTROL` (20) — the same role the menu it opens
      // takes, which is also what 同层统一 asks for. On a 32 vp chip this clamps to a
      // capsule; that is the correct reading of a radius spec that has no "circle".
      .borderRadius(RADIUS_CONTROL)
      .backgroundColor(menuTriggerBackground(this.palette))
    }
    .width(MENU_TRIGGER_TOUCH)
    .height(MENU_TRIGGER_TOUCH)
    // **Inward**, from the cover's bottom-right anchor. See the doc above: the sign is the
    // fix, and `MENU_TRIGGER_INSET` is a positive inset as the name says. The guard against
    // a positive `y` is arithmetic rather than taste — the box is exactly
    // `MENU_TRIGGER_TOUCH` tall and is aligned to the cover's bottom edge, so **any**
    // positive `y` puts part of the box, and half the chip with it, outside the cover.
    .offset({ x: -MENU_TRIGGER_INSET, y: -MENU_TRIGGER_INSET })
    .clickEffect(this.animationOn ? Motion.clickEffect() : null)
    .onClick((): void => {
      this.menuBookId = book.id;
    })
    .bindMenu(this.menuBookId === book.id, this.bookActionMenu(book), this.menuOptions())
  }

  /**
   * The `bindMenu` options — the **only** place a menu's system material may go.
   *
   * ## Why the material is here and not on the `Menu`
   *
   * `systemMaterial` looks like a universal attribute, and the SDK declares it as one
   * (`common.d.ts:22642`, on `CommonMethod`). It is not: the framework accepts it only
   * inside a `Navigation`/`NavDestination` title bar or a horizontal `Tabs` bottom
   * `TabBar` with `barPosition: BarPosition.End`. Given anything else it discards the
   * option and logs, from `C03900/<bundle>/Ace`:
   *
   *     [(100000:100000:scope)] Material inactive: out of scope.
   *     Use component in navigation title bar or Tabbar.
   *
   * which is what a `Menu` carrying `.systemMaterial(...)` produces on this device —
   * measured, not inferred. The 弹出类 surfaces are exempted by a *different* route: each
   * of their options objects carries its own `systemMaterial` field, and 菜单控制 is one
   * of the interfaces that "可在全页面生效" (`ContextMenuOptions.systemMaterial`,
   * `common.d.ts:15594`; `MenuOptions extends ContextMenuOptions`, `:15637`). The
   * component-adaptation guide says the same thing in one sentence — 「菜单支持通过
   * ContextMenuOptions 中的 systemMaterial 字段设置沉浸光感效果」 — and the API
   * reference's 「示例24（设置菜单的沉浸光感）」 is that call, verbatim.
   *
   * Two advantages come with the right route, both documented: the options route does
   * not care about attribute ordering the way the universal attribute does ("通过组件
   * options 参数设置沉浸式系统材质时则无需关注设置顺序"), and it does not need the app-level
   * `module.json5` switch — 组件级开启 overrides 应用级开启, and this app deliberately
   * leaves that switch unset so the material lands on this menu and nowhere else.
   *
   * ## Why the base four fields are built first and mutated once
   *
   * ArkTS has no object spread and no conditional field in a literal, so the alternative
   * was two whole literals with the placement, offset, transition and dismissal callback
   * copied into both — the shape that goes stale the first time one of them changes. The
   * material is therefore attached to the one literal, and only when there is one.
   */
  private menuOptions(): MenuOptions {
    const options: MenuOptions = {
      placement: Placement.BottomRight,
      offset: { x: 0, y: MENU_TRIGGER_GAP },
      // The menu's own show/hide, through the app's motion module so 「关闭」 reaches it:
      // `fadeIn()` returns `null` when animation is off, and `transitionOrIdentity`
      // turns that into the SDK's identity effect — the menu appears with no animation
      // rather than with a zero-length one. A fade rather than `Motion.scaleIn`, because
      // the SDK warns that a spring curve on a menu's *exit* leaves a rebound tail during
      // which other events cannot be handled, and `fadeIn` is the one `Motion` effect
      // that uses an ease instead of the spring.
      transition: transitionOrIdentity(this.animationOn ? Motion.fadeIn() : null),
      onWillDisappear: (): void => {
        this.menuBookId = '';
      },
    };
    const material: Object | undefined = this.menuMaterialFor();
    if (material !== undefined) {
      options.systemMaterial = material;
    }
    return options;
  }

  /**
   * The menu surface: this round, one destructive row.
   *
   * ## Why there are two branches
   *
   * The surface itself has to differ, because a material takes over the background,
   * border and shadow and the SDK advises against setting them alongside it. So the
   * `Menu` component is built twice: once bare, for the run where `menuOptions()` has
   * already handed the framework a material, and once in the palette, for the three
   * paths where `menuMaterialOption` returns `undefined`. Both branches are the *same*
   * menu — the difference is only who paints it. An attribute cannot be applied
   * conditionally in one component call, which is why this is a `if`/`else` and not a
   * ternary.
   *
   * **Nothing here carries `systemMaterial`.** The material travels in the `bindMenu`
   * options (`menuOptions` above), which is the only call site the framework accepts for
   * a menu; a `.systemMaterial(...)` here is the defect this round removed, and it is
   * recorded on `menuOptions` with the log line the device produced. This builder is
   * still the whole of what the material may cover — a popup menu and nothing larger. A
   * page-sized container carrying a material repaints the whole page from the system
   * palette, and a small selection chip carrying one loses the selection state under it;
   * both were real defects in this app.
   *
   * ## The rest of the look
   *
   *  - The width is `this.menuWidth()`: `MENU_WIDTH_CARD_RATIO` (1.5) × one card of the
   *    grid this menu opens over, **not** the menu guidance's fixed 224 vp. `Tokens.ets`
   *    records the departure, the arithmetic and the 224 vp the un-measured fallback still
   *    uses; `cardWidth()` is where the grid's padding, gap and column count enter.
   *  - `radius(RADIUS_CONTROL)` is 20 vp, the menu/button/tab role in the corner-radius
   *    spec — and it is also the platform's own default for a phone menu (8 vp is the
   *    2-in-1 default), so this pins the phone value on every device type.
   *  - `menuItemDivider` is the separators between items. It is **not** on by default
   *    ("If this attribute is not set, the divider will not be displayed"), so with one
   *    row there is currently nothing for it to draw between; it is set so that the
   *    second row this menu eventually grows is separated the way the reference's is,
   *    rather than needing someone to remember. Full width, one hairline, the palette's
   *    border — the reference's `itemDivider` is a full-bleed hairline too.
   *  - `transition` is the menu's own show/hide. It goes through `Motion.fadeIn()`, so
   *    「关闭」 makes the menu appear with no animation at all; the effect is a fade
   *    rather than `Motion.scaleIn`, because the SDK warns that a spring curve on a
   *    menu's exit leaves a long tail during which other events cannot be handled, and
   *    `fadeIn` is the one `Motion` effect that uses an ease instead of the spring.
   */
  @Builder
  private bookActionMenu(book: Book) {
    if (this.menuMaterialFor() !== undefined) {
      Menu() {
        this.deleteMenuItem(book)
      }
      .width(this.menuWidth())
      .radius(RADIUS_CONTROL)
      .menuItemDivider({
        strokeWidth: LengthMetrics.vp(1),
        color: this.palette.border,
        startMargin: LengthMetrics.vp(0),
        endMargin: LengthMetrics.vp(0),
      })
    } else {
      Menu() {
        this.deleteMenuItem(book)
      }
      .width(this.menuWidth())
      .radius(RADIUS_CONTROL)
      .menuItemDivider({
        strokeWidth: LengthMetrics.vp(1),
        color: this.palette.border,
        startMargin: LengthMetrics.vp(0),
        endMargin: LengthMetrics.vp(0),
      })
      .backgroundColor(this.palette.card)
      // A hairline edge, because a fill alone is not separation on every palette — the
      // same reason `ui/ListRow.ets` carries one. Unreachable while the material is
      // applied, which is why it lives only in this branch.
      .borderWidth(1)
      .borderColor(this.palette.border)
    }
  }

  /**
   * One row of the menu: leading symbol, then the label.
   *
   * A `MenuItem` rather than a hand-built `Row`, because that is what gives the menu a
   * row: the component's own metrics, its ripple, its hit area, and the dividers
   * `menuItemDivider` draws. A `Row` inside a `Menu` would have none of them and would
   * need its height, padding and press state invented.
   *
   * Both halves are the palette's `destructive` red, which is what marks the row as
   * destructive — the reference colours the label *and* the icon
   * (`BookCardActionSheet.tsx:125-126`), and colour alone is what it uses; there is no
   * extra confirm step on the row itself, because the confirmation is the next screen.
   * `contentFontColor` is the documented way to colour a `MenuItem`'s content; the icon
   * carries its own colour through the `SymbolGlyphModifier`.
   */
  @Builder
  private deleteMenuItem(book: Book) {
    MenuItem({ symbolStartIcon: this.deleteSymbol(), content: '删除' })
      .contentFontColor(this.palette.destructive)
      .onClick((): void => {
        this.askDelete(book);
      })
  }

  /**
   * The confirmation, with ReadAny's wording and ReadAny's choice.
   *
   * Every string here is the reference's, taken from the bundle its own UI renders —
   * `packages/core/src/i18n/locales/zh/library.json`, the `library.*` keys its delete
   * dialog and action sheet both call `t()` with. That distinction matters: those keys
   * exist in the zh bundle, so the **locale values** are what a Chinese-language ReadAny
   * shows on screen, and the second argument to each `t()` call is only the fallback for
   * a missing key. Two of the four differ —
   *
   *   key                          | displayed (zh bundle)        | component fallback
   *   ---------------------------- | ---------------------------- | --------------------------
   *   deleteBookDescription        | 书籍文件将从书架移除。        | 你可以选择保留笔记和阅读统计…
   *   preserveDeleteDataHint       | 重新导入同一本书时可恢复      | 勾选后会从书架移除书籍文件…
   *
   * — and the displayed text is the one replicated, because "the same wording" can only
   * mean what the reference actually puts in front of the user.
   *
   * The choice itself is the point: 保留笔记和阅读统计, checked by default, and the
   * two modes are not variations of one behaviour —
   *
   *  - **checked** (the default): the book comes off the shelf and its file goes, but its
   *    notes, highlights and reading history stay, and the row stays on disk with
   *    `deleted_at` set so the desktop sees the deletion as the same soft delete it
   *    performs;
   *  - **unchecked**: the book, its file and every annotation it owns are removed, with
   *    a tombstone that stops a peer resurrecting it.
   *
   * — so they must not be blurred, and the way not to blur them is to ask, in ReadAny's
   * words, exactly as this does.
   *
   * `Button` rather than `AlertDialog.show`, whose buttons cannot carry the checkbox;
   * the sheet is this app's existing modal idiom (`AnnotationsPage`'s editor sheet) and it
   * is driven by this component's own state, so the palette and the book are read live
   * rather than captured when a dialog controller was constructed.
   */
  @Builder
  private deleteConfirmSheet() {
    Column({ space: SPACE_M }) {
      Text('删除这本书？')
        .fontSize(TYPE_TITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.palette.foreground)
        .width('100%')

      // Which book, stated. The reference does not need this — its dialog is opened from
      // the card it concerns and no other book is in the dialog's scope — but here the
      // confirmation covers the shelf, and the one mistake worth designing out of a
      // destructive action is deleting the wrong book.
      if (this.pendingDelete !== undefined) {
        Text(this.pendingDelete.title.length > 0 ? this.pendingDelete.title : '未命名')
          .fontSize(TYPE_BODY)
          .fontColor(this.palette.mutedForeground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text('书籍文件将从书架移除。')
        .fontSize(TYPE_BODY)
        .fontColor(this.palette.mutedForeground)
        .width('100%')

      Row({ space: SPACE_S }) {
        // `.select(this.preserveData)` with the toggle on the label rather than on the
        // whole row: the reference makes the entire row pressable, and putting an
        // `onClick` on the row *and* an `onChange` on the box would fire both and cancel
        // itself out. This way the box and the label are each a single control and the
        // gap between them is the only dead space.
        Checkbox()
          .select(this.preserveData)
          .selectedColor(this.palette.primary)
          .onChange((value: boolean): void => {
            this.preserveData = value;
          })
        Column({ space: SPACE_XS }) {
          Text('保留笔记和阅读统计')
            .fontSize(TYPE_SUBTITLE)
            .fontColor(this.palette.foreground)
            .width('100%')
          Text('重新导入同一本书时可恢复')
            .fontSize(TYPE_CAPTION)
            .fontColor(this.palette.mutedForeground)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          this.preserveData = !this.preserveData;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: SPACE_S }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.palette.muted)
          .fontColor(this.palette.foreground)
          .onClick((): void => {
            this.confirmOpen = false;
            this.pendingDelete = undefined;
          })
        Button(this.deleting ? '删除中…' : '删除')
          .layoutWeight(1)
          .backgroundColor(this.palette.destructive)
          .fontColor(this.palette.destructiveForeground)
          .enabled(!this.deleting)
          .onClick((): void => {
            this.confirmDelete();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(SPACE_M)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.background)
  }

  @Builder
  private emptyState() {
    Column({ space: 10 }) {
      Text('书架是空的')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
      Text('导入 EPUB 后会显示在这里；\n也可以先在「同步」里配置 WebDAV 从其他设备拉取。')
        .fontSize(13)
        .fontColor(this.palette.mutedForeground)
        .textAlign(TextAlign.Center)
      Button('导入书籍')
        .margin({ top: 8 })
        .onClick((): void => {
          this.onImport();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }

  /**
   * `Grid` wants a template string, not a count.
   *
   * Built from the same count the breakpoint helper returns, so the two cannot
   * disagree.
   */
  private templateForColumns(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.columns; i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  /**
   * One cell's width in vp, from the grid's own geometry.
   *
   * The same shape the `Grid` lays out with: its box, less its horizontal padding, less one
   * gap between each pair of columns, divided by the column count. The three inputs are the
   * ones the grid is actually given (`SHELF_GRID_PADDING`, `SHELF_COLUMNS_GAP`,
   * `this.columns`), not copies of them.
   *
   * A non-positive answer means the grid has not been measured yet (see `gridWidth`);
   * `menuWidth()` treats that as "unknown" rather than as a zero-width cell.
   */
  private cardWidth(): number {
    const inner: number = this.gridWidth - SHELF_GRID_PADDING * 2;
    const gaps: number = SHELF_COLUMNS_GAP * (this.columns - 1);
    return (inner - gaps) / this.columns;
  }

  /**
   * The action menu's width in vp: `MENU_WIDTH_CARD_RATIO` of one card.
   *
   * The ratio, the guidance it departs from and the arithmetic that produces ~168 vp on
   * this project's reference phone are all documented in `theme/Tokens.ets`, next to the
   * token. The fallback is that guidance's fixed 224 vp, and it is for the un-measured case
   * only — a popup must not be built at a width derived from zero.
   */
  private menuWidth(): number {
    const card: number = this.cardWidth();
    if (card > 0) {
      return card * MENU_WIDTH_CARD_RATIO;
    }
    return MENU_WIDTH_UNMEASURED;
  }

  build() {
    Column() {
      // Search and sort live in the shelf, not the shell, because they only affect
      // this list.
      Row({ space: 8 }) {
        Search({ value: this.search, placeholder: '搜索书名或作者' })
          .layoutWeight(1)
          .onChange((value: string): void => {
            this.search = value;
            this.onReload();
          })
        // A single cycling button rather than a menu: there are five orders, the
        // label always shows the current one, and it costs one tap instead of two.
        Button(sortLabel(this.sort))
          .fontSize(13)
          .onClick((): void => {
            this.sort = nextSort(this.sort);
            this.onReload();
          })
        Button('导入')
          .fontSize(14)
          .onClick((): void => {
            this.onImport();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.loading) {
        Column() {
          LoadingProgress().width(32).height(32)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.books.length === 0) {
        Column() {
          this.emptyState()
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Grid() {
          ForEach(this.books, (book: Book, index: number) => {
            GridItem() {
              this.bookCell(book)
            }
            // The dense-grid entrance, with the reference's tight stagger (`i*2+10`):
            // a shelf can hold thirty cells, and the 10 ms-per-row stagger the settings
            // lists use would still be arriving a third of a second later.
            .transition(transitionOrIdentity(this.animationOn ? Motion.scaleInFast(index) : null))
          }, (book: Book) => `${book.id}-${book.updatedAt}`)
        }
        
        .columnsTemplate(this.templateForColumns())
        .columnsGap(SHELF_COLUMNS_GAP)
        .rowsGap(16)
        .width('100%')
        .layoutWeight(1)
        // Horizontal padding only. It is `SHELF_GRID_PADDING`, the value the action menu's width is
        // derived from (`cardWidth`), so it is named rather than written twice.
        //
        // r109: the **bottom** term moved out of `padding` and into `contentEndOffset` below.
        // A `Grid` whose child sits *entirely* inside the padding band does not draw that child at
        // all — ArkUI, `Grid`: 「设置Grid的padding后，如果子组件部分位于Grid内容区且部分位于padding
        // 区域内，则会显示；如果子组件完全位于padding区域内，则不会显示。」 So a bottom-padded
        // `Grid` carries a **no-item-may-begin** strip at its end, and a row crossing into that strip
        // was admitted *whole and in one frame*, filling the strip at full height. That was the 书架
        // pop: cell, cover, title and progress arriving together, with no hysteresis.
        // `contentEndOffset` reserves the same distance without declaring any padding, so the rule
        // above cannot apply by its own terms. `clip` is untouched — still the border box — so
        // content goes on sliding under the capsule and its mask, which is the intended look.
        .padding({ left: SHELF_GRID_PADDING, right: SHELF_GRID_PADDING })
        // `contentEndOffset(offset: number | Resource)`: `common.d.ts:25382`, `@since 22`, unit vp,
        // default 0. `GridAttribute extends ScrollableCommonMethod<GridAttribute>` (`grid.d.ts:338`)
        // is what puts it on `Grid`; `scroll.d.ts:492-493`: 「Starting from API version 22, the Grid
        // and WaterFlow components also support setting contentStartOffset and contentEndOffset.」
        // The contract is this project's invariant exactly: 「设置内容区末尾偏移量。滚动组件滚动到末尾
        // 位置时，内容与组件显示区域边界保留指定距离。」 The reserved distance is deliberately
        // **unchanged from r107** — this round moved the term, it did not re-derive it. Both mechanisms
        // shorten the scrollable end by the same 418.5 px on the reference device, so max scroll
        // (856.5 px) and the last row's resting position (2429.5 px) are identical to the padded
        // version; only the *mechanism* changed. Whether the gesture inset inside that value is still
        // load-bearing is **not** something this round re-measured, so it was left alone.
        //
        // `@since 22` <= this module's `compatibleSdkVersion` of 24, so there is **no** runtime guard
        // here — unlike the reader's `uiMaterial.ImmersiveMaterial` (@26), which does need one. A
        // version check on this line would be dead code.
        //
        // One degenerate case is documented and is deliberately **not** clamped: 「contentStartOffset
        // + contentEndOffset超过滚动组件内容区长度后contentStartOffset和contentEndOffset会置0」.
        // No `contentStartOffset` is set, so the clearance would need this Grid's content area to be
        // shorter than 124 vp. The Grid is `layoutWeight(1)` under a `height('100%')` section, so it
        // is screen height minus the title and chrome — and it cannot reach 124 vp without the page
        // being unusable well before that. A clamp would be unreachable code guarding an impossible
        // state, so the bound is recorded here instead of written as a branch.
        .contentEndOffset(FLOATING_BAR_CLEARANCE + this.bottomInsetVp)
        .scrollBar(BarState.Auto)
        // Gated like the other scroll owners, so switching animation off also stops the
        // shelf stretching past its last row and springing back.
        .edgeEffect(Motion.edgeEffect())
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          const width: number = Number(newValue.width);
          if (Number.isNaN(width) || width <= 0) {
            return;
          }
          // Recorded with the same compare-before-assign as `columns` below, and for the
          // same reason: writing an unchanged value to a state field still re-renders, and
          // this callback fires on every frame of a resize. This is the measurement the
          // action menu's width is derived from.
          if (width !== this.gridWidth) {
            this.gridWidth = width;
          }
          const next: number = shelfColumnsForWidth(width);
          // Compared before assigning because writing the same value to a state
          // field still triggers a re-render, and `onAreaChange` fires on every
          // frame of a resize.
          if (next !== this.columns) {
            this.columns = next;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.background)
    // **One** sheet binding, on the root container, mirroring `AnnotationsPage` — the
    // reader's own sheet host is a different component and is untouched by this. The
    // content is a builder of this component, so it is evaluated when the sheet opens
    // and reads the current book and the current palette.
    //
    // `FIT_CONTENT`, because the confirmation is a short block of text and two buttons;
    // a detent ladder would let a drag resize a destructive confirmation. `dragBar` and
    // `showClose` are off for the same reason: the sheet has exactly two exits, 取消 and
    // 删除, plus a tap outside it, which is the reference's modal behaviour.
    .bindSheet($$this.confirmOpen, this.deleteConfirmSheet(), {
      detents: [SheetSize.FIT_CONTENT],
      preferType: SheetType.BOTTOM,
      dragBar: false,
      showClose: false,
    })
  }
}

/** Human-readable label for a sort mode. */
export function sortLabel(sort: BookSort): string {
  switch (sort) {
    case Sort.RECENTLY_ADDED:
      return '最近添加';
    case Sort.TITLE:
      return '按书名';
    case Sort.AUTHOR:
      return '按作者';
    case Sort.PROGRESS:
      return '按进度';
    case Sort.RECENTLY_OPENED:
    default:
      return '最近阅读';
  }
}

/** Next sort mode in the cycle, for the one-button sort toggle. */
export function nextSort(sort: BookSort): BookSort {
  switch (sort) {
    case Sort.RECENTLY_OPENED:
      return Sort.RECENTLY_ADDED;
    case Sort.RECENTLY_ADDED:
      return Sort.TITLE;
    case Sort.TITLE:
      return Sort.AUTHOR;
    case Sort.AUTHOR:
      return Sort.PROGRESS;
    case Sort.PROGRESS:
    default:
      return Sort.RECENTLY_OPENED;
  }
}
