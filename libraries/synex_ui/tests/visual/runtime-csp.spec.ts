import { expect, test } from '@playwright/test';

test.describe('production runtime document', () => {
  test('keeps its CSP clean while applying dynamic screen and context styles', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'The runtime CSP smoke needs one representative Chromium profile.');

    const violations: string[] = [];
    page.on('console', (message) => {
      const text = message.text();
      if (/content security policy|refused to apply|refused to execute/i.test(text)) violations.push(text);
    });
    page.on('pageerror', (error) => violations.push(error.message));
    await page.route('https://synex_ui/**', async (route) => {
      await route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' });
    });

    await page.goto('http://127.0.0.1:4179', { waitUntil: 'domcontentloaded' });
    await expect(page.locator('#root')).toBeEmpty();
    await expect.poll(() => page.evaluate(() => {
      const root = document.getElementById('root');
      if (!root) return null;
      const htmlStyle = getComputedStyle(document.documentElement);
      const bodyStyle = getComputedStyle(document.body);
      const rootStyle = getComputedStyle(root);
      return {
        htmlBackground: htmlStyle.backgroundColor,
        bodyBackground: bodyStyle.backgroundColor,
        rootBackground: rootStyle.backgroundColor,
        bodyPointerEvents: bodyStyle.pointerEvents,
        rootPointerEvents: rootStyle.pointerEvents,
        rootDisplay: rootStyle.display,
      };
    })).toEqual({
      htmlBackground: 'rgba(0, 0, 0, 0)',
      bodyBackground: 'rgba(0, 0, 0, 0)',
      rootBackground: 'rgba(0, 0, 0, 0)',
      bodyPointerEvents: 'none',
      rootPointerEvents: 'none',
      rootDisplay: 'none',
    });
    await expect.poll(() => page.evaluate(() => document.documentElement.style.getPropertyValue('--synex-screen-width'))).toBe('1920px');

    await page.evaluate(() => {
      window.postMessage({
        protocolVersion: 1,
        messageId: 'message_context_csp_01',
        type: 'surface:open',
        ownerResource: 'synex_ui_probe',
        ownerEpoch: 1,
        revision: 1,
        payload: {
          requestId: 'request_context_csp_01',
          instanceId: 'instance_context_csp_01',
          surfaceId: 'surface_context_csp_01',
          kind: 'contextMenu',
          title: 'CSP context check',
          sections: [{ id: 'primary', items: [{ id: 'inspect', label: 'Inspect' }] }],
          anchor: { x: 0.73, y: 0.31 },
        },
      }, window.location.origin);
    });

    const surface = page.getByRole('dialog', { name: 'CSP context check' });
    await expect(surface).toBeVisible();
    await expect.poll(() => surface.evaluate((element) => ({
      x: (element as HTMLElement).style.getPropertyValue('--sx-runtime-anchor-x'),
      y: (element as HTMLElement).style.getPropertyValue('--sx-runtime-anchor-y'),
    }))).toEqual({ x: '73vw', y: '31vh' });
    expect(violations).toEqual([]);
  });
});
