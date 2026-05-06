import { expect, test, type Page } from '@playwright/test';

type Color = {
  r: number;
  g: number;
  b: number;
};

type RuntimeState = {
  gears: Array<
    | { SingleButtonState: { label: string; kind: 'single_button'; pressed: boolean } }
    | { LedStripState: { label: string; kind: 'ledstrip'; pixels: Color[]; refresh_count: number } }
  >;
};

test('Power button emits press and release events through the desktop UI', async ({ page }) => {
  const logs = collectConsoleLogs(page);
  await page.goto('/?pw=button');

  await expect.poll(() => logs.some((line) => line.includes('initial state'))).toBe(true);

  const press = page.waitForResponse((response) =>
    response.url().includes('/emit/button/press') && response.status() === 200
  );
  await page.locator('#power-btn').dispatchEvent('pointerdown');
  await press;

  await expect.poll(() => logs.some((line) => line.includes('emit') && line.includes('press'))).toBe(true);
  await expect.poll(() => buttonPressed(page)).toBe(true);

  const release = page.waitForResponse((response) =>
    response.url().includes('/emit/button/release') && response.status() === 200
  );
  await page.locator('#power-btn').dispatchEvent('pointerup');
  await release;

  await expect.poll(() => logs.some((line) => line.includes('emit') && line.includes('release'))).toBe(true);
  await expect.poll(() => buttonPressed(page)).toBe(false);
});

test('button-ledstrip user story drives the strip away from black', async ({ page }) => {
  await page.goto('/?pw=user-story');

  await page.locator('#power-btn').click();

  await expect.poll(() => stripHasNonBlackPixel(page), {
    message: 'Expected the desktop example to behave like the app user story and render a non-black strip.',
  }).toBe(true);
});

test('LED strip state is rendered into visible pixel colors', async ({ page }) => {
  await page.goto('/?pw=ledstrip');

  await expect.poll(() => firstStripPixels(page).then((pixels) => pixels.length), {
    message: 'Expected the runtime LED strip to expose pixels.',
  }).toBeGreaterThan(0);

  const pixels = await firstStripPixels(page);
  await expect(page.locator('#strip .pixel')).toHaveCount(pixels.length);

  await longPressPower(page, 3_100);
  await expect.poll(() => firstStripPixels(page), {
    message: 'Expected a 3s hold to change the LED strip pixels.',
  }).not.toEqual(pixels);

  const updatedPixels = await firstStripPixels(page);
  await expect.poll(() => firstRenderedPixelColor(page), {
    message: 'Expected the rendered pixel color to follow the runtime LED strip state.',
  }).toEqual(rgbText(updatedPixels[0]));
});

async function longPressPower(page: Page, durationMs: number): Promise<void> {
  const button = page.locator('#power-btn');
  await button.dispatchEvent('pointerdown');
  await page.waitForTimeout(durationMs);
  await button.dispatchEvent('pointerup');
}

async function buttonPressed(page: Page): Promise<boolean> {
  const state = await runtimeState(page);
  return state.gears.find((gear) => 'SingleButtonState' in gear)?.SingleButtonState.pressed ?? false;
}

async function firstStripPixels(page: Page): Promise<Color[]> {
  const state = await runtimeState(page);
  const strip = state.gears.find((gear) => 'LedStripState' in gear)?.LedStripState;
  return strip?.pixels ?? [];
}

async function firstRenderedPixelColor(page: Page): Promise<string> {
  return page.locator('#strip .pixel').first().evaluate((node) => getComputedStyle(node).backgroundColor);
}

function rgbText(color: Color): string {
  return `rgb(${color.r}, ${color.g}, ${color.b})`;
}

async function stripHasNonBlackPixel(page: Page): Promise<boolean> {
  const state = await runtimeState(page);
  const strip = state.gears.find((gear) => 'LedStripState' in gear)?.LedStripState;
  return strip?.pixels.some((pixel) => pixel.r !== 0 || pixel.g !== 0 || pixel.b !== 0) ?? false;
}

async function runtimeState(page: Page): Promise<RuntimeState> {
  const response = await page.request.get('/state');
  expect(response.ok()).toBe(true);
  return response.json() as Promise<RuntimeState>;
}

function collectConsoleLogs(page: Page): string[] {
  const logs: string[] = [];
  page.on('console', (message) => {
    if (message.type() === 'log') {
      logs.push(message.text());
    }
  });
  return logs;
}
