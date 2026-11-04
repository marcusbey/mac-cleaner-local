const path = require('node:path');
function nativeBundle(resourcesPath) {
  return path.join(resourcesPath, 'App Cleaner Local.app');
}
function launchArguments(resourcesPath) {
  return ['-a', nativeBundle(resourcesPath)];
}
module.exports = { nativeBundle, launchArguments };
