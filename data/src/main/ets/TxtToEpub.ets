/**
 * TXT → EPUB 2.0 conversion.
 *
 * ## Where this comes from
 *
 * A port of ReadAny's `packages/core/src/utils/txt-to-epub.ts` (the desktop client this
 * app syncs with). Only `txt` and `umd` become EPUB there
 * (`packages/app/src/stores/library-store.ts:421`, `:444`); every other import format is
 * stored in its original form. `harmony/data/src/main/ets/BookImporter.ets` is the only
 * caller.
 *
 * ## What was ported, and what "porting" means here
 *
 * The **algorithm**, not the class structure:
 *
 *  1. **Encoding detection.** A strict-UTF-8 probe of the head 64 KiB and the middle
 *     8 KiB (`{ fatal: true }` — an invalid sequence throws) decides UTF-8 outright. If
 *     that fails, an 80 %-valid scan follows, then a BOM check, then a high-byte ratio,
 *     and finally a GBK-vs-Shift-JIS disambiguation that counts the double-byte lead
 *     ranges the two encodings cannot share. The order is load-bearing: GBK decodes
 *     almost any byte pair without error, so a GBK-first detector accepts UTF-8 input
 *     and emits mojibake.
 *  2. **Segmentation.** The file is cut into segments at runs of blank lines (the
 *     `linesBetweenSegments` threshold) or at a long dash rule *before* chapters are
 *     looked for. That is what bounds the working set on a large file and what stops a
 *     stray "Chapter 1" in a preface from renumbering the book.
 *  3. **Several chapter patterns tried in turn, chosen by a heuristic.** This is the part
 *     that makes the output good, and one regex cannot replace it: Chinese and English
 *     headings need different patterns, and inside each language a strict pattern is
 *     tried before a loose one. `isGoodMatches` is the judge — a split is accepted only
 *     when it produced more than one non-blank piece *and* no piece exceeds
 *     `MAX_CHAPTER_BODY_CHARS`. A pattern that matched nothing returns the whole segment
 *     as one piece, and a pattern that matched once returns two, so both are rejected and
 *     the next pattern is tried.
 *  4. **Language detection** by CJK-vs-Latin character ratio, which picks the pattern set.
 *
 * ## Deliberate deviations from ReadAny, each a correction
 *
 *  - **Every chapter pattern has exactly one capturing group, and it always
 *    participates.** `String.split` inserts each group's text into its result, and the
 *    odd/even walk that reads titles back out depends on that shape. ReadAny's English
 *    pattern has *no* group around the heading and one *inside* its number pattern, so
 *    its split yields `[prefix, number, text, number, text, …]` and English chapter
 *    titles come out as bare numbers. Here the heading is the single group and the number
 *    pattern is non-capturing, so English titles are the real headings.
 *    `captureGroupCount` checks the invariant at runtime and `tools/verify-txt-epub.mjs`
 *    asserts it for every pattern this module builds.
 *  - **Chapter headings are XML-escaped inside `<h1>`/`<h2>`.** ReadAny escapes the nav
 *    label but interpolates the raw heading into the XHTML body, so a title containing
 *    `&` or `<` yields a file that is not well-formed XML and a strict reader rejects the
 *    whole chapter. Escaping cannot change a title that had no such character.
 *  - **The `u` flag is dropped** from the patterns: no pattern uses an escape the flag
 *    governs, and every character class involved is BMP, where `u` changes nothing.
 *  - **`\p{P}` / `\p{S}` become the explicit predicates** `isPunctuationOrSymbol` /
 *    `isTitleBreakChar`. Coverage is ASCII punctuation, U+2000–U+206F, U+3000–U+303F and
 *    the fullwidth forms — every character that occurs in a Chinese or English title. A
 *    function rather than a regex so the cross-check can exercise it directly.
 *  - **The archive is written as chapters are produced** (`StoreOnlyZip`) rather than
 *    assembled in memory. ReadAny holds every chapter and then the whole zip; a 9.7 MB
 *    book would need both alive at once on a phone. The entry order therefore differs
 *    after `mimetype` (which must be first and stored): chapters precede `toc.ncx` and
 *    `content.opf`, which have to be written after the last chapter is known. Nothing in
 *    OCF or EPUB 2 constrains that order.
 *
 * ## Cost, stated plainly
 *
 * Peak text held is one segment: the chunk being decoded plus the decoded text since the
 * last segment boundary. A segment ends at `linesBetweenSegments` blank lines and a real
 * book has them often, but a file with no such run anywhere is a single segment and is
 * therefore held whole — the same property ReadAny has, from the same rule. Chapter
 * *bodies* are never accumulated; only titles and volume flags (both small) are kept,
 * because `toc.ncx` and `content.opf` must follow the chapters.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { StoreOnlyZipWriter } from './StoreOnlyZip';

/** hilog domain and tag for this module. */
const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatTxtEpub';

// ---------------------------------------------------------------------------
// Tuning constants, all taken from the reference
// ---------------------------------------------------------------------------

/** Characters of the head kept for author/language detection. */
const HEADER_TEXT_MAX_CHARS: number = 1024;
/** Bytes of the head used for encoding detection and for that header text. */
const ENCODING_HEAD_SAMPLE_BYTES: number = 64 * 1024;
/** Bytes taken from the middle of the file as a second UTF-8 probe. */
const ENCODING_MID_SAMPLE_BYTES: number = 8192;
/** Bytes read per streaming step. */
const READ_CHUNK_BYTES: number = 512 * 1024;
/** Blank-line runs at or above this cut a segment. */
const LINES_BETWEEN_SEGMENTS: number = 8;
/** Paragraphs per synthesised chapter when no heading pattern fits. */
const FALLBACK_PARAGRAPHS_PER_CHAPTER: number = 100;
/** Longest piece `isGoodMatches` will accept, in characters. */
const MAX_CHAPTER_BODY_CHARS: number = 100000;
/** Fraction of U+FFFD above which a candidate encoding is rejected. */
const MAX_REPLACEMENT_RATIO: number = 0.005;
/** Bytes of the head used to decide whether an encoding decodes cleanly. */
const ENCODING_PROBE_BYTES: number = 8192;

