(() => {
  const page = new URL(window.location.href);
  if (!['http:', 'https:'].includes(page.protocol)) {
    alert('请先打开要保存的网页，再点击「存当前页到随记」。');
    return;
  }
  let id;
  if (typeof crypto.randomUUID === 'function') {
    id = crypto.randomUUID();
  } else {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('');
    id = hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16)
      + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
  }
  window.location.href = 'edgetodo://capture?id=' + encodeURIComponent(id)
    + '&title=' + encodeURIComponent(document.title.trim())
    + '&url=' + encodeURIComponent(page.href);
})();
