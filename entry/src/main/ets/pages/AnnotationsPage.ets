import { classifyLocator, compareCfiPosition, describeLocator, highlightColorHex, LocatorKind } from 'core';
import type { Bookmark, Highlight, Note } from 'data';
import { FLOATING_BAR_CLEARANCE, RADIUS_CARD, RADIUS_CONTROL, RADIUS_LABEL, RADIUS_MODAL } from '../theme/Theme';
import { MOTION_ON_KEY, Motion, transitionOrIdentity } from '../theme/Motion';
import { showToast } from '../ui/Toast';
import type { ThemePalette } from '../theme/Theme';

/**
 * Bookmarks, highlights and notes for one book.
 *
 * The three tables are shown as one list because that is how a reader thinks about
 * them: three ways of marking the same page. Merging happens on a single normalised
 * item so there is one sort path and one row builder, rather than three near-copies
 * that drift apart.
 *
 * Sorting is by position in the book, reusing `compareCfiPosition`. That function
 * compares the decimal runs in the string, which works for this client's
 * `spine:{n}:{domPos}` locators exactly as it does for a CFI, so a mixed list —
 * some annotations made here, some synced from a ReadAny client — still comes out
 * in reading order.
 *
 * Creating annotations is not here: a highlight needs a selection from the reader,
 * and the reader's selection surface is Reader Kit's to provide.
 */
@Component
export struct AnnotationsPage {
  @Prop bookTitle: string;
  @Link bookmarks: Bookmark[];
  @Link highlights: Highlight[];
  @Link notes: Note[];
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
  /** Which annotation types to show. */
  @Link showBookmarks: boolean;
  @Link showHighlights: boolean;
  @Link showNotes: boolean;

  onReload: () => Promise<void> = async (): Promise<void> => {};
  onDeleteBookmark: (item: AnnotationItem) => Promise<void> = async (): Promise<void> => {};
  onDeleteHighlight: (item: AnnotationItem) => Promise<void> = async (): Promise<void> => {};
  onDeleteNote: (item: AnnotationItem) => Promise<void> = async (): Promise<void> => {};
  onEditNote: (item: AnnotationItem, title: string, content: string) => Promise<void> =
    async (): Promise<void> => {};
  onNavigate: (item: AnnotationItem) => void = (): void => {};

  @State private editing: AnnotationItem | undefined = undefined;
  /**
   * Sheet visibility.
   *
   * Bound separately from `editing` because `bindSheet` takes a boolean; binding it
   * to the item would make the sheet's presence depend on an object identity that
   * the framework cannot observe.
   */
  @State private editorOpen: boolean = false;
  @State private editTitle: string = '';
  @State private editContent: string = '';
  /**
   * The animation switch, mirrored from `AppStorage`.
   *
   * Declared so this component re-renders when the setting changes, which is what
   * re-evaluates the row transitions and the list's edge effect below.
   */
  @StorageLink(MOTION_ON_KEY) private animationOn: boolean = true;

  /**
   * Merge the three tables into one ordered list.
   *
   * Rebuilt on every render rather than cached: the inputs are three bound arrays
   * that change independently, and a cache would need invalidating from each of
   * them, which is more state to get wrong than a merge over a few dozen rows.
   */
  private merged(): AnnotationItem[] {
    const items: AnnotationItem[] = [];
    if (this.showBookmarks) {
      for (const bookmark of this.bookmarks) {
        items.push(bookmarkItem(bookmark));
      }
    }
    if (this.showHighlights) {
      for (const highlight of this.highlights) {
        items.push(highlightItem(highlight));
      }
    }
    if (this.showNotes) {
      for (const note of this.notes) {
        items.push(noteItem(note));
      }
    }
    items.sort(compareItems);
    return items;
  }

  private toast(message: string): void {
    showToast(this.getUIContext(), message);
  }

