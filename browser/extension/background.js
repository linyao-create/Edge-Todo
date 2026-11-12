const actionTitle = '存入随记';

function buildCaptureURL(tab, id = crypto.randomUUID()) {
  if (!tab?.url) throw new Error('请先打开要保存的网页');
  let page;
  try {
    page = new URL(tab.url);
  } catch {
    throw new Error('当前网页链接无效');
  }
  if (!['http:', 'https:'].includes(page.protocol) || !page.hostname) {
    throw new Error('请在普通网页使用这个按钮');
  }
  const destination = 'edgetodo://capture?id=' + encodeURIComponent(id)
    + '&title=' + encodeURIComponent((tab.title ?? '').trim())
    + '&url=' + encodeURIComponent(tab.url);
  if (new TextEncoder().encode(destination).length > 65_536) {
    throw new Error('当前网页链接过长，无法保存');
  }
  return destination;
}

async function showFailure(tab, message) {
  const target = Number.isInteger(tab?.id) ? { tabId: tab.id } : {};
  await Promise.all([
    chrome.action.setBadgeBackgroundColor({ ...target, color: '#B42318' }),
    chrome.action.setBadgeText({ ...target, text: '!' }),
    chrome.action.setTitle({ ...target, title: `保存失败：${message}` }),
  ]);
}

async function captureTab(tab) {
  try {
    if (!Number.isInteger(tab?.id)) throw new Error('没有可用的网页标签');
    const destination = buildCaptureURL(tab);
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: target => { window.location.href = target; },
      args: [destination],
    });
    await Promise.all([
      chrome.action.setBadgeText({ tabId: tab.id, text: '' }),
      chrome.action.setTitle({ tabId: tab.id, title: actionTitle }),
    ]);
  } catch (error) {
    await showFailure(tab, error instanceof Error ? error.message : String(error));
  }
}

chrome.action.onClicked.addListener(captureTab);
