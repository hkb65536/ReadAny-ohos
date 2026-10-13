import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { setUuidGenerator } from 'core';

const DOMAIN: number = 0x0000;
const TAG: string = 'InkBoat';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Install the platform UUID generator before anything can mint ids.
    // Every synced entity id must come from here so that both clients agree
    // on the `{sanitized-title}-{uuid}` remote folder shape.
    setUuidGenerator((): string => {
      try {
        return util.generateRandomUUID(true);
      } catch (err) {
        // Deterministic fallback is unacceptable for synced ids, but throwing
        // here would take down app start. Log loudly and let the core layer's
        // own fallback keep the app usable; the next start will retry.
        hilog.error(DOMAIN, TAG, 'generateRandomUUID failed: %{public}s', JSON.stringify(err));
        return '';
      }
    });

    // The colour mode is deliberately **not** set here.
    //
    // The app ships three themes of its own, and the system colour mode is what decides
    // how system materials and `$r('sys.color.*')` render. Leaving it on "follow the
    // system" meant those two disagreed with the app's theme whenever the user picked a
    // theme other than the system's. `Index.applySystemAppearance` sets it from the
    // chosen theme instead, once the preference has been read.
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'loadContent threw: %{public}s', JSON.stringify(err));
    }
  }
  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    // Sync is checked on foreground rather than promised as a background task:
    // the system may suspend us at any time, so the reliable trigger is here.
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }
}
