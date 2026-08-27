const resourceName = GetParentResourceName();

export async function postNui(route, payload = {}, timeout = 5000) {
  const controller = timeout > 0 ? new AbortController() : null;
  const timeoutId = controller ? window.setTimeout(() => controller.abort(), timeout) : null;
  try {
    const response = await fetch(`https://${resourceName}/${route}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(payload),
      signal: controller?.signal,
    });
    if (!response.ok) return { ok: false, error: { code: 'NUI_HTTP_ERROR' } };
    const value = await response.json();
    return value && typeof value === 'object'
      ? value
      : { ok: false, error: { code: 'NUI_RESPONSE_INVALID' } };
  } catch {
    return { ok: false, error: { code: 'NUI_UNAVAILABLE' } };
  } finally {
    if (timeoutId !== null) window.clearTimeout(timeoutId);
  }
}

export function callbackCode(response) {
  if (response?.ok === true) return null;
  if (typeof response?.error === 'string') return response.error;
  return typeof response?.error?.code === 'string' ? response.error.code : 'NUI_UNAVAILABLE';
}
