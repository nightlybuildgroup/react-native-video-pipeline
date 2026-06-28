module.exports = {
  NitroModules: {
    createHybridObject() {
      throw new Error(
        'react-native-nitro-modules is mocked in Jest — inject a fake via __setNativeVideoPipelineForTesting',
      );
    },
    // Faithful box/unbox: a boxed object just round-trips the original via
    // `.unbox()`, mirroring Nitro's BoxedHybridObject contract for tests.
    box(obj) {
      return { unbox: () => obj };
    },
  },
};
