// Web shim for react-native-svg: the package's own web implementation,
// re-exported directly. The package index ('react-native-svg') resolves to
// the NATIVE module tree under esbuild (its `./elements` import picks
// elements.js over elements.web.js without Metro's platform-extension
// resolution), so we alias the bare specifier to this file instead
// (.design-sync/tsconfig.sync.json) and re-export the web build.
export * from 'react-native-svg/lib/module/elements.web';
export { default } from 'react-native-svg/lib/module/elements.web';
