module.exports = {
  env: {
    es6: true,
    node: true,
  },

  parserOptions: {
    ecmaVersion: 2020,
  },

  extends: [
    "eslint:recommended",
    "google",
  ],

  rules: {
    "no-restricted-globals": ["error", "name", "length"],
    "prefer-arrow-callback": "error",
    "quotes": [
      "error",
      "double",
      {
        "allowTemplateLiterals": true,
      },
    ],

    // Cloud Functions में हर function के लिए JSDoc जरूरी नहीं।
    "require-jsdoc": "off",
  },

  overrides: [
    {
      files: ["**/*.spec.*"],
      env: {
        mocha: true,
      },
      rules: {},
    },
  ],

  globals: {},
};
