import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./bookmarklet.js', import.meta.url), 'utf8');
function clickBookmark(pageURL, title, useFallbackID = false) {
  let destination;
  const messages = [];
  const location = { get href() { return pageURL; }, set href(value) { destination = value; } };
  const id = '76bc0073-6ab4-4b35-a4f6-449a140c4383';
  const crypto = useFallbackID ? { getRandomValues: bytes => bytes.fill(7) } : { randomUUID: () => id };
  runInNewContext(source, { window: { location }, document: { title }, URL, Uint8Array,
    crypto, encodeURIComponent, alert: text => messages.push(text) });
  return { destination, messages, id };
}

test('one click sends the current title and complete URL directly to Edge Todo', () => {
  const page = 'https://www.xiaohongshu.com/explore/note?xsec_token=a+b%2Fc&xsec_source=pc_user#comments';
  const title = '花 与灵感 ++ & 100% 🌸';
  const result = clickBookmark(page, title);
  const request = new URL(result.destination);
  assert.equal(request.protocol, 'edgetodo:');
  assert.equal(request.hostname, 'capture');
  assert.equal(request.searchParams.get('title'), title);
  assert.equal(request.searchParams.get('url'), page);
  assert.equal(request.searchParams.get('id'), result.id);
  assert.ok(!result.destination.includes('+'), 'use percent encoding so Swift preserves spaces and literal plus signs');
});

test('non-web pages never launch Edge Todo with an unusable URL', () => {
  for (const page of ['file:///private/test.html', 'edge://settings', 'about:blank']) {
    const result = clickBookmark(page, '页面');
    assert.equal(result.destination, undefined);
    assert.equal(result.messages.length, 1);
  }
});

test('ordinary HTTP pages also work when randomUUID requires a secure context', () => {
  const result = clickBookmark('http://example.com/note', '普通网页', true);
  const request = new URL(result.destination);
  assert.match(request.searchParams.get('id'), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