/** Default cover-less CSS, matching the reference's. */
const STYLE_CSS: string =
  "body { line-height: 1.6; font-size: 1em; font-family: 'Arial', sans-serif; "
  + 'text-align: justify; }\np { text-indent: 2em; margin: 0; }';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** One chapter of the produced book. */
interface Chapter {
  /** Escaped title: for `<title>` and the nav label. */
  title: string;
  /** Raw title, escaped again when written into the body heading. */
  rawTitle: string;
  /** Inner XHTML of `<body>`, already escaped. */
  content: string;
  isVolume: boolean;
}

/** What one segment yielded. */
export interface SegmentChapters {
  chapters: Chapter[];
  /**
   * True when these came from the paragraph-count fallback rather than a heading.
   *
   * Reported because the book still opens and reads correctly, but its table of
   * contents is `1..n` and says nothing about the text. That is a fact about the file,
   * not a failure, so it travels with the result instead of being thrown.
   */
  usedFallback: boolean;
}

/** What the converter needs to run. */
export interface TxtConvertOptions {
  /** Absolute path of the TXT to read. */
  sourcePath: string;
  /** Absolute path of the EPUB to write. */
  destPath: string;
  /** `dc:identifier`; the book id. */
  identifier: string;
  /** Author to use when the file's own header yields none. */
  author: string;
  /** Language to force, or an empty string to detect. */
  language: string;
}

/** What the caller gets back, and what the library row is built from. */
export interface TxtConvertResult {
  bookTitle: string;
  author: string;
  language: string;
  /** The encoding actually used, so a fallback can be surfaced to the user. */
  encoding: string;
  chapterCount: number;
  /** True when the table of contents is the paragraph-count fallback. */
  usedParagraphFallback: boolean;
}

/** The outcome of one segmentation pass. */
interface AttemptResult {
  chapterCount: number;
  usedParagraphFallback: boolean;
  /** Escaped titles, in order, for `toc.ncx`. */
  titles: string[];
  /** Volume flags, parallel to `titles`, for the `navPoint` nesting. */
  volumes: boolean[];
}

/** The two halves of a segment scan. */
export interface SegmentSplit {
  /** Segments whose closing boundary was seen. */
  segments: string[];
  /** The trailing text with no closing boundary yet. */
  pending: string;
}

// ---------------------------------------------------------------------------
// XML and language
// ---------------------------------------------------------------------------

/**
 * Escape the five XML predefined entities.
 *
 * Built with `split().join()` rather than `String.replace`: a replacement string
 * containing `$&` or `$'` is interpreted by `replace`, and escaping is the one place in
 * this module where the replacement is attacker-adjacent book text.
 */
export function escapeXml(text: string): string {
  if (text.length === 0) {
    return '';
  }
  return text
    .split('&').join('&amp;')
    .split('<').join('&lt;')
    .split('>').join('&gt;')
    .split('"').join('&quot;')
    .split("'").join('&apos;');
}

/**
 * `zh` when CJK characters dominate the sample, `en` otherwise.
 *
 * `cjk > latin * 0.5` rather than a plain majority: a Chinese book's head is often a
 * copyright page or a list of Latin names, and demanding a strict majority there
 * misclassifies the book as English and then selects the wrong chapter patterns.
 */
export function detectLanguage(text: string): string {
  const sample: string = text.length > 2000 ? text.substring(0, 2000) : text;
  let cjkCount: number = 0;
  let latinCount: number = 0;
  for (let i = 0; i < sample.length; i++) {
    const code: number = sample.charCodeAt(i);
    if ((code >= 0x4e00 && code <= 0x9fff)
      || (code >= 0x3400 && code <= 0x4dbf)
      || (code >= 0xf900 && code <= 0xfaff)) {
      cjkCount++;
    } else if ((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) {
      latinCount++;
    }
  }
  return cjkCount > latinCount * 0.5 ? 'zh' : 'en';
}

/**
 * Whitespace or punctuation: where a title token ends.
 *
 * Stands in for `[\s\p{P}]`; see the module comment for the coverage and the reason.
 */
export function isTitleBreakChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  if (code <= 0x20) {
    return true;                                   // C0 controls and space
  }
  if (code >= 0x21 && code <= 0x2f) {
    return true;                                   // ! " # $ % & ' ( ) * + , - . /
  }
  if (code >= 0x3a && code <= 0x40) {
    return true;                                   // : ; < = > ? @
  }
  if (code >= 0x5b && code <= 0x60) {
    return true;                                   // [ \ ] ^ _ `
  }
  if (code >= 0x7b && code <= 0x7e) {
    return true;                                   // { | } ~
  }
  if (code >= 0x2000 && code <= 0x206f) {
    return true;                                   // general punctuation
  }
  if (code >= 0x3000 && code <= 0x303f) {
    return true;                                   // CJK symbols and punctuation
  }
  if (code >= 0xff01 && code <= 0xff20) {
    return true;                                   // fullwidth forms
  }
  if (code >= 0xff3b && code <= 0xff40) {
    return true;
  }
  if (code >= 0xff5b && code <= 0xff65) {
    return true;
  }
  return false;
}

/** Punctuation or a symbol — stands in for `\p{P}\p{S}`, used to trim an author name. */
export function isPunctuationOrSymbol(ch: string): boolean {
  if (isTitleBreakChar(ch)) {
    return true;
  }
  const code: number = ch.charCodeAt(0);
  if (code >= 0x20a0 && code <= 0x20cf) {
    return true;                                   // currency symbols
  }
  if (code >= 0x2190 && code <= 0x21ff) {
    return true;                                   // arrows
  }
  if (code >= 0x2200 && code <= 0x22ff) {
    return true;                                   // mathematical operators
  }
  if (code >= 0x2600 && code <= 0x27bf) {
    return true;                                   // misc symbols and dingbats
  }
  return false;
}

