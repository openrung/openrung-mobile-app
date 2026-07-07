// Pre-create react-native-web's style element before RNW loads. RNW's
// createCSSStyleSheet reuses any existing element with this id; left to its
// own devices it creates `<style id="react-native-stylesheet">` as the FIRST
// child of <head> and fills it via CSSOM insertRule only — an element whose
// id matches the render check's mount-root selector (`[id^="r"]`), sorts
// first in document order, and has empty innerHTML. That combination made
// every preview flag "[RENDER] root empty" despite rendering fine. Creating
// the element at the END of <body> (bundle scripts run there, so body
// exists) keeps it after the real mount cells, and the text node keeps its
// innerHTML non-empty for any check that still reads it.
if (typeof document !== 'undefined' && !document.getElementById('react-native-stylesheet')) {
  const el = document.createElement('style');
  el.id = 'react-native-stylesheet';
  el.appendChild(
    document.createTextNode('/* react-native-web sheet — pre-created by design-sync shim */'),
  );
  (document.body ?? document.head).appendChild(el);
}

export {};
