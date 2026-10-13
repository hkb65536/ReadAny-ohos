/**
 * Persistence for the user's appearance choice.
 *
 * Deliberately separate from the sync configuration store: this is a display
 * preference, it has nothing to do with the server, and mixing the two would mean a
 * user who never configures sync could not have their theme remembered.
 *
 * Uses `preferences` rather than the asset store — a theme name is not a secret, and
 * the asset store's whole value is that it protects secrets.
 *
 * ## Two preferences, one store
 *
 * Phase 2 added the animation speed here rather than in a second store. Both are the
 * same kind of thing — how the app should look — and one `preferences` file means one
 * place to look when a display preference will not stick. The animation keys are read
 * and written by separate functions, so a caller that only cares about the theme never
 * touches the animation value and vice versa.
 */

import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { ThemeMode } from './Theme';
import { asThemeMode } from './Theme';
import { asAnimationSpeedIndex, DEFAULT_ANIMATION_SPEED_INDEX } from './Motion';

const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatAppearance';

const STORE_NAME: string = 'inkboat_appearance';
const KEY_THEME: string = 'theme_mode';
/**
 * The animation speed, stored as the *index* of the picker row.
 *
 * The index rather than the duration, matching ClashBox's `animationSpeedIndex`: a
 * duration alone cannot express 「关闭」, because 0 ms is not the same thing as no
 * animation at all (see `Motion.ets` — the off setting makes every effect `null`, not
 * zero-length). Storing the row the user selected keeps the switch and the speed in one
 * value, so they cannot be stored inconsistently.
 */
const KEY_ANIMATION_SPEED_INDEX: string = 'animation_speed_index';


/**
 * Read the saved theme.
 *
 * Any failure yields `dark`: a missing or unreadable preference is not worth an error
 * path, and the fallback has to be *some* theme. Logged rather than swallowed, because
 * "my theme keeps resetting" is a real complaint that this line explains.
 */
export async function loadThemeMode(context: common.UIAbilityContext): Promise<ThemeMode> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const raw: preferences.ValueType = await store.get(KEY_THEME, 'dark');
    return asThemeMode(typeof raw === 'string' ? raw : 'dark');
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'theme preference unreadable, using dark: %{public}s', String(err));
    return 'dark';
  }
}

/**
 * Save the theme.
 *
 * `put` only mutates the in-memory cache, so `flush` is what makes it survive a
 * restart. A failure is logged and otherwise ignored: the theme has already been
 * applied on screen, and refusing to change it because it could not be persisted would
 * punish the user for a storage problem.
 */
export async function saveThemeMode(
  context: common.UIAbilityContext,
  mode: ThemeMode,
): Promise<void> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    await store.put(KEY_THEME, mode);
    await store.flush();
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'theme preference not saved: %{public}s', String(err));
  }
}

/**
 * Read the saved animation speed, as a picker index.
 *
 * Falls back to `DEFAULT_ANIMATION_SPEED_INDEX` (标准, 300 ms) on any failure, including
 * a value that is not there at all. That is the same value a fresh install gets, and it
 * is the value that keeps animation **on** — a user who never opens this setting sees no
 * change at all, which is the whole point of the default.
 *
 * A stored value out of range is narrowed by `asAnimationSpeedIndex`, so a preference
 * written by an older build with fewer rows cannot select a row that does not exist.
 */
export async function loadAnimationSpeedIndex(context: common.UIAbilityContext): Promise<number> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const raw: preferences.ValueType = await store.get(KEY_ANIMATION_SPEED_INDEX, DEFAULT_ANIMATION_SPEED_INDEX);
    return asAnimationSpeedIndex(typeof raw === 'number' ? raw : DEFAULT_ANIMATION_SPEED_INDEX);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'animation preference unreadable, using normal: %{public}s', String(err));
    return DEFAULT_ANIMATION_SPEED_INDEX;
  }
}

/**
 * Save the animation speed index.
 *
 * Same shape as `saveThemeMode`, and for the same reasons: `flush` is what makes it
 * survive a restart, and a failure is logged rather than surfaced — the setting has
 * already taken effect on screen, so refusing the change would punish the user for a
 * storage problem.
 */
export async function saveAnimationSpeedIndex(
  context: common.UIAbilityContext,
  index: number,
): Promise<void> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    await store.put(KEY_ANIMATION_SPEED_INDEX, asAnimationSpeedIndex(index));
    await store.flush();
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'animation preference not saved: %{public}s', String(err));
  }
}
