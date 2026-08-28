import { expect, test, type Page } from '@playwright/test';

const sections = [
  'overview',
  'foundation',
  'actions',
  'forms',
  'selection',
  'navigation',
  'overlays',
  'menus',
  'feedback',
  'data',
  'utilities',
  'advanced',
  'runtime',
] as const;

const profileVariants = [
  { name: 'low', query: 'section=foundation&quality=LOW', attribute: 'data-sx-quality', value: 'low' },
  { name: 'high', query: 'section=foundation&quality=HIGH', attribute: 'data-sx-quality', value: 'high' },
  { name: 'ultra', query: 'section=foundation&quality=ULTRA', attribute: 'data-sx-quality', value: 'ultra' },
  { name: 'scale-85', query: 'section=overview&scale=85', property: '--synex-ui-scale', value: '0.85' },
  { name: 'scale-115', query: 'section=overview&scale=115', property: '--synex-ui-scale', value: '1.15' },
  { name: 'scale-125', query: 'section=overview&scale=125', property: '--synex-ui-scale', value: '1.25' },
  { name: 'density-compact', query: 'section=forms&density=compact', attribute: 'data-sx-density', value: 'compact' },
  { name: 'density-spacious', query: 'section=forms&density=spacious', attribute: 'data-sx-density', value: 'spacious' },
  { name: 'reduced-transparency', query: 'section=foundation&reducedTransparency=true', attribute: 'data-sx-reduced-transparency', value: 'true' },
  { name: 'reduced-motion', query: 'section=feedback&reducedMotion=true', attribute: 'data-sx-reduced-motion', value: 'true' },
  { name: 'high-contrast', query: 'section=data&highContrast=true', attribute: 'data-sx-high-contrast', value: 'true' },
] as const;

async function openDesignLab(page: Page, query = ''): Promise<void> {
  await page.goto(query ? `/?${query}` : '/', { waitUntil: 'domcontentloaded' });
  await expect(page.getByTestId('design-lab')).toBeVisible();

  await page.evaluate(async () => {
    await document.fonts.ready;
    const pendingImages = Array.from(document.images, (image) => {
      if (image.complete) return Promise.resolve();
      return image.decode().catch(() => undefined);
    });
    await Promise.all(pendingImages);
  });

  await expect(page.locator('.lab-header')).toContainText('Synex UI');
}

test.describe('Synex Design Lab visual regression', () => {
  test('overview remains composed at the configured viewport', async ({ page }, testInfo) => {
    await openDesignLab(page);

    const horizontalBounds = await page.evaluate(() => ({
      clientWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
    }));
    expect(horizontalBounds.scrollWidth).toBeLessThanOrEqual(horizontalBounds.clientWidth + 1);

    if (testInfo.project.name === 'mobile') {
      const settingsButton = page.getByRole('button', { name: 'View settings' });
      await expect(settingsButton).toBeVisible();
      await expect(settingsButton).toHaveAttribute('aria-expanded', 'false');
      await expect(settingsButton).toHaveAttribute('aria-controls', 'lab-view-settings');
      await settingsButton.click();
      await expect(page.locator('.lab-controls')).toHaveAttribute('data-open', 'true');
      const closeButton = page.getByRole('button', { name: 'Close settings' });
      await expect(closeButton).toHaveAttribute('aria-expanded', 'true');
      await page.keyboard.press('Escape');
      await expect(page.locator('.lab-controls')).not.toHaveAttribute('data-open', 'true');
      await expect(settingsButton).toHaveAttribute('aria-expanded', 'false');
      await expect(settingsButton).toBeFocused();
      const sectionHint = page.locator('.lab-index__hint');
      await expect(sectionHint).toBeVisible();
      const hintBounds = await sectionHint.boundingBox();
      expect(hintBounds).not.toBeNull();
      expect(hintBounds!.width).toBeGreaterThanOrEqual(80);
      expect(hintBounds!.x).toBeGreaterThanOrEqual(0);
      expect(hintBounds!.x + hintBounds!.width).toBeLessThanOrEqual(horizontalBounds.clientWidth + 1);
      await expect(page.locator('.lab-footer')).toHaveCSS('position', 'static');
      await openDesignLab(page);
    }

    if (testInfo.project.name === '720p') {
      const settingsButton = page.getByRole('button', { name: 'View settings' });
      await settingsButton.click();
      await expect(page.getByRole('switch', { name: 'Reduced motion' })).toBeVisible();
      await expect(page.getByRole('switch', { name: 'Opaque materials' })).toBeVisible();
      await expect(page.getByRole('switch', { name: 'High contrast' })).toBeVisible();
      await page.getByRole('button', { name: 'Close settings' }).click();
    }

    await expect(page).toHaveScreenshot('overview-viewport.png', {
      fullPage: false,
    });
  });

  for (const section of sections) {
    test(`renders the complete ${section} section at 1080p`, async ({ page }, testInfo) => {
      test.skip(testInfo.project.name !== '1080p', 'Detailed section baselines are captured at 1080p.');

      await openDesignLab(page, `section=${section}`);
      await expect(page.locator('.lab-family-header')).toBeVisible();
      await expect(page.locator('.lab-family-header h1')).toBeVisible();

      if (section === 'foundation') {
        for (const specimen of ['tokens', 'colors', 'materials', 'glass-intensity', 'screen-sizes']) {
          await expect(page.getByTestId(specimen)).toBeVisible();
        }
      }

      await expect(page.locator('.lab-stage')).toHaveScreenshot(`section-${section}.png`);
    });
  }

  test('keeps long direct data-grid text ellipsized inside the aligned cell', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== '1080p', 'Data-grid geometry is verified at 1080p.');

    await openDesignLab(page, 'section=data');
    const content = page.locator('.sx-data-grid__body .sx-data-grid__content').first();
    await expect(content).toBeVisible();
    const geometry = await content.evaluate((element) => {
      element.textContent = 'synex-data-grid-long-value-'.repeat(16);
      const style = getComputedStyle(element);
      return {
        clientWidth: element.clientWidth,
        scrollWidth: element.scrollWidth,
        overflow: style.overflow,
        textOverflow: style.textOverflow,
        whiteSpace: style.whiteSpace,
      };
    });
    expect(geometry.scrollWidth).toBeGreaterThan(geometry.clientWidth);
    expect(geometry.overflow).toBe('hidden');
    expect(geometry.textOverflow).toBe('ellipsis');
    expect(geometry.whiteSpace).toBe('nowrap');
  });

  for (const profile of profileVariants) {
    test(`renders the ${profile.name} profile at 1080p`, async ({ page }, testInfo) => {
      test.skip(testInfo.project.name !== '1080p', 'Profile baselines are captured at 1080p.');

      await openDesignLab(page, profile.query);
      if ('attribute' in profile) {
        await expect(page.locator('html')).toHaveAttribute(profile.attribute, profile.value);
      } else {
        await expect.poll(() => page.evaluate(
          (property) => document.documentElement.style.getPropertyValue(property),
          profile.property,
        )).toBe(profile.value);
      }

      await expect(page).toHaveScreenshot(`profile-${profile.name}.png`, {
        fullPage: false,
      });
    });
  }
});
