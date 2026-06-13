// Flat config para ESLint v9 (migrado desde .eslintrc.js el 2026-05-13).
//
// Cambios principales vs el config viejo:
//   - `eslint-config-google` SACADO: no fue actualizado para flat config
//     (último release v0.14.0 de 2022, ya no se mantiene). Las pocas
//     reglas que aportaba (quotes, indent, max-len) las dejamos
//     declaradas inline acá.
//   - `@typescript-eslint/eslint-plugin` + `@typescript-eslint/parser`
//     reemplazados por el paquete unificado `typescript-eslint` v8+.
//   - `--ext .js,.ts` ya no se usa: en flat config los patrones de
//     archivos van en `files` de cada bloque.

const tseslint = require("typescript-eslint");
const importPlugin = require("eslint-plugin-import");
const eslintJs = require("@eslint/js");

module.exports = tseslint.config(
  // ─── Ignores globales ──────────────────────────────────────────
  {
    ignores: [
      "lib/**",        // output del compilador
      "generated/**",
      "test/**",
      "test_rules/**", // mismo motivo que test/ (node:test plano, fuera de tsconfig)       // tests usan node:test simple, no requieren
                       // lint typescript-aware (su parser exige que
                       // los archivos estén en tsconfig.json, y no
                       // queremos meter test/ ahí porque eso compila
                       // los tests a lib/ y se suben al deploy).
      "eslint.config.js", // el propio config no está en tsconfig.json.
    ],
  },

  // ─── Base recomendada de ESLint ────────────────────────────────
  eslintJs.configs.recommended,

  // ─── Reglas de TypeScript (paquete unificado v8+) ──────────────
  ...tseslint.configs.recommended,

  // ─── Plugin de imports (flat-config-ready en >=2.31) ───────────
  importPlugin.flatConfigs.recommended,
  importPlugin.flatConfigs.typescript,

  // ─── Reglas del proyecto + parser options para .ts ─────────────
  {
    files: ["src/**/*.ts", "src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        // No usamos `env: { node: true }` (es legacy del .eslintrc).
        // En flat config se declaran los globales explícitos:
        process: "readonly",
        Buffer: "readonly",
        console: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        setImmediate: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
        module: "readonly",
        require: "readonly",
        exports: "writable",
        global: "readonly",
      },
      parserOptions: {
        project: ["tsconfig.json"],
        sourceType: "module",
        tsconfigRootDir: __dirname,
      },
    },
    rules: {
      // Reglas que antes venían del config local + Google style
      // mínimo necesario para el proyecto.
      "quotes": ["error", "double"],
      "indent": ["error", 2],
      "object-curly-spacing": ["error", "always"],
      "max-len": ["warn", { code: 100 }],
      "import/no-unresolved": "off", // TS-eslint resuelve los paths.
      "@typescript-eslint/no-unused-vars": "warn",
    },
  },
);
