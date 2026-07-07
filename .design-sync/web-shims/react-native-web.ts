// 'react-native' alias target (see tsconfig.sync.json): react-native-web
// from the .ds-sync scratch install, with the stylesheet pre-create fix
// running first (import order guarantees it executes before RNW's own
// module init creates the sheet).
import './rnw-stylesheet-fix';

export * from '../../.ds-sync/node_modules/react-native-web/dist/index.js';
