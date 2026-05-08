/**
 * BOOTSTRAP_PATTERN — the canonical asymmetric test pattern used by:
 *
 *  - T023 canary (JS-side analytical tripwire in `__tests__/bootstrap/`)
 *  - T053's iOS pointer-path smoke (bare-example worklet writes bytes via
 *    `ctx.target.writeBytes`)
 *  - T053a's Skia helper smoke (`drawWithSkia` produces pixel-equivalent
 *    output)
 *
 * Declared in the library (main package) as the single source of truth so
 * downstream smoke tests / canaries can import it directly. The library
 * itself never runs the pattern in production code — it's a pure JS
 * reference used only by tests and smoke harnesses.
 *
 * Design notes:
 *
 *  - The pattern is a **rotating right-triangle gradient** keyed on
 *    `frameIndex`. Two stacked asymmetries (triangle orientation rotates
 *    by 90° every frame; the gradient is distinct per quadrant) make any
 *    accidental horizontal / vertical flip or 90°/180°/270° rotation
 *    observable as a probe-pixel drift exceeding the ±32/255 tolerance.
 *  - RGB values are in the range [0, 255]; no alpha — the target buffer's
 *    alpha channel is always 0xff.
 *  - The formula is analytic — `expectedCenterRGBA` computes the expected
 *    center pixel for a given (frameIndex, width, height) in pure JS so
 *    the Jest/Node tripwire can verify without ever running the pipeline.
 */

export interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

/**
 * Compute the pattern RGBA at pixel (x, y) for frame `frameIndex` within a
 * `width × height` canvas. Shared by the native pump fallback, the JS
 * tripwire, and the consumer-facing bare-example worklet.
 *
 * Algorithm (deterministic, analytical):
 *
 *   1. `rot = frameIndex % 4` selects one of 4 triangle orientations:
 *        0 → top-left     (x+y <= w+h-1 keeps pixel "inside")
 *        1 → top-right    (x >= y anchor)
 *        2 → bottom-right
 *        3 → bottom-left
 *   2. "Inside" pixels get a per-quadrant distinctive RGB:
 *        rot 0: (nx, ny, 0xff)        — red/green gradient
 *        rot 1: (0xff - nx, ny, nx)   — magenta anchor
 *        rot 2: (0, 0xff - ny, nx)    — cyan anchor
 *        rot 3: (nx, 0, 0xff - ny)    — yellow anchor
 *      where (nx, ny) = (floor(x*255/(w-1)), floor(y*255/(h-1))).
 *   3. "Outside" pixels fall back to a flat frame-keyed colour:
 *        r = (frameIndex * 11) & 0xff
 *        g = (frameIndex * 53) & 0xff
 *        b = (frameIndex * 97) & 0xff
 *      (Same triple as the T041 placeholder, to keep migration continuous.)
 *
 * The triangle boundary is chosen so that the center pixel (x=w/2, y=h/2)
 * is ALWAYS inside — this keeps `expectedCenterRGBA` deterministic across
 * every (width, height, frameIndex) combination.
 */
export function bootstrapPatternRGBA(
  frameIndex: number,
  x: number,
  y: number,
  width: number,
  height: number,
): RGBA {
  const w1 = Math.max(1, width - 1);
  const h1 = Math.max(1, height - 1);
  const nx = Math.floor((x * 255) / w1);
  const ny = Math.floor((y * 255) / h1);

  const rot = ((frameIndex % 4) + 4) % 4;

  // Triangle boundary: the diagonals split the rectangle in half along
  // (w/2, h/2) so the integer center pixel is ALWAYS inside for every
  // orientation (each condition is `<=` or `>=` and hits equality at the
  // center). Using `w` and `h` directly (rather than `w-1`, `h-1`) keeps
  // the boundary exact for integer center coordinates.
  let inside: boolean;
  switch (rot) {
    case 0:
      inside = x * height + y * width <= width * height;
      break;
    case 1:
      inside = x * height >= y * width;
      break;
    case 2:
      inside = x * height + y * width >= width * height;
      break;
    default:
      inside = x * height <= y * width;
      break;
  }

  if (inside) {
    switch (rot) {
      case 0:
        return { r: nx, g: ny, b: 0xff, a: 0xff };
      case 1:
        return { r: 0xff - nx, g: ny, b: nx, a: 0xff };
      case 2:
        return { r: 0, g: 0xff - ny, b: nx, a: 0xff };
      default:
        return { r: nx, g: 0, b: 0xff - ny, a: 0xff };
    }
  }

  return {
    r: (frameIndex * 11) & 0xff,
    g: (frameIndex * 53) & 0xff,
    b: (frameIndex * 97) & 0xff,
    a: 0xff,
  };
}

/**
 * Analytic expected-RGBA at the center pixel (w/2, h/2) for frame
 * `frameIndex`. Used by the T023 canary tripwire to verify pipeline output
 * without running it: the formula is frozen here, and a drift in the
 * pattern definition breaks the tripwire before the pipeline regresses.
 */
export function expectedCenterRGBA(frameIndex: number, width: number, height: number): RGBA {
  return bootstrapPatternRGBA(
    frameIndex,
    Math.floor(width / 2),
    Math.floor(height / 2),
    width,
    height,
  );
}

/**
 * Consumer-side helper: fill a row-major pixel buffer with the pattern.
 * `format` controls the channel order; the target buffer must be at least
 * `height * rowBytes` bytes long. This is the body a worklet would call
 * inside `ctx.target.writeBytes(...)` — kept on the JS side so that
 * smoke screens don't need a Reanimated runtime to exercise the pump.
 */
export function fillBootstrapPattern(
  out: Uint8Array,
  frameIndex: number,
  width: number,
  height: number,
  rowBytes: number,
  format: 'bgra8888' | 'rgba8888',
): void {
  for (let y = 0; y < height; y += 1) {
    const rowStart = y * rowBytes;
    for (let x = 0; x < width; x += 1) {
      const px = bootstrapPatternRGBA(frameIndex, x, y, width, height);
      const i = rowStart + x * 4;
      if (format === 'bgra8888') {
        out[i + 0] = px.b;
        out[i + 1] = px.g;
        out[i + 2] = px.r;
        out[i + 3] = px.a;
      } else {
        out[i + 0] = px.r;
        out[i + 1] = px.g;
        out[i + 2] = px.b;
        out[i + 3] = px.a;
      }
    }
  }
}