  private async confirmDelete(item: AnnotationItem): Promise<void> {
    if (item.kind === AnnotationKind.BOOKMARK) {
      await this.onDeleteBookmark(item);
    } else if (item.kind === AnnotationKind.HIGHLIGHT) {
      await this.onDeleteHighlight(item);
    } else {
      await this.onDeleteNote(item);
    }
    this.toast('已删除');
  }

  @Builder
  private filterChip(label: string, selected: boolean, onToggle: () => void) {
    Text(label)
      .fontSize(12)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      // A selectable pill is something you tap, which the corner-radius spec puts at
      // 20vp (`RADIUS_CONTROL`). It was a bare `14` — not one of the five spec values, and
      // the same stray value the book-selector chips in `Index.ets` carried. Both move to
      // 20 together so the two chip rows read as one control family (同层统一).
      .borderRadius(RADIUS_CONTROL)
      .backgroundColor(selected
        ? $r('sys.color.comp_background_emphasize')
        : this.palette.muted)
      .fontColor(selected ? Color.White : this.palette.mutedForeground)
      .onClick((): void => {
        onToggle();
      })
  }

  @Builder
  private itemRow(item: AnnotationItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.kindLabel)
          .fontSize(11)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          // A status label, which the spec puts at 4vp (`RADIUS_LABEL`). The value was
          // already 4; naming it records *why* it is 4 and not the card radius.
          .borderRadius(RADIUS_LABEL)
          .backgroundColor(this.palette.muted)
          .fontColor(this.palette.mutedForeground)
        if (item.color.length > 0) {
          // The colour swatch is the highlight colour, so a list of highlights is
          // scannable without reading each row.
          Circle({ width: 10, height: 10 })
            .fill(item.color)
        }
        Text(item.positionLabel)
          .fontSize(11)
          .fontColor(this.palette.mutedForeground)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatTime(item.createdAt))
          .fontSize(11)
          .fontColor(this.palette.mutedForeground)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (item.body.length > 0) {
        Text(item.body)
          .fontSize(14)
          .width('100%')
          .maxLines(item.kind === AnnotationKind.NOTE ? 6 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (item.quote.length > 0) {
        // Quoted source text, visually separated from the user's own words.
        Text(item.quote)
          .fontSize(12)
          .fontColor(this.palette.mutedForeground)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8 })
          .border({ width: { left: 2 }, color: $r('sys.color.comp_background_emphasize') })
      }

      Row({ space: 16 }) {
        if (item.canNavigate) {
          // The label says how far the jump can go, because the two locator forms do
          // not have the same precision and the difference is invisible afterwards:
          // this client's `spine:{n}:{domPos}` restores the exact page, a ReadAny CFI
          // resolves to its chapter and no further (`ReaderView.annotationStart`).
          // Calling both "跳转" would promise a page the CFI case cannot deliver.
          Text(item.chapterOnly ? '跳转（仅到该章节）' : '跳转')
            .fontSize(12)
            .fontColor($r('sys.color.comp_background_emphasize'))
            .onClick((): void => {
              this.onNavigate(item);
            })
        } else {
          // Said plainly rather than offering a tap that does nothing: a `page:{N}`
          // marker or an unrecognised value is not a position this reader can resolve,
          // which is a real limitation rather than a bug to hide.
          Text('位置来自其他客户端，暂不可跳转')
            .fontSize(11)
            .fontColor(this.palette.mutedForeground)
        }
        if (item.kind === AnnotationKind.NOTE) {
          Text('编辑')
            .fontSize(12)
            .fontColor($r('sys.color.comp_background_emphasize'))
            .onClick((): void => {
              this.beginEdit(item);
            })
        }
        Text('删除')
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .onClick((): void => {
            this.confirmDelete(item);
          })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    // An annotation card is a **content container**, so 16vp (`RADIUS_CARD`). It was a
    // bare `10`, which is not one of the five spec values at all.
    .borderRadius(RADIUS_CARD)
    // `card`, not `muted`. `muted` is *lighter* than the page on the light theme
    // (`#F3F3EF` against `#F0F0EC`) and on dark (`#2A2A2A` against `#121212`), so it reads
    // as a recess rather than a raised surface — the wrong elevation direction. `card` is
    // the raised colour, and the hairline border is what gives it an edge: the separation
    // is only 1.14:1 on light, 1.12:1 on dark and 1.05:1 on sepia, so on sepia the border
    // is doing all of the work.
    .backgroundColor(this.palette.card)
    .borderWidth(1)
    .borderColor(this.palette.border)
    .margin({ bottom: 10 })
  }

  private beginEdit(item: AnnotationItem): void {
    this.editing = item;
    this.editTitle = item.title;
    this.editContent = item.body;
    this.editorOpen = true;
  }

  @Builder
  private editorSheet() {
    Column({ space: 10 }) {
      Text('编辑笔记')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      TextInput({ text: this.editTitle, placeholder: '标题' })
        .width('100%')
        .onChange((value: string): void => {
          this.editTitle = value;
        })
      TextArea({ text: this.editContent, placeholder: '正文' })
        .width('100%')
        .height(140)
        .onChange((value: string): void => {
          this.editContent = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.palette.muted)
          .fontColor(this.palette.foreground)
          .onClick((): void => {
            this.editorOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .onClick((): void => {
            const item: AnnotationItem | undefined = this.editing;
            if (item === undefined) {
              return;
            }
            const title: string = this.editTitle;
            const content: string = this.editContent;
            this.editorOpen = false;
            this.onEditNote(item, title, content).then((): void => {
              this.toast('已保存');
            }).catch((err: Object): void => {
              this.toast('保存失败');
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.palette.background)
    // The note editor's own surface, with only its top corners rounded because it is a
    // bottom sheet. The spec puts a sheet at 32vp (`RADIUS_MODAL`) — it is the top layer,
    // which is what 层级正相关 means. It was a bare `16`, the *card* role, which would have
    // made the top layer the same radius as the cards underneath it.
    .borderRadius({ topLeft: RADIUS_MODAL, topRight: RADIUS_MODAL })
  }

  build() {
    Column() {
      // Filters
      Row({ space: 8 }) {
        this.filterChip(`书签 ${this.bookmarks.length}`, this.showBookmarks, (): void => {
          this.showBookmarks = !this.showBookmarks;
        })
        this.filterChip(`高亮 ${this.highlights.length}`, this.showHighlights, (): void => {
          this.showHighlights = !this.showHighlights;
        })
        this.filterChip(`笔记 ${this.notes.length}`, this.showNotes, (): void => {
          this.showNotes = !this.showNotes;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(32).height(32)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.merged().length === 0) {
        Column({ space: 8 }) {
          Text('还没有标注')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Text(this.bookTitle.length > 0
            ? `在阅读「${this.bookTitle}」时添加书签或高亮，会显示在这里。`
            : '打开一本书并添加书签或高亮，会显示在这里。')
            .fontSize(13)
            .fontColor(this.palette.mutedForeground)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(24)
      } else {
        List({ space: 0 }) {
          ForEach(this.merged(), (item: AnnotationItem, index: number) => {
            ListItem() {
              this.itemRow(item)
            }
            // A short list of cards that all arrive at once, so the standard stagger is
            // right here rather than the dense-grid variant the shelf uses.
            .transition(transitionOrIdentity(this.animationOn ? Motion.scaleIn(index) : null))
          }, (item: AnnotationItem) => `${item.kind}-${item.id}-${item.updatedAt}`)
        }
        .width('100%')
        .layoutWeight(1)
        // Clears the floating bottom tab bar, which overlaps the content. At 16 the
        // last annotation sat under the capsule and could not be tapped.
        //
        // **r109 reverted this from `FLOATING_BAR_CLEARANCE + bottomInsetVp` back to the bare
        // constant.** r107 added that inset on a premise this device contradicts: it held that
        // lifting the capsule lifted the gradient mask with it, so a bare 96 would leave the last row
        // inside the fade. Measured: the mask is the bottom 32 vp of the tab area
        // (`Stack [0,2740][1320,2848]`) — **below** the capsule, not above it — and it did not move
        // when `barBottomMargin` went 8 -> 36. The bar's painted extent is 92.1 vp, so 96 already
        // over-reserved by ~4 vp and 124 over-reserved by ~32. The only measured effect of the
        // 96 -> 124 change was to move the invisible line up 94.5 px and grow the pop band from
        // 324 px to 418.5 px, about 44% worse.
        //
        // This list also **never had the defect the inset was meant to prevent**. `List` and
        // `WaterFlow` default to `ContentClipMode.CONTENT_ONLY`, while `Grid` and `Scroll` default to
        // `BOUNDARY` (ts-container-scrollable-common: 「默认值：Grid、Scroll的默认值为
        // ContentClipMode.BOUNDARY，List、WaterFlow的默认值为ContentClipMode.CONTENT_ONLY」), and the
        // waterflow reference states the consequence verbatim: 「内容裁剪模式为ContentClipMode.
        // CONTENT_ONLY，padding区域会被裁剪不显示」. A `List`'s padding band is **clipped away**, so no
        // admission rule can make a row pop there — and there was never a slide-under look to protect
        // either. That is exactly why this row needs no inset while the shelf's `Grid` does.
        .padding({ left: 16, right: 16, bottom: FLOATING_BAR_CLEARANCE })
        .scrollBar(BarState.Auto)
        // Gated like every other scroll owner: off means the list stops at its last row
        // instead of stretching and springing back.
        .edgeEffect(Motion.edgeEffect())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.palette.background)
    .bindSheet($$this.editorOpen, this.editorSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
    })
  }
}

/** Which table an item came from. */
export enum AnnotationKind {
  BOOKMARK = 'bookmark',
  HIGHLIGHT = 'highlight',
  NOTE = 'note',
}

/**
 * One row of the merged list.
 *
 * Normalised at construction: the three tables have different fields, and doing
 * the mapping once here keeps the row builder and the sort from each having to know
 * about all three shapes.
 */
export interface AnnotationItem {
  kind: AnnotationKind;
  kindLabel: string;
  id: string;
  bookId: string;
  /** Raw stored position, for navigation and for reporting the locator kind. */
  locator: string;
  positionLabel: string;
  /** The user's own words: a bookmark label, a highlight's note, a note's body. */
  body: string;
  /** Quoted source text: a highlight's selected text, or a note's linked quote. */
  quote: string;
  title: string;
  color: string;
  chapterTitle: string;
  createdAt: number;
  updatedAt: number;
  /** True when this device can resolve the position. */
  canNavigate: boolean;
  /**
   * True when the jump can only reach the chapter the locator names.
   *
   * Set for an EPUB CFI, which is what a ReadAny client writes: its spine step gives
   * the chapter, and the part inside the chapter is not representable in Reader Kit's
   * opaque `domPos` at all. Recorded at construction so the row renders the honest
   * label without re-classifying the locator on every frame.
   */
  chapterOnly: boolean;
}

function bookmarkItem(bookmark: Bookmark): AnnotationItem {
  const item: AnnotationItem = {
    kind: AnnotationKind.BOOKMARK,
    kindLabel: '书签',
    id: bookmark.id,
    bookId: bookmark.bookId,
    locator: bookmark.cfi,
    positionLabel: describeLocator(bookmark.cfi, bookmark.chapterTitle),
    body: bookmark.label,
    quote: '',
    title: '',
    color: '',
    chapterTitle: bookmark.chapterTitle,
    createdAt: bookmark.createdAt,
    updatedAt: bookmark.updatedAt,
    canNavigate: canNavigateTo(bookmark.cfi),
    chapterOnly: isChapterOnly(bookmark.cfi),
  };
  return item;
}

function highlightItem(highlight: Highlight): AnnotationItem {
  const item: AnnotationItem = {
    kind: AnnotationKind.HIGHLIGHT,
    kindLabel: '高亮',
    id: highlight.id,
    bookId: highlight.bookId,
    locator: highlight.cfi,
    positionLabel: describeLocator(highlight.cfi, highlight.chapterTitle),
    body: highlight.note,
    quote: highlight.text,
    title: '',
    color: highlightColorHex(highlight.color),
    chapterTitle: highlight.chapterTitle,
    createdAt: highlight.createdAt,
    updatedAt: highlight.updatedAt,
    canNavigate: canNavigateTo(highlight.cfi),
    chapterOnly: isChapterOnly(highlight.cfi),
  };
  return item;
}

function noteItem(note: Note): AnnotationItem {
  const item: AnnotationItem = {
    kind: AnnotationKind.NOTE,
    kindLabel: '笔记',
    id: note.id,
    bookId: note.bookId,
    locator: note.cfi,
    positionLabel: describeLocator(note.cfi, note.chapterTitle),
    body: note.content,
    quote: '',
    title: note.title,
    color: '',
    chapterTitle: note.chapterTitle,
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
    canNavigate: canNavigateTo(note.cfi),
    chapterOnly: isChapterOnly(note.cfi),
  };
  return item;
}

/**
 * True when tapping a row can open the reader at this locator.
 *
 * **Both** locator forms are navigable, which is a change: this used to accept only
 * `spine:{n}:{domPos}` and told the user a synced bookmark "暂不可跳转", even though
 * its CFI names a spine item this reader can map through `getSpineList()`. What the CFI
 * case cannot give is the position *inside* the chapter — see
 * `ReaderView.annotationStart` — so `isChapterOnly` travels alongside this and the row
 * says which one it is.
 *
 * A `page:{N}` marker and an unrecognised value are still not navigable: neither names
 * anything this reader can locate, and offering the tap would just fail after it.
 */
function canNavigateTo(locator: string): boolean {
  const kind: LocatorKind = classifyLocator(locator);
  return kind === LocatorKind.SPINE || kind === LocatorKind.EPUB_CFI;
}

/**
 * True when the locator resolves to its chapter but not to the exact position, i.e. an
 * EPUB CFI. Kept as its own predicate so the two answers cannot drift apart: a locator
 * that is navigable is chapter-only exactly when it is a CFI.
 */
function isChapterOnly(locator: string): boolean {
  return classifyLocator(locator) === LocatorKind.EPUB_CFI;
}

/**
 * Reading order, with the kind as a tie-break.
 *
 * A bookmark and a highlight can sit at the same position; putting bookmarks first
 * keeps the list stable across reloads, which matters because the underlying query
 * has no defined order.
 */
export function compareItems(left: AnnotationItem, right: AnnotationItem): number {
  const byPosition: number = compareCfiPosition(left.locator, right.locator);
  if (byPosition !== 0) {
    return byPosition;
  }
  if (left.kind !== right.kind) {
    return left.kind < right.kind ? -1 : 1;
  }
  return left.createdAt - right.createdAt;
}

/** `MM-DD HH:mm`, or a coarse relative label for recent items. */
function formatTime(timestamp: number): string {
  if (timestamp <= 0) {
    return '';
  }
  const now: number = Date.now();
  const delta: number = now - timestamp;
  if (delta >= 0 && delta < 60 * 60 * 1000) {
    const minutes: number = Math.floor(delta / 60000);
    return minutes <= 0 ? '刚刚' : `${minutes} 分钟前`;
  }
  const date: Date = new Date(timestamp);
  const month: string = pad2(date.getMonth() + 1);
  const day: string = pad2(date.getDate());
  const hour: string = pad2(date.getHours());
  const minute: string = pad2(date.getMinutes());
  return `${month}-${day} ${hour}:${minute}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}
