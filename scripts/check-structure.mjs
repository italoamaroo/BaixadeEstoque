import { readdirSync } from 'node:fs';

// Entry points belong here; modules belong in the established subdirectories.
const rootFiles = new Set([
  '.git', '.env.example', '.gitignore', 'README.md', 'index.html', 'package.json',
  'package-lock.json', 'postcss.config.js', 'render.yaml', 'tailwind.config.js',
  'tsconfig.app.json', 'tsconfig.json', 'tsconfig.node.json', 'vite.config.ts',
]);
const sourceFiles = new Set(['App.tsx', 'main.tsx', 'index.css', 'vite-env.d.ts']);
const invalid = [];
for (const entry of readdirSync('.', { withFileTypes: true })) {
  if (entry.isFile() && !rootFiles.has(entry.name)) invalid.push(entry.name);
}
for (const entry of readdirSync('src', { withFileTypes: true })) {
  if (entry.isFile() && !sourceFiles.has(entry.name)) invalid.push(`src/${entry.name}`);
}
if (invalid.length) {
  console.error('Coloque módulos em src/{components,pages,lib,hooks,...}, SQL em supabase e scripts em scripts/:');
  console.error(invalid.join('\n'));
  process.exit(1);
}
console.log('Estrutura do projeto verificada.');
