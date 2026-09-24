const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  { ignores: ['dist/'] },
  js.configs.recommended,
  { files: ['app.js', 'config.js'], languageOptions: { sourceType: 'script', globals: globals.browser } },
  { files: ['test/**/*.js', 'eslint.config.js'], languageOptions: { sourceType: 'commonjs', globals: globals.node } },
];
