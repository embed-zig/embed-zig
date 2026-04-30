import { defineConfig } from '@hey-api/openapi-ts';

export default defineConfig({
  input: '../api.json',
  output: 'src/api/generated',
  plugins: [
    {
      name: '@hey-api/client-fetch',
      runtimeConfigPath: '../client-config.ts',
    },
    {
      name: '@hey-api/typescript',
      enums: 'javascript',
    },
  ],
});
