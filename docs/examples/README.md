# Examples

Runnable scenarios, one per file. Each example is a complete snippet — copy, adjust paths, run. The runnable consumer apps in `apps/bare-example/` and `apps/expo-example/` exercise the same flows end-to-end; references at the bottom of each page point to the relevant screen.

For the full type reference see [`../api.md`](../api.md).

## Pick by operation

| Scenario                                  | Path        | File                                       |
| ----------------------------------------- | ----------- | ------------------------------------------ |
| Trim a clip without re-encoding           | remux       | [`trim.md`](./trim.md)                     |
| Flip horizontally / vertically            | remux/transcode | [`flip.md`](./flip.md)                 |
| Stamp a watermark or write metadata       | transcode/remux | [`stamp.md`](./stamp.md)               |
| Per-frame drawing on top of a clip        | compose     | [`compose.md`](./compose.md)               |
| Per-frame drawing with Skia (zero-copy)   | compose     | [`compose-skia.md`](./compose-skia.md)     |
| Generate a clip from scratch              | compose     | [`synthesize.md`](./synthesize.md)         |
| Probe a clip for codec / dimensions       | n/a         | [`probe.md`](./probe.md)                   |
| Cancel or gracefully finish a render      | any         | [`cancel-and-finish.md`](./cancel-and-finish.md) |

## Pick by execution path

- **Remux** (passthrough, fastest): [`trim.md`](./trim.md), metadata-only [`stamp.md`](./stamp.md), rotation-only [`flip.md`](./flip.md)
- **Transcode** (native overlays + transforms): watermark [`stamp.md`](./stamp.md), cropped [`trim.md`](./trim.md)
- **Compose** (worklet, slowest): [`compose.md`](./compose.md), [`compose-skia.md`](./compose-skia.md), [`synthesize.md`](./synthesize.md)

See [`../api.md#routing-rules`](../api.md#routing-rules) for the routing decision table.
