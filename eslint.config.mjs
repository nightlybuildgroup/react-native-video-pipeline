// ESLint config — transitional, scoped narrowly to React Native-specific
// rules that Biome does not (yet) cover. Biome is the primary lint + format
// tool (see biome.json). Every rule enabled here is documented with the
// reason Biome cannot replace it.
//
// If/when Biome ships equivalents, the matching rule here should be removed.

import tsParser from '@typescript-eslint/parser';
import reactNative from 'eslint-plugin-react-native';

export default [
  {
    ignores: [
      '**/node_modules/**',
      '**/.yarn/**',
      '**/lib/**',
      '**/build/**',
      '**/nitrogen/**',
      '**/plugin/build/**',
    ],
  },
  {
    files: ['**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: 'latest',
        sourceType: 'module',
        ecmaFeatures: { jsx: true },
      },
    },
    plugins: {
      'react-native': reactNative,
    },
    rules: {
      // React-Native-specific — Biome has no StyleSheet-aware analysis.
      'react-native/no-unused-styles': 'error',
      // React-Native-specific — platform Component splitting (X.ios.tsx /
      // X.android.tsx) is a Metro resolver concern Biome doesn't model.
      'react-native/split-platform-components': 'error',
      // React-Native-specific — inline styles defeat StyleSheet.create
      // caching; Biome has no equivalent heuristic.
      'react-native/no-inline-styles': 'error',
      // React-Native-specific — color literals belong in a theme token;
      // Biome has no RN-StyleSheet-aware rule for this.
      'react-native/no-color-literals': 'error',
      // React-Native-specific — raw text outside <Text> crashes on iOS;
      // Biome has no JSX-component-name-aware rule for this.
      'react-native/no-raw-text': 'error',
      // React-Native-specific — `style={[styles.x]}` is wasted work vs.
      // `style={styles.x}`; Biome has no StyleSheet-aware rule.
      'react-native/no-single-element-style-arrays': 'error',
    },
  },
];
