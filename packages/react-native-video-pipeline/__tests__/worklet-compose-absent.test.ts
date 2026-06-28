/**
 * #34: when `react-native-worklets-core` is not installed (or exposes no
 * `Worklets` API), the off-thread dispatcher is unavailable so `offthread`
 * compose falls back / rejects rather than crashing. Mocked here as a module
 * with no `Worklets` export — the deterministic "absent" shape.
 */
jest.mock('react-native-worklets-core', () => ({}), { virtual: true });

import { createWorkletDispatcher } from '../src/worklet-compose';

it('returns undefined when react-native-worklets-core exposes no Worklets API', () => {
  expect(createWorkletDispatcher((() => {}) as never, () => {})).toBeUndefined();
});
