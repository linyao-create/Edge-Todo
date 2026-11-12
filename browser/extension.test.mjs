import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('./extension/background.js', import.meta.url), 'utf8');

function loadExtension({ injectionError } = {}) {
  let onClick;
  let nextID = 0;
  const injections = [];
  const badges = [];
  const titles = [];
  const chrome = {
    action: {
      onClicked: { addListener(listener) { onClick = listener; } },
      setBadgeText(value) { badges.push(value); return Promise.resolve(); },
      setBadgeBackgroundColor() { return Promise.resolve(); },
      setTitle(value) { titles.push(value); return Promise.resolve(); },
    },
    scripting: {
      async executeScript(value) {
        injections.push(value);
        if (injectionError) throw injectionError;
      },
    },
  };
  runInNewContext(source, {
    chrome, URL, encodeURIComponent, TextEncoder,
    crypto: { randomUUID: () => `76bc0073-6ab4-4b35-a4f6-${String(++nextID).padStart(12, '0')}` },
  });
  assert.equal(typeof onClick, 'function');
  return { click: tab => onClick(tab), injections, badges, titles };
}

test('click passes the current title and complete URL to Edge Todo', async () => {
  const extension = loadExtension();
  const page = 'https://www.xiaohongshu.com/explore/note?xsec_token=a+b%2Fc#评论';
  await extension.click({ id: 7, title: '花 & 灵感 + 🌸', url: page });

  assert.equal(extension.injections.length, 1);
  assert.equal(extension.injections[0].target.tabId, 7);
  const destination = extension.injections[0].args[0];
  const request = new URL(destination);
  assert.equal(request.protocol, 'edgetodo:');
  assert.equal(request.hostname, 'capture');
  assert.equal(request.searchParams.get('title'), '花 & 灵感 + 🌸');
  assert.equal(request.searchParams.get('url'), page);
  assert.match(request.searchParams.get('id'), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.ok(!destination.includes('+'), 'literal plus and spaces must be percent encoded');
  const pageContext = { window: { location: { href: page } } };
  runInNewContext(`(${extension.injections[0].func.toString()})(destination)`, {
    ...pageContext, destination,
  });
  assert.equal(pageContext.window.location.href, destination);
  assert.ok(!extension.badges.some(value => value.text === '✓'), 'injection cannot prove native save succeeded');
});

test('each click gets a new request ID while keeping the page unchanged', async () => {
  const extension = loadExtension();
  const tab = { id: 1, title: '示例', url: 'https://example.com/note' };
  await extension.click(tab);
  await extension.click(tab);
  assert.equal(extension.injections.length, 2);
  assert.notEqual(new URL(extension.injections[0].args[0]).searchParams.get('id'),
    new URL(extension.injections[1].args[0]).searchParams.get('id'));
  assert.equal(tab.url, 'https://example.com/note');
});

test('protected and non-web pages never launch the Mac app', async () => {
  const extension = loadExtension();
  for (const url of ['edge://settings', 'file:///private/test.html', 'about:blank']) {
    await extension.click({ id: 2, title: '页面', url });
  }
  assert.equal(extension.injections.length, 0);
  assert.equal(extension.badges.filter(value => value.text === '!').length, 3);
});

test('injection failure is visible and is not marked as saved', async () => {
  const extension = loadExtension({ injectionError: new Error('Cannot access contents of url') });
  await extension.click({ id: 3, title: '页面', url: 'https://example.com' });
  assert.equal(extension.injections.length, 1);
  assert.ok(extension.badges.some(value => value.text === '!'));
  assert.ok(extension.titles.some(value => /无法|失败/.test(value.title)));
  assert.ok(!extension.badges.some(value => value.text === '✓'));
});

test('missing tab and invalid URL never issue a save request', async () => {
  const extension = loadExtension();
  await extension.click({ title: '无标签', url: 'https://example.com' });
  await extension.click({ id: 4, title: '无链接' });
  await extension.click({ id: 4, title: '错误链接', url: 'not a URL' });
  assert.equal(extension.injections.length, 0);
  assert.equal(extension.badges.filter(value => value.text === '!').length, 3);
  assert.ok(extension.titles.some(value => /网页标签/.test(value.title)));
  assert.ok(extension.titles.some(value => /网页链接|链接无效/.test(value.title)));
});

test('oversized capture URL is rejected before crossing into the Mac app', async () => {
  const extension = loadExtension();
  await extension.click({ id: 5, title: '很长的链接', url: `https://example.com/${'a'.repeat(66_000)}` });
  assert.equal(extension.injections.length, 0);
  assert.ok(extension.badges.some(value => value.text === '!'));
  assert.ok(extension.titles.some(value => /过长/.test(value.title)));
});

test('short tooltip is used initially and restored after a click', async () => {
  const manifest = JSON.parse(readFileSync(new URL('./extension/manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.action.default_title, '存入随记');
  const extension = loadExtension();
  await extension.click({ id: 1, title: '示例', url: 'https://example.com' });
  assert.equal(extension.titles.at(-1).title, '存入随记');
});
