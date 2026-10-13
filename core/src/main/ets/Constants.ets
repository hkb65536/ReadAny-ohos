/**
 * Project-wide constants. Keep values here in sync with the ReadAny clients —
 * the sync protocol depends on the on-disk / on-server contract, not on this app.
 */

export const APP_NAME: string = 'ReadAny';
export const APP_VERSION: string = '0.1.0';
export const BUNDLE_NAME: string = 'com.readany.reader';

/** Local database file name inside the app sandbox. */
export const DB_FILE_NAME: string = 'inkboat.db';

/** Directory (inside the app sandbox) that holds imported book files. */
export const BOOKS_DIR: string = 'books';
/** Directory that holds cover images. */
export const COVERS_DIR: string = 'covers';
/** Directory used for temporary transfer buffers. */
export const TMP_DIR: string = 'tmp';
