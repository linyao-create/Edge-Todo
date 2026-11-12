import { readFileSync, writeFileSync } from 'node:fs';

const name = '存当前页到随记';
const source = readFileSync(new URL('./bookmarklet.js', import.meta.url), 'utf8');
const bookmarklet = 'javascript:' + source.trim().split(/\r?\n/).map(line => line.trim()).join(' ');
const escapeHTML = value => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const attribute = escapeHTML(bookmarklet);

writeFileSync(new URL('./edge-favorites.html', import.meta.url), `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Edge Todo</TITLE>
<H1>Edge Todo</H1>
<DL><p>
  <DT><A HREF="${attribute}">${name}</A>
</DL><p>
`);

writeFileSync(new URL('./install.html', import.meta.url), `<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>在 Edge 工具栏添加「${name}」</title>
<style>
body{margin:0;background:#f5f7fa;color:#243442;font:16px/1.8 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:660px;margin:64px auto;padding:32px;background:white;border:1px solid #dbe3e9;border-radius:20px}
h1{font-size:24px;margin:0 0 12px}p{margin:12px 0;color:#536575}a#capture{display:inline-block;background:#e6f2ff;color:#1264ba;border:1px solid #9fc9f4;border-radius:8px;padding:9px 18px;text-decoration:none;font-weight:600;margin:12px 0}
ol{padding-left:24px}textarea{box-sizing:border-box;width:100%;min-height:100px;border:1px solid #dbe3e9;border-radius:8px;padding:12px;font:12px/1.5 monospace}summary{cursor:pointer;color:#536575}
@media(max-width:700px){main{margin:16px;padding:24px}}
</style>
<main><h1>把当前网页存到随记</h1>
<p>把 Edge Todo 图标固定在地址栏右侧，和收藏星标放在同一区域。以后点击图标，当前网页的标题和完整链接就会进入 Mac 的随记。</p>
<ol><li>先安装并打开支持浏览器接收功能的 Mac 版 EdgeTodo.app。</li><li>打开 Edge 的 <code>edge://extensions</code>，开启「开发人员模式」。</li><li>点击「加载解压缩的扩展」，选择此项目的 <code>browser/extension</code> 文件夹。</li><li>在地址栏右侧的扩展菜单中，找到「Edge Todo：存当前页到随记」，选择「在工具栏中显示」。</li><li>打开普通网页，单击蓝色随记图标。</li></ol>
<p>图标显示在地址栏右侧的扩展工具栏，不能放进 Edge 原生收藏星标所在的地址栏内部。首次使用时，Edge 可能询问是否打开 Edge Todo；请确认。保存成功后，Mac 随记面板会显示新条目。</p>
<p>只保存页面标题和完整链接，不收录图片、视频或全文。<code>edge://</code>、新标签页和本地文件等页面不能保存；图标上的感叹号表示扩展无法发起请求，可将鼠标移到图标上查看原因。</p>
<details><summary>备用：使用收藏夹栏按钮</summary><p>不安装扩展时，也可以把下方按钮拖到 Edge 收藏夹栏；按 Command + Shift + B 可显示收藏夹栏。旧按钮仍可使用。</p><a id="capture" draggable="true" href="${attribute}">${name}</a><p>还可以新建收藏夹，名称填「${name}」，网址粘贴下方内容；或在收藏夹管理页导入同目录的 edge-favorites.html。</p><textarea readonly aria-label="收藏夹网址">${escapeHTML(bookmarklet)}</textarea></details>
</main></html>
`);
console.log('Built browser/install.html and browser/edge-favorites.html');
