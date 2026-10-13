/**
 * InkBoat core — platform-independent types, pure logic and utilities.
 *
 * This barrel is intentionally free of any HarmonyOS / ArkUI imports so the
 * logic here can be unit-tested on its own and shared with other clients.
 */

export {
  APP_NAME,
  APP_VERSION,
  BOOKS_DIR,
  BUNDLE_NAME,
  COVERS_DIR,
  DB_FILE_NAME,
  TMP_DIR,
} from './src/main/ets/Constants';
export { InkBoatError, kindFromStatus, SyncErrorKind } from './src/main/ets/errors/InkBoatError';
export { generateId, isUuidV4, isStrictUuidV4, setUuidGenerator } from './src/main/ets/utils/Id';
export type { UuidGenerator } from './src/main/ets/utils/Id';
export {
  ANNOTATION_STABLE_ORDER,
  compareAnnotationPosition,
  compareCfiPosition,
  HIGHLIGHT_COLOR_HEX,
  HIGHLIGHT_COLORS,
  highlightColorHex,
  parsePageCfi,
  sortAnnotationsByPosition,
} from './src/main/ets/reader/AnnotationOrder';
export type { HighlightColor, PositionedAnnotation } from './src/main/ets/reader/AnnotationOrder';
export {
  CFI_ORDINAL_UNKNOWN,
  spineCfiFor,
  spineOrdinalFromCfi,
} from './src/main/ets/reader/EbookCfi';
export {
  classifyLocator,
  decodeSpineLocator,
  describeLocator,
  encodeSpineLocator,
  isEpubCfi,
  isPageMarker,
  isSpineLocator,
  LocatorKind,
  SPINE_LOCATOR_PREFIX,
} from './src/main/ets/reader/Locator';
export type { SpineLocator } from './src/main/ets/reader/Locator';
export {
  FieldReader,
  JsonRecordReader,
  jsonReader,
  RecordReader,
} from './src/main/ets/record/FieldReader';
export type { HighlightColorHex } from './src/main/ets/reader/AnnotationOrder';
