import { InkBoatError } from 'core';
import { DEFAULT_REMOTE_ROOT, DEFAULT_SYNC_INTERVAL_MINS, MAX_CONCURRENCY, MIN_CONCURRENCY } from 'sync';
import type { WebDavConfig } from 'sync';
import { showToast } from '../ui/Toast';
import { BUILD_STAMP } from './Index';
import type { ThemePalette } from '../theme/Theme';
import { RADIUS_CARD, TYPE_CAPTION } from '../theme/Theme';

/**
 * WebDAV sync settings.
 *
 * This is the first screen that talks to a real server, so it is deliberately
 * plain ArkUI. The 7.0 material layer is added once the feature works: mixing an
 * unverified network path with an unverified visual layer makes it impossible to
 * tell which one broke an install.
 *
 * "Test connection" is separate from "Save" on purpose. It runs against a
 * throwaway client so a wrong address or password never gets written to
 * preferences or the credential store.
 */
@Component
export struct SyncSettingsPage {
  /**
   * The persisted configuration, as the shell loaded it.
   *
   * `@Watch` because the shell replaces this object whenever the store is re-read — the
   * auto-sync switch is saved by the shell, not by this component, so without the watch
   * this page could keep showing a value that is no longer what is stored (for example
   * after the save fails and the shell keeps the old one, or after the page is opened
   * again from a tab switch while the shell already has newer state).
   */
  @Prop @Watch('onConfigChanged') config: WebDavConfig;
  /**
   * The active colour theme.
   *
   * Passed in rather than read from the system: this form used `$r('sys.color.*')`, so
   * under the dark and sepia palettes it rendered system greys — a white card and dark
   * text on a near-black page. The palette is the same one the shell uses.
   */
  @Prop palette: ThemePalette;
  /** Injected so the page has no direct dependency on the service singleton. */
  onTest: (url: string, username: string, password: string, allowInsecure: boolean, remoteRoot: string) => Promise<void> =
    async (): Promise<void> => {};
  onSave: (url: string, username: string, password: string, allowInsecure: boolean, remoteRoot: string) => Promise<void> =
    async (): Promise<void> => {};
  /**
   * Fired as soon as the 「自动同步」 switch is flipped.
   *
   * A callback of its own rather than another parameter on `onSave`: the switch writes
   * through immediately, so that turning the app's automatic network access off takes
   * effect at the flip and not at the next 保存 tap. The shell routes it into the same
   * `SyncConfigStore` path `onSave` uses — there is no second storage location.
   */
  onAutoSyncChange: (enabled: boolean) => Promise<void> = async (): Promise<void> => {};
  /**
   * Whether a WebDAV password is currently in the credential store.
   *
   * Passed in like `config` and `palette`, so this page still has no dependency on the
   * service singleton. It exists because the form can only say "leave the field empty to
   * keep the saved password" if it knows there *is* a saved password — and because an
   * empty field must not be read as "clear it" (see `SyncService.saveConnection`).
   */
  @Prop hasStoredPassword: boolean;
  /**
   * Forget the stored password, on an explicit request from the user.
   *
   * The counterpart of "an empty field keeps the saved password": with that rule, a save
   * can no longer remove the credential, so the removal needs a control of its own.
   */
  onClearPassword: () => Promise<void> = async (): Promise<void> => {};

  @State private url: string = '';
  @State private username: string = '';
  @State private password: string = '';
  @State private remoteRoot: string = DEFAULT_REMOTE_ROOT;
  @State private allowInsecure: boolean = false;
  /** Mirrors `config.autoSync`; see `onConfigChanged` for why it is not read directly. */
  @State private autoSync: boolean = false;
  /** True while the switch's own save is in flight, to stop a double flip racing it. */
  @State private autoSyncBusy: boolean = false;

  @State private busy: boolean = false;
  @State private busyLabel: string = '';
  @State private resultText: string = '';
  @State private resultOk: boolean = false;

  aboutToAppear(): void {
    this.url = this.config.url;
    this.username = this.config.username;
    this.remoteRoot = this.config.remoteRoot.length > 0
      ? this.config.remoteRoot
      : DEFAULT_REMOTE_ROOT;
    this.allowInsecure = this.config.allowInsecure;
    // Taken from the configuration that was loaded from preferences, so what the switch
    // shows on open is the persisted value and not a default.
    this.autoSync = this.config.autoSync;
  }

  /**
   * Re-read the switch from the configuration when the shell replaces it.
   *
   * This is what keeps the switch honest across a save, a failed save, and a tab switch
   * away and back.
   */
  private onConfigChanged(): void {
    this.autoSync = this.config.autoSync;
  }

