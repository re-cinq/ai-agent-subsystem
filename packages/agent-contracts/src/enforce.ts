// D-style std.exception bouncers: either the condition holds or you're thrown
// out on the spot. No polite if-throw ceremonies.

/** Throws unless `value` is truthy, returns the narrowed value (like D's `enforce`). */
export function enforce<T>(value: T, message: string): NonNullable<T> {
  if (!value) throw new Error(message);
  return value as NonNullable<T>;
}

/** Throws unless the response status is 2xx; returns the body on success. */
export function enforceHTTPSuccess(res: { status: number; body: unknown }): unknown {
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`kube request failed (${res.status}): ${JSON.stringify(res.body)}`);
  }
  return res.body;
}
