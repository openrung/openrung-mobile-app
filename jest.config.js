module.exports = {
  preset: '@react-native/jest-preset',
  // The preset's pattern plus @noble: @noble/ed25519 and @noble/hashes are ESM-only, so Jest
  // needs babel-jest to transform them to CJS (Metro consumes their ESM directly).
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?|@noble)/)',
  ],
  // Shared non-test helpers for suites (e.g. relay-list signing fixtures); everything else under
  // __tests__/ is a test file.
  testPathIgnorePatterns: ['/node_modules/', '/__tests__/helpers/'],
};
