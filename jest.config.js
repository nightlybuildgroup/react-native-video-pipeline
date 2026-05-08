/** @type {import('jest').Config} */
module.exports = {
  rootDir: '.',
  testMatch: [
    '<rootDir>/packages/*/__tests__/**/*.test.ts',
    '<rootDir>/packages/*/__tests__/**/*.test.tsx',
    '<rootDir>/apps/*/__tests__/**/*.test.ts',
    '<rootDir>/apps/*/__tests__/**/*.test.tsx',
    '<rootDir>/__tests__/**/*.test.ts',
    '<rootDir>/__tests__/**/*.test.tsx',
    // Bootstrap entries keep their PRD §12 names (`self-test.ts`,
    // `generators.ts`) without a `.test.ts` suffix. Match them directly.
    '<rootDir>/__tests__/bootstrap/self-test.ts',
    '<rootDir>/__tests__/bootstrap/generators.ts',
  ],
  transform: {
    '^.+\\.tsx?$': [
      'ts-jest',
      {
        tsconfig: {
          module: 'CommonJS',
          moduleResolution: 'Node',
          target: 'ES2020',
          esModuleInterop: true,
          isolatedModules: true,
        },
      },
    ],
  },
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json'],
  moduleNameMapper: {
    '^react-native-nitro-modules$': '<rootDir>/__mocks__/react-native-nitro-modules.js',
  },
  testPathIgnorePatterns: ['/node_modules/', '/lib/', '/build/', '/nitrogen/', '/plugin/build/'],
  passWithNoTests: true,
};