  /**
   * Persist a flip of the 「自动同步」 switch.
   *
   * The visual state moves first so the switch does not feel broken, and is put back if
   * the write fails — an off switch that silently stays on would be worse than either
   * outcome.
   */
  private async applyAutoSync(enabled: boolean): Promise<void> {
    if (this.autoSyncBusy) {
      return;
    }
    const previous: boolean = this.autoSync;
    this.autoSync = enabled;
    this.autoSyncBusy = true;
    try {
      await this.onAutoSyncChange(enabled);
      this.resultOk = true;
      this.resultText = enabled
        ? '已开启自动同步：启动应用时会同步一次书目与标注。'
        : '已关闭自动同步：启动应用时不会发起任何同步。';
    } catch (err) {
      this.autoSync = previous;
      this.resultOk = false;
      this.resultText = describeError(err);
      this.toast('保存失败');
    } finally {
      this.autoSyncBusy = false;
    }
  }

  /**
   * Show a message.
   *
   * Routed through the shared helper, which uses the non-deprecated
   * `UIContext.getPromptAction()` path and logs a failure instead of hiding it; see
   * `ui/Toast.ets`. The same text is also rendered inline, so a missing toast never
   * turns a successful sync into a reported error.
   */
  private toast(message: string): void {
    showToast(this.getUIContext(), message);
  }

