import type {
  DurationMode,
  RenderControllerState,
  VideoRenderController as VideoRenderControllerSpec,
} from './nitro/VideoPipeline.nitro';

/**
 * Bindings the `Video.*` wrapper (T012) hands to the controller at the moment
 * it kicks off a native render. Wires the JS-side controller to the tokenised
 * `finishRender` / `cancelRender` pair exposed by the Nitro module.
 *
 * @internal
 */
export interface ControllerBindings {
  readonly finishRender: () => void;
  readonly cancelRender: () => void;
  /**
   * Duration mode of the render this controller is attached to. `finish()` is
   * a no-op on fixed-duration renders: truncating a fixed-duration render
   * would blur the abort/finish distinction, so early termination of a fixed
   * render uses `AbortSignal` instead.
   */
  readonly durationMode: DurationMode;
}

/**
 * Handle for graceful end-of-stream on open-ended renders.
 *
 * Distinct from `AbortSignal`:
 *  - `abort()` cancels and **discards** the output — the render promise
 *    rejects with `Cancelled`.
 *  - `finish()` stops after the current frame and **finalises** the output —
 *    the render promise resolves normally.
 *
 * State transitions:
 *  - `running → finishing → done`  (graceful: `finish()` then native flush)
 *  - `running → done`              (fixed-duration natural end)
 *  - `running → aborted`           (hard cancel)
 *  - `finishing → aborted`         (abort wins over in-flight finish)
 *
 * Terminal states (`done`, `aborted`) absorb further calls: both `finish()`
 * and `abort()` are idempotent.
 *
 * A controller maps 1:1 to a render — pass a fresh instance per `Video.*`
 * call. Rebinding is a programmer error and throws.
 */
export class VideoRenderController implements VideoRenderControllerSpec {
  #state: RenderControllerState = 'running';
  #bindings: ControllerBindings | undefined;
  #finishRequested = false;

  get state(): RenderControllerState {
    return this.#state;
  }

  finish(): void {
    if (this.#state !== 'running') return;
    this.#finishRequested = true;
    if (this.#bindings === undefined) return;
    if (this.#bindings.durationMode === 'fixed') return;
    this.#state = 'finishing';
    this.#bindings.finishRender();
  }

  abort(): void {
    if (this.#state === 'aborted' || this.#state === 'done') return;
    this.#state = 'aborted';
    this.#bindings?.cancelRender();
  }

  /**
   * Attach native bindings. Called by the `Video.*` wrapper exactly once,
   * synchronously with the Nitro render invocation. Any state transitions
   * the caller already performed (`abort()` / `finish()` before the render
   * was started) are relayed to native here.
   *
   * @internal
   */
  _bind(bindings: ControllerBindings): void {
    if (this.#bindings !== undefined) {
      throw new Error(
        'VideoRenderController is already bound to a render — create a new controller per Video.render() call',
      );
    }
    this.#bindings = bindings;

    if (this.#state === 'aborted') {
      bindings.cancelRender();
      return;
    }
    if (this.#finishRequested && this.#state === 'running' && bindings.durationMode !== 'fixed') {
      this.#state = 'finishing';
      bindings.finishRender();
    }
  }

  /**
   * Transition to the `done` terminal state. Called by the `Video.*` wrapper
   * when the native render promise resolves successfully. A prior `abort()`
   * wins — native may emit a final frame after we told it to cancel, and we
   * must not flip the terminal state back to `done`.
   *
   * @internal
   */
  _markDone(): void {
    if (this.#state === 'aborted') return;
    this.#state = 'done';
  }
}
