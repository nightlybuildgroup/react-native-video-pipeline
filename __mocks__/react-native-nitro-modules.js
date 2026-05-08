module.exports = {
  NitroModules: {
    createHybridObject() {
      throw new Error(
        'react-native-nitro-modules is mocked in Jest — inject a fake via __setNativeVideoPipelineForTesting',
      );
    },
  },
};
