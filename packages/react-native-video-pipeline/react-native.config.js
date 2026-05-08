// React Native CLI autolinking config — tells `@react-native-community/cli`
// to discover this package as a native dependency on both platforms. iOS
// picks up the podspec; Android picks up android/build.gradle.

module.exports = {
  dependency: {
    platforms: {
      ios: {},
      android: {},
    },
  },
};
