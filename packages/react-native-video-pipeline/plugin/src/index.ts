import { type ConfigPlugin, createRunOncePlugin, withAndroidManifest } from '@expo/config-plugins';

// Read at runtime from the compiled location (plugin/build/index.js) so the
// run-once key tracks the package version without hardcoding it.
declare const require: (moduleId: string) => unknown;
const pkg = require('../../package.json') as { name: string; version: string };

/**
 * Foreground-service permissions used by `ForegroundExportService`, which keeps
 * long video exports alive while the app is backgrounded (T047).
 *
 * The library's own `android/src/main/AndroidManifest.xml` already declares both
 * permissions *and* the `<service>`, and Gradle's manifest merger folds them
 * into the consuming app automatically. We re-assert the permissions at the app
 * level so they survive setups that strip library-declared permissions (e.g.
 * aggressive manifest-cleanup plugins). Adding an already-present permission is
 * a no-op, so this stays idempotent.
 */
const FOREGROUND_PERMISSIONS = [
  'android.permission.FOREGROUND_SERVICE',
  'android.permission.FOREGROUND_SERVICE_MEDIA_PROCESSING',
] as const;

const withVideoPipelineAndroid: ConfigPlugin = (config) =>
  withAndroidManifest(config, (cfg) => {
    const { manifest } = cfg.modResults;
    const existing = manifest['uses-permission'] ?? [];
    const present = new Set(existing.map((p) => p.$['android:name']));

    for (const name of FOREGROUND_PERMISSIONS) {
      if (!present.has(name)) {
        existing.push({ $: { 'android:name': name } });
      }
    }

    manifest['uses-permission'] = existing;
    return cfg;
  });

/**
 * Expo config plugin for `react-native-video-pipeline`.
 *
 * iOS needs no native config: background exports use a finite-length
 * `UIApplication -beginBackgroundTaskWithName:` task (no `UIBackgroundModes`
 * entry required), and the Nitro pod autolinks via Expo autolinking.
 *
 * Android: ensures the foreground-service permissions are present (see above).
 *
 * Consumers register it in `app.json` / `app.config.{js,ts}`:
 *
 *   { "plugins": ["react-native-video-pipeline"] }
 */
const withVideoPipeline: ConfigPlugin = (config) => withVideoPipelineAndroid(config);

export default createRunOncePlugin(withVideoPipeline, pkg.name, pkg.version);
