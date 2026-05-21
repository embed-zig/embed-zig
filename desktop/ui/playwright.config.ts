import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.DESKTOP_UI_E2E_PORT);
if (!Number.isInteger(port) || port <= 0 || port > 65_535) {
  throw new Error('DESKTOP_UI_E2E_PORT must be set to a valid TCP port. Use `bun run test:e2e`.');
}
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: './e2e',
  timeout: 10_000,
  expect: {
    timeout: 2_000,
  },
  use: {
    baseURL,
    trace: 'retain-on-failure',
  },
  webServer: {
    command: `cd ../../examples/desktop/launcher && zig build run -Dapp=zux_button-ledstrip -Dport=${port}`,
    url: baseURL,
    reuseExistingServer: false,
    timeout: 30_000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
      },
    },
  ],
});
