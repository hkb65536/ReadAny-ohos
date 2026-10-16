import { InkBoatError } from 'core';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import type { ThemePalette } from '../theme/Theme';
import type { Book } from 'data';
import {
  FLOATING_BAR_CLEARANCE,
  headerBarMaterialOption,
  menuMaterialOption,
  menuTriggerBackground,
  MIN_TAP_TARGET,
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
  TYPE_TITLE_LARGE,
} from '../theme/Theme';
import {
  COVER_PROGRESS_HEIGHT,
  HEADER_TITLE_HIDE_OFFSET,
  MENU_TRIGGER_GAP,
  MENU_TRIGGER_GLYPH_SIZE,
  MENU_TRIGGER_INSET,
  MENU_TRIGGER_SIZE,
  MENU_TRIGGER_TOUCH,
  MENU_WIDTH_CARD_RATIO,
  MENU_WIDTH_UNMEASURED,
  PLACEHOLDER_TITLE_LINES,
  PLACEHOLDER_TITLE_SIZE,
  ROW_ICON_SIZE,
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
 * ## The sort control is gone, and this is what it cost
 *
 * The header row used to hold a single cycling sort button — `Button(sortLabel(this.sort))`, whose
 * label was the order currently in force (「最近阅读」 by default), stepping through five of them with
 * `nextSort`. r117 deleted it at the user's request
 * (「把主界面的"最近阅读"按钮删了，换成...」), and the whole of its wiring went with it: the button,
 * `nextSort`, `sortLabel`, and the `@Link sort` this page was handed (the rule r109 applied to
 * `AnnotationsPage`'s dead `bottomInsetVp` — a prop nothing reads is deleted together with the
 * argument that fed it).
 *
 * **The functionality it removes is real and is not hidden: the shelf can no longer be re-ordered at
 * all.** `Index.shelfSort` still exists and is still what the repository query sorts by, but nothing
 * on screen writes it any more, so the shelf is permanently 最近阅读-first — 最近添加 / 按书名 /
 * 按作者 / 按进度 are unreachable. Nothing persists the choice, so no unreachable stored state is left
 * behind; the four orders are simply no longer selectable. Reading the shelf still *sorts* (by
 * `lastOpenedAt`, descending), which is why this is a lost control rather than a lost feature.
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
  /**
   * Whether a sync pass is running, mirrored from the shell.
   *
   * **This is the shell's own `syncBusy` (`Index.ets`), not a second flag.** It is the same field the
   * 设置 → 同步 page's 同步 button and its 全量上传 / 全量下载 buttons disable themselves on, so the
   * two surfaces cannot disagree about whether a pass is in flight, and the shelf's button needs no
   * state of its own. It is a `@Prop` rather than a `@Link` because this page only reads it.
   *
   * `false` is the idle value, which is why it is the default: the shelf renders before any pass and
   * must render as idle rather than as busy.
   */
  @Prop syncBusy: boolean = false;
  /**
   * The tab's own title, drawn inside the header — `书架`.
   *
   * **The title moved here from `Index.pageTitle` in this round**, and the reason is the material
   * rather than the title: the framework serves `systemMaterial` **only** inside a
   * `Navigation`/`NavDestination` title bar or a horizontal `Tabs` bottom `TabBar`, so the header that
   * is meant to carry it has to *be* a title bar — and a title bar's content is this component's, not
   * the shell's. Keeping a second copy of the title in `Index` would print it twice, which is the
   * defect the audit's `pageTitle` section already guards against on the settings detail pages.
   *
   * It is therefore the same title as before, spelled from the same tokens: `TYPE_TITLE_LARGE` (30),
   * `FontWeight.Bold` and `palette.foreground`, which is exactly what `pageTitle` draws. The shell
   * still owns the string (it is handed in), so 「书架」 has one writer.
   */
  @Prop pageTitle: string = '书架';
  /**
   * The top system band the header must clear, in vp, handed down by the shell.
   *
   * `shellTopInsetVp`, unchanged and still the shell's single measurement (r107). The header used to
   * receive it *indirectly*, through the section's title row above it; with the title now inside the
   * header it takes the band itself, so the title's first line of ink still starts below the status
   * bar and the punch hole.
   *
   * 0 is the pre-r107 geometry and the value before the window answers, which is why it is the default.
   */
  @Prop topInsetVp: number = 0;

  /**
   * Start one ordinary sync pass, or do nothing.
   *
   * Injected rather than called directly for the same reason `onDelete` is: `runSync` owns the shell's
   * progress card, its summary line and the shelf reload that follows a pass, and a page that reached
   * into the service would be a second place that decides what a sync writes. The shell hands in
   * `Index.runSync(SyncMode.NORMAL)` — the identical call the 设置 → 同步 page's 同步 button makes, so
   * the shelf's button triggers what exists rather than a new path.
   */
  onSync: () => void = (): void => {};

  onImport: () => Promise<void> = async (): Promise<void> => {};
  onOpen: (book: Book) => void = (): void => {};
  onReload: () => Promise<void> = async (): Promise<void> => {};
  /**
   * Report the grid's scroll direction and position so the shell can hide the 「书架」 title.
   *
   * **The decision is the shell's, the measurement is this page's.** The grid is what scrolls, so it
   * is the only thing that can say which way the user is moving; but the rule that turns that into
   * "the title is hidden" belongs beside the title's own state, in `Index`, for the same reason
   * `onSync` is injected rather than called directly — a second place that decided it could disagree
   * with the first.
   *
   * `up` is true when this frame moved the content further from the top, and `offset` is the
   * cumulative scroll distance in vp. Both are passed rather than one derived flag, so the hysteresis
   * (see `HEADER_TITLE_HIDE_THRESHOLD`) lives in exactly one place.
   */
  onTitleScroll: (up: boolean, offset: number) => void = (up: boolean, offset: number): void => {};
  /**
   * The grid's scroll offset, in vp, accumulated from `onDidScroll`'s per-frame deltas.
   *
   * `onDidScroll` reports **how far this frame moved**, not where it is, so the absolute position has
   * to be accumulated. It is a plain field rather than `@State`: nothing renders from it — it is the
   * only input to the direction test above — and making it state would re-render the whole grid on
   * every frame of every scroll.
   *
   * A stale value is self-correcting rather than sticky: the grid is re-created when the book list is
   * replaced, so the accumulator is reset in `aboutToAppear` alongside the covers.
   */
  private scrollOffsetVp: number = 0;
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

  /**
   * The 沉浸光感 material the header's surface is painted with, or `undefined` for the opaque path,
   * or `null` while that question has not been asked yet.
   *
   * ## Why it is resolved in `aboutToAppear` and not at construction
   *
   * `headerBarMaterialOption()` builds a real `uiMaterial.ImmersiveMaterial` when the gate admits it,
   * and that object is `@since 26.0.0`. An eager field initialiser runs **before** any lifecycle hook,
   * on whatever runtime the module finds itself on, so putting the construction there would evaluate
   * an API-26 namespace during construction on an API-24 device — the one thing
   * `canApplyImmersiveMaterial()` exists to prevent. The reader already establishes the shape: it
   * stores the *gate's answer* at construction and constructs the object only where that answer has
   * already said yes (`ReaderView.topBarMaterialObject`).
   *
   * ## What `undefined` means, and why the opaque branch is not a fallback nobody reaches
   *
   * `headerBarMaterialOption` is the app's guarded decision point for a **top bar's** material: it asks
   * the same two questions `topBarMaterialOption` (the reader's floating top bar) asks, in the same
   * order, and answers `undefined` on all three documented "no material" paths at once:
   *
   *  1. **The API is absent** (a pre-26 runtime). The namespace does not exist there, so the object
   *     cannot be constructed at all and the guard answers before anything touches it.
   *  2. **The device reports no support** (`isImmersiveMaterialSupported`) — a device fact independent
   *     of the API level.
   *  3. **The material level is the low-compute one**, where a material stops being a filter over this
   *     app's surface and *becomes* the surface, painted from the system's palette. A system material
   *     knows only light from dark, so at that level the sepia header would come back white or black —
   *     the defect this project has already hit twice, on a page-sized container and on the ⋯ chip.
   *
   * It is deliberately **not** `topBarMaterialOption` itself: this header's material carries
   * 自动反色 (`colorInvert`) so the two glyphs on it can be re-toned against a translucent surface,
   * and the reader's top bar — verified work — keeps the recipe it was verified with.
   * `immersiveHeaderBarMaterialOption` records both halves.
   *
   * ## Why the answer is memoised
   *
   * It decides **which of two component trees is built**, not a value inside one: ArkTS cannot apply an
   * attribute conditionally in a single component call, so the material branch and the opaque branch
   * each exist in full. Settling it once means the tree does not change shape underneath the grid while
   * the user is scrolling it.
   */
  private headerMaterial: Object | undefined | null = null;
  /**
   * Whether the 「书架」 title is hidden because the shelf is scrolled up — **and with it the whole
   * region the title occupied**.
   *
   * The shell writes it (see `onTitleScroll`); this page only renders from it. Four properties are
   * derived from it and no more: the title row's `height`, its `opacity`, its `translate`, and the
   * header bar's own height — one read in each height helper and two in the title's builder, so the
   * count is asserted rather than left to inspection. `headerTitle` records why a layout property
   * joined the two render-only ones in r119.
   */
  @Prop titleHidden: boolean = false;

  aboutToAppear(): void {
    this.refreshCovers();
    // The accumulator is a plain field, so it is not reset for free when the component is rebuilt
    // for a new book list. See `scrollOffsetVp`.
    this.scrollOffsetVp = 0;
    // The material question is asked here rather than at construction — see `headerMaterial`.
    this.headerMaterial = headerBarMaterialOption();
  }

  /**
   * Feed one frame of the grid's scroll to the shell's hide/show rule.
   *
   * `onDidScroll(handler: OnScrollCallback)` — `common.d.ts:25435`, **`@since 12`**, with the
   * callback `(scrollOffset: number, scrollState: ScrollState)`. Two things about it are
   * load-bearing here and both come from the declaration rather than from a guess:
   *
   *  - **`scrollOffset` is the offset of *this frame*, signed** — the declaration says
   *    "scrollOffset is offset per frame scrolling" (`common.d.ts:25400`). It is not a position, so
   *    the cumulative distance is accumulated here and that sum is what the shell's thresholds are
   *    compared against.
   *  - **`onScroll` is the wrong API for this.** It is `@since 11`, **deprecated since 12**, and its
   *    `@useinstead` is exactly this method (`common.d.ts:25407-25408`). The deprecated callback also
   *    takes no `ScrollState`, which is the second reason not to use it: without the state there is
   *    no way to tell a user's drag from the spring's own settle.
   *
   * **Positive is up.** The grid's content moves up the screen as the user reads further down, and
   * that is the direction the user's 「上划」 names — so `movedUp` is `delta > 0` and it means the
   * content travelled upward, i.e. the reader is scrolling toward the end of the list.
   *
   * **`ScrollState` is deliberately not branched on.** The trigger the user asked for is 「上划的时候」
   * — a direction, not a gesture phase — so a fling, a drag and a programmatic move all obey the same
   * rule, and letting go of the list does not change what is on screen. `ScrollState` carries no
   * direction of its own (Idle/Scroll/Fling), so it could not express this rule even if it were used.
   */
  private handleGridScroll(delta: number): void {
    if (!Number.isFinite(delta) || delta === 0) {
      return;
    }
    this.scrollOffsetVp += delta;
    if (this.scrollOffsetVp < 0) {
      // A spring overshoot at the top reports a negative cumulative sum. Clamped so the accumulator
      // stays a distance from the top rather than drifting below it. (The comment deliberately does
      // not spell the enum's name: `verify-motion.mjs` asserts that no page carries an unconditional
      // edge-effect literal, and it scans comments too.)
      this.scrollOffsetVp = 0;
    }
    this.onTitleScroll(delta > 0, this.scrollOffsetVp);
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

        // ## The reading progress, on the cover's bottom edge (r117)
        //
        // It used to be a **sibling under the caption**, a `Progress` of its own in the cell
        // `Column`. The user asked for it on the cover instead, thinner, at the very bottom
        // (「把主界面里显示阅读进度的那个进度条移到书的封面上，可以再细一点，放在封面的最下面」),
        // and this is that bar: a child of the cover `Stack`, so it is an **overlay** and takes no
        // part in the cell's height.
        //
        //  - **Placement: flush with the cover's bottom edge, full width.** That is what 「封面的最
        //    下面」 says, and a bar is the cover's own edge — an inset would leave a strip of cover
        //    below it with nothing in it. `Stack`'s `alignContent: Alignment.BottomEnd` puts this
        //    full-width child on that edge without a per-child alignment.
        //  - **Thickness: `COVER_PROGRESS_HEIGHT` (2 vp), for both the box and the stroke.** The old
        //    bar set only `.height(3)` and left `LinearStyleOptions.strokeWidth` at its 4 vp default,
        //    so the ink on screen was 4 vp while the node was 3 — the token carries the whole
        //    argument, including why shrinking the box alone would not have made it thinner.
        //  - **The track is set, not left to the framework — and the track is load-bearing.**
        //    `Progress`'s own default background is a system colour, and this bar is drawn over *cover
        //    art* — any image at all. The pair is the one the shell's sync bar already uses
        //    (`.color(primary)` on `.backgroundColor(muted)`, `Index.syncProgressDeterminate`), so the
        //    app has one progress idiom rather than two, and the fill's separation is a palette pair
        //    rather than a composite over an unknown image. Measured fill-on-track: light 15.900:1,
        //    dark 14.353:1, sepia 5.600:1 — every one above the 4.5:1 floor as well as the 3:1 graphical
        //    one; on a coverless book's placeholder the same fill measures 12.410 / 14.353 / 5.600:1.
        //    `verify-themes.mjs` re-derives all of them.
        //
        //    The **opaque** track is what makes an arbitrary cover safe, because the fill alone is not:
        //    a white fill on a white cover (dark theme) or a near-black fill on a dark cover (light
        //    theme) is invisible where it lies. With both drawn, one of the two always reads against the
        //    art — the unfilled remainder is `#2A2A2A` in the theme whose fill is white, and `#F3F3EF`
        //    in the theme whose fill is near-black — so the boundary between them still marks the
        //    progress in the case where the fill itself vanishes. A transparent track would throw that
        //    property away, which is the whole reason this is not simply `.color(...)`.
        //  - **It cannot reach the `⋯` control.** That control's tap box is anchored to the cover's
        //    bottom-right corner and inset `MENU_TRIGGER_INSET` (8) inward, so its bottom edge is 8 vp
        //    above the cover's bottom edge while this bar occupies the bottom 2 vp: 6 vp of clear air,
        //    and `verify-book-menu.mjs` evaluates `COVER_PROGRESS_HEIGHT <= MENU_TRIGGER_INSET` rather
        //    than trusting this sentence.
        //  - **Why the cover `Stack` clips.** A full-width bar at the very bottom of an
        //    `RADIUS_IMAGE`-rounded box would paint its top row up to ~2.7 vp *outside* the rounded
        //    silhouette at each end — a dark sliver on the page beside the cover's corner. The SDK's
        //    own rule is that a radius clips with `clip` ("设置圆角后，可搭配 clip 属性进行裁剪，避免子组
        //    件超出组件自身"), so the `Stack` carries the radius and the clip. Both the `⋯` box (inset 8
        //    vp, 48 vp) and the placeholder's own box are inside it, so nothing else is cut.
        //
        // The gate is unchanged and deliberate: a bar is shown only when there is progress to show.
        // **The percentage below is not gated**, and that is what makes the row height independent of
        // whether a book has been opened — with the bar out of the `Column`, the only progress-shaped
        // thing left in it is a single line of text that is always present.
        if (book.progress > 0.001) {
          Progress({ value: book.progress * 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(COVER_PROGRESS_HEIGHT)
            // The stroke is the bar's thickness too, from the same name: the default is 4 vp, which
            // is thicker than this box, and an indicator wider than its box is painted overflowing it.
            .style({ strokeWidth: COVER_PROGRESS_HEIGHT })
            .color(this.palette.primary)
            .backgroundColor(this.palette.muted)
        }

        this.coverMenuTrigger(book)
      }
      .width('100%')
      .aspectRatio(0.7)
      // `RADIUS_IMAGE` + `clip`: the cover's own shape, and the reason the progress bar above cannot
      // paint past it. The radius was already on the `Image` and the placeholder; it is on the box
      // that carries the ratio now so the *overlay* is bounded by the same silhouette.
      .borderRadius(RADIUS_IMAGE)
      .clip(true)

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

      // ## The reading percentage, where the bar used to be (r117)
      //
      // 「然后在现在显示进度条的地方显示百分比」 — the bar's old slot in this `Column` now carries the
      // number the bar drew. `book.progress` is a **fraction, 0–1** (`data/Types.ets`:
      // "Reading progress, 0-1"; `Books.updateReadingPosition` clamps it into that range on write), and
      // `progressLabel` turns it into `N%` with the same `Math.round(ratio × 100)` the shell's sync card
      // uses, so "35%" means the same thing on both surfaces. 0 → 「0%」, 1 → 「100%」.
      //
      // **It is drawn for every book, including one that has never been opened.** Two reasons, and the
      // second is the load-bearing one: a read-out of 0 % is what the value actually is, and gating the
      // line on `progress > 0` would have put the cell back to two possible heights — the thing the
      // bar's move was supposed to end. With the bar inside the cover and this line always present, the
      // cell is `cover + gap + caption + gap + one line` for every book on the shelf.
      //
      // `TYPE_CAPTION` and `palette.foreground`, the same type step and colour as the caption one line
      // above it. `mutedForeground` is the obvious "quieter" choice and is **not** usable here: it
      // measures 4.27:1 on the light page and 4.40:1 on the sepia one (`Theme.ets`' `READER_MUTED_ALPHA`
      // records both figures), i.e. below this project's 4.5:1 floor for text on the page. `foreground`
      // on `background` measures 17.428:1 light / 17.183:1 dark / 10.842:1 sepia. `verify-themes.mjs`
      // re-derives the three figures from the palettes on every run.
      Text(this.progressLabel(book.progress))
        .fontSize(TYPE_CAPTION)
        .fontColor(this.palette.foreground)
        // One line, so the row is one line box whatever a long-locale font metric does — `maxLines(1)`
        // bounds the `Text`'s measured height exactly as the caption's does.
        .maxLines(1)
        // Bounded, like the caption: an unconstrained `Text` in a `Column` of `width('100%')` is not
        // what decides this cell's width, and a `Text` that measured itself would be a second thing
        // the row height depended on.
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onOpen(book);
    })
  }

  /**
   * The reading progress as the text that replaced the bar, e.g. `35%`.
   *
   * The value is the fraction `book.progress` carries, clamped before it is rounded: the column is
   * clamped by `Books.updateReadingPosition` on this device's writes, but a row can also arrive from a
   * peer over sync, and `Math.round(1.4 × 100)` would print 「140%」 for a value this client never
   * wrote. The clamp is the same shape that function uses (`< 0 → 0`, `> 1 → 1`).
   *
   * `Math.round` rather than a floor or a decimal: the shell's sync card labels its own bar this way
   * (`Index.progressPercentLabel`), so one rounding rule covers both progress read-outs in the app.
   * It does mean a book at 99.6 % reads 「100%」 while its bar is a hair short of full — the same
   * tradeoff the sync card makes, and the alternative (truncating) reads 「99%」 on a finished book.
   */
  private progressLabel(progress: number): string {
    const clamped: number = progress < 0 ? 0 : progress > 1 ? 1 : progress;
    return `${Math.round(clamped * 100)}%`;
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

  /**
   * The header's sync control: one icon, no label (r117).
   *
   * It replaces the sort button this row used to hold. 「把主界面的"最近阅读"按钮删了，换成一个同步
   * 按钮，用图标表示即可」 — so it is an icon button and nothing else: **no visible text**, with
   * `accessibilityText` carrying the name for a screen reader (icon-only was the request, and a
   * control a reader cannot name is a control half the users cannot find).
   *
   * ## The symbol
   *
   * `sys.symbol.arrow_clockwise`. It is not a new choice: the shell already names that symbol for
   * **同步** — `Index.settingsRow('sync', '同步', $r('sys.symbol.arrow_clockwise'), 1)` — so the
   * shelf's button wears the same glyph as the settings row that leads to the same page. A
   * `SymbolGlyph` component rather than a `SymbolGlyphModifier`, because this is a child of the button
   * and not a style handed to a component that takes one (`BottomTabBarStyle`, `MenuItem`); both forms
   * are used in this file and the difference is only where the glyph is consumed. `@kit.ArkUI`'s
   * `SymbolGlyphModifier` is already imported (the menu's trash row needs it), which is the import
   * whose absence is the recorded cause of icons that do not render.
   *
   * ## What it says about the pass
   *
   * The state is the shell's `syncBusy` — **the same field the 设置 → 同步 page's own buttons disable
   * themselves on**, so this button and that page cannot disagree about whether a pass is in flight,
   * and no new state was added for it. Three things carry it, so it does not depend on the framework's
   * idea of a disabled button:
   *
   *  - `enabled(!syncBusy)`: a second tap during a pass is refused, exactly as on the sync page;
   *  - the glyph becomes a `LoadingProgress` ring while a pass runs — unmistakably "working" rather
   *    than "dimmer", and the same component this page already uses for its own loading state;
   *  - `accessibilityText` says 「同步进行中」 rather than 「同步」, so the state is available to a
   *    reader who cannot see the ring at all.
   *
   * **Failure is deliberately not shown here.** The only failure signal the shell has is the text of
   * its last summary/error line, and turning *that* into a red icon would mean either matching error
   * strings (a guess) or adding a flag beside `syncMessage` (a second source of truth for the same
   * fact). Both are worse than what already exists: a failed pass raises `toast('同步失败')` and leaves
   * its message on the 设置 → 同步 page, which is where a pass is configured and where its detail
   * lives. This button is a trigger, and it reports the one thing a trigger can honestly report.
   *
   * ## Layout, and the fill this control no longer has (r119)
   *
   * `MIN_TAP_TARGET` (48 vp) square, so the touch target is the guidance minimum even though the glyph
   * inside it is `ROW_ICON_SIZE` (24 vp). `Button({ type: ButtonType.Circle })` because an icon button
   * is a circle — with both width and height set, the radius is half the smaller side and any
   * `borderRadius` would be ignored.
   *
   * The user, on r118's version: 「然后两个按钮现在都是黑色的，帮我换成透明的吧，不然沉浸光感看不出来」.
   * The circle's fill was `palette.primary`, and a child's own `backgroundColor` sits **above** the
   * material layer (沉浸光感常见问题 · 材质效果的显示层级问题: 「自绘制组件的背景色作用于内容层，材质效果作用
   * 于背板层，而内容层位于背板层之上」) — so the fill was a black disc over the surface this row was moved
   * into the title bar to get. It is now `Color.Transparent`.
   *
   * **`Color.Transparent` rather than no `backgroundColor` at all**: an unset `Button` background is the
   * framework's own button colour, which follows the **system** colour mode and would paint exactly the
   * disc that is being removed. Removing the attribute and setting it transparent are not the same
   * thing, and only one of them is transparent.
   *
   * ## The glyph is the system's invertible resource, not a palette constant
   *
   * With no fill behind it the glyph sits on the material, and a hardcoded colour there cannot adapt:
   * 自动反色 「使用硬编码的颜色值（如 Color.White、'#FFFFFFFF'）不会触发自动反色，仅对…特殊资源（见下表1）
   * 值时生效」. `$r('sys.color.icon_primary')` is one of 表1's resources and resolves `#E5000000` in the
   * light system mode and `#E5FFFFFF` in the dark one, so the glyph is the system's own "primary icon"
   * tone on whichever surface it lands — and on a `THIN` material with `colorInvert` on (this header's
   * material carries it; `headerBarMaterialOption` records why) the framework may re-tone it against a
   * backdrop that disagrees with the system mode.
   *
   * **Measured for the case where there is no material at all**, since the opaque branch of the header
   * paints `palette.card` and there is no inversion to lean on there (composited at the resource's own
   * `0xE5`, against `palette.card` / the page the material would otherwise cover):
   *
   *   light  `#1A1A1A` on `#FFFFFF` 17.404:1 · on `#F0F0EC` 15.541:1
   *   dark   `#E8E8E8` on `#1E1E1E` 13.606:1 · on `#121212` 15.149:1
   *   sepia  `#191816` on `#F5EBD7` 14.994:1 · on `#F0E6D2` 14.463:1
   *
   * All six are far above the 4.5:1 floor, so unlike the rest of the header this control needs **no
   * second branch** for the no-material device: the same glyph resource is legible on both surfaces in
   * all three themes. `verify-themes.mjs` computes those six numbers from the palettes and from the
   * app's own system-mode mapping rather than trusting this paragraph.
   *
   * ## The press state, which is now the only thing drawing here
   *
   * `stateEffect: true` is unchanged (and is what `Button` defaults to). The declaration of
   * `stateEffect` says the press overlay is composited **on the background colour after the state style
   * is applied**, so a fully transparent background leaves the framework with a translucent overlay over
   * the material rather than a fill to darken — the press feedback is a grey wash over the material
   * instead of a darker disc. Whether the framework's overlay is strong enough to read on a thin
   * material is **not verifiable without the device** (see the round's hand-run list); what is certain
   * from the declaration is that no fill is required for `stateEffect` to draw.
   */
  @Builder
  private syncIconButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      if (this.syncBusy) {
        LoadingProgress()
          .width(ROW_ICON_SIZE)
          .height(ROW_ICON_SIZE)
          // **Not on 表1.** `colorInvert`'s list names `Text`/`Button`/`SymbolGlyph` `fontColor`,
          // `Image.fillColor`, `Search`'s parts, … and `LoadingProgress.color` is not among them, so
          // this ring is *statically* coloured — it cannot be re-toned against the material. The
          // resource is still the right one (it is the system's primary-icon tone for the mode this app
          // forces from its own theme), and it is deliberately the same value as the glyph beside it so
          // the two states of one control are one colour.
          .color($r('sys.color.icon_primary'))
      } else {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(ROW_ICON_SIZE)
          // 表1 lists `SymbolGlyph`'s `fontColor` as one of the attributes that participates in
          // 自动反色; a palette constant here would not, and would be the tone of the material it is
          // drawn on as soon as the material's backdrop disagreed with it.
          .fontColor([$r('sys.color.icon_primary')])
      }
    }
    .width(MIN_TAP_TARGET)
    .height(MIN_TAP_TARGET)
    .backgroundColor(Color.Transparent)
    .enabled(!this.syncBusy)
    .accessibilityText(this.syncBusy ? '同步进行中' : '同步')
    .onClick((): void => {
      // The shell's own pass, in the same mode the sync page's 同步 button uses. Not awaited and not
      // `void`-ed, matching that button: `runSync` reports its own outcome and never rejects.
      this.onSync();
    })
  }

  /**
   * The header's import control: one icon, no label (r117).
   *
   * 「导入也换成图标」. Same construction as `syncIconButton` above and for the same reasons — a 48 vp
   * circle with **no fill of its own** (r119: 「两个按钮现在都是黑色的，帮我换成透明的吧」 — the fill
   * covered the material the whole header exists to carry), the glyph at `ROW_ICON_SIZE` in the system's
   * invertible `$r('sys.color.icon_primary')` rather than a palette constant, and
   * `accessibilityText('导入')` for the name — so the row's two controls are one kind of thing rather
   * than two. The 48 vp tap box is the box; what changed is only what is painted inside it.
   *
   * ## The symbol, and why these two cannot be confused
   *
   * `sys.symbol.plus`. The action is *add books to this shelf* — the same action the empty state
   * spells out as 「导入书籍」 — and a plus is the platform's own word for adding. It is also the
   * farthest glyph from the sync button's circular arrow that this icon set offers: the requirement
   * is that the two remain distinguishable at a glance, and two arrow-shaped glyphs (say
   * `arrow_down_to_line` beside `arrow_clockwise`) would be one arrow apiece at 24 vp. `sys.symbol.plus`
   * is in the SDK's own symbol table (`toolchains/id_defined.json`), which is the check that matters:
   * an unknown `sys.symbol.*` name is a **compile** error, not a blank glyph.
   */
  @Builder
  private importIconButton() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(ROW_ICON_SIZE)
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(MIN_TAP_TARGET)
    .height(MIN_TAP_TARGET)
    .backgroundColor(Color.Transparent)
    .accessibilityText('导入')
    .onClick((): void => {
      this.onImport();
    })
  }

  /**
   * The shelf header inside a `Navigation` title bar — **the only place the framework serves a
   * system material to it.**
   *
   * ## Why a title bar, and why here
   *
   * `systemMaterial` is declared on `CommonMethod` (`common.d.ts:22642`, `@since 26.0.0`), so it looks
   * like a universal attribute. It is not one. The platform's own enablement guide says it in one
   * sentence, and this is the sentence this project's rule came from:
   *
   *   「其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中 barPosition 为 BarPosition.End 的
   *    底部 TabBar 中生效。在其他区域中设置沉浸光感效果不生效。」
   *   — 开启沉浸光感, https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-enable
   *
   * and the FAQ names the runtime tell for the violation:
   *
   *   「日志中存在打印：Material inactive: out of scope. Use component in navigation title bar or
   *    Tabbar.」 — 沉浸光感常见问题 · 组件不在沉浸光感生效范围
   *
   * So the search field and the two icon buttons — which live in the shelf tab's *content* today —
   * cannot be given the material where they are. They are moved into a title bar instead, which is
   * the documented remedy rather than this app's invention: the FAQ's own 解决措施 is 「将需要沉浸光感
   * 效果的组件置于 Navigation/NavDestination 标题栏…中」, and its worked example sets the material on
   * a `Column` **inside the title builder** while the identical `Column` in the content area renders
   * with no material.
   *
   * The header is a **local container** inside the bar rather than the bar itself, which is the shape
   * the power guide's 正例 prescribes — 「在Navigation标题栏中为局部容器设置沉浸式系统材质，材质生效且
   * 面积可控」 (沉浸光感功耗优化) — one 359 vp × 92 vp surface instead of a half-screen slab. It is also
   * the same shape `ReaderView.topBarTitle` already uses for the reader's floating top bar, so the app
   * has one way of hosting a material and not two.
   *
   * ## The `Navigation` is a material host, not a navigation container
   *
   * No `NavPathStack`, no destination, and **no content**: it exists for its title bar, exactly as the
   * reader's top bar does. It is a sibling *above* the grid in this page's `Column`, not an overlay, so
   * the bar reserves its own height in the layout and the grid simply starts below it — there is no
   * second `contentStartOffset` to keep in step with it, and nothing to measure.
   *
   * That is why this is the low-risk form of the change: the shell's own `Navigation`
   * (`Index.build`), its `settingsPathStack`, its `NavDestination` map, the r107 insets, the HdsTabs
   * shell and the floating tab bar are all untouched. The nesting is the one the reader already has
   * (a `Navigation` inside a `TabContent` inside the shell) and it is what keeps the material's
   * carrier local to the page that needs it.
   *
   * ## The four attributes that are not cosmetic
   *
   *  - **`hideBackButton(true)`** — there is no back to go to, and the framework's own back control
   *    would be a fourth thing in a bar that holds exactly three. Setting `title` is also what keeps
   *    the bar displayed in spite of it.
   *  - **`title`'s `backgroundColor: Color.Transparent`** — a material's visual layer sits *under*
   *    `backgroundColor` and `backgroundBlurStyle` (沉浸光感常见问题 · 背景色或背景模糊遮挡材质效果), so
   *    a bar still painting its own band would draw that slab **over** the material and the header
   *    would read as flat. Transparent leaves the material as the only surface.
   *  - **`barStyle: BarStyle.STACK`** — the material guide's own recommendation
   *    (「建议设置沉浸光感时，使用 barStyle 为 STACK 样式，以便 Navigation 内容区延伸至标题栏区域，获得
   *    沉浸光感的最佳体验」). It extends the *content* under the bar; this bar sits above the grid
   *    rather than over it, so the extension changes nothing here, and the style is set because the
   *    guide names it as part of the material configuration rather than for its layout effect.
   *  - **`expandSafeArea([], [])`** — `Navigation` expands into the safe area by default, and this
   *    component's own box must not grow into the band the header's padding is measured against
   *    (「expand nothing」, the same pair `ReaderView.topBar` passes).
   */
  @Builder
  private headerBar() {
    Navigation() {
      // Deliberately empty. See the note above: this `Navigation` exists for its title bar.
    }
    .width('100%')
    .height(this.headerBarCurrentHeight())
    .hideBackButton(true)
    .title({ builder: this.materialHeaderTitle, height: this.headerBarCurrentHeight() },
      { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
    .expandSafeArea([], [])
  }

  /**
   * The title bar's height in vp **with the 「书架」 title showing**: the measured system band, the
   * title's line box, the header row, and the two gaps that separate them.
   *
   * Derived rather than fixed, and that is the point: the band is a property of the device (39 vp on
   * the reference phone) and the row is `MIN_TAP_TARGET`, so a fixed number would be wrong on the first
   * device with a different status bar. The other two tabs still take the same band through
   * `Index.pageTitle`'s padding, so this bar and they cannot disagree about where the band ends — the
   * one measurement is still the shell's (`Index.shellTopInsetVp`) and it still reaches both.
   *
   * `TAB_CONTENT_TITLE_HEIGHT` is deliberately **not** used as the bar's height. It is 56 vp because
   * the reference keeps its page title as a fixed anchor a scrolling list collapses against; this bar
   * cannot be that, because it holds a 48 vp control *and* a 30 fp title, and 56 vp would clip both.
   *
   * **r119: this is now one of two heights rather than the height.** The sum below is written in the
   * order band → title → row → band, and the **middle** `SPACE_S` is the bar content's bottom padding
   * (the content column's own `padding` is top `topInsetVp + SPACE_S`, bottom `SPACE_S`), so the whole
   * expression is exactly that column's measured content: `39 + 8 + 35.25 + 48 + 8 = 138.25 vp`.
   * `headerBarCollapsedHeight` is the same sum with the title's line box removed.
   */
  private headerBarHeight(): number {
    // The title's line box comes from `headerTitleHeight`, not from a second literal: the bar's
    // height and the title's own reserved space are two halves of one arithmetic, and the moment they
    // are two numbers the title clips inside its own bar or leaves a gap nobody can explain.
    return this.topInsetVp + SPACE_S + this.headerTitleHeight() + SPACE_S + MIN_TAP_TARGET;
  }

  /**
   * The title bar's height in vp with the 「书架」 title hidden: the same arithmetic, one term shorter.
   *
   * `topInsetVp + SPACE_S + MIN_TAP_TARGET + SPACE_S` = `39 + 8 + 48 + 8` = **103 vp**, i.e. the same
   * 8 vp above and below the row the showing bar has. The 35.25 vp that leaves the sum is
   * `TYPE_TITLE_LARGE × 1.175`, the title's own line box — **the region the user asked to disappear**
   * (「我不是只想文字消失，我是想那块区域也消失。也就是说下拉的时候搜索框、同步按钮和导入按钮要顶到
   * 现在标题的框的位置。」). Nothing else moves: the band is still at the top (so the first line of ink
   * still clears the status bar) and the row lands exactly where the title's box was.
   */
  private headerBarCollapsedHeight(): number {
    return this.topInsetVp + SPACE_S + MIN_TAP_TARGET + SPACE_S;
  }

  /**
   * The header's height right now — **the one number the bar, its material carrier and the grid all
   * read.**
   *
   * `Navigation.height` and `Navigation.title`'s `height` are handed the same call, and so is the
   * material-carrying `Column` inside the title builder. That is deliberate and it is the whole of how
   * the material follows a shrinking bar: the carrier's box *is* the current height, so the material
   * can never be painted beyond its own content (which would leave the search row floating on an
   * unpainted strip) nor stop short of it. The grid needs nothing of its own either — its top edge is
   * this bar's bottom edge, and `ShelfPage.build` places it as the next sibling.
   */
  private headerBarCurrentHeight(): number {
    return this.titleHidden ? this.headerBarCollapsedHeight() : this.headerBarHeight();
  }

  /**
   * The title bar's content: the 「书架」 title, then the search field and the two icon actions.
   *
   * The title's own builder (`headerTitle`) carries the hide/show rule; the row's (`headerRow`) carries
   * the width arithmetic. What is decided *here* is only who paints the box they sit in, because that
   * is the one thing that differs between a device the framework serves a material to and one it does
   * not — and ArkTS cannot apply an attribute conditionally inside a single component call, so the box
   * exists twice, containing the same two builders.
   *
   * ## Why the title lives inside this bar rather than in `Index.pageTitle`
   *
   * Because a `Navigation` title bar's content is this component's builder, and the title has to be
   * *in* it to be part of the same surface. Keeping a copy in `Index` would draw 「书架」 twice — the
   * duplication the audit's `pageTitle` section exists to prevent on the settings detail pages. The
   * title is therefore handed in as a string (`pageTitle`) and drawn here from the same tokens
   * `pageTitle` uses, so the three tabs still cannot disagree about the step, the weight or the colour.
   *
   * ## What each branch paints
   *
   * The material branch carries **no background at all**: a material's visual layer sits *under*
   * `backgroundColor` and `backgroundBlurStyle`, so a background beside it is the slab that covers it
   * (沉浸光感常见问题 · 背景色或背景模糊遮挡材质效果). The opaque branch is the palette's `card` — the
   * surface this row already sat on, since the page is `background` — so a device that cannot be served
   * a material sees the header it had before this round rather than a hole where one should be.
   */
  @Builder
  private materialHeaderTitle() {
    // The surface exists twice because ArkTS cannot apply an attribute conditionally inside one
    // component call, and the two differ in **who paints**, not in what they contain.
    if (this.headerMaterial !== undefined) {
      Column() {
        this.headerTitle()
        this.headerRow()
      }
      .width('100%')
      // **The animated height, not `'100%'` of the bar.** r119: the bar shrinks when the title's
      // region collapses, and this carrier is what the material is painted on — so its box has to be
      // the same expression the bar's box is, frame for frame, or the material would stop short of the
      // row it carries and leave it floating on an unpainted strip. `headerBarCurrentHeight` carries
      // that argument.
      .height(this.headerBarCurrentHeight())
      .padding({ left: SHELF_GRID_PADDING, right: SHELF_GRID_PADDING, top: this.topInsetVp + SPACE_S, bottom: SPACE_S })
      .alignItems(HorizontalAlign.Start)
      // **The only `systemMaterial` this page carries, and it is inside a `Navigation` title bar's
      // builder.** `headerBar` is what makes it in scope; see that builder for the citation.
      .systemMaterial(this.headerMaterial)
    } else {
      Column() {
        this.headerTitle()
        this.headerRow()
      }
      .width('100%')
      // The same box in the opaque branch. It is not cosmetic here either: this is the surface a
      // device that cannot be served a material sees, and it has to shrink with the bar for the same
      // reason — otherwise the header would keep a card-coloured strip under a collapsed title.
      .height(this.headerBarCurrentHeight())
      .padding({ left: SHELF_GRID_PADDING, right: SHELF_GRID_PADDING, top: this.topInsetVp + SPACE_S, bottom: SPACE_S })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.palette.card)
    }
  }

  /**
   * One line box of the title, in vp: the constant both heights above are built from, and the exact
   * distance the header loses when the title's region collapses.
   *
   * A separate helper rather than one expression written twice, and now load-bearing in three places:
   * the showing bar adds it, the collapsed bar omits it, and the title's own row is either this or 0.
   * Written as two literals they would be three numbers that have to agree.
   *
   * The `1.175` is the reference device's **own measured line-box ratio** for this font, not a
   * typographic guess — `Tokens.ets` records both measurements taken on the device (1.161 em for the
   * 12 fp caption and 1.175 em for the 28 fp cover title) and the larger of the two is used here, which
   * is the conservative end: at 30 fp a clipped line box would be worse than a spare 2 vp.
   */
  private headerTitleHeight(): number {
    return TYPE_TITLE_LARGE * 1.175;
  }

  /**
   * The search field and the two icon actions — the row that used to be the top of this page's
   * `Column`.
   *
   * Unchanged in content, arithmetic and order. What moved is its **place in the tree**, and that is
   * the whole of what the material needed:
   *
   *   359.1 vp content  = 391.1 − 2 × 16            (SHELF_GRID_PADDING, both sides)
   *   247.1 vp search   = 359.1 − 48 − 48 − 2 × 8   (two MIN_TAP_TARGET circles, two 8 vp gaps)
   *
   * The two circles are fixed-size and the search field is the only weighted child, so the row cannot
   * overflow: there is nothing for it to squeeze but the field. The right padding is `SPACE_S` here
   * rather than the grid's `SHELF_GRID_PADDING` — that comes from the parent `Row`, so the two are not
   * added, and `MIN_TAP_TARGET` + `SPACE_S` match the gap the row already had above and below it.
   */
  @Builder
  private headerRow() {
    Row({ space: SPACE_S }) {
      Search({ value: this.search, placeholder: '搜索书名或作者' })
        .layoutWeight(1)
        .onChange((value: string): void => {
          this.search = value;
          this.onReload();
        })
      this.syncIconButton()
      this.importIconButton()
    }
    .width('100%')
    .height(MIN_TAP_TARGET)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * The 「书架」 title — the one thing in this header that moves, and since r119 the region it sat in
   * moves with it.
   *
   * ## The user's correction, and what it costs
   *
   * r118 hid the title by fading the text and **reserving** its line box. The user rejected that
   * arrangement in as many words:
   *
   *   「我不是只想文字消失，我是想那块区域也消失。也就是说…搜索框、同步按钮和导入按钮要顶到现在标题的框
   *     的位置。」
   *
   * So the row's height is now `headerTitleHeight()` **or 0**, and the header bar's height loses exactly
   * that same term (`headerBarCollapsedHeight`). Three properties are derived from `titleHidden` here —
   * this one, `opacity` and `translate` — plus one more in the bar's height helper, and the count is
   * asserted.
   *
   * ## This IS a layout animation, deliberately, and the r118 objection does not survive the hysteresis
   *
   * r118 refused to reclaim the space because it would "grow the grid by ~44 vp **during the gesture**"
   * (r118's own estimate; the exact term is `headerTitleHeight()`, 35.25 vp), naming r109's whole-row
   * pop in this very grid and the reader re-paginating when a bar changed its measured page box. Both
   * of those are real, and neither is what this is:
   *
   *  - **The reflow happens once per toggle, not once per frame.** The decision is not taken here and
   *    not taken per frame: `Index.onShelfTitleScroll` reads a **cumulative** offset against a 24 vp
   *    hide threshold and a 12 vp show threshold, so a 12 vp band of hysteresis stands between the two
   *    states and the flag can only flip on a movement that crosses the band. Between the crossings
   *    `titleHidden` is constant, so the layout is constant — and scrolling inside the band changes
   *    nothing at all.
   *  - **Growing the grid's *box* is not re-paginating its content.** r109's pop was a `Grid` with a
   *    bottom **`padding`**, where ArkUI refuses to draw a child that begins wholly inside the padding
   *    band (「如果子组件完全位于padding区域内，则不会显示」) and so admitted a row whole and in one
   *    frame. That mechanism needs padding, and this grid still has none — its bottom clearance is
   *    `contentEndOffset`, deliberately, and r119 leaves both that call and its call site untouched.
   *    The grid's rows are height-derived from the **column width** (`GridItem` → an `aspectRatio` cover
   *    in a `columnsTemplate` grid), not from the grid's own height, so the 35.25 vp the box gains
   *    reveals 35.25 vp more of the next row and moves no row's top edge. It is the same thing that
   *    happens when the user scrolls by 35.25 vp, which is the gesture already in progress.
   *  - **The reader is not this case either.** Its re-pagination came from a *measured page box* handed
   *    to Reader Kit; nothing here is measured by, or reported to, anything.
   *
   * What has NOT changed is the mechanism's shape: the collapse rides the same motion-gated animation
   * the fade does (`Index.applyShelfTitleHidden`), so with 「设置 → 动画」 off it snaps to the final
   * geometry in one frame — no tween, and no `duration: 0`.
   *
   * The movement is upward, which is the direction the gesture is going, so the title reads as receding
   * rather than as sliding sideways out of a header that is staying put. The text is not clipped while
   * it goes: a `Row` does not clip by default, `opacity` reaches 0 on the same curve, and adding
   * `clip(true)` here would cut the glyphs mid-slide for no gain.
   */
  @Builder
  private headerTitle() {
    Row() {
      Text(this.pageTitle)
        .fontSize(TYPE_TITLE_LARGE)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.palette.foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(this.titleHidden ? 0 : this.headerTitleHeight())
    .opacity(this.titleHidden ? 0 : 1)
    .translate({ y: this.titleHidden ? -HEADER_TITLE_HIDE_OFFSET : 0 })
  }

  build() {
    Column() {
      // Search, the two actions and the title all live in the shelf, not the shell, because they only
      // affect this list.
      //
      // **They are no longer the page's first row.** r117's row — the search field between the sync
      // and import circles, padded by `SHELF_GRID_PADDING`, top and bottom by `SPACE_S` — is now
      // `headerRow()` inside `materialHeaderTitle`, which is the content of the `Navigation` title
      // bar above. The geometry is unchanged; only the host moved, and it moved because the framework
      // serves 沉浸光感 to a component in a title bar and to nowhere else.
      //
      // **The sort button is still gone (r117)** and this round does not restore it: its slot holds the
      // sync button, and 导入 is the circle beside it. The ability to re-order the shelf is still lost,
      // and it is still recorded on this struct, on `Index.shelfSort` and in the audit.
      this.headerBar()

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
        // Feeds the 「书架」 title's hide/show rule. `handleGridScroll` carries the declaration
        // (`@since 12`), why it is `onDidScroll` rather than the deprecated `onScroll`, and why the
        // callback is not branched on `ScrollState`.
        .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
          this.handleGridScroll(scrollOffset);
        })
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

// `sortLabel` and `nextSort` were deleted here in r117, together with the cycling sort button they
// served. The five orders they named (最近阅读 / 最近添加 / 按书名 / 按作者 / 按进度) still exist in
// `data`'s `BookSort` enum and the repository query still sorts by them; what is gone is any control
// that lets a user choose between them, so `Index.shelfSort` stays at its default. The note is left
// here so that the next reader looking for the sort control finds out where it went rather than
// concluding it was never there.