  private async runTest(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.url.trim().length === 0 || this.username.trim().length === 0) {
      this.resultOk = false;
      this.resultText = '请先填写服务器地址和用户名。';
      return;
    }
    this.busy = true;
    this.busyLabel = '正在测试连接...';
    this.resultText = '';
    try {
      await this.onTest(
        this.url,
        this.username,
        this.password,
        this.allowInsecure,
        this.remoteRoot,
      );
      this.resultOk = true;
      this.resultText = '连接成功。服务器可达，凭据有效，目录结构已就绪。';
      this.toast('连接成功');
    } catch (err) {
      this.resultOk = false;
      this.resultText = describeError(err);
      this.toast('连接失败');
    } finally {
      this.busy = false;
      this.busyLabel = '';
    }
  }

  private async runSave(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.url.trim().length === 0 || this.username.trim().length === 0) {
      this.resultOk = false;
      this.resultText = '请先填写服务器地址和用户名。';
      return;
    }
    // Captured before the await, because the field is emptied on success below.
    const typed: string = this.password;
    this.busy = true;
    this.busyLabel = '正在保存...';
    try {
      await this.onSave(
        this.url,
        this.username,
        typed,
        this.allowInsecure,
        this.remoteRoot,
      );
      // The secret lives in the credential store now, not in this component's state. Empty
      // is also the state that means "keep the saved password" on the next save, so this is
      // the same thing the field looks like on open.
      this.password = '';
      this.resultOk = true;
      this.resultText = typed.length > 0
        ? '已保存。密码已存入系统安全存储。'
        : (this.hasStoredPassword
          ? '已保存。密码留空，沿用已保存的密码。'
          : '已保存连接信息；尚未保存密码，同步前需要填写。');
      this.toast('已保存');
    } catch (err) {
      this.resultOk = false;
      this.resultText = describeError(err);
      this.toast('保存失败');
    } finally {
      this.busy = false;
      this.busyLabel = '';
    }
  }

  /**
   * Ask, then remove the stored password.
   *
   * A confirmation because this is the only destructive control on the page and the only
   * way to lose the credential — with 「留空即沿用」 in force, an accidental tap would
   * otherwise be unrecoverable without the secret. `UIContext.showAlertDialog` is a platform
   * dialog, so it floats over the page rather than being laid out inside it; nothing here
   * can shift the form. The `UIContext` route rather than the module-level
   * `AlertDialog.show` for the same reason `ui/Toast.ets` exists: the global form is
   * deprecated, and the compiler says so on every build.
   */
  private confirmClearPassword(): void {
    this.getUIContext().showAlertDialog({
      title: '清除已保存的密码',
      message: '只会删除系统安全存储中的 WebDAV 密码，服务器地址和同步参数会保留。清除后同步会显示为未配置，需要重新填写密码。',
      primaryButton: {
        value: '取消',
        action: (): void => {},
      },
      secondaryButton: {
        value: '清除',
        action: (): void => {
          this.clearPassword();
        },
      },
    });
  }

  /** Remove the credential through the shell, and report the outcome on the page. */
  private async clearPassword(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.busyLabel = '正在清除密码...';
    this.resultText = '';
    try {
      await this.onClearPassword();
      this.password = '';
      this.resultOk = true;
      this.resultText = '已清除保存的密码。同步会显示为未配置，直到重新填写密码并保存。';
      this.toast('已清除密码');
    } catch (err) {
      this.resultOk = false;
      this.resultText = describeError(err);
      this.toast('清除失败');
    } finally {
      this.busy = false;
      this.busyLabel = '';
    }
  }

  @Builder
  private renderFieldLabel(text: string, hint: string) {
    Column({ space: 2 }) {
      Text(text)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .width('100%')
      Text(hint)
        .fontSize(11)
        .fontColor(this.palette.mutedForeground)
        .width('100%')
    }
    .width('100%')
    .margin({ top: 14, bottom: 6 })
  }

  /**
   * The form. **Not** a Scroll.
   *
   * It used to be one, and that broke the page it is embedded in. `syncSection` wraps
   * this in its own Scroll so the self-test below the form can be reached; two nested
   * scroll containers meant the inner one swallowed every drag and bounced (its content
   * fits the viewport), so the outer never scrolled and the self-test was unreachable
   * on a phone.
   *
   * A component that knows it will be embedded should not impose a scroll container.
   * The **scrolling** belongs to the parent, which is the only place that knows the full height
   * of the content, and since r116 the parent owns the horizontal inset too. That is not a
   * style preference: this form is a `width('100%')` child, and a `width('100%')` child does not
   * shrink for its own `margin` in ArkUI, so an element that insets itself with a margin
   * overflows its parent. `syncSection` pads its content column once and every child — this
   * form included — is a plain `width('100%')` of the result.
   */
  build() {
    Column() {
        // ---- server ------------------------------------------------------
        this.renderFieldLabel('服务器地址', '例如 https://dav.jianguoyun.com/dav')
        TextInput({ text: this.url, placeholder: 'https://' })
          .type(InputType.Normal)
          .width('100%')
          .onChange((value: string): void => {
            this.url = value;
          })

        this.renderFieldLabel('用户名', 'WebDAV 账号；坚果云请使用「应用密码」对应账号')
        TextInput({ text: this.username, placeholder: '用户名' })
          .type(InputType.Normal)
          .width('100%')
          .onChange((value: string): void => {
            this.username = value;
          })

        this.renderFieldLabel('密码 / 应用密码',
          this.hasStoredPassword
            ? '已保存在系统安全存储中；留空表示沿用已保存的密码'
            : '保存在系统安全存储中，不会写入配置文件')
        // **The field is empty on purpose, and the placeholder is the signal.** Pre-filling it
        // with the real secret would put the password into `@State` and into the rendered
        // text, and it would make "leave it empty to keep what is stored" impossible to
        // express — an empty field would then have to mean "the user deleted it".
        TextInput({
          text: this.password,
          placeholder: this.hasStoredPassword ? '已保存 · 留空则不修改' : '密码',
        })
          .type(InputType.Password)
          .width('100%')
          .onChange((value: string): void => {
            this.password = value;
          })

        // The explicit clear. Shown only when there is something to clear, because an
        // always-present "clear" button on a page with no stored password is a control that
        // can only lie. Secondary styling rather than the primary fill of 保存/测试连接: it
        // is not the page's main action, and `Color.Transparent` is written down because an
        // *unset* `backgroundColor` on a Button is the framework's own fill, not transparency.
        if (this.hasStoredPassword) {
          Row() {
            // No `padding({ left, right })` here on purpose: `verify-reader-chrome` asserts that this
            // whole form carries **zero** horizontal padding or margin, because the parent owns the
            // page's single inset (r116) and an element that re-adds either is inset twice. The
            // capsule's own internal padding is what gives this button its width.
            Button('清除已保存的密码')
              .fontSize(13)
              .height(32)
              .backgroundColor(Color.Transparent)
              .fontColor($r('sys.color.warning'))
              .enabled(!this.busy)
              .onClick((): void => {
                this.confirmClearPassword();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .margin({ top: 4 })
        }

        // ---- advanced ----------------------------------------------------
        this.renderFieldLabel('远程目录', `默认 ${DEFAULT_REMOTE_ROOT}；会创建在服务器上`)
        TextInput({ text: this.remoteRoot, placeholder: DEFAULT_REMOTE_ROOT })
          .type(InputType.Normal)
          .width('100%')
          .onChange((value: string): void => {
            this.remoteRoot = value;
          })

        Row() {
          Column({ space: 2 }) {
            Text('允许不安全连接')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text('强制使用 HTTP 或接受自签名证书。仅用于自建 NAS。')
              .fontSize(11)
              .fontColor(this.palette.mutedForeground)
              .width('100%')
          }
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.allowInsecure })
            .onChange((isOn: boolean): void => {
              this.allowInsecure = isOn;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 18 })

        // ---- auto sync ---------------------------------------------------
        // The same row shape as 「允许不安全连接」 above, and it sits next to it because
        // the two answer the same kind of question: what this app is allowed to do to the
        // network on its own. It saves on the flip rather than on 保存 — see
        // `applyAutoSync`.
        //
        // The subtitle states the *limits* of the automatic pass, because "自动同步"
        // alone reads as "keep my library in step", which is not what happens: the
        // automatic pass is the ordinary one, so it never re-uploads or re-downloads book
        // files — and it runs the per-book (v2) protocol only. A server speaking the older
        // per-device (v1) dialect is deliberately left to an explicit tap, because a v1
        // pass is the one that publishes this device's whole library and merges peers'
        // snapshots into the local database. See `SyncService.autoSyncGate`.
        Row() {
          Column({ space: 2 }) {
            Text('自动同步')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text('启动应用时自动同步一次：只同步书目、标注与封面，不会整库上传或下载书籍文件。'
              + '远端是 v1（每设备快照）格式时不会自动同步，请在同步页手动运行一次。')
              .fontSize(11)
              .fontColor(this.palette.mutedForeground)
              .width('100%')
          }
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.autoSync })
            .enabled(!this.autoSyncBusy)
            .onChange((isOn: boolean): void => {
              // Not awaited: this is a UI callback. `applyAutoSync` reports its own
              // outcome through `resultText`, so nothing here has to handle a rejection.
              this.applyAutoSync(isOn);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 18 })

        // ---- actions -----------------------------------------------------
        Row({ space: 12 }) {
          Button('测试连接')
            .layoutWeight(1)
            // The app palette, not the system default. Without these the button rendered
            // in the system accent — blue — which belongs to none of the three themes and
            // is glaring against sepia.
            .backgroundColor(this.palette.primary)
            .fontColor(this.palette.primaryForeground)
            .enabled(!this.busy)
            .onClick((): void => {
              this.runTest();
            })
          Button('保存')
            .layoutWeight(1)
            .backgroundColor(this.palette.primary)
            .fontColor(this.palette.primaryForeground)
            .enabled(!this.busy)
            .onClick((): void => {
              this.runSave();
            })
        }
        .width('100%')
        .margin({ top: 22 })

        if (this.busy) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18)
            Text(this.busyLabel).fontSize(13)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 16 })
        }

        if (this.resultText.length > 0) {
          Text(this.resultText)
            .fontSize(13)
            .width('100%')
            .padding(12)
            // A content container: 16vp (`RADIUS_CARD`). It was a bare `8`.
            .borderRadius(RADIUS_CARD)
            // `card` + a hairline border, not `muted`. `muted` is lighter than the page on
            // the light and dark palettes, so it reads as a recess; the card is the raised
            // surface, and the border is what gives it an edge on sepia (1.047:1 fill against
            // page — the weakest of the three themes, and the one the user's device check
            // found unreadable without the edge; see `ui/ListRow.ets`).
            .backgroundColor(this.palette.card)
            .borderWidth(1)
            .borderColor(this.palette.border)
            // The result's own state colour is kept: a failure must still read as a failure.
            .fontColor(this.resultOk
              ? this.palette.foreground
              : $r('sys.color.warning'))
            .margin({ top: 16 })
        }

        // ---- what the values mean ----------------------------------------
        Column({ space: 6 }) {
          Text('同步参数')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ bottom: 2 })
          Text(`同步间隔：${this.config.syncIntervalMins} 分钟（默认 ${DEFAULT_SYNC_INTERVAL_MINS}）`)
            .fontSize(12)
            .fontColor(this.palette.mutedForeground)
            .width('100%')
          Text(`并发传输：${this.config.concurrency}（范围 ${MIN_CONCURRENCY}-${MAX_CONCURRENCY}）`)
            .fontSize(12)
            .fontColor(this.palette.mutedForeground)
            .width('100%')
          Text(`仅 Wi-Fi 同步：${this.config.wifiOnly ? '开' : '关'}`)
            .fontSize(12)
            .fontColor(this.palette.mutedForeground)
            .width('100%')
          Text(BUILD_STAMP)
            .fontSize(11)
            .fontColor(this.palette.mutedForeground)
            .width('100%')
            .margin({ top: 6 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        // A content container holding the diagnostics read-out: 16vp (`RADIUS_CARD`), up
        // from a bare `8`, and the card surface rather than `muted` — see the note on the
        // result box above; the two panels are the same kind of surface and now look it,
        // hairline included.
        .borderRadius(RADIUS_CARD)
        .backgroundColor(this.palette.card)
        .borderWidth(1)
        .borderColor(this.palette.border)
        .margin({ top: 24 })

        Blank().height(24)
    }
    .width('100%')
    .padding({ top: 8 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.palette.background)
  }
}

/**
 * Turn a thrown value into something a user can act on.
 *
 * `InkBoatError` already carries a classified `kind` and a Chinese message, so it
 * is shown verbatim; anything else is shown raw rather than hidden behind a
 * generic "failed", because during development the raw text is the useful part.
 */
function describeError(err: Object): string {
  if (err instanceof InkBoatError) {
    return err.message;
  }
  if (err instanceof Error) {
    return `${err.message}`;
  }
  return JSON.stringify(err);
}
