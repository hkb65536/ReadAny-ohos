import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
// HDS supplies the floating (悬浮式) bottom tab bar and its 沉浸光感 material. Guarded
// by a capability check at render time, so a device without it uses native `Tabs`
// rather than failing.
import { BlurStrategy, hdsMaterial, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { InkBoatError } from 'core';
import { defaultWebDavConfig } from 'sync';
// `SyncMode` is an enum and `labelForMode` a function, so both are values.
import { labelForMode, SyncMode } from 'sync';
import type { WebDavConfig } from 'sync';
import {
  defaultBinaryOptions,
  defaultLibraryQuery,
  emptyManifest,
  FileStorageRunner,
  manifestCoversAll,
  manifestFromWire,
  manifestToWire,
  planBinarySync,
  // The protocol the remote index implies, as a value. The screen never constructs an
  // engine: `sync()` routes internally and this is only how the result is *named* on
  // screen. Keeping the engines inside the data layer is what stops the two dialects
  // from being mixed at a call site.
  SyncProtocol,
  TransferKind,
  // The v1 per-device protocol's public constants, referenced here so the ArkTS
  // compiler really checks `SyncV1.ets`: an unreferenced HAR (or a barrel whose
  // v1 section nothing consumes) is skipped entirely and its type errors stay
  // hidden until a device runs the code.
  V1_INDEX_PATH,
  V1_INDEX_VERSION,
  V1_SYNC_TABLES,
  v1DevicePath,
} from 'data';import type {
  Book,
  BookBinaryInput,
  Bookmark,
  BookSort,
  Highlight,
  LocalBinaryState,
  Note,
  ReaderSettings,
  ReadingPosition,
  RemoteBinaryState,
  SyncProgress,
  V1TableConfig,
} from 'data';
import { BookSort as Sort, defaultReaderSettings, emptyPosition, resolveOpenPosition } from 'data';
import { appCoreError, bookImporter, bookRepository, bookmarkStore, createBookmarkAt, createNoteAt, databaseDiagnostics, groupCount, highlightStore, initAppCore, isAppCoreReady, noteStore, reader, removeLocalFile, sync, toAbsolutePath, toFileUri } from '../AppCore';
import { AnnotationKind } from './AnnotationsPage';
import type { AnnotationItem } from './AnnotationsPage';
import { AnnotationsPage } from './AnnotationsPage';
import { ReaderView } from './ReaderView';
import { ShelfPage } from './ShelfPage';
import { SyncSettingsPage } from './SyncSettingsPage';
import { apiLevel, asThemeMode, deviceMaterialLevel, FLOATING_BAR_BOTTOM_MARGIN, FLOATING_BAR_CLEARANCE, FLOATING_BAR_MASK_HEIGHT, FLOATING_BAR_SIDE_MARGIN, MIN_TAP_TARGET, materialOption, paletteFor, RADIUS_CARD, RADIUS_CHIP, RADIUS_CONTROL, RADIUS_IMAGE, RADIUS_LABEL, SPACE_M, SPACE_S, SPACE_XS, SurfaceStyle, TAB_LABEL_SIZE, THEME_MODES, ThemeMode, ThemePalette, themeDescription, TYPE_BODY, TYPE_TITLE, TYPE_TITLE_LARGE, TYPE_CAPTION, TYPE_SUBTITLE } from '../theme/Theme';
import { loadAnimationSpeedIndex, loadThemeMode, saveAnimationSpeedIndex, saveThemeMode } from '../theme/AppearanceStore';
import {
  ANIMATION_OPTIONS,
  AnimationOption,
  applyAnimationSetting,
  currentAnimationSpeedIndex,
  DEFAULT_ANIMATION_SPEED_INDEX,
  MOTION_ON_KEY,
  MOTION_SPEED_INDEX_KEY,
  Motion,
  transitionOrIdentity,
} from '../theme/Motion';
import { showToast } from '../ui/Toast';
import { ListRow } from '../ui/ListRow';
import {
  DEFAULT_PROBE_URL,
  formatProbeResult,
  probeCustomMethod,
} from 'sync';
import type { ProbeResult } from 'sync';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatShell';

/**
 * Duration of the tab-content transition when a tab is tapped, in ms.
 *
 * Set explicitly because the platform default is **0 whenever any tab uses
 * `BottomTabBarStyle`** — which all three now do, for their symbols. Tapping a tab
 * therefore switched instantly, while swiping still animated, because the swipe path is
 * driven by the gesture rather than by this value. 300 ms is the platform default for the
 * other tab-bar styles, so a tap and a swipe now feel the same.
 *
 * Phase 2: this is now the **fallback** rather than the value in force.
 * `Motion.tabSwitchDuration()` returns the user's chosen speed, floored at
 * `TAB_SWITCH_MIN_MS` so that selecting 「关闭」 cannot produce a 0 ms tab tap. The
 * constant stays because it is the number in force before the stored setting has been
 * read — the first frame or two — and because a floored speed is easier to reason about
 * with the default written down.
 */
const TAB_SWITCH_DURATION_MS: number = 300;

// The settings-row symbol size was a module-private `SETTINGS_ICON_SIZE = 24` here. It is
// gone because the row it sized is now `ui/ListRow.ets`, which takes its icon size from
// `ROW_ICON_SIZE` in `theme/Tokens.ets` — the same 24, with one owner.

// `FLOATING_BAR_SIDE_MARGIN` and `FLOATING_BAR_CLEARANCE` come from `../theme/Theme`,
// so this file, `ShelfPage` and `AnnotationsPage` cannot disagree about the clearance.

/**
 * Build stamp, shown in the sync tab.
 *
 * A sideloaded build is otherwise indistinguishable from the previous one, and
 * there is no way to confirm the installed HAP contains the code just written
 * rather than an older copy.
 *
 * **This string must be changed by every round that ships a build.** It sat at
 * `r81` while `Books.ets` and `ReaderStore.ets` moved on, which cost a whole
 * on-device investigation: the device displayed `r81` and that was taken as proof it
 * ran the current source, when the stamp was simply stale. A stamp nobody updates is
 * worse than no stamp, because it is read as evidence.
 *
 * `r83` is the build where tapping a bookmark, highlight or note opens the reader at
 * that annotation: `openReader` now takes the annotation's locator as an explicit
 * override and `ReaderView.annotationStart` resolves it — `spine:{n}:{domPos}` exactly,
 * a ReadAny CFI to its chapter. The `(annotation-jump)` marker is part of the string
 * rather than a comment so that the stamp itself says which build this is: `r82` was
 * the same calendar day and otherwise indistinguishable on screen.
 *
 * `r84` is the reader-chrome redesign: `ReaderView` owns the whole reader screen, its
 * top bar is exactly 返回 · chapter title (centred) · page-within-chapter with no refresh
 * control, the page area carries nothing overlaid, and the bottom bar is the
 * display-only progress read-out plus 目录 / 书签 / 笔记 / 设置. The shell no longer draws
 * its own reader header (`readerScreen`), which is what makes the top bar exactly three
 * elements. Opaque surfaces only — no `systemMaterial`, no blur.
 *
 * `r86` was the txt-to-epub importer. `r87` is the shelf's per-book action menu: a `⋯`
 * on each cover's bottom-right opening a 224 vp `Menu` whose one entry is 删除, which
 * asks ReadAny's own confirmation question before it removes anything, and the two
 * deletions behind that answer (`deleteBookFromShelf` here, `Books.softDeleteBook`).
 * The first build that carries the 沉浸光感 material on a popup surface as well as on
 * the tab bar, which is why the string names the menu rather than the delete alone:
 * `menuMaterialOption` is the part that changes what a device looks like.
 *
 * `r88` is the shelf's coverless card. Its placeholder was painted with the shared
 * `muted` control fill, which in the light theme is `#F3F3EF` on a `#F0F0EC` page — a
 * 1.03:1 difference, so a book with no cover had no visible surface and the grid read as
 * gaps. It now paints `palette.placeholderSurface`: `#D8D8D8` in the light theme, 1.25:1
 * against the page and above the white card's own 1.14:1 edge, with
 * `placeholderForeground` (`#5C5C66`, 4.64:1) darkening with it to keep the initial
 * letter legible. Dark and sepia carry over the values they already rendered, unchanged.
 * Nothing else about the card moved — not the `⋯` trigger, not the layout, not the menu.
 *
 * `r89` moves the menu's 沉浸光感 to where the framework actually accepts it: the
 * `bindMenu` **options** object (`MenuOptions.systemMaterial`, inherited from
 * `ContextMenuOptions`), at `ImmersiveStyle.THICK`, instead of a `.systemMaterial(...)`
 * attribute on the `Menu`. The attribute is out of scope outside a Navigation title bar
 * or a bottom TabBar — the device logged `Material inactive: out of scope. Use component
 * in navigation title bar or Tabbar.` and drew the menu from the palette — while a
 * popup's own options field is served page-wide. No `module.json5` switch is set, so the
 * material lands on this menu and on nothing else. The `Menu`, its width, its radius, its
 * divider, its one 删除 row and the palette fallback are unchanged.
 *
 * `r91` is the reader page theme. The reader had its own `themeColor` / `fontColor` /
 * `nightMode` and its own 夜间 toggle, with nothing connecting them to `themeMode` — so the
 * sepia theme painted the window sepia and the page white, and dark mode never produced
 * light text. The page colours are now derived from the application theme by
 * `readerAppearance(mode)`: sepia `#F0E6D2`/`#3D2B1F`, dark `#121212`/`#F5F5F5`, light
 * `#F0F0EC`/`#090909`, background and text from one palette in one call. The 夜间 toggle is
 * removed (ReadAny's reader has no theme control at all) and the persisted `nightMode` /
 * `themeColor` / `fontColor` are dropped from the reader's settings blob on load, so a
 * device carrying stale settings cannot keep the white page.
 *
 * `r92` is the reader sheets' surfaces, their blur outside, their draggable height, and three
 * page titles. Four things, one build:
 *
 *  - **A row inside a sheet is a surface of its own.** The row and the sheet body were both
 *    `palette.card` — pixel-identical in all three themes, so the settings row was just a 1 vp
 *    hairline around nothing. The sheet body stayed `card` and the row became the palette's new
 *    `cardSubtle`, one step off it (light `#F6F6F2`, dark `#2C2C2C`, sepia `#FBF4E5`), with the
 *    row's own controls moved to the edge role because `muted` was a near-match for the row it
 *    sat on. Every text-on-surface pair stays above 4.5:1; `Theme.ets` carried the table.
 *    (**r94 inverted the pair and deleted the token** — the body is `background` and the row is
 *    `card` now; see below.)
 *  - **Dragging the header resizes the sheet again**, with `SHEET_MIN_HEIGHT` (`'50%'`) shared
 *    by all four as both the opening height and the floor, and `SheetSize.LARGE` as the detent
 *    above it. Dragging the **content** still scrolls; the header holds no scrollable, which is
 *    what keeps the split. (r92 also refused a downward drag at the floor; **r94 removed that
 *    refusal** — see below.)
 *  - **The area outside a sheet is blurred** — 毛玻璃, explicitly *not* 沉浸光感: a plain
 *    `foregroundBlurStyle` on the page area while a sheet is up, which is the only mechanism
 *    this SDK offers (`SheetOptions.blurStyle` is the sheet's own background) and the one the
 *    reference uses.
 *  - **书架 / 书签笔记 / 设置 each carry a large top-left title** (`pageTitle`, 30 fp bold),
 *    fixed above their scrollables, following the reference's 更多 page.
 *
 * `r93` extends that surface treatment outward and takes the outlines away. Two things:
 *
 *  - **The app's own settings surfaces are bounded by their fill and nothing else.**
 *    外面的设置菜单 = the 设置 tab and the two pages behind it: `ui/ListRow.ets`'s index rows,
 *    the theme and animation rows, the two sync progress cards, the method-probe panel and
 *    `SyncSettingsPage`'s two panels each dropped the 1 vp `palette.border` hairline they
 *    carried (「把内容的边框去掉」). They keep the palette's `card` fill, which is already a
 *    step off the page — 1.143:1 (light), 1.124:1 (dark), 1.047:1 (sepia) — rather than moving
 *    to `cardSubtle`: on a `background` body that would *weaken* the light theme to 1.055:1
 *    (below the reader's own confirmed-visible 1.083:1) in exchange for sepia, and it would
 *    drag the token's nested-control consequence — `muted` stops reading on a `cardSubtle`
 *    surface — onto the sync progress card. `Theme.ets` and `ui/ListRow.ets` carry the
 *    reasoning; `verify-themes.mjs` now holds those three fill figures, because until this
 *    round the hairline was the backstop and nothing had to hold the fill.
 *  - **The reader's settings row lost its hairline too**, and there the fill is what carries
 *    it: `cardSubtle` on the sheet measures 1.083 / 1.194 / 1.080:1. The 2 vp `primary` rings
 *    on the theme and animation rows stay: those are the *selected* state, not an outline.
 *
 * `r94` is the user's device review of r93, and it reverses two of its decisions. Three things:
 *
 *  - **The hairline borders are back**, on every surface r93 stripped them from —
 *    `ui/ListRow.ets`'s index rows, the theme and animation rows, the two sync progress cards,
 *    the method-probe panel, `SyncSettingsPage`'s two panels and the reader's settings row.
 *    r93 removed them on the arithmetic (`card` against `background` is 1.143:1 light,
 *    1.124:1 dark, **1.047:1 sepia**) and the arithmetic was not wrong — it was *insufficient*.
 *    The user looked at the installed build and said 「还是保留边框吧，护眼模式下确实看不清」:
 *    in 护眼 the borderless cards are unreadable. Sepia's 1.047:1 was flagged as marginal when
 *    r93 shipped, and that flag was the correct reading of the number. The lesson is recorded
 *    rather than the number re-argued: a fill ratio is not a measurement of whether a surface
 *    is visible, and this project has now been misled by a passing ratio once.
 *    The 2 vp `primary` **selection** rings stay — they are a state, and the hairline is a
 *    boundary — so those two `borderWidth` expressions are `2 : 1` again rather than `2 : 0`.
 *  - **The reader's four sheets are 背景灰 + 内容白, like the app's settings page.**
 *    The user's 「阅读界面的设置的颜色是背景白内容灰，外面的设置里是背景灰内容白。把这两个地方
 *    的配色统一成背景灰内容白。其他三个sheet的背景色也统一成灰」. So `sheetCard()` — the sheet
 *    body, the shared header and the `bindSheet` container — is `palette.background`, and
 *    `sheetRow()` is `palette.card`. That is the exact pair the 设置 tab already paints
 *    (`background` page, `card` cards), which is the point of the change. All three themes.
 *  - **`cardSubtle` is gone.** It existed only to be the reader's row on a `card` body; with
 *    the body grey and the row `card`, it had no reader left. Removing a role rather than
 *    leaving it defined-but-unread is the same rule the sheet accessors follow.
 *
 * r98 completes the cycle discipline r96 started, one variable further in, and the report is
 * from the device seconds after installing r97: 「如果正常打开，遮罩是正常的。如果关掉立马打开，遮罩会
 * 出现异常」. r96/r97 paired every write of `sheetOpen` with a write of the blur gate
 * (`sheetBlur`), but the **repair** in `onSheetOpenSettled` — the one place the app re-raises
 * `sheetOpen` after the framework's late `$$` write-back clobbered an open — re-raised it alone.
 * So the cycle in which the previous dismissal is still live ended with the sheet up (the repair
 * put it back) and the gate down (the late `onWillDismiss`/`onDisappear` had cleared it): a
 * sheet on screen with no 毛玻璃 behind it. Two changes, both in `ReaderView`: the repair raises
 * the gate in the same frame it raises the binding, and the clear in `onSheetWillDismiss` is
 * given the cycle it belongs to (`sheetDismissalIsStale`, built from the cycle fields
 * `onSheetOpenSettled` already uses) so a dismissal that is not of the live sheet cannot take
 * the frost off one that is. `onDisappear`'s clear stays unconditional, so the gate can still
 * never outlive the sheet. `sheetOpen = false` is still written exactly once.
 */
export const BUILD_STAMP: string = 'build 2026-10-13 r102 (cutout-inset-and-shared-bar-width)';

/**
 * A byte count as something a person can read.
 *
 * Only ever applied to a number the transfer layer actually measured — a download's
 * received bytes and the server's `Content-Length`. It is never used to estimate a size, so
 * a value shown here is a fact about a transfer rather than a guess about one.
 *
 * A megabyte is 1024 × 1024 rather than 10^6, matching what a file manager on the device
 * reports for the same file; mixing the two conventions is how a progress line ends up
 * disagreeing with the storage app the user checks it against.
 */
function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return `${Math.round(bytes)} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}

/**
 * Binary-sync decision probe.
 *
 * `planBinarySync` is the rule that decides whether a book file is uploaded or
 * downloaded. Getting it wrong either re-uploads the whole library on every sync
 * or leaves a device without the files it needs, and neither shows up as an error.
 * Rendering the decisions makes a device install verify the rule on real hardware,
 * not just at compile time.
 *
 * It also keeps the binary-sync module genuinely compiled: a HAR that nothing
 * imports is skipped entirely by the ArkTS compiler.
 */
function probeBinaryPlan(): string[] {
  const options = defaultBinaryOptions();

  const localOnly = emptyLocal();
  localOnly.fileExists = true;
  localOnly.fileSize = 1000;
  const remoteMissing = emptyRemote();

  const bothPresent = emptyLocal();
  bothPresent.fileExists = true;
  bothPresent.fileSize = 1000;
  const remotePresent = emptyRemote();
  remotePresent.fileExists = true;
  remotePresent.fileSize = 1000;

  const neither = emptyLocal();
  const neitherRemote = emptyRemote();

  const inputLocalOnly: BookBinaryInput = makeInput('book-a', '三体', 'epub', localOnly, remoteMissing);
  const inputBoth: BookBinaryInput = makeInput('book-b', '球状闪电', 'epub', bothPresent, remotePresent);
  const inputNeither: BookBinaryInput = makeInput('book-c', '黑暗森林', 'epub', neither, neitherRemote);

  const plan = planBinarySync([inputLocalOnly, inputBoth, inputNeither], options);

  const lines: string[] = [];
  lines.push(`uploads=${plan.uploads.length} (expect 1: only the local-only book)`);
  lines.push(`downloads=${plan.downloads.length} (expect 0)`);
  lines.push(`markLocal=${plan.markLocal.length} (expect 2)`);
  lines.push(`markRemote=${plan.markRemote.length} (expect 0)`);
  lines.push(`orphans=${plan.orphans.length} (expect 1: neither side has it)`);
  if (plan.uploads.length > 0) {
    lines.push(`upload kind=${plan.uploads[0].kind} (expect ${TransferKind.BOOK_UPLOAD})`);
    lines.push(`upload path=${plan.uploads[0].remotePath}`);
  }

  // A receive-only pass must not plan any upload.
  const receiveOnly = defaultBinaryOptions();
  receiveOnly.disableUploads = true;
  const roPlan = planBinarySync([inputLocalOnly], receiveOnly);
  lines.push(`receiveOnly uploads=${roPlan.uploads.length} (expect 0)`);

  // Manifest trust: a manifest missing an entry for a known book cannot be used,
  // because every absent entry would read as "the server has nothing" and the
  // client would re-upload files it already has.
  const emptyWire = manifestToWire(emptyManifest(), 1);
  const parsed = manifestFromWire(emptyWire);
  lines.push(`manifest empty trusted=${manifestCoversAll(parsed, [])} (expect true)`);
  lines.push(`manifest missing entry trusted=${manifestCoversAll(parsed, ['book-a'])} (expect false)`);

  const query = defaultLibraryQuery();
  lines.push(`library default sort=${query.sort}`);
  lines.push(`file runner: ${typeof FileStorageRunner !== 'undefined' ? 'wired' : 'missing'}`);

  // --- v1 per-device protocol surface ---------------------------------------
  // Two purposes, one line each. It keeps `SyncV1.ets` genuinely compiled — a HAR
  // barrel whose v1 section nothing references is skipped by the compiler, so its
  // type errors would not show up until a device ran it — and it puts the paths
  // the v1 engine would write where a device install can see them, which is the
  // fastest way to confirm the two protocols are not sharing a path by accident.
  //
  // These lines are **diagnostics, not routing**: the routing decision lives in
  // `data/SyncRouter.ets` and is driven by `SyncService`, so nothing in this file
  // constructs an engine. They also show that both protocols deliberately share one
  // index path, which is why the decision is made from the document's shape.
  lines.push(`v1 index=${V1_INDEX_PATH} version=${V1_INDEX_VERSION}`);
  lines.push(`v1 device path=${v1DevicePath('sample-device')}`);
  lines.push(`v1 tables=${V1_SYNC_TABLES.length} (${V1_SYNC_TABLES.map((t: V1TableConfig): string => t.name).join(',')})`);

  return lines;
}

/**
 * A book with its chapter count replaced.
 *
 * Written field by field because ArkTS has no object spread; the alternative —
 * mutating the object the shelf is rendering from — would make an in-flight render
 * see a half-updated row.
 */
function copyBookForChapterCount(source: Book, chapterCount: number): Book {
  const copy: Book = {
    id: source.id,
    filePath: source.filePath,
    format: source.format,
    title: source.title,
    author: source.author,
    publisher: source.publisher,
    language: source.language,
    isbn: source.isbn,
    description: source.description,
    coverUrl: source.coverUrl,
    publishDate: source.publishDate,
    rating: source.rating,
    reviews: source.reviews,
    subjects: source.subjects,
    totalPages: source.totalPages,
    totalChapters: chapterCount,
    groupId: source.groupId,
    addedAt: source.addedAt,
    lastOpenedAt: source.lastOpenedAt,
    updatedAt: source.updatedAt,
    deletedAt: source.deletedAt,
    progress: source.progress,
    currentCfi: source.currentCfi,
    currentSpine: source.currentSpine,
    currentDomPos: source.currentDomPos,
    tags: source.tags,
    fileHash: source.fileHash,
    syncStatus: source.syncStatus,
  };
  return copy;
}

function emptyLocal(): LocalBinaryState {
  return { fileExists: false, fileSize: 0, coverExists: false, coverSize: 0, coverHash: '' };
}

function emptyRemote(): RemoteBinaryState {
  return {
    fileExists: false,
    fileSize: 0,
    coverExists: false,
    coverSize: 0,
    coverHash: '',
    coverSourcePath: '',
  };
}

function makeInput(
  bookId: string,
  title: string,
  format: string,
  local: LocalBinaryState,
  remote: RemoteBinaryState,
): BookBinaryInput {
  const input: BookBinaryInput = {
    bookId: bookId,
    title: title,
    format: format,
    coverUrl: '',
    coverExt: '',
    localFilePath: `books/${bookId}.${format}`,
    localCoverPath: '',
    local: local,
    remote: remote,
    folderName: `${title}-${bookId}`,
    relativeFilePath: `books/${bookId}.${format}`,
  };
  return input;
}

/**
 * Shell.
 *
 * Four sections, matching the four supported features. The reader and the
 * annotation list are pushed as destinations because they need a book id; the
 * shelf and sync settings are top-level and live in the tab body.
 *
 * Synchronous initialization is awaited here rather than in the ability so that a
 * failure has somewhere to be shown. An ability callback has no UI, so an error
 * thrown there would be invisible.
 */
@Entry
@Component
struct Index {
  @State private ready: boolean = false;
  @State private initMessage: string = '正在初始化...';
  @State private activeTab: number = 0;
  /**
   * The user's chosen colour theme, one of the three ReadAny ships.
   *
   * Defaults to dark until the stored value is read, and the read happens after the
   * first frame: a preference lookup is fast but not free, and a shell that renders
   * immediately and then settles is better than a blank one while storage is read.
   */
  @State private themeMode: ThemeMode = 'dark';
  /**
   * Whether the user has left animation switched on, mirrored from `AppStorage`.
   *
   * `@StorageLink` rather than a `@State` copied in from the store: the appearance page
   * writes the same key, so the two cannot drift, and this declaration is what makes the
   * shell re-render when the setting changes.
   *
   * It is read by `tabSwitchDuration` only. Every other piece of motion in this file and
   * the pages it hosts goes through `Motion`, which reads the same key itself — so this
   * field is the tab bar's dependency, not a second source of truth.
   */
  @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;
  /**
   * The selected speed index, mirrored from `AppStorage`.
   *
   * Bound for the same reason and read in two places: `tabSwitchDuration`, and the
   * animation picker on the appearance page, whose tick mark has to follow the stored value
   * rather than a component-local one.
   */
  @StorageLink(MOTION_SPEED_INDEX_KEY) private animationSpeedIndex: number = DEFAULT_ANIMATION_SPEED_INDEX;
  /**
   * The settings sub-page stack: 主题 and 同步 are pushed `NavDestination`s.
   *
   * They used to be a second branch inside the settings tab, which meant they rendered
   * *inside* the tab content and the floating tab bar stayed on top of them. Pushed onto
   * a `Navigation` in `NavigationMode.Stack`, a settings page is drawn over the whole
   * content area instead, tab bar included — which is what makes it read as a page.
   *
   * Kept on the shell rather than inside `settingsSection` so switching bottom tabs and
   * coming back returns to the sub-page the user was on: the stack outlives the tab
   * content it was pushed from.
   */
  @Provide('settingsPathStack') private settingsPathStack: NavPathStack = new NavPathStack();
  /**
   * Whether this device can render the floating bottom tab bar.
   *
   * Evaluated once at construction rather than per render: a capability does not change
   * while the app runs, and reading it inside `build` would make the branch's identity
   * unstable across re-renders.
   *
   * Not API-level gating. HDS is `@since 6.1.0(23)` and this module's
   * `compatibleSdkVersion` is 24, so the expected answer is `true` everywhere the app
   * claims support; the check is here so that if it is ever `false` the user gets a
   * working tab bar instead of a blank shell.
   */
  private hdsTabsAvailable: boolean = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
  /**
   * The HDS tab controller.
   *
   * The device logs HDS_tabs: GetHdsTabsController no hdsTabsControllerClass prop when
   * it is omitted, and the floating style is applied through this controller — so leaving
   * it out is one of the reasons the bar stayed in the tiled presentation.
   */
  private hdsController: HdsTabsController = new HdsTabsController();
  @State private config: WebDavConfig = defaultWebDavConfig();
  /**
   * The status line under the 同步 button.
   *
   * Empty until something actually happens, which is what makes the auto-sync switch a
   * genuine off switch on screen as well as on the wire: with it off, a launch writes
   * nothing here, so the sync tab shows no status at all until the user asks for a pass.
   * It used to start at 「尚未同步」, a placeholder that is itself a sync status line and
   * therefore contradicts "off means nothing is shown".
   */
  @State private syncMessage: string = '';
  /**
   * True while a pass is running, so the transfer buttons disable themselves.
   *
   * `SyncService` already refuses a concurrent pass, but a button that stays enabled
   * and then throws is a worse experience than one that is visibly unavailable — and a
   * full download takes long enough that a second tap is likely.
   */
  @State private syncBusy: boolean = false;
  /**
   * The newest progress report from a running pass, or `undefined` when none is running.
   *
   * The whole card is gated on this being defined, which is what makes "on completion it
   * transitions to the existing summary line" true rather than a claim: as soon as the pass
   * ends — success or failure — this goes back to `undefined` and the summary (or the error)
   * is the only sync text on screen.
   *
   * Deliberately **one** object rather than six parallel `@State` fields: ArkUI re-renders
   * on any assigned field, so six fields would mean six change notifications per update, and
   * a report is one atomic fact rather than six independent ones.
   */
  @State private syncProgress: SyncProgress | undefined = undefined;
  /**
   * How many files the current pass will move, or 0 when that is not yet known.
   *
   * Set by the transfer phase as soon as the planner has run. Kept separate from
   * `syncProgress.total` because a phase that cannot count its work reports 0, and the card
   * has to be able to say "共 12 个文件" during a phase that is not itself counting.
   */
  @State private syncFileTotal: number = 0;
  /**
   * The noun the progress counter counts, so the card never lies about its unit.
   *
   * A v2 pass counts book files; a v1 pass counts **devices**, because that is what its
   * work is — one snapshot per peer. "文件 2 / 3" during a v1 pass would describe a phase
   * that is not happening.
   */
  @State private syncUnit: string = '文件';
  /**
   * Which protocol the configured server speaks, as last detected.
   *
   * The user has to be able to see this. The two dialects put different things on the same
   * paths, so "which one is my server speaking" decides what a pass will do — and, for v1,
   * that no book file will ever move. It starts at 「未检测」 rather than guessing: a guess
   * here would be the app asserting something about the user's server that it has not read.
   */
  @State private serverProtocol: string = '远端协议：未检测';
  @State private planChecks: string[] = probeBinaryPlan();

  // --- shelf state ---------------------------------------------------------
  @State private shelfBooks: Book[] = [];
  @State private shelfLoading: boolean = true;
  @State private shelfSearch: string = '';
  @State private shelfSort: BookSort = Sort.RECENTLY_OPENED;
  @State private shelfMessage: string = '';

  // --- reader state --------------------------------------------------------
  /** The book currently open, or `undefined` when the shelf is showing. */
  @State private openBook: Book | undefined = undefined;
  @State private openBookPath: string = '';
  @State private readerSettings: ReaderSettings = defaultReaderSettings();
  @State private readerPosition: ReadingPosition = emptyPosition();
  /**
   * The locator of the annotation the current open was asked to jump to, or empty.
   *
   * **This is the override, and it is deliberately not part of `readerPosition`.**
   * `readerPosition` is the *stored* position after `resolveOpenPosition`, and it stays
   * exactly that: it is what the reader falls back to when this locator turns out to be
   * unusable. Folding the annotation's position into `readerPosition` instead would
   * leave nothing to fall back to, and it is precisely what the previous version did —
   * it assigned a synthesised position here and then threw it away in `openReader`.
   *
   * Held as a plain string rather than a decoded position because the decode needs the
   * book's parsed spine list, which does not exist until `ReaderView` has opened the
   * file; `ReaderView.annotationStart` does the decoding at the one point where the
   * spine is known.
   */
  @State private readerLocator: string = '';
  /**
   * Pending position from the reader, flushed on a timer.
   *
   * Held here rather than written through: the kit emits a page change on every
   * turn, and writing each one would put a database write plus a bumped
   * `updated_at` on the critical path of every page turn.
   */
  private pendingPosition: ReadingPosition | undefined = undefined;
  private pendingBookId: string = '';
  /**
   * The position most recently **committed** to the local store.
   *
   * This is the close-flush fallback, and it exists because "the reader stopped
   * reporting" is not the same as "there is nothing to write":
   *
   *  - If `closeReader` is reached without a pending position, the last position the
   *    reader ever reported is still the right thing to persist. Without this field a
   *    close that arrives after a flush has already run would write nothing, and any
   *    page turn the reader failed to re-report would be lost silently.
   *  - It is only ever a *re-write of an already-reached position*, never an
   *    overwrite of a newer one: the close flush prefers `pendingPosition` whenever
   *    that exists.
   *
   * Compared against `pendingPosition` by value, not identity, so re-reporting the
   * page already committed does not cause a second write.
   */
  private committedPosition: ReadingPosition | undefined = undefined;
  private committedBookId: string = '';
  private flushTimer: number = -1;
  /**
   * The flush currently in flight, if any.
   *
   * Awaited by `openReader` so the position a just-closed book left behind is on
   * disk **before** the store is read back for that book. That is the explicit
   * ordering: nothing here relies on the flush happening to finish first.
   */
  private pendingFlush: Promise<void> = Promise.resolve();
  /** Position saves are throttled to this interval. */
  private readonly flushIntervalMs: number = 5000;

  // --- annotations state ---------------------------------------------------
  /** Which book the annotation tab is showing, or empty for the recent view. */
  @State private annotationBookId: string = '';
  @State private annotationBookTitle: string = '';
  @State private annotationBookmarks: Bookmark[] = [];
  @State private annotationHighlights: Highlight[] = [];
  @State private annotationNotes: Note[] = [];
  @State private annotationsLoading: boolean = true;
  @State private showBookmarks: boolean = true;
  @State private showHighlights: boolean = true;
  @State private showNotes: boolean = true;
  @State private annotationsMessage: string = '';

  // --- visual capability ---------------------------------------------------
  /**
   * Material option, resolved once at construction.
   *
   * **No longer applied to any component in this file.** Phase 4 removed the last three
   * `.systemMaterial(this.material)` call sites — the theme picker row, the two full-transfer
   * buttons and the self-test panel — because a system material only distinguishes light from
   * dark, so on the sepia palette it repainted each of them with the system's colour and
   * discarded the app's own. The one place the 沉浸光感 material belongs is the floating tab
   * bar, which `HdsTabs` paints from `barFloatingStyle.systemMaterialEffect` below, not from
   * this value.
   *
   * Kept because it is what `surfaceStyle` is derived from and the self-test reports it: the
   * question "did this device take the 26-only material path" still has an answer, and that
   * answer is what tells a device install apart from a silent fallback.
   */
  private readonly material: Object | undefined = materialOption();
  @State private deviceApiLevel: number = apiLevel();
  /** Shelf-group count, for the self-test block. -1 means the table could not be read. */
  @State private groupTotal: number = -1;
  @State private materialLevel: number = deviceMaterialLevel();
  /**
   * Which surface style the shell ended up with.
   *
   * Shown in the self-test block: on a device this is the only way to tell the
   * material path was taken from a silent fallback, and a fallback looks identical
   * to a material that renders as nothing.
   */
  @State private surfaceStyle: SurfaceStyle = materialOption() !== undefined
    ? SurfaceStyle.IMMERSIVE
    : SurfaceStyle.OPAQUE;

  // --- network method probe state ------------------------------------------
  @State private probeUrl: string = DEFAULT_PROBE_URL;
  @State private probeLines: string[] = [];
  @State private probeVerdict: string = '';
  @State private probeWorks: boolean = false;
  @State private probeRunning: boolean = false;

  /**
   * Run the network method probe.
   *
   * Results are rendered rather than logged: the whole point is that a person holding
   * the device can read the answer and report it, and hilog is not visible to them.
   */
  private async runMethodProbe(): Promise<void> {
    this.probeRunning = true;
    this.probeLines = ['正在探测...'];
    this.probeVerdict = '';
    try {
      const url: string = this.probeUrl.trim().length > 0 ? this.probeUrl.trim() : DEFAULT_PROBE_URL;
      const result: ProbeResult = await probeCustomMethod(url);
      this.probeLines = formatProbeResult(result);
      this.probeVerdict = result.verdict;
      this.probeWorks = result.customMethodWorks;
    } catch (err) {
      // A throw here means the probe itself failed to run, which is different from a
      // probe that ran and found the method unusable.
      const message: string = err instanceof Error ? err.message : JSON.stringify(err);
      this.probeLines = [];
      this.probeVerdict = `探测未能执行：${message}`;
      this.probeWorks = false;
    } finally {
      this.probeRunning = false;
    }
  }

  aboutToAppear(): void {
    this.bootstrap();
    this.restoreTheme();
  }

  /**
   * The ability context, or `undefined` when the component is not attached to a window.
   *
   * `getHostContext()` is declared `Context | undefined` and the undefined case really
   * happens, so it is returned rather than cast away. Callers that only need to read or
   * write a preference treat `undefined` as "skip", because a preference is not worth an
   * error message.
   */
  private context(): common.UIAbilityContext | undefined {
    const host: Context | undefined = this.getUIContext().getHostContext();
    return host === undefined ? undefined : host as common.UIAbilityContext;
  }

  /**
   * Read the saved theme and animation setting, and apply both.
   *
   * Runs alongside `bootstrap` rather than after it: the two touch different storage and
   * neither depends on the other, so serialising them would only delay the first frame
   * that shows the right colours.
   *
   * The animation setting is read from the same `preferences` file (a second
   * `getPreferences` on an already-open store is cheap), and both reads are issued before
   * either is awaited so the two do not queue behind each other.
   */
  private async restoreTheme(): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context();
    if (context === undefined) {
      return;
    }
    const themeRead: Promise<ThemeMode> = loadThemeMode(context);
    const animationRead: Promise<number> = loadAnimationSpeedIndex(context);
    // The animation setting is applied first: it is what the first frame of the settings
    // page depends on, and it must be in `AppStorage` before the page can bind to it.
    // `Motion` already seeded both keys with their defaults at module load, so this is a
    // write over a valid value, never the creation of one.
    this.applyAnimationSpeed(await animationRead, false);
    this.themeMode = await themeRead;
    this.applySystemAppearance();
  }

  /**
   * Put a speed index into force, and remember it.
   *
   * The screen updates first — `applyAnimationSetting` writes `AppStorage`, which is what
   * every `Motion` call reads — and the preference write follows. That order is the same
   * one `chooseTheme` uses, and for the same reason: a storage failure must not make the
   * setting feel broken. `false` for persistence on restore, because the value just came
   * *from* storage.
   */
  private async applyAnimationSpeed(index: number, persist: boolean): Promise<void> {
    // `Motion` is the only writer of the two `AppStorage` keys, so the switch and the
    // speed cannot end up disagreeing (a stored value that is out of range is clamped
    // there, once).
    applyAnimationSetting(index);
    if (!persist) {
      return;
    }
    const context: common.UIAbilityContext | undefined = this.context();
    if (context !== undefined) {
      await saveAnimationSpeedIndex(context, currentAnimationSpeedIndex());
    }
  }

  /**
   * Make the system's own colours follow the app's theme, and paint the window to match.
   *
   * **This is the single cause behind two visible defects.** The app ships its own three
   * themes, but the system does not know about them: system materials (the immersive
   * light on the floating tab bar) and every \`$r('sys.color.*')\` resource follow the
   * **system colour mode** instead. So with the system in dark mode and the app set to
   * light, the bottom of the page — which the floating bar's material paints — came out
   * \`#121212\` under a white page. Sampled from a device screenshot, which is how the
   * band was finally identified: it was never black, it was *the dark theme's background*.
   *
   * The same mismatch made dark-mode text unreadable: with the system light and the app
   * dark, system-coloured text rendered dark on the app's dark background.
   *
   * Setting the colour mode from the theme fixes both at once. Sepia maps to light,
   * because it is a light theme with a warm cast — telling the system "dark" for it
   * would make every system surface fight the page.
   *
   * ## It is also the app's window-geometry call since r101
   *
   * Full screen and the hidden status bar are issued from the same `.then` as the window colour,
   * for the reasons written at the call site. What that changes, and what it deliberately does
   * not:
   *
   *  - **The reader's two bars do not move.** They are `position`-anchored to the reader's page
   *    `Stack` (top edge / bottom edge), and the `Stack` is what grows, so top-anchored still
   *    means the top of the page and bottom-anchored still means the bottom of it. The top bar is
   *    inside a `Navigation` that opts out of safe-area expansion (`expandSafeArea([], [])`), so
   *    it cannot be pushed around by the inset change either.
   *  - **`SHEET_MIN_HEIGHT` keeps its value and changes its base.** `'50%'` is half the sheet's
   *    own maximum, which is the window less the sheet's top safe-area inset, and full screen
   *    removes that inset — so the four reader sheets open about 29 vp higher (half of 57.8).
   *    Deliberate: a percentage keeps "half of what the sheet has" true on rotation and on other
   *    devices, where a vp literal would not. `SHEET_MIN_HEIGHT`'s own note records it.
   *  - **The three tap zones need no change, and that is checked rather than assumed.** They are
   *    three `layoutWeight(1)` columns of a full-width, full-height row (`height('100%')`), so
   *    their boundaries are the thirds of whatever box the page area has: the x-boundaries are
   *    unchanged (the page was already full width) and the y-extent simply grows with the box.
   *    "Middle" is still the middle, on both axes.
   *  - **`resolveViewPort()` is untouched and still cannot return 0.** The taller box arrives
   *    through the existing `onAreaChange` on the page layer as a larger `viewHeight`, and
   *    `resolveViewPort` multiplies *whatever it measured* by the display density. Nothing in it
   *    clamps, special-cases or assumes a height — its only branches are "measured", "window",
   *    "nominal fallback" — so a taller measurement is simply a taller measurement.
   */
  private applySystemAppearance(): void {
    const context: common.UIAbilityContext | undefined = this.context();
    if (context === undefined) {
      return;
    }
    const dark: boolean = this.themeMode === 'dark';
    try {
      context.getApplicationContext().setColorMode(dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', String(err));
    }

    const colour: string = paletteFor(this.themeMode).background;
    window.getLastWindow(context)
      .then((win: window.Window): void => {
        win.setWindowBackgroundColor(colour);
        // --- full screen, and the status bar hidden with it (r101) -----------------
        //
        // **Why here.** This is the one place the app already holds the main window
        // (`window.getLastWindow`), so it costs no second lookup, and a window-level setting
        // re-asserted from `applySystemAppearance` is re-asserted on every theme change for free.
        //
        // **Why full screen at all.** Reader Kit insets the reading area itself — its own
        // 68 / 48 / 27 / 27 vp 页眉页脚 reserve, which is documented as reserved and is **not**
        // configurable (`ReaderSetting` has thirteen fields and no padding/inset/margin/safeArea;
        // `setPageConfig` takes font metrics plus `viewPortWidth`/`viewPortHeight` and nothing
        // else). So the only lever that can actually move the text is the window's own layout
        // area: `setWindowLayoutFullScreen(true)` is documented as "the layout does not avoid the
        // status bar … and components may overlap with them" (`@ohos.window.d.ts:4528`), which
        // hands the page the status bar's 57.8 vp at the top and the gesture bar's 27.9 vp at the
        // bottom (both measured on this device).
        //
        // **Why app-wide rather than only while reading.** Three reasons, and the second is the
        // decisive one:
        //
        //  1. These are properties of the **window**, not of the reader. A per-reader version
        //     would toggle the window twice per book and would need the mode kept somewhere — a
        //     second piece of state that `openReader`/`closeReader` could desync from. App-wide,
        //     the value is a constant and there is nothing to desync.
        //  2. A toggle at `openReader` would move the window's layout area **while the reader
        //     mounts**, so the kit would lay out once at the old geometry and again at the new
        //     one — a `setPageConfig` re-pagination in front of a reader who has already started
        //     reading, which is the exact trap `ReaderView`'s two bars are built to avoid. Asserted
        //     at start-up, the reader's *first* layout is already the final geometry.
        //  3. `setSpecificSystemBarEnabled('status', false)` is documented to take effect **only**
        //     in full-screen mode and to "take effect once the main window enters full-screen or
        //     maximized mode" (`@ohos.window.d.ts:4637`). So the two have the same lifetime by
        //     construction: any moment full screen is off is a moment the status bar returns. They
        //     belong on the same lines.
        //
        // **The disclosed consequence.** This is a window setting, so the shell gets it too: the
        // shelf/书签笔记/设置 content areas also begin at the screen's top edge now, and the
        // shared `pageTitle` therefore sits `SPACE_S` (8 vp) below it instead of 8 vp below the
        // status bar. Nothing overlaps — the status bar is hidden — but the three section titles
        // are one status-bar height higher than they were. Left as it is rather than compensated
        // with a magic top padding: the honest version of that compensation needs a real
        // measurement (`getWindowAvoidArea`), which is a separate change. If it reads badly on the
        // device, that is the fix, not a larger constant.
        //
        // Log-and-continue on both, matching the window colour's own handling: neither is worth an
        // error the user has to dismiss, and the app is fully usable at the default geometry.
        win.setWindowLayoutFullScreen(true).catch((err: Object): void => {
          hilog.warn(DOMAIN, TAG, 'window layout not made full screen: %{public}s', String(err));
        });
        // Not conditioned on `themeMode`, unlike the colour beside it: the status bar's
        // *visibility* is not theme-derived. Also a documented silent no-op in split-screen and
        // floating-window mode (`@ohos.window.d.ts:4638`), which is why this is a log and not a
        // retry.
        win.setSpecificSystemBarEnabled('status', false).catch((err: Object): void => {
          hilog.warn(DOMAIN, TAG, 'status bar not hidden: %{public}s', String(err));
        });
      })
      .catch((err: Object): void => {
        // Cosmetic only: the app is fully usable with the default window colour, so a
        // failure here must not surface as an error the user has to dismiss.
        hilog.warn(DOMAIN, TAG, 'window background not set: %{public}s', String(err));
      });
  }

  /** Apply a theme and remember it. */
  private async chooseTheme(mode: ThemeMode): Promise<void> {
    // The screen updates first: a storage failure must not make the picker feel broken.
    this.themeMode = mode;
    this.applySystemAppearance();
    const context: common.UIAbilityContext | undefined = this.context();
    if (context !== undefined) {
      await saveThemeMode(context, mode);
    }
  }

  /**
   * Handle the system back gesture at the shell level.
   *
   * With a book open, back closes the book and stays in the app. Without one, the
   * event is left to the framework: it pops the top settings page when one is open and
   * otherwise exits — the standard behaviour for a home screen.
   *
   * This is what makes the reader feel like a page rather than a mode: previously the
   * back gesture exited the application from inside a book.
   */
  onBackPress(): boolean {
    if (this.openBook !== undefined) {
      // `onBackPress` is synchronous and cannot await, so the ordering is carried by
      // `closeReader` itself: it publishes its flush on `pendingFlush` on entry, and
      // `openReader` awaits that before reading the store. The returned `true` still
      // consumes the gesture, so back closes the book rather than exiting.
      void this.closeReader();
      return true;
    }
    // A pushed settings page is deliberately not handled here any more. `Navigation` in
    // Stack mode owns the back gesture for its own stack: it pops the top
    // `NavDestination` before the event is allowed to reach the application, and this
    // returning false leaves exactly that default in place. Consuming the event here as
    // well would pop twice per press.
    return false;
  }

  /**
   * Flush the reading position when the page stops being visible.
   *
   * Backgrounding the app is a common way to stop reading — more common than the back
   * gesture — and without this the position written on the last page turn could be up
   * to `flushIntervalMs` old, losing a few pages of progress. The throttle exists to
   * keep a database write off the page-turn path; it must not also mean losing the
   * last few pages.
   *
   * Not awaited — `onPageHide` is synchronous and the platform finishes the write as
   * the app is suspended — but the promise is published on `pendingFlush` so a re-open
   * that happens before the suspension completes still waits for it rather than
   * reading the store early.
   */
  onPageHide(): void {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.pendingFlush = this.flushPendingPosition();
  }

  /**
   * The duration of a tab-switch tap animation, in ms.
   *
   * **Never 0**, including when the user has chosen 「关闭」. With `BottomTabBarStyle` the
   * platform default is 0, which is the defect the explicit duration was added to fix: a
   * tab tap that teleports is disorienting, and a tap is *navigation feedback*, not
   * decoration. So 「关闭」 degrades to this constant (300 ms, the platform default for the
   * other bar styles) rather than to 0, and every other option uses its own duration.
   *
   * `Motion.tabSwitchDuration()` owns the rule — including the 120 ms floor for any future
   * speed slower than the four offered today — and this method exists only so the call
   * sites are one expression and the fallback constant is visibly in force. Note the shape
   * of the expression: the constant is the *else*, not dead code.
   */
  private tabSwitchDuration(): number {
    // Reading the bound fields is what makes this re-evaluate when the setting changes; see
    // the note on `animationSpeedIndex`. The speed index is the *default* rather than the
    // value, because with animation off the picker has no speed to give.
    return this.animationOn
      ? Motion.tabSwitchDuration()
      : TAB_SWITCH_DURATION_MS;
  }

  private async bootstrap(): Promise<void> {
    if (isAppCoreReady()) {
      this.applyConfig();
      await this.reloadShelf();
      await this.reloadAnnotations();
      this.groupTotal = await groupCount();
      this.autoSyncOnStartup();
      return;
    }
    try {
      // `getHostContext()` is declared `Context | undefined`, so the undefined
      // case is a real possibility (it happens when the component is not attached
      // to a window yet) and must not be cast away.
      const host: Context | undefined = this.getUIContext().getHostContext();
      if (host === undefined) {
        this.initMessage = '初始化失败：无法获取应用上下文，请重启应用。';
        return;
      }
      const context: common.UIAbilityContext = host as common.UIAbilityContext;
      await initAppCore(context);
      this.ready = true;
      this.initMessage = '';
      this.applyConfig();
      await this.reloadShelf();
      await this.reloadAnnotations();
      this.groupTotal = await groupCount();
      this.autoSyncOnStartup();
    } catch (err) {
      // Surfaced on screen: without this the app would sit on a spinner and the
      // only clue would be in hilog.
      const message: string = appCoreError().length > 0
        ? appCoreError()
        : (err instanceof Error ? err.message : JSON.stringify(err));
      this.initMessage = `初始化失败：${message}`;
    }
  }

  /** Reload the shelf from the repository. */
  private async reloadShelf(): Promise<void> {
    if (!isAppCoreReady()) {
      return;
    }
    this.shelfLoading = true;
    try {
      const query = defaultLibraryQuery();
      query.search = this.shelfSearch;
      query.sort = this.shelfSort;
      this.shelfBooks = await bookRepository().list(query);
      this.shelfMessage = '';
    } catch (err) {
      this.shelfMessage = err instanceof Error ? err.message : JSON.stringify(err);
      this.shelfBooks = [];
    } finally {
      this.shelfLoading = false;
    }
  }

  /**
   * Import books.
   *
   * The list is reloaded even when the picker was dismissed, because a previous
   * attempt may have imported some files before failing on a later one.
   */
  private async importBooks(): Promise<void> {
    try {
      const result = await bookImporter().pickAndImport();
      if (result.cancelled) {
        return;
      }
      await this.reloadShelf();
      if (result.warnings.length > 0) {
        // Failures are reported but do not undo the imports that succeeded.
        this.shelfMessage = `部分失败：${result.warnings.join('；')}`;
        this.toast('部分书籍导入失败');
      } else {
        this.toast('导入完成');
      }
    } catch (err) {
      const message: string = err instanceof InkBoatError
        ? err.message
        : (err instanceof Error ? err.message : JSON.stringify(err));
      this.shelfMessage = message;
      this.toast('导入失败');
    }
  }

  /**
   * Delete one book, in the mode the user chose in the confirmation.
   *
   * This is the whole of this client's deletion, and it has exactly two steps, in this
   * order:
   *
   *  1. **the database write, awaited.** Either ReadAny's soft delete
   *     (`Books.softDeleteBook`: `deleted_at` stamped, row kept, the desktop learns about
   *     it) or its hard delete (`Books.deleteBook`: the book and every annotation it owns
   *     removed, with a tombstone so a peer cannot resurrect it).
   *  2. **then the local file** (`removeLocalFile`), and only if step 1 resolved.
   *
   * The order is the point. Unlinking first and writing second loses the book outright
   * if the process dies in between: no row left to retry from, no file left to read. If
   * step 1 throws, this method returns with the file untouched and the book intact on
   * the shelf — nothing has happened, which is the only correct outcome for a failed
   * delete.
   *
   * **No remote delete, in either mode.** Nothing here reaches the server: the file call
   * unlinks a path inside this app's sandbox, and the only thing that leaves the device
   * is the row a later sync pass pushes — the same row a desktop ReadAny produces for
   * the same action. Whether the *uploaded* copy then disappears is the desktop's
   * decision (`cleanupRemoteOrphans`), not this client's, and this client has no code
   * that could make it.
   *
   * The cover is removed only in the hard mode, which is what the reference does: its
   * `removeBook` deletes the book file for both modes and gates the cover on
   * `!preserveData` (`packages/app/src/stores/library-store.ts:804-835`).
   *
   * Errors are swallowed into `shelfMessage` rather than thrown. `ShelfPage` closes the
   * confirmation when this resolves, and an exception here would leave the user with a
   * dismissed dialog and no explanation.
   */
  private async deleteBookFromShelf(book: Book, preserveData: boolean): Promise<void> {
    if (!isAppCoreReady()) {
      return;
    }
    try {
      if (preserveData) {
        await bookRepository().softDeleteBook(book.id);
      } else {
        await bookRepository().deleteBook(book.id);
      }
    } catch (err) {
      const message: string = err instanceof InkBoatError
        ? err.message
        : (err instanceof Error ? err.message : JSON.stringify(err));
      this.shelfMessage = `删除失败，书籍未改动：${message}`;
      this.toast('删除失败');
      return;
    }

    // Past this line the row is committed, so the file is now garbage whichever mode was
    // chosen. A file failure must not present itself as a failed deletion — the book is
    // already gone from the shelf — so it is reported separately and the reload still runs.
    try {
      await removeLocalFile(book.filePath);
      if (!preserveData) {
        await removeLocalFile(book.coverUrl);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'book file removal failed for %{public}s: %{public}s',
        book.id, String(err));
      this.shelfMessage = '书籍已删除，但本机文件未能删除。';
    }

    // A deleted book that the reader still holds open would be a reader on a missing
    // file. The shelf is only reachable with the reader closed, so this is a guard
    // rather than a path anyone can reach today — the reference closes its matching
    // reader tabs before removing a book for the same reason.
    //
    // Discarded with `void` rather than awaited: that is this app's form for a close whose
    // completion the caller does not depend on, and the other two call sites do the same.
    // `closeReader` publishes the position flush itself and reloads the shelf when it
    // finishes, so the `toast` below may land before that reload. Awaiting would be just as
    // safe, but `tools/verify-reading-position.mjs` requires every call site to be either
    // un-awaited-but-`void`ed or awaited-with-`void`, and conforming to the existing check
    // was preferable to loosening it.
    if (this.openBook !== undefined && this.openBook.id === book.id) {
      void this.closeReader();
    } else {
      await this.reloadShelf();
    }
    this.toast(preserveData ? '已从书架移除，笔记与阅读记录保留' : '已彻底删除');
  }

  // -------------------------------------------------------------------------
  // Reader
  // -------------------------------------------------------------------------

  /**
   * Open a book.
   *
   * A book whose file is not on this device cannot be opened: Reader Kit reads
   * local files only, and the sync layer marks such a book `remote`. Saying so is
   * better than opening a reader that fails on a missing path.
   *
   * `annotationLocator` is the **override**: the locator of the bookmark, highlight or
   * note the user tapped, or undefined for an ordinary open. It wins over the stored
   * position for that open — that is the feature, since a person taps a bookmark in
   * order to go to it — and it is chosen as a *parameter* rather than by pre-seeding
   * `readerPosition` or by a shell-held "pending annotation" field for two reasons:
   *
   *  1. **An argument cannot leak into an unrelated open.** A field would have to be
   *     cleared on every path, including the two early returns below, and a stale
   *     value would send the next book to a stranger's page.
   *  2. **It is immune to the in-flight flush by construction.** The flush publishes
   *     writes to the *store*; this value never passes through the store, and it is
   *     assigned to `readerLocator` **after** the ordering gate below, so a flush that
   *     lands while this method is awaiting cannot replace it. The fallback — the
   *     stored position — is still read after the gate, which is what keeps the
   *     restored page honest when the locator turns out to be unusable.
   */
  private async openReader(book: Book, annotationLocator?: string): Promise<void> {
    if (book.syncStatus !== 'local') {
      this.toast('这本书的文件还在服务器上，请先同步下载');
      return;
    }
    const absolute: string = toAbsolutePath(book.filePath);
    if (absolute.length === 0) {
      this.toast('找不到书籍文件');
      return;
    }

    // This device's own last position wins, and the position synced on the book row
    // is the fallback — `resolveOpenPosition` records why no column can honestly
    // order the two. The fallback is what makes a reinstall or a second device open
    // where the book was left instead of at page 1; the local entry is what keeps an
    // offline reading session from being dragged backwards by an older pull.
    let local: ReadingPosition = emptyPosition();
    try {
      this.readerSettings = await reader().loadSettings();
    } catch (err) {
      // Defaults are always usable; a settings read failure must not block reading.
      this.readerSettings = defaultReaderSettings();
    }
    // **The ordering gate.** Wait for any position write still in flight before
    // reading the store back. Without this, a fast "return then re-open" could load
    // the previous value while the current one was still being written — the store
    // would be correct a moment later, and the reader would already be showing the
    // old page. Awaiting the in-flight flush is what makes the read happen-after the
    // write instead of merely usually-after it. It is a no-op when nothing is
    // flushing, and it is the local `sync_metadata` upsert that is being waited on,
    // not a network call.
    try {
      await this.pendingFlush;
    } catch (err) {
      // `flushPendingPosition` is written not to throw; this guard only keeps a future
      // change to it from turning into an unopenable book. Logged rather than swallowed
      // so that a gate which starts failing is visible instead of merely slow.
      hilog.warn(DOMAIN, TAG, 'pending position flush failed before open: %{public}s',
        String(err));
    }
    try {
      local = await reader().loadPosition(book.id);
    } catch (err) {
      // A position read failure must not block reading either. The synced columns on
      // the row are still tried below, and `emptyPosition()` means "no local
      // position" rather than "page 0".
      local = emptyPosition();
    }
    this.readerPosition = resolveOpenPosition(local, book);
    // The override, applied last and outside the stored position. `annotationLocator`
    // is a parameter, so neither the flush above nor the store read can have replaced
    // it; clearing it to `''` on an ordinary open is what stops a jump from leaking
    // into the next book opened.
    this.readerLocator = annotationLocator === undefined ? '' : annotationLocator;

    this.openBookPath = absolute;
    this.openBook = book;
  }

  /**
   * Record a position change from the reader.
   *
   * Kept in memory and flushed on a timer, plus once on close. The timer is what
   * bounds the write rate; the close flush is what stops the last page turn of a
   * session from being lost.
   */
  private onReaderPosition(position: ReadingPosition): void {
    this.readerPosition = position;
    this.pendingPosition = position;
    this.pendingBookId = this.openBook !== undefined ? this.openBook.id : '';
    if (this.flushTimer === -1) {
      this.flushTimer = setTimeout((): void => {
        this.flushTimer = -1;
        this.flushPendingPosition();
      }, this.flushIntervalMs);
    }
  }

  /**
   * Write the pending position, if any.
   *
   * **Ordering of the two writes is deliberate.** `reader().savePosition` goes to the
   * local `sync_metadata` entry, which is a single keyed upsert and is exactly what
   * `ReaderStore.loadPosition` reads back on the next open — so it is the write that
   * decides where the book reopens, and it is attempted **first** and alone.
   * `bookRepository().updateReadingPosition` is the synced book row (progress bar,
   * other clients); it needs `writeTransaction` plus two extra reads and can fail on
   * its own, so it is attempted separately and its failure cannot take the durable
   * local write down with it. The old order did the opposite: a book-row failure meant
   * the local position was never written at all.
   *
   * **The pending position is cleared only once the durable write has succeeded.**
   * Clearing it up front (which is what this used to do) meant that any failure
   * dropped the position permanently — there was nothing left for a retry to pick up.
   */
  private async flushPendingPosition(): Promise<void> {
    const position: ReadingPosition | undefined = this.pendingPosition;
    const bookId: string = this.pendingBookId;
    if (position !== undefined && bookId.length > 0) {
      await this.persistPosition(bookId, position);
      return;
    }
    // Nothing pending. The last position the reader reported is still the right thing
    // to have on disk, so a close that arrives after an earlier flush re-writes it
    // rather than leaving whatever the previous session committed.
    const fallback: ReadingPosition | undefined = this.committedPosition;
    if (fallback !== undefined && this.committedBookId.length > 0) {
      await this.persistPosition(this.committedBookId, fallback);
    }
  }

  /**
   * Write one position to the durable local store, then mirror it on the book row.
   *
   * See `flushPendingPosition` for why the local write is attempted first and why the
   * pending value is cleared only after it succeeds. Never throws: a failed local write
   * is restored into `pendingPosition` — unless a newer position has already replaced
   * it — so the throttle timer retries instead of the position being lost.
   */
  private async persistPosition(bookId: string, position: ReadingPosition): Promise<void> {
    try {
      await reader().savePosition(bookId, position);
    } catch (err) {
      // Restored so the timer retries it. Not surfaced to the user — a failed position
      // write must not interrupt a reading session — but logged, because swallowing it
      // entirely makes "the app forgot where I was" undiagnosable.
      if (this.pendingPosition === undefined) {
        this.pendingPosition = position;
        this.pendingBookId = bookId;
      }
      hilog.warn(DOMAIN, TAG, 'savePosition failed: %{public}s', String(err));
      return;
    }
    this.pendingPosition = undefined;
    this.committedPosition = position;
    this.committedBookId = bookId;

    // Best-effort and independent: the shelf's progress and the synced columns.
    try {
      await bookRepository().updateReadingPosition(
        bookId,
        position.fraction,
        position.spineIndex,
        position.domPos,
      );
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'updateReadingPosition failed: %{public}s', String(err));
    }
  }

  /**
   * Close the reader, flushing any unsaved position first.
   *
   * **Awaited at every call site now.** It used to be called without `await` from
   * three places, which made "return to the shelf" and "persist the position" two
   * independent races. The un-awaited calls were not by themselves what lost the page
   * — the write was not happening at all — but they are the shape that makes the loss
   * possible, so they are gone.
   *
   * `closeReader` is also idempotent: a second entry (the back gesture and the
   * on-screen 返回 both fire in some flows) awaits the first rather than starting a
   * second flush, which would be a second write of the same position.
   */
  private async closeReader(): Promise<void> {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    // Ordering is explicit rather than hoped for: `pendingFlush` is the promise the
    // shell hands to `openReader`, which awaits it before it reads the store back.
    this.pendingFlush = this.flushPendingPosition();
    await this.pendingFlush;
    this.openBook = undefined;
    this.openBookPath = '';
    await this.reloadShelf();
  }

  /** Persist a reader settings change. */
  private async onReaderSettingsChanged(next: ReaderSettings): Promise<void> {
    this.readerSettings = next;
    try {
      await reader().saveSettings(next);
    } catch (err) {
      // The change is already applied in memory for this session, so the session is
      // unaffected — but it will silently revert to the previous value on the next
      // launch, which is exactly the kind of thing that needs a log line.
      hilog.warn(DOMAIN, TAG, 'saveSettings failed: %{public}s', String(err));
    }
  }

  private applyConfig(): void {
    try {
      this.config = sync().currentConfig();
    } catch (err) {
      this.initMessage = '同步服务不可用';
    }
  }

  /**
   * Show a transient confirmation.
   *
   * Routed through the shared helper so the deprecated module-level
   * `promptAction.showToast` cannot creep back in; see `ui/Toast.ets`.
   */
  private toast(message: string): void {
    showToast(this.getUIContext(), message);
  }

  /** Test against a throwaway client so nothing is persisted on failure. */
  private async testConnection(
    url: string,
    username: string,
    password: string,
    allowInsecure: boolean,
    remoteRoot: string,
  ): Promise<void> {
    await sync().testConnection(url, username, password, allowInsecure, remoteRoot);
  }

  private async saveConnection(
    url: string,
    username: string,
    password: string,
    allowInsecure: boolean,
    remoteRoot: string,
  ): Promise<void> {
    await sync().saveConnection(url, username, password, allowInsecure, remoteRoot);
    this.applyConfig();
  }

  /**
   * Persist the 「自动同步」 switch the moment it is flipped.
   *
   * A separate path from `saveConnection`, deliberately. Widening the form's `onSave`
   * would have made the switch wait for a 保存 tap, and this is the one control whose
   * whole purpose is to stop the app touching the server: a user who flips it off and
   * then leaves the screen has to be actually off, not off-once-they-remember-to-save.
   *
   * `savePreferences` loads the *stored* configuration, replaces only the four
   * preference fields, and writes everything back, so half-typed connection details
   * sitting in the form are not committed by this path. The other three preferences are
   * passed through from the live configuration for the same reason: this handler has no
   * business writing a value the user did not just change.
   *
   * `applyConfig` then refreshes the shell's `config`, which is what `autoSyncOnStartup`
   * reads — so the new value takes effect without a restart, and `@Prop` pushes it back
   * down to the switch as the persisted value.
   */
  private async saveAutoSync(enabled: boolean): Promise<void> {
    const current: WebDavConfig = sync().currentConfig();
    await sync().savePreferences(
      enabled,
      current.syncIntervalMins,
      current.wifiOnly,
      current.concurrency,
    );
    this.applyConfig();
  }

  /**
   * Run one pass in the given mode.
   *
   * The mode is threaded through rather than being a pair of booleans here, because the
   * metadata and binary policies have to agree: a "full download" that pushed local
   * metadata would overwrite the very server copy the user is restoring from.
   *
   * **Which protocol runs is not decided here.** `sync()` reads the remote index and
   * routes, so this method is the same for a v1 and a v2 server; the only thing it does
   * differently is prefer the summary the v1 engine produced (which names rows and
   * devices) over the file-count line, because a v1 pass moves no files and "文件上传 0"
   * would describe a phase that does not exist.
   */
  private async runSync(mode: SyncMode): Promise<void> {
    this.syncBusy = true;
    this.syncFileTotal = 0;
    this.syncProgress = undefined;
    this.syncMessage = `${labelForMode(mode)}进行中...`;
    try {
      const counts = await sync().syncNow(mode, this.progressHandler());
      const summary: string = sync().lastSummaryOf();
      this.syncMessage = summary.length > 0
        ? summary
        : `${labelForMode(mode)}完成：拉取 ${counts.pulled}，`
          + `推送 ${counts.pushed}，文件上传 ${counts.uploaded}，`
          + `文件下载 ${counts.downloaded}，失败 ${counts.failed}`;
      // The pass itself is the most authoritative detection there is, so the protocol line
      // is refreshed from it rather than left at whatever the last manual probe said.
      this.serverProtocol = `远端协议：${sync().protocolLabel()}`;
      this.toast(`${labelForMode(mode)}完成`);
      // A full download adds books that were not on the shelf a moment ago, so the
      // grid has to be rebuilt either way. A v1 pass can add books too, for the same
      // reason: it merges other devices' rows.
      await this.reloadShelf();
      await this.reloadAnnotations();
    } catch (err) {
      this.syncMessage = err instanceof InkBoatError ? err.message : String(err);
      // A refusal is not a failed transfer: the protocol line has to say 已拒绝, because
      // the message alone ("索引形状无法识别") does not say whether anything was written.
      this.serverProtocol = `远端协议：${sync().protocolLabel()}`;
      this.toast(`${labelForMode(mode)}失败`);
    } finally {
      // Released first, and unconditionally: a pass that threw must leave the buttons
      // usable again.
      this.syncBusy = false;
      // The pass is over, so the live card gives way to the summary line set above — or to
      // the error line. Cleared here rather than at each exit so a throw cannot leave a
      // stale progress card on a finished sync.
      this.syncProgress = undefined;
      this.syncFileTotal = 0;
      this.syncUnit = '文件';
    }
  }

  /**
   * Ask the server which protocol it speaks, without running a pass.
   *
   * Reads the index and writes nothing, so it is safe on a screen the user has only just
   * opened — and it is the affordance that makes the routing visible before a pass rather
   * than after one. A refusal is shown as the refusal message, not as a generic error:
   * that message names what was found and says that nothing was overwritten, which is the
   * part the user needs.
   */
  private async detectServerProtocol(): Promise<void> {
    try {
      const protocol: SyncProtocol = await sync().detectProtocol();
      this.serverProtocol = `远端协议：${sync().protocolLabel()}`;
      this.syncMessage = protocol === SyncProtocol.REFUSED
        ? sync().protocolMessage()
        : `${sync().protocolLabel()}：索引已读取，尚未写入任何内容。`;
      this.toast(protocol === SyncProtocol.REFUSED ? '协议不被识别' : '已识别协议');
    } catch (err) {
      this.syncMessage = err instanceof InkBoatError ? err.message : String(err);
      this.toast('检测失败');
    }
  }

  /**
   * The progress handler handed to `syncNow`.
   *
   * One expression, reused by the manual pass and by startup auto-sync, so the two cannot
   * show different things about the same work. It runs on the same task queue as the render
   * — `syncNow` is awaited from this component's own event handler — so it assigns state
   * directly. The engine reports per phase and per file, and `SyncService` coalesces to
   * about five updates a second before this is called, which is what keeps a per-chunk
   * download report from becoming a render storm.
   */
  private progressHandler(): (progress: SyncProgress) => void {
    return (progress: SyncProgress): void => {
      this.syncProgress = progress;
      // The unit follows what the pass is actually doing. `progressUnit` reads the
      // decision the service is already running under *and* which half of a v1 pass is
      // reporting, so the label cannot disagree with the numbers beside it: a v1 metadata
      // phase counts 设备, and its file phase counts 文件.
      this.syncUnit = sync().progressUnit();
      if (progress.total > this.syncFileTotal) {
        this.syncFileTotal = progress.total;
      }
    };
  }

  /**
   * Whether the pass can show a real fraction, or only that it is working.
   *
   * `total > 0` is the whole test, and it is honest by construction: the engine reports 0
   * only for the phases that have nothing to count (the metadata reads and writes, each of
   * which is one HTTP request of unknown duration). The alternative — a bar that sits at 0%
   * for the first half of every pass — is the fabrication this rule exists to prevent.
   */
  private progressIsDeterminate(): boolean {
    const progress: SyncProgress | undefined = this.syncProgress;
    return progress !== undefined && progress.total > 0;
  }

  /** Completion as a percentage, for the determinate bar. */
  private progressPercent(): number {
    const progress: SyncProgress | undefined = this.syncProgress;
    if (progress === undefined || progress.total <= 0) {
      return 0;
    }
    const ratio: number = progress.completed / progress.total;
    return Math.max(0, Math.min(100, ratio * 100));
  }

  /**
   * The live line under the bar.
   *
   * Three cases, in order of how much is known:
   *
   *  1. a file is moving and its server-reported size is known — "下载 三体 · 1.2 MB / 3.4 MB";
   *  2. a file is moving with an unknown size (an upload, or a download with no
   *     `Content-Length`) — the file's name and, if any bytes have arrived, how many;
   *  3. no file is moving — the phase's own message, which for the metadata phases is all
   *     that can honestly be said.
   */
  private progressDetail(): string {
    const progress: SyncProgress | undefined = this.syncProgress;
    if (progress === undefined) {
      return '';
    }
    const file: string = progress.currentFile;
    if (file.length === 0) {
      // Nothing is named yet, so the header is already carrying the whole message and a
      // second copy of it below the bar would be noise rather than information.
      return '';
    }
    if (progress.fileBytesDone > 0 && progress.fileBytesTotal > 0) {
      return `${progress.message} · ${formatBytes(progress.fileBytesDone)}`
        + ` / ${formatBytes(progress.fileBytesTotal)}`;
    }
    if (progress.fileBytesDone > 0) {
      return `${progress.message} · 已接收 ${formatBytes(progress.fileBytesDone)}`;
    }
    return progress.message;
  }

  /** The percentage as text, for the determinate card's right-hand corner. */
  private progressPercentLabel(): string {
    return `${Math.round(this.progressPercent())}%`;
  }

  /**
   * The card's headline: the mode, how many files the pass will move, and how many of the
   * current phase's items are done. Falls back to naming the active file when the phase
   * itself has no counter, because "下载 三体" is more useful than the word 「同步」.
   */
  private progressTitle(): string {
    const parts: string[] = [];
    const mode: string = this.syncModeLabel();
    if (mode.length > 0) {
      parts.push(mode);
    }
    if (this.syncFileTotal > 0) {
      parts.push(`共 ${this.syncFileTotal} 个${this.syncUnit}`);
    }
    const count: string = this.progressCountLabel();
    if (count.length > 0) {
      parts.push(count);
    }
    if (parts.length === 0) {
      return '同步进行中';
    }
    return parts.join(' · ');
  }

  /**
   * The line under the bar, or the text beside the ring when there is no bar.
   *
   * With no file named — the metadata phases — this returns the full phase message, because
   * the header only carries the part before the first colon.
   */
  private progressStatus(): string {
    const detail: string = this.progressDetail();
    if (detail.length > 0) {
      return detail;
    }
    const progress: SyncProgress | undefined = this.syncProgress;
    return progress === undefined ? '' : progress.message;
  }

  /** The counter shown beside the bar: "文件 3 / 12", or nothing when uncountable. */
  private progressCountLabel(): string {
    const progress: SyncProgress | undefined = this.syncProgress;
    if (progress === undefined || progress.total <= 0) {
      return '';
    }
    return `${this.syncUnit} ${progress.completed} / ${progress.total}`;
  }

  /**
   * Which mode the running pass is, read out of its own progress line.
   *
   * The engine prefixes every transfer-phase line with `labelForMode(mode)`, so the label
   * is already in the report and does not need a second channel — or a second field that
   * could disagree with it. Falling back to the generic word keeps this a pure function of
   * what has actually been reported: during the first metadata phase there is no mode in
   * the line yet, and the card says 「同步」 rather than guessing.
   */
  private syncModeLabel(): string {
    const progress: SyncProgress | undefined = this.syncProgress;
    if (progress === undefined) {
      return '';
    }
    const colon: number = progress.message.indexOf('：');
    if (colon <= 0) {
      return '同步';
    }
    return progress.message.substring(0, colon);
  }

  /**
   * The live progress card.
   *
   * Rendered only while a pass is reporting, which is what makes the transition to the
   * summary line a real transition rather than an extra line that lingers: on completion
   * `syncProgress` goes back to `undefined` and this builder renders nothing at all.
   *
   * Two shapes, chosen by `progressIsDeterminate()`:
   *
   *  - **determinate** (the transfer phases, and the two metadata phases that walk a known
   *    list) — a linear bar filled by `completed / total`, with the count spelled out;
   *  - **indeterminate** (the phases that are a single request of unknown duration) — a
   *    turning ring and the phase name, with **no bar at all**. A bar pinned at 0% would be
   *    the app asserting a fraction it does not have.
   *
   * House style: the palette's card surface, the 1 vp `palette.border` hairline, `RADIUS_CARD`,
   * and no `systemMaterial` — a system material knows only light from dark and would repaint
   * this card with the system's colour on the sepia palette, which is the defect phase 4 removed
   * from every other surface in this file. The hairline is back in r94 because the borderless
   * version was unreadable in 护眼 on the device; see `ui/ListRow.ets`.
   */
  @Builder
  private syncProgressCard() {
    if (this.syncProgress !== undefined && this.progressIsDeterminate()) {
      this.syncProgressDeterminate()
    } else if (this.syncProgress !== undefined) {
      this.syncProgressIndeterminate()
    }
  }

  /**
   * The card's determinate body: a real fraction, so a real bar.
   *
   * A `@Builder` body is UI syntax only, so nothing is computed inside it that a helper
   * method cannot answer: the colours, the strings and the percentage all come from the
   * methods above. That is also what keeps the update cheap — ArkUI re-renders whichever
   * fields the report changed, and there is no state written during rendering.
   */
  @Builder
  private syncProgressDeterminate() {
    Column({ space: 8 }) {
      Row() {
        Text(this.progressTitle())
          .fontSize(TYPE_CAPTION)
          .fontColor(paletteFor(this.themeMode).mutedForeground)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.progressPercentLabel())
          .fontSize(TYPE_CAPTION)
          .fontColor(paletteFor(this.themeMode).foreground)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // The fill is not eased: this bar's whole purpose is to show a number the engine
      // actually counted, and `enableSmoothEffect` is a `Ring`/`ScaleRing` option in this
      // SDK — it is not available on the linear type, which the compiler confirms. The
      // setting still reaches this card through the ring in the indeterminate branch and
      // through `Motion.fadeIn()` on the entrance, the two places where anything animates.
      Progress({ value: this.progressPercent(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color(paletteFor(this.themeMode).primary)
        .backgroundColor(paletteFor(this.themeMode).muted)
        .borderRadius(RADIUS_LABEL)

      Text(this.progressStatus())
        .fontSize(TYPE_CAPTION)
        .fontColor(paletteFor(this.themeMode).mutedForeground)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(SPACE_M)
    .backgroundColor(paletteFor(this.themeMode).card)
    .borderRadius(RADIUS_CARD)
    // The hairline is back. r93 removed it on the fill arithmetic — `card` against the page is
    // 1.143:1 (light), 1.124:1 (dark) and 1.047:1 (sepia) — and sepia is the theme where the
    // number was tightest and the device check disagreed with it. See `ui/ListRow.ets`, which
    // carries the full reasoning; the short version is that a 1.047:1 step with no edge reads
    // as one flat surface once it is on a real screen.
    .borderWidth(1)
    .borderColor(paletteFor(this.themeMode).border)
    .transition(transitionOrIdentity(Motion.fadeIn()))
    .margin({ left: 16, right: 16 })
  }

  /**
   * The card's indeterminate body: the phase is happening, and no fraction exists.
   *
   * A ring rather than a bar. `Progress`'s linear type has no indeterminate mode, and a
   * linear bar pinned at 0% would have the app assert a fraction it does not have — the one
   * thing this branch exists to avoid. The ring's tick count comes from `Motion`, so turning
   * the animation setting off stops it turning.
   */
  @Builder
  private syncProgressIndeterminate() {
    Column({ space: 8 }) {
      Text(this.progressTitle())
        .fontSize(TYPE_CAPTION)
        .fontColor(paletteFor(this.themeMode).mutedForeground)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 8 }) {
        // `type: ProgressType.Ring` with the base `ProgressStyleOptions` is the SDK's
        // indeterminate ring: there is no value to fill, and the tick count is what sets
        // whether — and how fast — it turns. The count comes from `Motion`, so the animation
        // setting reaches it; `Motion.progressTickCount()` returns 0 when the setting is off.
        // (The declarative `style` option is the deprecated `ProgressStyle` enum, which is why
        // this is the `.style()` attribute instead of a third constructor member.)
        Progress({ value: 0, total: 100, type: ProgressType.Ring })
          .style({ scaleCount: Motion.progressTickCount(), scaleWidth: 2 })
          .width(18)
          .height(18)
          .color(paletteFor(this.themeMode).primary)
        Text(this.progressStatus())
          .fontSize(TYPE_CAPTION)
          .fontColor(paletteFor(this.themeMode).mutedForeground)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(SPACE_M)
    .backgroundColor(paletteFor(this.themeMode).card)
    .borderRadius(RADIUS_CARD)
    // The same hairline as the determinate body above, for the same reason and from the same
    // device check: the two states of one card must not be bounded differently.
    .borderWidth(1)
    .borderColor(paletteFor(this.themeMode).border)
    .transition(transitionOrIdentity(Motion.fadeIn()))
    .margin({ left: 16, right: 16 })
  }

  /**
   * Sync once, quietly, after startup.
   *
   * Deliberately undramatic compared with the manual button:
   *
   *  - it does nothing at all unless the user has left 「自动同步」 switched on; see the
   *    guard below for why that makes the switch a real off switch;
   *  - it does nothing at all when sync has never been configured, so a user who only
   *    reads local books is never shown a network error;
   *  - a failure is written to the sync tab's status line and **not** toasted. An
   *    automatic action must not interrupt someone who did not ask for it, and the
   *    common failures here are mundane — no network, or the device still locked so
   *    the credential cannot be read.
   *  - `syncNow` already refuses when a sync is in flight and when the network policy
   *    (Wi-Fi only) is not satisfied, so those checks are not repeated here.
   *
   * It is a single attempt, not a retry loop: a background retry schedule is a
   * different feature, and one that the platform can suspend at any time.
   */
  private async autoSyncOnStartup(): Promise<void> {
    // The auto-sync switch, consulted in exactly **one** place. `bootstrap` awaits this
    // method from two branches — the already-initialised path and the cold-start path —
    // so the guard lives here rather than at either call site, and the two cannot drift
    // apart the way two copies of a check would.
    //
    // Read from `this.config`, the shell's copy of what `SyncConfigStore` loaded; there
    // is deliberately no second storage path for this flag. With the switch off the
    // method returns before any network work *and* before anything is written to the sync
    // status line, so a launch with auto-sync off is indistinguishable from a launch with
    // no server configured at all.
    if (!this.config.autoSync) {
      return;
    }
    if (!isAppCoreReady()) {
      return;
    }
    let configured: boolean = false;
    try {
      const service = sync();
      configured = service.isConfigured();
      if (!configured || service.isRunning()) {
        return;
      }
      // The protocol gate. `automaticPassGate` reads the remote index (writes nothing) and
      // returns the reason an automatic pass must not run — a v1 server, or an index it
      // cannot classify — or an empty string when the ordinary v2 pass may proceed. The
      // policy lives in the service so this screen and any future caller cannot disagree
      // about it; what is decided here is only whether to show the user a line about it.
      const gate: string = await service.autoSyncGate();
      if (gate.length > 0) {
        this.syncMessage = gate;
        return;
      }
    } catch (err) {
      // A service that cannot report its own state is not ready to sync. Logged
      // because this is the difference between "sync is not configured" and "sync
      // could not be asked", and the two look identical from the outside.
      hilog.warn(DOMAIN, TAG, 'auto-sync state check failed: %{public}s', String(err));
      return;
    }
    try {
      // The ordinary pass, with the same live-progress handler the manual button uses.
      const onProgress = this.progressHandler();
      const counts = await sync().syncNow(SyncMode.NORMAL, onProgress);
      this.syncMessage =
        `启动同步：拉取 ${counts.pulled}，推送 ${counts.pushed}，失败 ${counts.failed}`;
      if (counts.pulled > 0 || counts.pushed > 0) {
        // Only reload when something actually changed; a reload rebuilds the grid
        // from SQLite and would throw away the user's scroll position.
        await this.reloadShelf();
        await this.reloadAnnotations();
      }
    } catch (err) {
      this.syncMessage = `启动同步失败：${
        err instanceof InkBoatError ? err.message : String(err)
      }`;
    } finally {
      // The live card gives way to whichever line above applies. In `finally` so a throw
      // cannot leave a progress card on a finished pass.
      this.syncProgress = undefined;
      this.syncFileTotal = 0;
    }
  }

  /**
   * The large title at the top-left of a top-level page: 书架 / 书签笔记 / 设置.
   *
   * ## What it is modelled on
   *
   * The reference app draws its 更多 page title as a `Row` holding one bold `Text` at the very
   * top-left of the page, painted the page background and positioned **outside** the scrolling
   * list (`ClashBox/entry/src/main/ets/pages/MorePage.ets:106-118`: the `Row` is a sibling of
   * the `Scroll` inside the page `Stack`, with `.position({x: 0, y: ...})` and
   * `.zIndex(1)`), and the `Scroll` is given `padding({top: TAB_CONTENT_TITLE_HEIGHT})` so the
   * first row starts below the title rather than under it (`:192`). Its size is
   * `TAB_CONTENT_TITLE_FONT_SIZE` — 30, `FontWeight.Bold` (`common/entity/Constants.ets:54-56`).
   *
   * This is that treatment with this app's tokens: `TYPE_TITLE_LARGE` (30) and `Bold`, on the
   * palette's `foreground`, at the page's own horizontal margin (`SPACE_M`, the same 16 the
   * shelf's grid and both settings lists use, so the title and the first card start on one
   * line). It is a **page** title and not a section heading — that is `TYPE_TITLE_LARGE`'s
   * role here and what `detailHeader` already uses; `TYPE_TITLE` (20) is the sheet headers'
   * step, and a tab titled at the size of a sheet title would read as a panel.
   *
   * ## Fixed, not scrolling
   *
   * Each caller puts this above its scrollable, never inside it, which is what keeps the
   * reference's fixed title. That is also why it is one builder in this file rather than three
   * in the pages: the three tabs must not disagree about the step, the weight or the inset, and
   * `ShelfPage` / `AnnotationsPage` have no title of their own to reuse.
   *
   * ## Why it cannot double up
   *
   * None of the three tabs drew a page title before this: the shelf opens on its search row,
   * 书签笔记 on the book-selector strip, 设置 on the first list row, and the settings *detail*
   * pages draw `detailHeader` instead — those are pushed `NavDestination`s, not tabs, and they
   * are not given this. The tab bar's own label names the section, which is why the old
   * comment said a heading was not needed; the user has asked for one, and the two do not
   * collide because the bar is at the bottom of the window and this is at the top.
   *
   * ## The status-bar inset
   *
   * It is inherited rather than computed. The shell's root `Column` carries
   * `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])`, so the
   * content area already begins below the status bar and this `Row`'s `top: SPACE_S` is added
   * to that. Putting the title *inside* the expanded area would have put it under the clock.
   */
  @Builder
  private pageTitle(title: string) {
    Row() {
      Text(title)
        .fontSize(TYPE_TITLE_LARGE)
        .fontWeight(FontWeight.Bold)
        .fontColor(paletteFor(this.themeMode).foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: SPACE_M, right: SPACE_M, top: SPACE_S, bottom: SPACE_XS })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private shelfSection() {
    Column() {
      this.pageTitle('书架')

      ShelfPage({
        palette: paletteFor(this.themeMode),
        books: this.shelfBooks,
        loading: this.shelfLoading,
        search: this.shelfSearch,
        sort: this.shelfSort,
        toFileUri: (relativePath: string): string => toFileUri(relativePath),
        onImport: (): Promise<void> => this.importBooks(),
        onReload: (): Promise<void> => this.reloadShelf(),
        onDelete: (book: Book, preserveData: boolean): Promise<void> =>
          this.deleteBookFromShelf(book, preserveData),
        onOpen: (book: Book): void => {
          this.openReader(book);
        },
      })
        .layoutWeight(1)

      if (this.shelfMessage.length > 0) {
        Text(this.shelfMessage)
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private annotationsSection() {
    Column() {
      this.pageTitle('书签笔记')

      // Book selector: a horizontal strip of titles rather than a dropdown, because
      // with a handful of books it is one tap instead of two.
      if (this.shelfBooks.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text('全部')
              .fontSize(12)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              // A selectable pill you tap: 20vp (`RADIUS_CONTROL`), the same role and now
              // the same value as the filter chips in `AnnotationsPage`. Both were a bare
              // `14`, which is not one of the five spec values.
              .borderRadius(RADIUS_CONTROL)
              .backgroundColor(this.annotationBookId.length === 0
                ? $r('sys.color.comp_background_emphasize')
                : $r('sys.color.comp_background_tertiary'))
              .fontColor(this.annotationBookId.length === 0
                ? Color.White
                : $r('sys.color.font_secondary'))
              .onClick((): void => {
                this.selectAnnotationBook('', '');
              })
            ForEach(this.shelfBooks, (book: Book) => {
              Text(book.title.length > 0 ? book.title : '未命名')
                .fontSize(12)
                .maxLines(1)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(RADIUS_CONTROL)
                .backgroundColor(this.annotationBookId === book.id
                  ? $r('sys.color.comp_background_emphasize')
                  : $r('sys.color.comp_background_tertiary'))
                .fontColor(this.annotationBookId === book.id
                  ? Color.White
                  : $r('sys.color.font_secondary'))
                .onClick((): void => {
                  this.selectAnnotationBook(book.id, book.title);
                })
            }, (book: Book) => book.id)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(44)
        // This strip is horizontal and one row tall, so its overscroll is a side-to-side
        // wobble rather than a bounce. Gated anyway, because the reference gates every
        // scrollable it owns and a switch that stops one edge effect but not the next one
        // the finger touches reads as broken.
        .edgeEffect(Motion.edgeEffect())
      }

      AnnotationsPage({
        palette: paletteFor(this.themeMode),
        bookTitle: this.annotationBookTitle,
        bookmarks: this.annotationBookmarks,
        highlights: this.annotationHighlights,
        notes: this.annotationNotes,
        loading: this.annotationsLoading,
        showBookmarks: this.showBookmarks,
        showHighlights: this.showHighlights,
        showNotes: this.showNotes,
        onReload: (): Promise<void> => this.reloadAnnotations(),
        onDeleteBookmark: (item: AnnotationItem): Promise<void> => this.deleteAnnotation(item),
        onDeleteHighlight: (item: AnnotationItem): Promise<void> => this.deleteAnnotation(item),
        onDeleteNote: (item: AnnotationItem): Promise<void> => this.deleteAnnotation(item),
        onEditNote: (item: AnnotationItem, title: string, content: string): Promise<void> =>
          this.editNote(item, title, content),
        onNavigate: (item: AnnotationItem): void => {
          this.navigateToAnnotation(item);
        },
      })
        .layoutWeight(1)

      if (this.annotationsMessage.length > 0) {
        Text(this.annotationsMessage)
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * The settings tab: an index of pages, each opening its own.
   *
   * A list with a chevron per row, because each page carries real content rather than a
   * single switch — an index says "there is more behind this" in a way a segmented
   * control cannot, and it leaves room for the per-row subtitle.
   *
   * No heading of its own for the *list*: the tab's large title (`pageTitle`) already names the
   * page once at the top, and repeating it above the first row would print 设置 twice. The
   * previously recorded reason for having no title at all — the tab bar names the section — is
   * what the user overrode by asking for one; the list below it is unchanged.
   */
  @Builder
  private settingsSection() {
    // ONE flex container, and it is the flex parent the list needs.
    //
    // `settingsList`'s Scroll sizes itself with `layoutWeight`, which needs a flex parent
    // to distribute space. A tab content is not one, so without this Column the weight was
    // ignored, the Scroll fell back to its content height, and the tab content centred the
    // result: a two-row list floating in the middle of an empty screen.
    //
    // Only the index lives here now. The two detail pages are `NavDestination`s pushed onto
    // the shell's stack, so they cover this tab — and the floating tab bar with it — while
    // they are open, and closing one comes back to the index it was pushed from.
    Column() {
      this.pageTitle('设置')
      this.settingsList()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * The route table for the settings stack: one destination per index row.
   *
   * `navDestination` is handed the name that was pushed by `pushPathByName`, and the two
   * rows in `settingsList` push the same two names this builder switches on. A name that
   * matches nothing here renders an empty destination instead of failing, so the pairing
   * is kept adjacent — and the rows are named by route, not by an index, so a row cannot
   * silently become the wrong page.
   *
   * The built-in title bar is hidden on both destinations because it is drawn from system
   * colours, which know light from dark but not sepia: it would put a white bar across the
   * top of the warm palette. `detailHeader` draws the same back affordance and title from
   * the app's own palette instead.
   */
  @Builder
  private settingsPagesMap(name: string) {
    if (name === 'theme') {
      NavDestination() {
        // The Column is the flex parent `themeSection`'s Scroll needs for its
        // `layoutWeight`, exactly as in the settings tab.
        Column() {
          this.detailHeader('主题')
          this.themeSection()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .hideTitleBar(true)
      // The palette background, never a system material: a page-sized system surface only
      // distinguishes light from dark, so it repaints the sepia and dark themes with its own
      // colour — the defect that made the page container carry no material at all.
      .backgroundColor(paletteFor(this.themeMode).background)
    } else if (name === 'sync') {
      NavDestination() {
        Column() {
          this.detailHeader('同步')
          this.syncSection()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .hideTitleBar(true)
      .backgroundColor(paletteFor(this.themeMode).background)
    }
  }

  /**
   * The header of a detail page: a round back button and the page title.
   *
   * Drawn from the app palette rather than left to the destination's own title bar, which
   * is hidden: the built-in bar uses system colours and so cannot follow the sepia theme.
   *
   * The button is a circle rather than a bare chevron because it needs a hit area of its
   * own — a lone glyph is hard to tap and gives no visual confirmation that it is
   * tappable. Its diameter is the minimum tap target, not the icon size.
   */
  @Builder
  private detailHeader(title: string) {
    Row({ space: SPACE_M }) {
      Stack() {
        Text('‹')
          .fontSize(TYPE_TITLE)
          .fontColor(paletteFor(this.themeMode).foreground)
      }
      .width(MIN_TAP_TARGET)
      .height(MIN_TAP_TARGET)
      // A circle, so the radius is the diameter over two. Not one of the five spec values,
      // and deliberately so: this shape's role is "round", and `BorderRadiuses` cannot express
      // a circle from a smaller token. Rounding it to 20 or 32 would square it off.
      .borderRadius(MIN_TAP_TARGET / 2)
      // `card`, not `muted`: the page background was greyed so that cards read as raised
      // surfaces, which left `muted` at roughly 1.03:1 against the page — the circle
      // stopped being visible as a shape at all. `card` is 1.14:1 and matches the raised
      // treatment every other surface on the page now uses.
      .backgroundColor(paletteFor(this.themeMode).card)
      // The same hairline the other cards carry. It is not decoration: on sepia the card is
      // only 1.05:1 against the page, so without this the circle would have no edge there —
      // the one theme where the border is doing all of the work.
      .borderWidth(1)
      .borderColor(paletteFor(this.themeMode).border)
      .onClick((): void => {
        // Pops the page this header belongs to. The system back gesture reaches the same
        // place through `Navigation`, which is why nothing here has to know which page it
        // is on.
        this.settingsPathStack.pop();
      })

      Text(title)
        .fontSize(TYPE_TITLE_LARGE)
        .fontWeight(FontWeight.Bold)
        .fontColor(paletteFor(this.themeMode).foreground)
    }
    .width('100%')
    .padding({ left: SPACE_M, right: SPACE_M, top: SPACE_S, bottom: SPACE_M })
    .alignItems(VerticalAlign.Center)
  }

  /** The index: one row per page. */
  @Builder
  private settingsList() {
    Scroll() {
      Column({ space: SPACE_S }) {
        this.settingsRow('theme', '主题', $r('sys.symbol.paintpalette'), 0)
        this.settingsRow('sync', '同步', $r('sys.symbol.arrow_clockwise'), 1)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: SPACE_M,
        right: SPACE_M,
        top: SPACE_S,
        // Plain `SPACE_M`, **not** `FLOATING_BAR_CLEARANCE`.
        //
        // This is the settings index, and it lives inside the tab shell, so the floating bar
        // is technically drawn over it — but the index is two rows tall and the bar sits far
        // below them, so nothing is hidden and 96 would only be dead space.
        bottom: SPACE_M,
      })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
    // Gated exactly as the reference gates its 14 files: springy overscroll when animation
    // is on, a flat stop when it is off. `Motion` returns `EdgeEffect.None` rather than
    // `null` because this SDK's `edgeEffect` takes a non-nullable `EdgeEffect` (see
    // `Motion.edgeEffect`).
    .edgeEffect(Motion.edgeEffect())
  }

  /**
   * One index row: symbol, title, and the chevron that promises a page.
   *
   * `route` is the name of the `NavDestination` this row opens — the same string
   * `settingsPagesMap` switches on, so a row cannot point at a page that does not exist
   * without the two being visibly out of step in this file.
   *
   * The row is drawn by `ui/ListRow.ets`, which is the shared skeleton the rest of phase 3
   * and phase 4 build on. Two things move as a result, both intended:
   *
   *  - the title/subtitle grow from 14/12 to the skeleton's 16/14, and the card radius from
   *    `RADIUS_CARD` (12) to `BORDER_RADIUS_CARD` (20);
   *  - the chevron becomes `sys.symbol.chevron_right` at 28 instead of the text glyph `›`
   *    at 20. The text glyph was chosen originally because it cannot fail to resolve; the
   *    symbol is the same one the reference app uses, and this project already renders a
   *    dozen `sys.symbol.*` glyphs, so the resolution risk it was avoiding is not real.
   *
   * The click stays here, on the caller, exactly as the reference app attaches it to the
   * `ListItem` rather than to the row component: the whole card is the hit area.
   */
  @Builder
  private settingsRow(route: string, title: string, icon: Resource, index: number) {
    ListRow({
      palette: paletteFor(this.themeMode),
      icon: icon,
      title: title,
      // The staggered entrance lives on `ListRow` itself, which reads this index. Each
      // row therefore arrives 10 ms after the one before it, the same sequence the
      // reference gets from `customAnimationUtil.isScaleTran(index, uiConfig)`.
      index: index,
    })
      .onClick((): void => {
        // `true` asks for the push animation, which Navigation plays as a page slide. The
        // destination covers the whole shell, floating tab bar included — the point of the
        // stack: a settings detail page is a page, not a panel behind a tab bar.
        this.settingsPathStack.pushPathByName(route, null, true);
      })
  }

  @Builder
  private themeSection() {
    Scroll() {
      Column({ space: SPACE_S }) {
        ForEach(THEME_MODES, (mode: ThemeMode, index: number) => {
          this.themeRow(mode, index)
        }, (mode: ThemeMode) => mode)

        Text('主题同时决定阅读器内的正文底/字色：浅色、深色与护眼各有一套。')
          .fontSize(TYPE_CAPTION)
          .fontColor(paletteFor(this.themeMode).mutedForeground)
          .width('100%')
          .padding({ left: SPACE_XS, top: SPACE_S })

        // The animation setting, on the appearance page and below the theme picker,
        // because the two answer the same question: how should the interface look and
        // behave. It is deliberately *not* a row on the settings index — it is a control
        // with four states, and the index is for things that open a page.
        this.animationSection()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: SPACE_M,
        right: SPACE_M,
        top: SPACE_S,
        // Plain `SPACE_M`, **not** `FLOATING_BAR_CLEARANCE`, and the reason is the opposite
        // of the index's. This section is rendered inside a pushed `NavDestination`, and
        // `Navigation` in `NavigationMode.Stack` gives the destination the whole content
        // area — the floating tab bar is *behind* this page while it is open, so there is
        // nothing at the bottom to clear. 96 here was 96vp of empty page under the last row.
        //
        // Phase 2 added two more cards below these (the animation picker's header and its
        // four rows), which does not change the argument: the padding is about what is
        // *behind* the page, not about how tall the page is.
        bottom: SPACE_M,
      })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
    .edgeEffect(Motion.edgeEffect())
  }

  /**
   * The animation-speed picker.
   *
   * Four rows in one card-shaped column, the same shape the theme picker uses above it:
   * a title, a one-line explanation, then one tappable card per option with a checkmark
   * on the selected one. A picker rather than a switch because there are four states, and
   * 「关闭」 is one of them rather than a separate control — the same four ClashBox offers
   * (0 → 100, 1 → 300, 2 → 500, 3 → off).
   *
   * The header is a caption, not a `TYPE_TITLE_LARGE` heading: this is a group inside the
   * appearance page, and the page's own title is drawn by `detailHeader`.
   */
  @Builder
  private animationSection() {
    Column({ space: SPACE_S }) {
      Text('界面动效')
        .fontSize(TYPE_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor(paletteFor(this.themeMode).foreground)
        .width('100%')
        .padding({ left: SPACE_XS, top: SPACE_M })

      Text('控制列表入场、点击反馈与滚动回弹。关闭后所有动效直接呈现，界面不会变慢。')
        .fontSize(TYPE_CAPTION)
        .fontColor(paletteFor(this.themeMode).mutedForeground)
        .width('100%')
        .padding({ left: SPACE_XS, bottom: SPACE_XS })

      ForEach(ANIMATION_OPTIONS, (option: AnimationOption, index: number) => {
        this.animationRow(option, THEME_MODES.length + index)
      }, (option: AnimationOption) => `${option.speed}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * One animation option: label, duration, and a checkmark when it is the selected one.
   *
   * Built from the same card treatment as `themeRow` — `RADIUS_CARD`, the palette's `card`
   * fill, the 1 vp `palette.border` hairline, and a 2 vp `palette.primary` ring on the
   * selection — so the two pickers on this page read as one family. **No `systemMaterial`**:
   * it only knows light from dark, so under sepia it would paint this card with the system's
   * colour and drop the `#F5EBD7` the theme is about, and it would take over the background so
   * the selection border could not be drawn.
   *
   * `index` is the stagger input and is passed in rather than taken from the loop, because
   * the animation rows follow the three theme rows in the same column: numbering them
   * 0-3 would make them all arrive before the theme cards they sit under.
   */
  @Builder
  private animationRow(option: AnimationOption, index: number) {
    Row({ space: SPACE_M }) {
      Column({ space: SPACE_XS }) {
        Text(option.label)
          .fontSize(TYPE_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(paletteFor(this.themeMode).foreground)
        Text(option.isOn
          ? `${option.description} · ${option.duration} ms`
          : option.description)
          .fontSize(TYPE_BODY)
          .fontColor(paletteFor(this.themeMode).mutedForeground)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.animationSpeedIndex === option.speed) {
        Text('✓')
          .fontSize(TYPE_SUBTITLE)
          .fontColor(paletteFor(this.themeMode).primary)
      }
    }
    .width('100%')
    .padding(SPACE_S)
    // A card-shaped content container you tap: 16vp (`RADIUS_CARD`), the same role and the
    // same value as a theme row.
    .borderRadius(RADIUS_CARD)
    .backgroundColor(paletteFor(this.themeMode).card)
    // The **selection** ring, not a card outline: 2 vp of `primary` on the selected option
    // and 1 vp of `border` on the other three. The distinction is the point — the ring is a
    // state, the hairline is the card's edge — and r93 collapsed them by setting the
    // unselected width to 0. That was part of the same outline removal the user has now
    // reversed (「还是保留边框吧，护眼模式下确实看不清」): with no edge, an unselected card in
    // sepia is 1.047:1 against the page.
    .borderWidth(this.animationSpeedIndex === option.speed ? 2 : 1)
    .borderColor(this.animationSpeedIndex === option.speed
      ? paletteFor(this.themeMode).primary
      : paletteFor(this.themeMode).border)
    // The staggered entrance, the same one every list in the app uses.
    .transition(transitionOrIdentity(this.animationOn
      ? Motion.scaleIn(index)
      : null))
    .onClick((): void => {
      // Not awaited: `applyAnimationSpeed` reports nothing and cannot reject — a failed
      // preference write is logged and the on-screen change stands. See `AppearanceStore`.
      this.applyAnimationSpeed(option.speed, true);
    })
  }

  /**
   * One theme card.
   *
   * `index` is the stagger input — pass the loop index so the three cards arrive in
   * sequence, which is the treatment the reference gives every list.
   */
  @Builder
  private themeRow(mode: ThemeMode, index: number) {
    Row({ space: SPACE_M }) {
      // A swatch of the palette itself, so the row shows the colours rather than
      // describing them.
      Stack() {
        Column()
          .width(44)
          .height(44)
          // The swatch is a colour preview — an image-like tile, which the corner-radius
          // spec puts at 8vp (`RADIUS_IMAGE`), the same role the shelf's cover takes. At
          // the card radius (16) a 44vp square rounded by more than a third reads as a
          // blob, and it would have disagreed with every other small preview in the app.
          .borderRadius(RADIUS_IMAGE)
          .backgroundColor(paletteFor(mode).background)
          .borderWidth(1)
          .borderColor(paletteFor(mode).border)
        Text('A')
          .fontSize(TYPE_SUBTITLE)
          .fontColor(paletteFor(mode).foreground)
      }

      Column({ space: SPACE_XS }) {
        Text(paletteFor(mode).label)
          // 16/14 is the skeleton's row type (`TYPE_SUBTITLE`/`TYPE_BODY`), which is what
          // `ListRow` renders. At 14/12 this card looked like a denser control than the
          // two rows on the settings index, even though it is the same kind of surface.
          .fontSize(TYPE_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(paletteFor(this.themeMode).foreground)
        Text(themeDescription(mode))
          .fontSize(TYPE_BODY)
          .fontColor(paletteFor(this.themeMode).mutedForeground)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.themeMode === mode) {
        Text('✓')
          .fontSize(TYPE_SUBTITLE)
          .fontColor(paletteFor(this.themeMode).primary)
      }
    }
    .width('100%')
    .padding(SPACE_S)
    // A theme row is a card-shaped content container you tap, so 16vp. Not the control
    // radius (20): it is a card that happens to be tappable, not a button.
    .borderRadius(RADIUS_CARD)
    // The app palette, and **no `systemMaterial`**.
    //
    // This row used `surfaceBackground(this.material, ...)` + `.systemMaterial(...)`. The
    // material only distinguishes light from dark, so it repainted the row with its own
    // colour and threw away the palette the row is *about*: under sepia (mapped to the
    // system's light mode) the theme picker showed a white card instead of `#F5EBD7`. It
    // also takes over the background, so the 2vp selection border below could not read as
    // a selection at all.
    //
    // The immersive material belongs on the floating tab bar only, where `HdsTabs` already
    // applies it through `barFloatingStyle.systemMaterialEffect`. This is exactly the
    // "small selection chip" mistake the project has hit twice.
    .backgroundColor(paletteFor(this.themeMode).card)
    // The selection ring again — 2 vp of `primary` on the theme in force, 1 vp of `border` on
    // the other two, for the same reason as the animation rows above.
    .borderWidth(this.themeMode === mode ? 2 : 1)
    .borderColor(this.themeMode === mode
      ? paletteFor(this.themeMode).primary
      : paletteFor(this.themeMode).border)
    // The staggered entrance. `Motion.scaleIn` returns `null` when animation is off, and
    // `transitionOrIdentity` turns that into the SDK's own "no transition" — see
    // `Motion.ets` for why the substitution exists instead of passing `null` through.
    .transition(transitionOrIdentity(this.animationOn ? Motion.scaleIn(index) : null))
    .onClick((): void => {
      this.chooseTheme(mode);
    })
  }

  /**
   * The protocol line and its probe.
   *
   * The two dialects share `/readany/sync/index.json`, so the *shape* of that document is
   * what decides whether a pass speaks v1 (one full snapshot per device) or v2 (one file
   * per book) — and the user is the one who has to know, because the consequences differ:
   * a v1 server receives metadata only from this client, and never a book file.
   *
   * The probe is a **read** and writes nothing, which is why it is a button of its own
   * rather than something that happens as a side effect of opening the screen. Its result
   * is the same line a pass refreshes once it has run.
   *
   * A card surface with a hairline border and the control radius, from the app palette —
   * no `systemMaterial` on a small row (a system material knows only light from dark and
   * would drop the sepia palette, the mistake this file has made twice).
   */
  @Builder
  private protocolRow() {
    Row({ space: 12 }) {
      Text(this.serverProtocol)
        .fontSize(TYPE_CAPTION)
        .fontColor(paletteFor(this.themeMode).mutedForeground)
        .layoutWeight(3)
      Button('检测协议')
        .layoutWeight(1)
        .enabled(!this.syncBusy)
        .backgroundColor(paletteFor(this.themeMode).card)
        .fontColor(paletteFor(this.themeMode).foreground)
        .borderRadius(RADIUS_CONTROL)
        .borderWidth(1)
        .borderColor(paletteFor(this.themeMode).border)
        .onClick((): void => {
          this.detectServerProtocol();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    // Routed through `Motion`, like every other entrance in this file, so 「关闭」 really
    // turns it off: `Motion.fadeIn()` returns `null` when the setting is off and
    // `transitionOrIdentity` turns that into the SDK's own "no transition".
    .transition(transitionOrIdentity(this.animationOn ? Motion.fadeIn() : null))
  }

  @Builder
  private syncSection() {
    // ONE scroll container, deliberately. This used to wrap a `SyncSettingsPage` that was
    // *itself* a viewport-filling Scroll: the inner one swallowed every drag and bounced,
    // so the outer never scrolled and everything below the form — the self-test and the
    // network probe — was **unreachable on a phone**. `SyncSettingsPage` is a plain column
    // now and this Scroll owns all scrolling for the tab.
    Scroll() {
      Column({ space: 12 }) {
        if (this.config.url.length > 0) {
          Row({ space: 12 }) {
            Button(labelForMode(SyncMode.NORMAL))
              .layoutWeight(2)
              .enabled(!this.syncBusy)
              .onClick((): void => {
                this.runSync(SyncMode.NORMAL);
              })
            Text(this.syncMessage)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(3)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 0 })
          .alignItems(VerticalAlign.Center)

          // Which protocol the server speaks, and how to ask. Above the transfer buttons
          // because it is the fact that decides what they will do.
          this.protocolRow()

          // --- full transfer ---------------------------------------------------
          // Separate from the ordinary button because the cost is different by orders
          // of magnitude: an ordinary pass moves metadata and covers, these move every
          // book file. A user tapping the wrong one spends their data allowance, so
          // the labels say which direction moves files.
          //
          // Both carry the app palette now, not `sys.color.background_secondary` +
          // `systemMaterial`. A system material knows only light from dark, so it painted
          // these with the system's colour and dropped the sepia palette entirely; and
          // `sys.color.*` follows the *system* colour mode, which this app deliberately sets
          // from its own theme, so the two could disagree. The immersive material belongs on
          // the floating tab bar, where `HdsTabs` applies it.
          Row({ space: 12 }) {
            Button('全量上传')
              .layoutWeight(1)
              .enabled(!this.syncBusy)
              .backgroundColor(paletteFor(this.themeMode).card)
              .fontColor(paletteFor(this.themeMode).foreground)
              .borderRadius(RADIUS_CONTROL)
              .borderWidth(1)
              .borderColor(paletteFor(this.themeMode).border)
              .onClick((): void => {
                this.confirmFullTransfer(SyncMode.FULL_UPLOAD);
              })
            Button('全量下载')
              .layoutWeight(1)
              .enabled(!this.syncBusy)
              .backgroundColor(paletteFor(this.themeMode).card)
              .fontColor(paletteFor(this.themeMode).foreground)
              .borderRadius(RADIUS_CONTROL)
              .borderWidth(1)
              .borderColor(paletteFor(this.themeMode).border)
              .onClick((): void => {
                this.confirmFullTransfer(SyncMode.FULL_DOWNLOAD);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 0 })

          // States what each one does, because "full download" pulling an entire
          // library is not obvious from the label alone.
          Text('普通同步只同步书目、标注与封面；全量上传/下载会额外传输书籍文件本身。')
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
        }

        this.syncProgressCard()

        SyncSettingsPage({
          config: this.config,
          palette: paletteFor(this.themeMode),
          onTest: (url: string, username: string, password: string, allowInsecure: boolean, remoteRoot: string): Promise<void> =>
            this.testConnection(url, username, password, allowInsecure, remoteRoot),
          onSave: (url: string, username: string, password: string, allowInsecure: boolean, remoteRoot: string): Promise<void> =>
            this.saveConnection(url, username, password, allowInsecure, remoteRoot),
          // Separate from `onSave` on purpose: the switch saves itself, because a
          // safety control that needs a second, unrelated tap is a trap. See
          // `saveAutoSync`.
          onAutoSyncChange: (enabled: boolean): Promise<void> =>
            this.saveAutoSync(enabled),
        })

        this.planProbeSection()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // Clears the floating tab bar, which overlaps this scroll area.
      .padding({ bottom: FLOATING_BAR_CLEARANCE })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
    // Gated like the other two scroll owners in this file; sync is the longest list on the
    // page, so its overscroll is the one that is actually felt.
    .edgeEffect(Motion.edgeEffect())
  }

  /**
   * Ask before a full transfer.
   *
   * Not a formality: a full download pulls every book file the server has, which on a
   * large library is gigabytes and, on a metered connection, real money. A full upload
   * re-sends every file too. Both are worth one confirmation.
   */
  private confirmFullTransfer(mode: SyncMode): void {
    // Both full modes are named explicitly rather than making one of them the `else`.
    // With a silent fallback, adding a third mode later would show the upload warning
    // for an operation that is not an upload — and the user would be agreeing to
    // something other than what they were told.
    let detail: string = '';
    if (mode === SyncMode.FULL_DOWNLOAD) {
      detail = '将从服务器下载全部书籍文件到本机。文件较多时耗时较长，并会消耗流量。';
    } else if (mode === SyncMode.FULL_UPLOAD) {
      detail = '将把本机全部书籍文件重新上传到服务器。文件较多时耗时较长。';
    }
    AlertDialog.show({
      title: labelForMode(mode),
      message: detail,
      primaryButton: {
        value: '取消',
        action: (): void => {},
      },
      secondaryButton: {
        value: '开始',
        action: (): void => {
          this.runSync(mode);
        },
      },
    });
  }

  /**
   * The open reader.
   *
   * Rendered instead of the tab shell rather than as an overlay: a reading screen
   * should own the window, and a sheet-based overlay would leave the tab bar
   * visible along the bottom of the page.
   *
   * **No shell-drawn reader header any more.** This builder used to put a row of
   * `返回` + book title above the component, while `ReaderView` drew its own header
   * underneath — two back controls and the book title twice, since the kit's running
   * head is the book title for a book with no running-head markup. The approved reader
   * design gives the top bar exactly three elements, and `ReaderView.topBar` draws all
   * three of them: `返回` · chapter title (centred) · page within the chapter. So the
   * reader owns its whole screen and the shell contributes nothing above it.
   */
  @Builder
  private readerScreen(book: Book) {
    Column() {
      ReaderView({
        bookId: book.id,
        filePath: this.openBookPath,
        title: book.title,
        initialSpine: this.readerPosition.spineIndex,
        initialDomPos: this.readerPosition.domPos,
        // Only used when `initialSpine` is negative, i.e. neither this device nor the
        // synced columns have a position; the reader then resolves the chapter the
        // peer's CFI names.
        initialCfi: book.currentCfi,
        // The override: empty for an ordinary open, the tapped annotation's locator
        // when the shell was asked to jump. It is resolved inside `ReaderView`, where
        // the book's parsed spine list is available, and it wins over `initialSpine`
        // when it resolves — falling back to it when it does not.
        initialLocator: this.readerLocator,
        settings: this.readerSettings,
        // **The reader's page colours come from here.** `ReaderView` derives its page
        // background and text from this one value (`readerAppearance(themeMode)`), so the
        // sepia theme paints a sepia page instead of the reader's old cream, and dark mode
        // paints light text. Passing the theme rather than a colour is the point: there is
        // no second place a page colour could be set.
        themeMode: this.themeMode,
        callbacks: {
          onPositionChanged: (position: ReadingPosition): void => {
            this.onReaderPosition(position);
          },
          onOpenFailed: (message: string): void => {
            this.shelfMessage = message;
          },
          onReady: (chapterCount: number): void => {
            // The chapter count is known only after parsing; persisting it here
            // saves the next open a parse just to show a number.
            if (chapterCount > 0 && chapterCount !== book.totalChapters) {
              this.recordChapterCount(book, chapterCount);
            }
          },
          onSettingsChanged: (next: ReaderSettings): void => {
            this.onReaderSettingsChanged(next);
          },
          onAddBookmark: (
            spineIndex: number,
            domPos: string,
            label: string,
            chapterTitle: string,
          ): Promise<void> => this.addBookmark(book.id, spineIndex, domPos, label, chapterTitle),
          onAddNote: (
            spineIndex: number,
            domPos: string,
            title: string,
            content: string,
            chapterTitle: string,
          ): Promise<void> =>
            this.addNote(book.id, spineIndex, domPos, title, content, chapterTitle),
          onBack: (): void => {
            void this.closeReader();
          },
        },
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    // The application theme's page colour, not a reader setting: this is the frame behind
    // `ReaderView`, so it has to be the same colour the reader's own bars paint.
    .backgroundColor(paletteFor(this.themeMode).background)
  }

  // -------------------------------------------------------------------------
  // Annotations
  // -------------------------------------------------------------------------

  /**
   * Load the annotation tab.
   *
   * With no book selected this shows the most recently updated notes across the
   * whole library, which is the useful view when the user is looking for something
   * they wrote rather than something in one book.
   */
  private async reloadAnnotations(): Promise<void> {
    if (!isAppCoreReady()) {
      return;
    }
    this.annotationsLoading = true;
    try {
      if (this.annotationBookId.length === 0) {
        this.annotationBookmarks = [];
        this.annotationHighlights = [];
        this.annotationNotes = await noteStore().listRecent(50);
        this.annotationBookTitle = '';
      } else {
        this.annotationBookmarks = await bookmarkStore().listForBook(this.annotationBookId);
        this.annotationHighlights = await highlightStore().listForBook(this.annotationBookId);
        this.annotationNotes = await noteStore().listForBook(this.annotationBookId);
      }
      this.annotationsMessage = '';
    } catch (err) {
      this.annotationsMessage = err instanceof Error ? err.message : JSON.stringify(err);
    } finally {
      this.annotationsLoading = false;
    }
  }

  /** Switch the annotation tab to a book, or back to the recent view. */
  private async selectAnnotationBook(bookId: string, title: string): Promise<void> {
    this.annotationBookId = bookId;
    this.annotationBookTitle = title;
    await this.reloadAnnotations();
  }

  private async deleteAnnotation(item: AnnotationItem): Promise<void> {
    try {
      if (item.kind === AnnotationKind.BOOKMARK) {
        await bookmarkStore().remove(item.id);
      } else if (item.kind === AnnotationKind.HIGHLIGHT) {
        await highlightStore().remove(item.id);
      } else {
        await noteStore().remove(item.id);
      }
      await this.reloadAnnotations();
      this.groupTotal = await groupCount();
    } catch (err) {
      this.annotationsMessage = err instanceof Error ? err.message : JSON.stringify(err);
    }
  }

  private async editNote(item: AnnotationItem, title: string, content: string): Promise<void> {
    await noteStore().update(item.id, title, content, []);
    await this.reloadAnnotations();
  }

  /**
   * Jump to an annotation — a bookmark, a highlight or a note.
   *
   * All three carry a locator (`bookmark.cfi` / `highlight.cfi` / `note.cfi`, one
   * column shared by the three tables) and all three are navigable now: an annotation
   * written on this device holds this reader's `spine:{n}:{domPos}` pair and restores
   * exactly, while one synced from a ReadAny client holds an EPUB CFI that resolves to
   * its chapter. `ReaderView.annotationStart` is the single place that decides which
   * of those a locator is and what it can restore; this method only hands the locator
   * over.
   *
   * **This method deliberately does not touch the stored reading position.** It used
   * to load the position into `readerPosition` and then overwrite that field with a
   * synthesised position — a write the open discarded, and a wasted store read. Now the
   * locator travels as `openReader`'s override and `readerPosition` stays whatever the
   * store says, so the fallback for an unusable locator is the real stored position.
   * No `savePosition` / `persistPosition` call is added here either: jumping to a
   * bookmark is not reading there, and a second writer here would race the flush that
   * `openReader` awaits. The position *does* move once the reader genuinely displays
   * the page — through the same throttled `pageShow` path as any other page — which is
   * truthful, because it really did display it, and it is what keeps the shelf progress
   * from disagreeing with the page on screen.
   */
  private async navigateToAnnotation(item: AnnotationItem): Promise<void> {
    const book: Book | undefined = await bookRepository().getById(item.bookId);
    if (book === undefined) {
      this.toast('找不到这本书');
      return;
    }
    await this.openReader(book, item.locator);
  }

  /**
   * Create a bookmark at the reader's current page.
   *
   * The annotation tab is refreshed so that going back shows the new bookmark
   * without a manual reload.
   */
  private async addBookmark(
    bookId: string,
    spineIndex: number,
    domPos: string,
    label: string,
    chapterTitle: string,
  ): Promise<void> {
    await createBookmarkAt(bookId, spineIndex, domPos, label, chapterTitle);
    await this.reloadAnnotations();
  }

  private async addNote(
    bookId: string,
    spineIndex: number,
    domPos: string,
    title: string,
    content: string,
    chapterTitle: string,
  ): Promise<void> {
    await createNoteAt(bookId, spineIndex, domPos, title, content, chapterTitle);
    await this.reloadAnnotations();
  }

  /** Update a book's chapter count after the reader has parsed it. */
  private async recordChapterCount(book: Book, chapterCount: number): Promise<void> {
    try {
      const updated: Book = copyBookForChapterCount(book, chapterCount);
      await bookRepository().upsert(updated);
    } catch (err) {
      // Cosmetic: the count reappears next time the book is opened. Logged anyway, so
      // a persistently failing write is visible in diagnostics rather than looking like
      // a book that simply has no chapter count.
      hilog.warn(DOMAIN, TAG, 'chapter count upsert failed: %{public}s', String(err));
    }
  }
  /**
   * Binary-plan self-test, rendered so a device install verifies the upload and
   * download decision rule rather than only the compiler doing so.
   */
  @Builder
  private planProbeSection() {
    Column({ space: 4 }) {
      Text('文件同步决策自检')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 4 })
      ForEach(this.planChecks, (line: string) => {
        Text(line)
          .fontSize(11)
          .width('100%')
          // A check line can be a long path with no space in it. Without an explicit
          // break rule the Text has nowhere to wrap, so the column is stretched to the
          // text's width and the panel runs off the right edge of the screen.
          .wordBreak(WordBreak.BREAK_ALL)
      }, (line: string) => line)
      Text(`API ${this.deviceApiLevel} · 表面样式 ${this.surfaceStyle}`)
        .fontSize(11)
        .width('100%')
        .margin({ top: 4 })

      // The database's effective pragmas, read back from the store rather than
      // assumed. `foreign_keys` must be 1 for cascade deletes to work at all, and
      // SQLite disables it by default — a store that refused the pragma would delete
      // a book without its annotations and look like a data bug.
      Text(`数据库 ${databaseDiagnostics()} · 分组 ${this.groupTotal}`)
        .fontSize(11)
        .width('100%')

      // --- network method probe ---------------------------------------------
      // Placed here because it needs no credentials and answers the project's
      // largest open question: whether `customMethod` puts a non-standard verb on
      // the wire. Tapping this is a few seconds of work; configuring a WebDAV
      // account first is not, which is the whole reason it exists.
      Divider().margin({ top: 8, bottom: 6 })

      Text('网络方法自检（无需 WebDAV 账号）')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      TextInput({ text: this.probeUrl, placeholder: DEFAULT_PROBE_URL })
        .fontSize(12)
        .width('100%')
        .onChange((value: string): void => {
          this.probeUrl = value;
        })

      Row({ space: 8 }) {
        Button(this.probeRunning ? '探测中...' : '运行探测')
          .fontSize(13)
          .backgroundColor(paletteFor(this.themeMode).primary)
          .fontColor(paletteFor(this.themeMode).primaryForeground)
          .enabled(!this.probeRunning)
          .onClick((): void => {
            this.runMethodProbe();
          })
        if (this.probeLines.length > 0) {
          Button('清除')
            .fontSize(13)
            .backgroundColor(paletteFor(this.themeMode).card)
            .fontColor(paletteFor(this.themeMode).foreground)
            .borderWidth(1)
            .borderColor(paletteFor(this.themeMode).border)
            .onClick((): void => {
              this.probeLines = [];
              this.probeVerdict = '';
            })
        }
      }
      .width('100%')
      .margin({ top: 6 })

      ForEach(this.probeLines, (line: string) => {
        Text(line)
          .fontSize(11)
          .width('100%')
          // A check line can be a long path with no space in it. Without an explicit
          // break rule the Text has nowhere to wrap, so the column is stretched to the
          // text's width and the panel runs off the right edge of the screen.
          .wordBreak(WordBreak.BREAK_ALL)
      }, (line: string) => line)

      if (this.probeVerdict.length > 0) {
        Text(this.probeVerdict)
          .fontSize(11)
          .width('100%')
          .margin({ top: 4 })
          .fontColor(this.probeWorks ? $r('sys.color.font_primary') : $r('sys.color.warning'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    // This panel is a content container, so 16vp (`RADIUS_CARD`); it was a bare `8`.
    .borderRadius(RADIUS_CARD)
    // The palette's card colour, plus the hairline border that makes it read as a surface
    // on all three themes — restored after the device check that rejected the borderless
    // settings surfaces (see `ui/ListRow.ets`). It used `sys.color.comp_background_tertiary`
    // + `systemMaterial`, which is the same mistake as the theme picker: a system material
    // knows only light and dark, so the panel came out system-coloured on sepia rather than
    // `#F5EBD7`.
    .backgroundColor(paletteFor(this.themeMode).card)
    .borderWidth(1)
    .borderColor(paletteFor(this.themeMode).border)
    .margin({ left: 16, right: 16, top: 16 })
  }

  build() {
    Column() {
      if (!this.ready) {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36)
          Text(this.initMessage)
            .fontSize(14)
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.openBook !== undefined) {
        // The reader replaces the shell rather than layering over it: a reading
        // screen should own the window, and an overlay would leave the tab bar
        // sitting along the bottom of the page.
        this.readerScreen(this.openBook)
      } else {
        // No material on the page container, deliberately.
        //
        // It used to be applied here, and it broke every theme except light. A system
        // material only distinguishes light from dark, so it painted the whole page with
        // its own colour and ignored the app's palette: sampled from a device screenshot,
        // the dark theme's page came out \`#000000\` instead of \`#121212\`, and sepia came out
        // \`#FFFFFF\` instead of \`#F0E6D2\`. Light looked correct only because the light
        // material is white and the light palette is near-white.
        //
        // The immersive material belongs on the floating tab bar, which is where the
        // design spec puts it and where HDS already applies it through
        // \`barFloatingStyle.systemMaterialEffect\`. A page-sized surface is not a material
        // surface — it is the theme's background.
        //
        // The shell — and only the shell — sits inside the root `Navigation`.
        //
        // In `NavigationMode.Stack` a pushed `NavDestination` fills the whole content
        // area, so the floating tab bar is covered while a settings page is open. That is
        // the entire reason for the wrapper: a settings detail page rendered *inside* the
        // tab content leaves the tab bar floating over it, which reads as a panel rather
        // than as a page.
        //
        // The reader branch above stays outside on purpose: it already replaces the shell
        // rather than layering over it, and pushing it would give a page that owns the
        // window a tab bar behind it in the back stack.
        Navigation(this.settingsPathStack) {
          this.shellTabs()
        }
        .width('100%')
        .height('100%')
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .hideToolBar(true)
        .navDestination(this.settingsPagesMap)
      }
    }
    .width('100%')
    .height('100%')
    // The themed background, not the system one. A system colour would sit behind the
    // sepia and dark palettes and show through wherever a child has no background of
    // its own, which is exactly the seam that makes a themed app look half-applied.
    .backgroundColor(paletteFor(this.themeMode).background)
    // The themed background must reach into the system navigation-bar area.
    // Without this the area below the floating tab bar is painted by the window
    // (black) instead of the app, which reads as a stray band under the capsule.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * The tab items, shared by the HDS and the native shell.
   *
   * A separate builder so the two component branches cannot drift: whichever shell is
   * used, the same three tabs are rendered with the same order and labels. `TabContent`
   * must be a direct child of the tabs component, and a builder that emits them is
   * inlined, so this is valid in both.
   */
  @Builder
  private tabItems() {
    TabContent() {
      this.shelfSection()
    }
    .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.ebook')) }, '书架')
      .labelStyle({ font: { size: TAB_LABEL_SIZE, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: paletteFor(this.themeMode).primary,
        unselectedColor: paletteFor(this.themeMode).mutedForeground,
      }))

    TabContent() {
      this.annotationsSection()
    }
    .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.bookmark_fill')) }, '书签笔记')
      .labelStyle({ font: { size: TAB_LABEL_SIZE, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: paletteFor(this.themeMode).primary,
        unselectedColor: paletteFor(this.themeMode).mutedForeground,
      }))

    TabContent() {
      this.settingsSection()
    }
    .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')) }, '设置')
      .labelStyle({ font: { size: TAB_LABEL_SIZE, weight: FontWeight.Medium } })
      .iconStyle({
        selectedColor: paletteFor(this.themeMode).primary,
        unselectedColor: paletteFor(this.themeMode).mutedForeground,
      }))
  }

  /**
   * The tab shell.
   *
   * Two branches, chosen by capability rather than by API level:
   *
   *  - **`HdsTabs`** when `SystemCapability.UIDesign.HDSComponent.Core` is present. The
   *    HarmonyOS design spec makes the **floating** bottom tab bar (悬浮式) an HDS
   *    feature: it is the control that carries the 沉浸光感 material, the capsule
   *    container, and the gradient mask. `barFloatingStyle` is what selects it.
   *  - **native `Tabs`** otherwise, which is the tiled presentation (平铺式). The spec
   *    documents both as valid; only the material differs.
   *
   * `canIUse` is the correct test here and the distinction matters, because the two
   * questions are easy to conflate: this is "does the device have the capability",
   * while API-level gating elsewhere uses `deviceInfo.sdkApiVersion`. HDS is
   * `@since 6.1.0(23)`, below this module's `compatibleSdkVersion` of 24, so on every
   * device this app claims to support the answer should be yes — the branch exists so
   * that a device without it degrades to a working tab bar instead of a blank shell.
   *
   * The floating bar **overlaps the content**, so every scrollable section carries
   * bottom padding of `FLOATING_BAR_CLEARANCE`. Without it the last row of a list sits
   * under the bar and cannot be reached — the same class of defect as the nested
   * `Scroll` fixed in this file, and one that also only shows up under a finger.
   */
  @Builder
  private shellTabs() {
    if (this.hdsTabsAvailable) {
      HdsTabs({ barPosition: BarPosition.End, index: this.activeTab, controller: this.hdsController }) {
        this.tabItems()
      }
      .width('100%')
      .height('100%')
      .barMode(BarMode.Fixed)
      // The floating presentation has four required conditions, and the official
      // example states all of them: barFloatingStyle, barOverlap(true),
      // vertical(false), and barPosition(BarPosition.End).
      //
      // Two earlier attempts set only barFloatingStyle and barPosition, and the bar
      // stayed in the tiled presentation. barOverlap is what makes the bar overlay the
      // content, and it is also what raises the default blur to
      // BlurStyle.COMPONENT_THICK, so without it there is nothing to blur and nothing
      // to float.
      .barOverlap(true)
      .vertical(false)
      // Follows the user's speed setting, but never 0: with 「关闭」 this is
      // `TAB_SWITCH_DURATION_MS` (300 ms), because a tab tap with no transition at all is
      // disorienting. See `tabSwitchDuration` and `TAB_SWITCH_DURATION_MS`.
      .animationDuration(this.tabSwitchDuration())
      .barFloatingStyle({
        barSideMargin: `${FLOATING_BAR_SIDE_MARGIN}vp`,
        barBottomMargin: `${FLOATING_BAR_BOTTOM_MARGIN}vp`,
        gradientMask: {
          maskColor: paletteFor(this.themeMode).background,
          maskHeight: FLOATING_BAR_MASK_HEIGHT,
        },
        // The material the design spec names for 悬浮式: "悬浮式底部页签……适配沉浸光感
        // 材质". `MaterialType.IMMERSIVE` is that material. The level is left at ADAPTIVE
        // so the system decides how far to push it — the spec's own illustration is the
        // strong setting and is explicitly not the component default.
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
        barOpacity: 1,
      })
      // Follow the system's own policy on whether to blur, rather than forcing it on.
      .blurStrategy(BlurStrategy.ADAPTIVE)
      .onChange((index: number): void => {
        this.activeTab = index;
      })
    } else {
      Tabs({ barPosition: BarPosition.End, index: this.activeTab }) {
        this.tabItems()
      }
      .width('100%')
      .height('100%')
      .barMode(BarMode.Fixed)
      // Follows the user's speed setting, but never 0: with 「关闭」 this is
      // `TAB_SWITCH_DURATION_MS` (300 ms), because a tab tap with no transition at all is
      // disorienting. See `tabSwitchDuration` and `TAB_SWITCH_DURATION_MS`.
      .animationDuration(this.tabSwitchDuration())
      .onChange((index: number): void => {
        this.activeTab = index;
      })
    }
  }
}
