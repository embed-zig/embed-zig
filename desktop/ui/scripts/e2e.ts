import { spawn } from 'node:child_process';
import { createServer } from 'node:net';

const port = process.env.DESKTOP_UI_E2E_PORT ?? String(await pickPort());
const playwright = Bun.which('playwright') ?? './node_modules/.bin/playwright';
const child = spawn(playwright, ['test', ...process.argv.slice(2)], {
  env: {
    ...process.env,
    DESKTOP_UI_E2E_PORT: port,
  },
  stdio: 'inherit',
});

child.on('error', (err) => {
  console.error(err);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});

async function pickPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (address == null || typeof address === 'string') {
        server.close();
        reject(new Error('Unable to allocate a loopback port for Playwright.'));
        return;
      }

      server.close((err) => {
        if (err) {
          reject(err);
          return;
        }
        resolve(address.port);
      });
    });
  });
}
