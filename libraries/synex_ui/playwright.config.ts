import { defineConfig } from '@playwright/test';

const viewports = {
  'mobile': { width: 390, height: 844 },
  '720p': { width: 1280, height: 720 },
  '1080p': { width: 1920, height: 1080 },
  '1440p': { width: 2560, height: 1440 },
  '4k': { width: 3840, height: 2160 },
  '21x9-2560': { width: 2560, height: 1080 },
  '21x9': { width: 3440, height: 1440 },
  '32x9': { width: 5120, height: 1440 },
} as const;

export default defineConfig({
  testDir: './tests/visual',
  fullyParallel: false,
  workers: 1,
  timeout: 45_000,
  outputDir: '../../.build/synex_ui/playwright-results',
  expect: {
    timeout: 5_000,
    toHaveScreenshot: {
      animations: 'disabled',
      caret: 'hide',
      scale: 'css',
      threshold: 0.25,
      maxDiffPixelRatio: 0.035,
    },
  },
  use: {
    baseURL: 'http://127.0.0.1:4178',
    colorScheme: 'dark',
    locale: 'en-US',
    deviceScaleFactor: 1,
  },
  snapshotPathTemplate: '{testDir}/__screenshots__/{projectName}/{arg}{ext}',
  projects: Object.entries(viewports).map(([name, viewport]) => ({
    name,
    use: { viewport },
    grep: name === '1080p' ? undefined : /configured viewport/,
  })),
  webServer: [
    {
      command: 'npm run dev:playground -- --host 127.0.0.1 --port 4178 --strictPort',
      url: 'http://127.0.0.1:4178',
      reuseExistingServer: true,
      timeout: 30_000,
      stdout: 'ignore',
      stderr: 'pipe',
    },
    {
      command: 'npm run preview:runtime -- --host 127.0.0.1 --port 4179 --strictPort',
      url: 'http://127.0.0.1:4179',
      reuseExistingServer: true,
      timeout: 30_000,
      stdout: 'ignore',
      stderr: 'pipe',
    },
  ],
});
