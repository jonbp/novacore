<?xml version="1.0" encoding="utf-8"?>
<!--
  Directory listings for sites, in the style of the Novacore dashboard.

  Vhosts set `autoindex_format xml` for folders without an index file and run
  nginx's XML through this stylesheet. Parameters, from xslt_string_param:
    path  the request path, e.g. /assets/img/
    host  the site's domain
-->
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:str="http://exslt.org/strings"
    extension-element-prefixes="str">

<xsl:output method="html" encoding="utf-8" indent="no" doctype-system="about:legacy-compat"/>

<xsl:param name="path" select="'/'"/>
<xsl:param name="host" select="''"/>

<xsl:template match="/list">
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title><xsl:value-of select="$host"/><xsl:value-of select="$path"/></title>
<link rel="icon" href="/__novacore/novacore.svg" type="image/svg+xml"/>
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #f6f6f4; --card: #fff; --muted: #6b6b6b; --line: #e2e2df; --hover: #f0f0ed; --accent: #17d4a4; --link: #0b8f6d; --folder: #0b8f6d; }
  @media (prefers-color-scheme: dark) { :root { --fg: #ececec; --bg: #131615; --card: #1b1f1e; --muted: #9a9a9a; --line: #2c3331; --hover: #222826; --link: #17d4a4; --folder: #17d4a4; } }
  * { box-sizing: border-box; }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  body { font: 16px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 1120px; margin: 0 auto; padding: 48px 16px; }
  header { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 12px 24px; margin-bottom: 20px; }
  .host { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin: 0 0 4px; }
  .host a { color: inherit; font-weight: 600; }
  h1 { margin: 0; font-size: 1.6rem; letter-spacing: -0.02em; font-weight: 700; overflow-wrap: anywhere; }
  h1 a { color: var(--muted); font-weight: 600; }
  h1 .sep, h1 .root { margin-right: 0.2em; }
  h1 .sep { color: var(--muted); margin-left: 0.2em; font-weight: 400; }
  h1 .here { color: var(--link); }
  .filter { font: inherit; font-size: 0.92rem; color: var(--fg); background: var(--card); border: 1px solid var(--line); padding: 7px 12px; width: 240px; max-width: 100%; outline: none; }
  .filter:focus { border-color: var(--accent); }
  .wrap { background: var(--card); border: 1px solid var(--line); border-left: 3px solid var(--accent); }
  table { width: 100%; border-collapse: collapse; table-layout: fixed; }
  th { text-align: left; font-size: 0.8rem; font-weight: 600; color: var(--muted); padding: 10px 16px; border-bottom: 1px solid var(--line); user-select: none; }
  th button { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: 4px; }
  th button:hover, th button:focus-visible { color: var(--fg); }
  th.size button { flex-direction: row-reverse; }
  th button span { display: block; }
  th svg.arrow { display: block; width: 11px; height: 11px; overflow: visible; color: var(--accent); opacity: 0; transform: rotate(-90deg); transition: transform 0.15s, opacity 0.15s; }
  th button:hover svg.arrow, th button:focus-visible svg.arrow { opacity: 0.4; }
  th[aria-sort] svg.arrow { opacity: 1; }
  th[aria-sort="descending"] svg.arrow { transform: rotate(90deg); }
  svg.back { width: 14px; height: 14px; margin: 0 2px; overflow: visible; transform: rotate(180deg); }
  td { padding: 0 16px; border-bottom: 1px solid var(--line); white-space: nowrap; }
  tr:last-child td { border-bottom: 0; }
  tbody tr:hover { background: var(--hover); }
  .size, .date { color: var(--muted); font-size: 0.88rem; font-variant-numeric: tabular-nums; }
  th.size, td.size { width: 110px; text-align: right; }
  th.date, td.date { width: 190px; }
  td.name { overflow: hidden; text-overflow: ellipsis; }
  td.name a { display: flex; align-items: center; gap: 10px; padding: 9px 0; color: var(--fg); text-decoration: none; }
  td.name a span { overflow: hidden; text-overflow: ellipsis; }
  td.name a:hover span { color: var(--link); text-decoration: underline; }
  tr.dir td.name a { font-weight: 600; }
  svg { flex: none; width: 18px; height: 18px; }
  tr.dir svg { color: var(--folder); }
  tr.file svg { color: var(--muted); }
  .empty td { padding: 28px 16px; color: var(--muted); text-align: center; }
  footer { margin-top: 16px; color: var(--muted); font-size: 0.85rem; }
  code { font: 0.88em ui-monospace, SFMono-Regular, Menlo, monospace; }
  @media (max-width: 640px) {
    body { padding-top: 28px; }
    th.date, td.date { display: none; }
    th.size, td.size { width: 84px; }
    td, th { padding-left: 12px; padding-right: 12px; }
    .filter { width: 100%; }
  }
</style>
</head>
<body>
<header>
  <div>
    <p class="host"><a href="/"><xsl:value-of select="$host"/></a></p>
    <h1><xsl:call-template name="crumbs"/></h1>
  </div>
  <xsl:if test="count(*) &gt; 0">
    <input class="filter" type="search" placeholder="Filter  ( / )" aria-label="Filter files" autocomplete="off" spellcheck="false"/>
  </xsl:if>
</header>

<div class="wrap"><table>
<thead><tr>
  <th class="name" aria-sort="ascending"><button type="button" data-key="name"><span>Name</span><svg class="arrow" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1 9L17 9L9 1M12.8 13.2L9 17"/></svg></button></th>
  <th class="size"><button type="button" data-key="size"><span>Size</span><svg class="arrow" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1 9L17 9L9 1M12.8 13.2L9 17"/></svg></button></th>
  <th class="date"><button type="button" data-key="mtime"><span>Modified</span><svg class="arrow" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1 9L17 9L9 1M12.8 13.2L9 17"/></svg></button></th>
</tr></thead>
<tbody>
  <xsl:if test="$path != '/'">
    <tr class="dir up"><td class="name"><a href="../"><svg class="back" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 9L17 9L9 1M12.8 13.2L9 17"/></svg><span>Parent folder</span></a></td><td class="size"></td><td class="date"></td></tr>
  </xsl:if>
  <xsl:apply-templates select="directory"/>
  <xsl:apply-templates select="file"/>
  <xsl:if test="count(*) = 0">
    <tr class="empty"><td colspan="3">This folder is empty.</td></tr>
  </xsl:if>
  <tr class="empty nomatch" hidden="hidden"><td colspan="3">Nothing matches.</td></tr>
</tbody>
</table></div>

<footer>
  <xsl:value-of select="count(directory)"/>
  <xsl:choose><xsl:when test="count(directory) = 1"> folder, </xsl:when><xsl:otherwise> folders, </xsl:otherwise></xsl:choose>
  <xsl:value-of select="count(file)"/>
  <xsl:choose><xsl:when test="count(file) = 1"> file</xsl:when><xsl:otherwise> files</xsl:otherwise></xsl:choose>
  <xsl:if test="file"> · <xsl:call-template name="size"><xsl:with-param name="bytes" select="sum(file/@size)"/></xsl:call-template></xsl:if>
  · Add an <code>index.php</code> or <code>index.html</code> to show a page here instead.
</footer>

<script><![CDATA[
(() => {
  const tbody = document.querySelector("tbody");
  const rows = [...tbody.querySelectorAll("tr[data-name]")];
  const nomatch = tbody.querySelector(".nomatch");
  const filter = document.querySelector(".filter");

  // Modified times arrive in UTC; show them in local time.
  const fmt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
  for (const td of document.querySelectorAll("td.date[data-mtime]")) {
    const d = new Date(td.dataset.mtime);
    if (!isNaN(d)) { td.textContent = fmt.format(d); td.title = d.toString(); }
  }

  // Sort by column, folders always first.
  let key = "name", dir = 1;
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  function sort() {
    rows.sort((a, b) => {
      const da = a.classList.contains("dir"), db = b.classList.contains("dir");
      if (da !== db) return da ? -1 : 1;
      let c = key === "name" ? collator.compare(a.dataset.name, b.dataset.name)
            : key === "size" ? (+a.dataset.size) - (+b.dataset.size)
            : a.dataset.mtime.localeCompare(b.dataset.mtime);
      if (c === 0 && key !== "name") c = collator.compare(a.dataset.name, b.dataset.name);
      return c * dir;
    });
    for (const r of rows) tbody.insertBefore(r, nomatch);
    for (const th of document.querySelectorAll("th")) {
      const k = th.querySelector("button").dataset.key;
      if (k === key) th.setAttribute("aria-sort", dir > 0 ? "ascending" : "descending");
      else th.removeAttribute("aria-sort");
    }
  }
  for (const b of document.querySelectorAll("th button")) {
    b.addEventListener("click", () => {
      if (b.dataset.key === key) dir = -dir;
      else { key = b.dataset.key; dir = key === "name" ? 1 : -1; }
      sort();
    });
  }
  sort();

  if (!filter) return;
  function apply() {
    const q = filter.value.trim().toLowerCase();
    let shown = 0;
    for (const r of rows) {
      const hit = !q || r.dataset.name.toLowerCase().includes(q);
      r.hidden = !hit;
      if (hit) shown++;
    }
    nomatch.hidden = shown > 0;
  }
  filter.addEventListener("input", apply);
  filter.addEventListener("keydown", e => {
    if (e.key === "Escape") { filter.value = ""; apply(); filter.blur(); }
    if (e.key === "Enter") {
      const first = rows.find(r => !r.hidden);
      if (first) first.querySelector("a").click();
    }
  });
  document.addEventListener("keydown", e => {
    if (e.key === "/" && document.activeElement !== filter) { e.preventDefault(); filter.focus(); }
  });
})();
]]></script>
</body>
</html>
</xsl:template>

<xsl:template match="directory">
  <tr class="dir" data-name="{.}" data-size="-1" data-mtime="{@mtime}">
    <td class="name"><a href="{str:encode-uri(., true())}/"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M1.5 4A1.5 1.5 0 0 1 3 2.5h3l1.5 1.5H13A1.5 1.5 0 0 1 14.5 5.5v7A1.5 1.5 0 0 1 13 14H3a1.5 1.5 0 0 1-1.5-1.5z"/><path d="M1.5 6.5h13"/></svg><span><xsl:value-of select="."/></span></a></td>
    <td class="size">—</td>
    <xsl:call-template name="date-cell"/>
  </tr>
</xsl:template>

<xsl:template match="file">
  <tr class="file" data-name="{.}" data-size="{@size}" data-mtime="{@mtime}">
    <td class="name"><a href="{str:encode-uri(., true())}"><xsl:call-template name="file-icon"/><span><xsl:value-of select="."/></span></a></td>
    <td class="size" title="{format-number(@size, '#,##0')} bytes"><xsl:call-template name="size"><xsl:with-param name="bytes" select="@size"/></xsl:call-template></td>
    <xsl:call-template name="date-cell"/>
  </tr>
</xsl:template>

<!-- A line icon for a handful of common web files, by extension; a plain page otherwise. -->
<xsl:template name="file-icon">
  <xsl:variable name="ext">
    <xsl:if test="contains(substring(., 2), '.')">
      <xsl:value-of select="translate(str:tokenize(., '.')[last()], 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"/>
    </xsl:if>
  </xsl:variable>
  <xsl:variable name="key" select="concat('|', $ext, '|')"/>
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <xsl:choose>
      <xsl:when test="$ext != '' and contains('|png|jpg|jpeg|gif|webp|avif|svg|ico|bmp|', $key)">
        <xsl:attribute name="class">icon-image</xsl:attribute>
        <path d="M2 3.5A1.5 1.5 0 0 1 3.5 2h9A1.5 1.5 0 0 1 14 3.5v9a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 12.5z"/><circle cx="10.5" cy="5.5" r="1.2"/><path d="M2 11.5l3.5-3.5 3 3 1.5-1.5 4 4"/>
      </xsl:when>
      <xsl:when test="$ext != '' and contains('|php|js|mjs|ts|css|scss|html|htm|json|xml|', $key)">
        <xsl:attribute name="class">icon-code</xsl:attribute>
        <path d="M3.5 1.5h5.5l3.5 3.5v9.5h-9z"/><path d="M9 1.5V5h3.5"/><path d="M6.5 8 5 9.75l1.5 1.75M9.5 8l1.5 1.75-1.5 1.75"/>
      </xsl:when>
      <xsl:when test="$ext != '' and contains('|zip|gz|tgz|tar|rar|7z|bz2|', $key)">
        <xsl:attribute name="class">icon-archive</xsl:attribute>
        <path d="M3.5 1.5h5.5l3.5 3.5v9.5h-9z"/><path d="M9 1.5V5h3.5"/><path d="M6.5 3v.5M6.5 5v.5M6.5 7v.5"/><path d="M5.5 9.5h2v2.5h-2z"/>
      </xsl:when>
      <xsl:when test="$ext != '' and contains('|txt|md|log|csv|sql|', $key)">
        <xsl:attribute name="class">icon-text</xsl:attribute>
        <path d="M3.5 1.5h5.5l3.5 3.5v9.5h-9z"/><path d="M9 1.5V5h3.5"/><path d="M5.5 8h3M5.5 10h5M5.5 12h5"/>
      </xsl:when>
      <xsl:otherwise>
        <path d="M3.5 1.5h5.5l3.5 3.5v9.5h-9z"/><path d="M9 1.5V5h3.5"/>
      </xsl:otherwise>
    </xsl:choose>
  </svg>
</xsl:template>

<!-- nginx gives mtime as 2026-11-09T14:38:12Z; shown as UTC until the script localises it. -->
<xsl:template name="date-cell">
  <td class="date" data-mtime="{@mtime}">
    <xsl:value-of select="substring(@mtime, 1, 10)"/>
    <xsl:text> </xsl:text>
    <xsl:value-of select="substring(@mtime, 12, 5)"/>
  </td>
</xsl:template>

<xsl:template name="size">
  <xsl:param name="bytes"/>
  <xsl:choose>
    <xsl:when test="$bytes &lt; 1024"><xsl:value-of select="$bytes"/> B</xsl:when>
    <xsl:when test="$bytes &lt; 1048576"><xsl:value-of select="format-number($bytes div 1024, '0.#')"/> KB</xsl:when>
    <xsl:when test="$bytes &lt; 1073741824"><xsl:value-of select="format-number($bytes div 1048576, '0.#')"/> MB</xsl:when>
    <xsl:otherwise><xsl:value-of select="format-number($bytes div 1073741824, '0.##')"/> GB</xsl:otherwise>
  </xsl:choose>
</xsl:template>

<!-- The path as links: /a/b/c/ → / a / b / c, each leading back up. -->
<xsl:template name="crumbs">
  <xsl:param name="rest" select="substring($path, 2)"/>
  <xsl:param name="href" select="'/'"/>
  <xsl:choose>
    <xsl:when test="$rest = ''"><span class="here">/</span></xsl:when>
    <xsl:otherwise><a class="root" href="/">/</a></xsl:otherwise>
  </xsl:choose>
  <xsl:call-template name="crumb">
    <xsl:with-param name="rest" select="$rest"/>
    <xsl:with-param name="href" select="$href"/>
  </xsl:call-template>
</xsl:template>

<xsl:template name="crumb">
  <xsl:param name="rest"/>
  <xsl:param name="href"/>
  <xsl:if test="$rest != ''">
    <xsl:variable name="part" select="substring-before($rest, '/')"/>
    <xsl:variable name="next" select="substring-after($rest, '/')"/>
    <xsl:variable name="url" select="concat($href, str:encode-uri($part, true()), '/')"/>
    <xsl:if test="$href != '/'"><span class="sep">/</span></xsl:if>
    <xsl:choose>
      <xsl:when test="$next = ''"><span class="here"><xsl:value-of select="$part"/></span></xsl:when>
      <xsl:otherwise><a href="{$url}"><xsl:value-of select="$part"/></a></xsl:otherwise>
    </xsl:choose>
    <xsl:call-template name="crumb">
      <xsl:with-param name="rest" select="$next"/>
      <xsl:with-param name="href" select="$url"/>
    </xsl:call-template>
  </xsl:if>
</xsl:template>

</xsl:stylesheet>