/** Leading and trailing punctuation and symbols removed. */
export function trimPunctuation(text: string): string {
  let start: number = 0;
  let end: number = text.length;
  while (start < end && isPunctuationOrSymbol(text.charAt(start))) {
    start++;
  }
  while (end > start && isPunctuationOrSymbol(text.charAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/** The first run of non-break characters: the first token of a line. */
export function firstTitleToken(text: string): string {
  let end: number = 0;
  while (end < text.length && !isTitleBreakChar(text.charAt(end))) {
    end++;
  }
  return text.substring(0, end);
}

// ---------------------------------------------------------------------------
// Chapter patterns
// ---------------------------------------------------------------------------

/** Characters that make a `第…` heading a volume rather than a chapter. */
const VOLUME_MARKERS_ZH: RegExp = /第[零〇一二三四五六七八九十百千万0-9]+(卷|本|册|部)/;

/** Words that make an English heading a volume rather than a chapter. */
const VOLUME_MARKERS_EN: RegExp = /\b(Part|Volume|Book)\b/i;

/**
 * Number of capturing groups in a pattern's source.
 *
 * `String.split` inserts the text of every capturing group into its result, and the walk
 * that reads chapter titles back out assumes exactly one group per pattern — the
 * heading. The count is therefore checked rather than assumed: a pattern that breaks the
 * invariant is refused loudly instead of silently producing "titles" that are really body
 * text. `(?:`, `(?=`, `(?!` and the two lookbehind forms are correctly not counted, while
 * a **named** group `(?<name>…)` correctly is.
 */
export function captureGroupCount(patternSource: string): number {
  let count: number = 0;
  let i: number = 0;
  let inClass: boolean = false;
  while (i < patternSource.length) {
    const ch: string = patternSource.charAt(i);
    if (ch === '\\') {
      i += 2;
      continue;
    }
    if (inClass) {
      if (ch === ']') {
        inClass = false;
      }
      i++;
      continue;
    }
    if (ch === '[') {
      inClass = true;
      i++;
      continue;
    }
    if (ch === '(') {
      const next: string = i + 1 < patternSource.length ? patternSource.charAt(i + 1) : '';
      if (next !== '?') {
        count++;
      } else if (i + 2 < patternSource.length && patternSource.charAt(i + 2) === '<') {
        // `(?<name>…)` captures; `(?<=…)` and `(?<!…)` are lookbehinds and do not.
        const third: string = i + 3 < patternSource.length ? patternSource.charAt(i + 3) : '';
        if (third !== '=' && third !== '!') {
          count++;
        }
      }
    }
    i++;
  }
  return count;
}

/**
 * The patterns to try, in order, for a language.
 *
 * The first is strict and the second loose; `isGoodMatches` decides which one actually
 * fitted the text. The ordering *is* the mechanism — a loose pattern first would match
 * almost every short line and produce hundreds of one-line chapters.
 */
export function createChapterRegexps(language: string): RegExp[] {
  const chapterRegexps: RegExp[] = [];

  if (language === 'zh') {
    const strong: string = '(?:^|\\n)\\s*('
      + [
        '第[零〇一二三四五六七八九十0-9][零〇一二三四五六七八九十百千万0-9]*'
          + '(?:[章卷节回讲篇封本册部话])(?:[：:、 　()0-9]*[^\\n-]{0,24})(?!\\S)',
        '(?:楔子|前言|简介|引言|序言|序章|总论|概论|后记)(?:[：: 　][^\\n-]{0,24})?(?!\\S)',
        'chapter[\\s.]*[0-9]+(?:[：:. 　]+[^\\n-]{0,50})?(?!\\S)',
      ].join('|')
      + ')';
    chapterRegexps.push(new RegExp(strong, 'gi'));

    const loose: string = '(?:^|\\n)\\s*('
      + [
        '[一二三四五六七八九十][零〇一二三四五六七八九十百千万]?[：:、 　][^\\n-]{0,24}(?=\\n|$)',
        '[0-9]+[^\\n]{0,16}(?=\\n|$)',
      ].join('|')
      + ')';
    chapterRegexps.push(new RegExp(loose, 'g'));

    return chapterRegexps;
  }

  const chapterKeywords: string[] = ['Chapter', 'Part', 'Section', 'Book', 'Volume', 'Act'];
  const prefaceKeywords: string[] = [
    'Prologue', 'Epilogue', 'Introduction', 'Foreword', 'Preface', 'Afterword',
  ];

  // Non-capturing: a group here would be a second piece inserted into `split`'s result.
  const numberPattern: string = '(?:\\d+|(?:[IVXLCDM]{2,}|V|X|L|C|D|M)\\b)';
  const dotNumberPattern: string = '\\.\\d{1,4}';
  const titlePattern: string = '[^\\n]{0,50}';

  const normalChapterPattern: string = chapterKeywords
    .map((keyword: string): string =>
      `${keyword}\\s*(?:${numberPattern}|${dotNumberPattern})(?:[:.\\-–—]?\\s*${titlePattern})?`)
    .join('|');

  const prefacePattern: string = prefaceKeywords
    .map((keyword: string): string => `${keyword}(?:[:.\\-–—]?\\s*${titlePattern})?`)
    .join('|');

  // The single capturing group is the heading itself — the correction that makes English
  // titles real rather than numeric. See the module comment.
  const combined: string =
    `(?:^|\\n|\\s)((?:${normalChapterPattern}|${prefacePattern}))(?=\\s|$)`;
  chapterRegexps.push(new RegExp(combined, 'gi'));

  return chapterRegexps;
}

/** `(?:\r?\n){n,}` or a long dash rule: where one segment ends and the next begins. */
export function createSegmentRegex(linesBetweenSegments: number): RegExp {
  return new RegExp(`(?:\\r?\\n){${linesBetweenSegments},}|-{8,}\\r?\\n`);
}

/**
 * Is this split a usable set of chapter boundaries?
 *
 * More than one non-blank piece, and no piece longer than `maxLength`. The second test is
 * the important one: a pattern that matched nothing returns the whole segment as a single
 * piece and a pattern that matched once returns two, so requiring more than one rejects
 * both.
 */
export function isGoodMatches(parts: string[], maxLength: number): boolean {
  const meaningful: string[] = [];
  for (const part of parts) {
    if (part.trim().length > 0) {
      meaningful.push(part);
    }
  }
  if (meaningful.length <= 1) {
    return false;
  }
  for (const part of meaningful) {
    if (part.length > maxLength) {
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/** Decode with a fatal UTF-8 decoder; throws on the first invalid sequence. */
function decodeStrictUtf8(sample: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(sample);
}

/**
 * Is `sample` valid UTF-8?
 *
 * A sample cut out of the middle of a file can begin or end inside a multi-byte
 * character, which is a property of *where the sample came from*, not of the file. So up
 * to three bytes are trimmed from each end before the sample is called invalid.
 */
export function isStrictUtf8Sample(sample: Uint8Array): boolean {
  try {
    decodeStrictUtf8(sample);
    return true;
  } catch (err) {
    const maxOffset: number = Math.min(3, sample.length - 1);
    for (let startOffset: number = 0; startOffset <= maxOffset; startOffset++) {
      for (let endOffset: number = 0; endOffset <= maxOffset; endOffset++) {
        if (startOffset === 0 && endOffset === 0) {
          continue;
        }
        const end: number = sample.length - endOffset;
        if (end - startOffset < 16) {
          continue;
        }
        try {
          decodeStrictUtf8(sample.subarray(startOffset, end));
          return true;
        } catch (innerErr) {
          // Not an error: this is the retry loop, and a failure here means "that trim was
          // not the answer, try the next one" — it is expected for every offset except
          // the one that works, and for all of them when the sample really is not UTF-8.
          // Logged at debug rather than left silent because a silent catch once made a
          // real failure undiagnosable, and the number of attempts is the only evidence
          // of which case this was when a file is later reported as mis-decoded.
          hilog.debug(DOMAIN, TAG,
            'utf-8 probe rejected a trim (start=%{public}d end=%{public}d): %{public}s',
            startOffset, endOffset, String(innerErr));
        }
      }
    }
    return false;
  }
}

/**
 * The encoding of a file, from a head sample and an optional middle sample.
 *
 * The order is the reference's and is load-bearing: strict UTF-8 first, because every
 * other candidate decodes UTF-8 bytes without error and would otherwise win by default.
 */
export function detectEncoding(head: Uint8Array, mid: Uint8Array | undefined): string {
  const headIsUtf8: boolean = isStrictUtf8Sample(head);
  const midIsUtf8: boolean = mid === undefined || mid.length === 0
    ? true
    : isStrictUtf8Sample(mid);
  if (headIsUtf8 && midIsUtf8) {
    return 'utf-8';
  }

  // The strict probe failed. Measure how much of the head is even *valid* UTF-8: one
  // mis-encoded byte is common in an otherwise-UTF-8 file, and declaring the whole file
  // GBK for it would mangle every other character.
  let validBytes: number = 0;
  let checkedBytes: number = 0;
  const sampleSize: number = Math.min(head.length, 10000);
  const probe: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: true });
  for (let i = 0; i < sampleSize; i++) {
    try {
      probe.decodeToString(head.subarray(i, i + 100));
      validBytes += 100;
      checkedBytes += 100;
      i += 99;
    } catch (err) {
      checkedBytes++;
    }
  }
  const validPercentage: number = checkedBytes > 0 ? (validBytes / checkedBytes) * 100 : 0;
  if (validPercentage > 80) {
    return 'utf-8';
  }

  if (head.length >= 2 && head[0] === 0xff && head[1] === 0xfe) {
    return 'utf-16le';
  }
  if (head.length >= 2 && head[0] === 0xfe && head[1] === 0xff) {
    return 'utf-16be';
  }
  if (head.length >= 3 && head[0] === 0xef && head[1] === 0xbb && head[2] === 0xbf) {
    return 'utf-8';
  }

  const sample: Uint8Array = head.subarray(0, Math.min(4096, head.length));
  let highByteCount: number = 0;
  for (let i = 0; i < sample.length; i++) {
    if (sample[i] >= 0x80) {
      highByteCount++;
    }
  }
  const highByteRatio: number = sample.length > 0 ? highByteCount / sample.length : 0;
  if (highByteRatio > 0.3) {
    return 'gbk';
  }

  if (highByteRatio > 0.1) {
    // Disambiguate Shift-JIS from GBK/GB18030 by the lead ranges they cannot share.
    // GBK double-byte: lead 0xA1–0xFE, trail 0xA1–0xFE.
    // Shift-JIS-distinctive: lead 0x81–0x9F, below GBK's lead range.
    let gbkPairs: number = 0;
    let sjisDistinctPairs: number = 0;
    for (let i = 0; i < sample.length - 1; i++) {
      const b1: number = sample[i];
      const b2: number = sample[i + 1];
      if (b1 >= 0xa1 && b1 <= 0xfe && b2 >= 0xa1 && b2 <= 0xfe) {
        gbkPairs++;
        i++;
      } else if (b1 >= 0x81 && b1 <= 0x9f
        && ((b2 >= 0x40 && b2 <= 0x7e) || (b2 >= 0x80 && b2 <= 0xfc))) {
        sjisDistinctPairs++;
        i++;
      }
    }
    if (sjisDistinctPairs > 0 && sjisDistinctPairs > gbkPairs) {
      return 'shift-jis';
    }
    return 'gb18030';
  }

  return 'utf-8';
}

/** Can the platform build a decoder for this label? */
export function isEncodingSupported(encoding: string): boolean {
  try {
    util.TextDecoder.create(encoding);
    return true;
  } catch (err) {
    return false;
  }
}

/** How many U+FFFD the decode produced. */
export function replacementCharCount(text: string): number {
  let count: number = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 0xfffd) {
      count++;
    }
  }
  return count;
}

/**
 * The label to actually decode with, checked by decoding.
 *
 * `isEncodingSupported` asks whether a decoder can be *constructed*, which is not the
 * same question: a label the platform does not know may be accepted and silently treated
 * as UTF-8, which turns GBK bytes into a page of U+FFFD rather than failing. So each
 * candidate is tried on real bytes from this file and rejected if it produced replacement
 * characters, and the first clean candidate wins. Answering UTF-8 as the last resort is
 * deliberate — the caller surfaces `TxtConvertResult.encoding`, so a file no candidate
 * decodes cleanly is reported rather than converted into confident mojibake.
 */
export function pickEncoding(detected: string, probeBytes: Uint8Array): string {
  const normalized: string = detected.toLowerCase();
  const candidates: string[] = [];

  if (normalized === 'gbk') {
    candidates.push('gbk', 'gb18030', 'gb2312');
  } else if (normalized === 'gb18030') {
    candidates.push('gb18030', 'gbk', 'gb2312');
  } else if (normalized === 'shift-jis' || normalized === 'shift_jis') {
    candidates.push('shift_jis', 'shift-jis', 'sjis');
  } else if (normalized === 'utf-16') {
    candidates.push('utf-16le', 'utf-16be');
  } else if (normalized.length > 0) {
    candidates.push(normalized);
  }
  candidates.push('utf-8');

  const limit: number = Math.min(probeBytes.length, ENCODING_PROBE_BYTES);
  const probe: Uint8Array = probeBytes.subarray(0, limit);
  const allowed: number = Math.floor(limit * MAX_REPLACEMENT_RATIO);

  for (const candidate of candidates) {
    if (!isEncodingSupported(candidate)) {
      continue;
    }
    try {
      const text: string = util.TextDecoder.create(candidate, { fatal: false })
        .decodeToString(probe);
      if (replacementCharCount(text) <= allowed) {
        return candidate;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'encoding %{public}s failed to decode a sample: %{public}s',
        candidate, String(err));
    }
  }
  return 'utf-8';
}

// ---------------------------------------------------------------------------
// Text → chapters
// ---------------------------------------------------------------------------

/**
 * Escape a run of text and turn it into paragraphs.
 *
 * Escaping happens **before** the split because the `</p><p>` separators this produces
 * are markup; a `&` in the text must be escaped and a `&` introduced here must not be.
 */
export function formatSegment(segment: string): string {
  const escaped: string = escapeXml(segment);
  const flattened: string = escaped
    .split(/-{8,}/).join('\n')
    .split(/_{8,}/).join('\n');
  const lines: string[] = [];
  for (const line of flattened.split(/\n+/)) {
    const trimmed: string = line.trim();
    if (trimmed.length > 0) {
      lines.push(trimmed);
    }
  }
  return lines.join('</p><p>');
}

/**
 * Split one segment into chapters.
 *
 * `chapterOffset` is the number of chapters already emitted, so the paragraph-count
 * fallback keeps numbering across segments.
 */
export function extractChaptersFromSegment(
  segment: string,
  language: string,
  chapterOffset: number,
): SegmentChapters {
  const trimmedSegment: string = segment.split('<!--').join('').trim();
  const empty: Chapter[] = [];
  if (trimmedSegment.length === 0) {
    const nothing: SegmentChapters = { chapters: empty, usedFallback: false };
    return nothing;
  }

  const chapterRegexps: RegExp[] = createChapterRegexps(language);
  let parts: string[] = [];
  let matched: boolean = false;
  for (const chapterRegex of chapterRegexps) {
    const tryParts: string[] = trimmedSegment.split(chapterRegex);
    if (isGoodMatches(tryParts, MAX_CHAPTER_BODY_CHARS)) {
      parts = tryParts;
      matched = true;
      break;
    }
  }

  if (!matched) {
    const chapters: Chapter[] = [];
    const paragraphs: string[] = trimmedSegment.split(/\n+/);
    const total: number = paragraphs.length;
    for (let i = 0; i < total; i += FALLBACK_PARAGRAPHS_PER_CHAPTER) {
      const chunks: string[] = paragraphs.slice(i, i + FALLBACK_PARAGRAPHS_PER_CHAPTER);
      const title: string = `${chapterOffset + chapters.length + 1}`;
      const chapter: Chapter = {
        title: escapeXml(title),
        rawTitle: title,
        content: `<h2>${escapeXml(title)}</h2><p>${formatSegment(chunks.join('\n'))}</p>`,
        isVolume: false,
      };
      chapters.push(chapter);
    }
    const fellBack: SegmentChapters = { chapters: chapters, usedFallback: chapters.length > 0 };
    return fellBack;
  }

  const chapters: Chapter[] = [];
  // `parts` is [prefix, title, text, title, text, …]. Exactly one capturing group per
  // pattern is what makes that shape hold; see `captureGroupCount`.
  for (let j = 1; j + 1 < parts.length; j += 2) {
    const rawTitle: string = parts[j].trim();
    const body: string = parts[j + 1].trim();
    if (rawTitle.length === 0 && body.length === 0) {
      continue;
    }

    let isVolume: boolean = false;
    if (language === 'zh') {
      isVolume = VOLUME_MARKERS_ZH.test(rawTitle);
    } else {
      isVolume = VOLUME_MARKERS_EN.test(rawTitle);
    }

    const headingTag: string = isVolume ? 'h1' : 'h2';
    const chapter: Chapter = {
      title: escapeXml(rawTitle),
      rawTitle: rawTitle,
      content: `<${headingTag}>${escapeXml(rawTitle)}</${headingTag}>`
        + `<p>${formatSegment(body)}</p>`,
      isVolume: isVolume,
    };
    chapters.push(chapter);
  }

  const prefix: string = parts.length > 0 ? parts[0].trim() : '';
  if (prefix.length > 0) {
    const firstLine: string = prefix.split('\n')[0].trim();
    const token: string = firstTitleToken(prefix);
    const segmentTitle: string = (firstLine.length > 16 ? token : firstLine)
      || prefix.substring(0, 16);
    const lead: Chapter = {
      title: escapeXml(segmentTitle),
      rawTitle: segmentTitle,
      content: `<h3></h3><p>${formatSegment(prefix)}</p>`,
      isVolume: false,
    };
    chapters.unshift(lead);
  }

  const result: SegmentChapters = { chapters: chapters, usedFallback: false };
  return result;
}

/**
 * Chapters in one segment, without building their content.
 *
 * For the retry probe: the answer is a count, and running the full extraction for it
 * would allocate every chapter's XHTML for a decision that then discards it.
 */
export function probeChapterCountFromSegment(segment: string, language: string): number {
  const trimmedSegment: string = segment.split('<!--').join('').trim();
  if (trimmedSegment.length === 0) {
    return 0;
  }

  const chapterRegexps: RegExp[] = createChapterRegexps(language);
  let parts: string[] = [];
  for (const chapterRegex of chapterRegexps) {
    const tryParts: string[] = trimmedSegment.split(chapterRegex);
    if (isGoodMatches(tryParts, MAX_CHAPTER_BODY_CHARS)) {
      parts = tryParts;
      break;
    }
  }

  if (parts.length === 0) {
    const paragraphs: number = trimmedSegment.split(/\n+/).length;
    return Math.ceil(paragraphs / FALLBACK_PARAGRAPHS_PER_CHAPTER);
  }

  let count: number = Math.floor(parts.length / 2);
  if (parts[0].trim().length > 0) {
    count++;
  }
  return count;
}

/** Book title from a file name: the `《…》` form when present, else the stem. */
export function extractBookTitle(filename: string): string {
  const match = filename.match(/《([^》]+)》/);
  if (match !== null && match.length > 1) {
    return match[1];
  }
  const parts: string[] = filename.split('.');
  return parts.length > 0 && parts[0].length > 0 ? parts[0] : filename;
}

/** Last path segment of a path or URI, without its extension. */
export function baseFilename(path: string): string {
  const normalized: string = path.split('\\').join('/');
  const segments: string[] = normalized.split('/');
  const name: string = segments.length > 0 ? segments[segments.length - 1] : normalized;
  const withoutExtension: string = name.replace(/\.\w+$/, '');
  return withoutExtension.length > 0 ? withoutExtension : name;
}

/** Author from the head of the file, or the supplied fallback. */
export function extractAuthor(fileHeader: string, providedAuthor: string): string {
  const match = fileHeader.match(/[【[]?作者[】\]]?[:：\s]\s*(.+)\r?\n/)
    ?? fileHeader.match(/[【[]?\s*(.+)\s+著\s*[】\]]?\r?\n/);
  let matched: string = '';
  if (match !== null && match !== undefined && match.length > 1) {
    matched = match[1].trim();
  }
  if (matched.length === 0) {
    return providedAuthor;
  }
  const trimmed: string = trimPunctuation(matched);
  return trimmed.length > 0 ? trimmed : providedAuthor;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/** Read up to `want` bytes at absolute offset `at`. */
async function readChunk(fd: number, at: number, want: number): Promise<Uint8Array> {
  const buffer: ArrayBuffer = new ArrayBuffer(want);
  // `lseek` rather than `ReadOptions.offset`: the declaration says "current filePointer
  // plus offset" (`@ohos.file.fs.d.ts:5691`), which is not the absolute pread semantics
  // the rest of this codebase assumes from it. Seeking explicitly cannot be misread.
  fileIo.lseek(fd, at, fileIo.WhenceType.SEEK_SET);
  const read: number = await fileIo.read(fd, buffer, { length: want });
  const bytes: Uint8Array = new Uint8Array(buffer);
  return read === want ? bytes : bytes.slice(0, read);
}

/**
 * Split `pending` at every segment boundary that has definitely been seen.
 *
 * The trailing text is returned separately rather than as a last array element: a
 * boundary needs `linesBetweenSegments` consecutive newlines, and the chunk boundary can
 * fall in the middle of that run, so the tail may still grow into one.
 */
export function splitCompleteSegments(pending: string, segmentRegex: RegExp): SegmentSplit {
  const segments: string[] = [];
  let rest: string = pending;
  let match: RegExpExecArray | null = segmentRegex.exec(rest);
  while (match !== null) {
    segments.push(rest.substring(0, match.index));
    rest = rest.substring(match.index + match[0].length);
    match = segmentRegex.exec(rest);
  }
  const split: SegmentSplit = { segments: segments, pending: rest };
  return split;
}

// ---------------------------------------------------------------------------
// EPUB assembly
// ---------------------------------------------------------------------------

function containerXml(): string {
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">\n'
    + '  <rootfiles>\n'
    + '    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>\n'
    + '  </rootfiles>\n'
    + '</container>';
}

function chapterXhtml(title: string, content: string, language: string): string {
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
    + '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
    + `<html xmlns="http://www.w3.org/1999/xhtml" lang="${language}" xml:lang="${language}">\n`
    + '  <head>\n'
    + `    <title>${title}</title>\n`
    + '    <link rel="stylesheet" type="text/css" href="../style.css"/>\n'
    + '  </head>\n'
    + `  <body>${content}</body>\n`
    + '</html>';
}

function tocNcx(bookTitle: string, author: string, titles: string[], volumes: boolean[]): string {
  let isNested: boolean = false;
  let navPoints: string = '';
  for (let i = 0; i < titles.length; i++) {
    const id: string = `chapter${i + 1}`;
    const playOrder: number = i + 1;
    const isVolume: boolean = volumes[i];
    if (isVolume && isNested) {
      navPoints += '</navPoint>\n';
      isNested = false;
    }
    navPoints += `<navPoint id="navPoint-${id}" playOrder="${playOrder}">\n`
      + `<navLabel><text>${titles[i]}</text></navLabel>\n`
      + `<content src="./OEBPS/${id}.xhtml" />\n`;
    if (isVolume && !isNested) {
      isNested = true;
    } else {
      navPoints += '</navPoint>\n';
    }
  }
  if (isNested) {
    navPoints += '</navPoint>';
  }

  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
    + '  <head>\n'
    + '    <meta name="dtb:uid" content="book-id" />\n'
    + '    <meta name="dtb:depth" content="1" />\n'
    + '    <meta name="dtb:totalPageCount" content="0" />\n'
    + '    <meta name="dtb:maxPageNumber" content="0" />\n'
    + '  </head>\n'
    + `  <docTitle><text>${escapeXml(bookTitle)}</text></docTitle>\n`
    + `  <docAuthor><text>${escapeXml(author)}</text></docAuthor>\n`
    + '  <navMap>\n'
    + `    ${navPoints}\n`
    + '  </navMap>\n'
    + '</ncx>';
}

function contentOpf(
  bookTitle: string,
  author: string,
  language: string,
  identifier: string,
  chapterCount: number,
): string {
  const manifestItems: string[] = [];
  const spineItems: string[] = [];
  for (let i = 1; i <= chapterCount; i++) {
    manifestItems.push(`<item id="chap${i}" href="OEBPS/chapter${i}.xhtml" `
      + 'media-type="application/xhtml+xml"/>');
    spineItems.push(`<itemref idref="chap${i}"/>`);
  }
  const manifest: string = manifestItems.join('\n      ');
  const spine: string = spineItems.join('\n      ');

  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="2.0">\n'
    + '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    + `    <dc:title>${escapeXml(bookTitle)}</dc:title>\n`
    + `    <dc:language>${language}</dc:language>\n`
    + `    <dc:creator>${escapeXml(author)}</dc:creator>\n`
    + `    <dc:identifier id="book-id">${escapeXml(identifier)}</dc:identifier>\n`
    + '  </metadata>\n'
    + '  <manifest>\n'
    + `      ${manifest}\n`
    + '      <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
    + '      <item id="css" href="style.css" media-type="text/css"/>\n'
    + '  </manifest>\n'
    + '  <spine toc="ncx">\n'
    + `      ${spine}\n`
    + '  </spine>\n'
    + '</package>';
}

// ---------------------------------------------------------------------------
// The converter
// ---------------------------------------------------------------------------

/**
 * Convert one TXT file into `options.destPath`.
 *
 * When this resolves, the archive is complete. When it throws, no usable EPUB is left
 * behind: a `StoreOnlyZipWriter` that was never closed has no end-of-central-directory
 * record, and a file without one is not a ZIP, so a half-written book can never be
 * mistaken for a whole one. The caller still removes the file.
 */
export class TxtToEpubConverter {
  /** Metadata carried into `toc.ncx` and `content.opf` at the end of an attempt. */
  private title: string = '';
  private author: string = '';
  private language: string = 'en';
  private identifier: string = '';

  async convert(options: TxtConvertOptions): Promise<TxtConvertResult> {
    const stat: fileIo.Stat = await fileIo.stat(options.sourcePath);
    const size: number = stat.size;
    if (size === 0) {
      throw new Error('TXT 文件为空，没有可转换的内容');
    }

    const file: fileIo.File = await fileIo.open(options.sourcePath, fileIo.OpenMode.READ_ONLY);
    const fd: number = file.fd;
    const writer: StoreOnlyZipWriter = new StoreOnlyZipWriter(options.destPath);
    let writerOpen: boolean = false;

    try {
      const head: Uint8Array =
        await readChunk(fd, 0, Math.min(size, ENCODING_HEAD_SAMPLE_BYTES));
      let mid: Uint8Array | undefined = undefined;
      if (size > ENCODING_HEAD_SAMPLE_BYTES * 2) {
        const midSize: number =
          Math.min(ENCODING_MID_SAMPLE_BYTES, size - ENCODING_HEAD_SAMPLE_BYTES);
        const midStart: number = Math.floor((size - midSize) / 2);
        mid = await readChunk(fd, midStart, midSize);
      }

      const detected: string = detectEncoding(head, mid);
      const encoding: string = pickEncoding(detected, head);
      if (encoding !== detected) {
        hilog.warn(DOMAIN, TAG,
          'encoding %{public}s unavailable or decodes uncleanly; using %{public}s',
          detected, encoding);
      }

      this.identifier = options.identifier;
      this.title = extractBookTitle(baseFilename(options.sourcePath));
      const headerText: string = this.decodeHead(head, encoding);
      this.author = extractAuthor(headerText, options.author);
      this.language = options.language.length > 0
        ? options.language
        : detectLanguage(headerText);

      this.assertPatternsAreWalkable();

      await writer.open();
      writerOpen = true;

      let attempt: AttemptResult = await this.runAttempt(
        writer, fd, size, encoding, LINES_BETWEEN_SEGMENTS);
      if (attempt.chapterCount <= 1) {
        // One chapter means the segmentation found no headings. The reference probes a
        // looser blank-line threshold to learn which way to go, then re-runs; the retry
        // truncates the archive rather than appending to it.
        const probe: number = await this.probeAttempt(
          fd, size, encoding, this.language, LINES_BETWEEN_SEGMENTS - 1);
        const retryLines: number = probe > 1
          ? LINES_BETWEEN_SEGMENTS - 1
          : LINES_BETWEEN_SEGMENTS - 2;
        hilog.info(DOMAIN, TAG,
          'only %{public}d chapter(s) at %{public}d blank lines; retrying at %{public}d',
          attempt.chapterCount, LINES_BETWEEN_SEGMENTS, retryLines);
        attempt = await this.runAttempt(writer, fd, size, encoding, retryLines);
      }

      if (attempt.chapterCount === 0) {
        throw new Error('TXT 中未识别到任何章节');
      }

      await writer.close();
      writerOpen = false;

      const result: TxtConvertResult = {
        bookTitle: this.title,
        author: this.author,
        language: this.language,
        encoding: encoding,
        chapterCount: attempt.chapterCount,
        usedParagraphFallback: attempt.usedParagraphFallback,
      };
      return result;
    } catch (err) {
      if (writerOpen) {
        await writer.abort();
      }
      // Re-thrown as a typed `Error` rather than as the caught value: ArkTS refuses
      // `throw err` from a catch clause (`arkts-limited-throw`, docs/arkts-constraints.md
      // §2.2). An error that already is one is forwarded unchanged so its `kind` and
      // message survive for the caller's message.
      const wrapped: Error = err instanceof Error ? err : new Error(String(err));
      throw wrapped;
    } finally {
      try {
        await fileIo.close(file);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'closing %{public}s failed: %{public}s',
          options.sourcePath, String(err));
      }
    }
  }

  /**
   * Refuse to proceed if any chapter pattern does not have exactly one capturing group.
   *
   * The split-walk that reads titles depends on it, and a pattern edited later that
   * acquires a second group would otherwise silently shift every title by one position.
   * Checked once per conversion, against the patterns for the language actually in use.
   */
  private assertPatternsAreWalkable(): void {
    const regexps: RegExp[] = createChapterRegexps(this.language);
    for (const regexp of regexps) {
      const groups: number = captureGroupCount(regexp.source);
      if (groups !== 1) {
        throw new Error(
          `章节正则必须恰好有一个捕获组，实际为 ${groups}：${regexp.source}`);
      }
    }
  }

  /** Decode the head sample for author and language detection. */
  private decodeHead(head: Uint8Array, encoding: string): string {
    try {
      const text: string = util.TextDecoder.create(encoding, { fatal: false })
        .decodeToString(head);
      return text.length > HEADER_TEXT_MAX_CHARS
        ? text.substring(0, HEADER_TEXT_MAX_CHARS).trim()
        : text.trim();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'head sample could not be decoded as %{public}s: %{public}s',
        encoding, String(err));
      return '';
    }
  }

  /**
   * One full segmentation attempt.
   *
   * Restarts the archive (`open()` truncates, so a retry replaces the previous attempt
   * rather than appending to it), writes the three fixed entries, streams the file, and
   * writes each chapter as it is produced.
   */
  private async runAttempt(
    writer: StoreOnlyZipWriter,
    fd: number,
    size: number,
    encoding: string,
    linesBetweenSegments: number,
  ): Promise<AttemptResult> {
    await writer.abort();
    await writer.open();

    await writer.addEntry('mimetype', utf8Bytes('application/epub+zip'));
    await writer.addEntry('META-INF/container.xml', utf8Bytes(containerXml()));
    await writer.addEntry('style.css', utf8Bytes(STYLE_CSS));

    const titles: string[] = [];
    const volumes: boolean[] = [];
    let usedParagraphFallback: boolean = false;
    const language: string = this.language;

    await this.streamSegments(fd, size, encoding, linesBetweenSegments,
      async (segment: string): Promise<void> => {
        const extracted: SegmentChapters =
          extractChaptersFromSegment(segment, language, titles.length);
        if (extracted.usedFallback) {
          usedParagraphFallback = true;
        }
        for (const chapter of extracted.chapters) {
          titles.push(chapter.title);
          volumes.push(chapter.isVolume);
          const name: string = `OEBPS/chapter${titles.length}.xhtml`;
          await writer.addEntry(
            name,
            utf8Bytes(chapterXhtml(chapter.title, chapter.content, language)),
          );
        }
      });

    if (titles.length > 0) {
      // Written last because both need the chapter count and every title. Nothing in
      // EPUB 2 requires them earlier; only `mimetype` is position-constrained.
      await writer.addEntry('toc.ncx', utf8Bytes(
        tocNcx(this.title, this.author, titles, volumes)));
      await writer.addEntry('content.opf', utf8Bytes(
        contentOpf(this.title, this.author, language, this.identifier, titles.length)));
    }

    const result: AttemptResult = {
      chapterCount: titles.length,
      usedParagraphFallback: usedParagraphFallback,
      titles: titles,
      volumes: volumes,
    };
    return result;
  }

  /** Count chapters without writing anything, for the retry decision. */
  private async probeAttempt(
    fd: number,
    size: number,
    encoding: string,
    language: string,
    linesBetweenSegments: number,
  ): Promise<number> {
    let count: number = 0;
    await this.streamSegments(fd, size, encoding, linesBetweenSegments,
      async (segment: string): Promise<void> => {
        count += probeChapterCountFromSegment(segment, language);
      });
    return count;
  }

  /**
   * Decode the file in chunks and hand each **segment** to `onSegment`.
   *
   * `decodeToString(chunk, { stream: true })` is the streaming form: the declaration is
   * explicit that an incomplete byte sequence at the end of a chunk is held in an
   * internal buffer for the next call (`@ohos.util.d.ts:255-268`). A plain
   * `decodeToString` per chunk would emit U+FFFD at the boundary instead — on a GBK file
   * read in 512 KiB steps that is roughly one character per step, and every one of them
   * lands inside a chapter.
   */
  private async streamSegments(
    fd: number,
    size: number,
    encoding: string,
    linesBetweenSegments: number,
    onSegment: (segment: string) => Promise<void>,
  ): Promise<void> {
    const segmentRegex: RegExp = createSegmentRegex(linesBetweenSegments);
    const decoder: util.TextDecoder = util.TextDecoder.create(encoding, { fatal: false });
    let pending: string = '';
    let at: number = 0;

    while (at < size) {
      const want: number = Math.min(READ_CHUNK_BYTES, size - at);
      const chunk: Uint8Array = await readChunk(fd, at, want);
      if (chunk.length === 0) {
        break;
      }
      at += chunk.length;
      pending += decoder.decodeToString(chunk, { stream: true });
      const split: SegmentSplit = splitCompleteSegments(pending, segmentRegex);
      pending = split.pending;
      for (const piece of split.segments) {
        await onSegment(piece);
      }
    }

    pending += this.flushDecoder(decoder);
    const tail: SegmentSplit = splitCompleteSegments(pending, segmentRegex);
    for (const piece of tail.segments) {
      await onSegment(piece);
    }
    if (tail.pending.length > 0) {
      await onSegment(tail.pending);
    }
  }

  /**
   * Emit whatever the streaming decoder is still holding.
   *
   * A decoder left in streaming mode keeps a trailing incomplete sequence back. Discarding
   * it would silently drop the last character of the book when the encoding is GBK and the
   * file ends mid-character — rare, and invisible when it happens, which is why this has
   * its own step rather than being folded into the loop.
   */
  private flushDecoder(decoder: util.TextDecoder): string {
    try {
      return decoder.decodeToString(new Uint8Array(0), { stream: false });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'flushing the text decoder failed: %{public}s', String(err));
      return '';
    }
  }
}

/** UTF-8 bytes of a string. */
function utf8Bytes(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}
