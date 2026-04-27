import path from 'node:path';
import { defineConfig } from 'vitest/config';

const ci = process.env.CI === 'true';

export default defineConfig({
  resolve: {
    alias: {
      '@kiket/api-client': path.resolve(__dirname, '../packages/api-client/src/index.ts'),
      '@kiket/engine': path.resolve(__dirname, '../packages/engine/src/index.ts'),
    },
  },
  test: {
    include: ['tests/**/*.test.ts'],
    ...(ci
      ? {
          maxWorkers: 1,
          minWorkers: 1,
          fileParallelism: false,
          maxConcurrency: 1,
        }
      : {}),
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/index.ts'],
    },
  },
});
