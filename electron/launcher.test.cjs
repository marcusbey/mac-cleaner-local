const test = require('node:test');
const assert = require('node:assert/strict');
const { launchArguments } = require('./launcher.cjs');
test('launches only bundled native app with literal spaced path',()=>{
  assert.deepEqual(launchArguments('/Applications/App Cleaner Desktop.app/Contents/Resources'),['-a','/Applications/App Cleaner Desktop.app/Contents/Resources/App Cleaner Local.app']);
});
test('shell-looking names remain literal arguments',()=>{
  const root='/tmp/$(do-not-execute); space';
  assert.equal(launchArguments(root)[1],root+'/App Cleaner Local.app');
});
