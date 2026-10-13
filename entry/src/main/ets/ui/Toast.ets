/**
 * Toast helper.
 *
 * Exists because the obvious call is the wrong one. The module-level
 * `promptAction.showToast` is **`@deprecated since 18`**, with
 * `@useinstead ohos.arkui.UIContext.PromptAction#showToast`. This app installs from
 * API 24, so every toast was going through a deprecated path.
 *
 * The failure mode was worse than a broken toast: all three call sites wrapped the
 * call in `try { … } catch { /* ignored *\/ }`, so if the deprecated entry point did
 * nothing on a newer runtime, the user got **no feedback at all** and every action
 * still looked like it had succeeded. A swallowed error is indistinguishable from
 * success unless something else reports it.
 *
 * The supported path needs a `UIContext`, which a page obtains with
 * `this.getUIContext()`. Threading it in explicitly is the price of correctness, and
 * it is what makes the deprecation impossible to reintroduce by accident: there is no
 * argument-free overload to fall back to.
 */

import { UIContext } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoatToast';

/** Default toast duration in ms. */
export const TOAST_DURATION_MS: number = 2500;

/**
 * Show a toast.
 *
 * A failure is logged rather than thrown: a toast is a courtesy, and no caller should
 * fail its own operation because a notification could not be displayed. Logging
 * matters here — the previous `catch {}` made this class of failure invisible, which
 * is exactly how the deprecation went unnoticed.
 */
export function showToast(context: UIContext, message: string): void {
  if (message.length === 0) {
    return;
  }
  try {
    const options: promptAction.ShowToastOptions = {
      message: message,
      duration: TOAST_DURATION_MS,
    };
    context.getPromptAction().showToast(options);
  } catch (err) {
    const detail: string = err instanceof Error ? err.message : JSON.stringify(err);
    hilog.warn(DOMAIN, TAG, 'showToast failed: %{public}s', detail);
  }
}
