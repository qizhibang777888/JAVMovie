#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
javdb 内部短 ID  <->  番號  双向解析器

关系本质：
  /v/{SHORT_ID} 是 JavDB 自己数据库里的记录主键（短码，5~7 位 [0-9A-Za-z]，按入库批次生成）；
  "SONE-012" 只是这条记录的一个文本字段（厂商发行番号）。
  两者一对一绑定，但没有任何可从番号算出的算法 —— 只能通过站内索引（search）来查。

用法:
  python3 javdb_id_map.py SONE-012        # 番號 -> 内部 ID
  python3 javdb_id_map.py 35bvyD          # 内部 ID -> 番號
  python3 javdb_id_map.py SONE-010 2a5B9q # 混合批量
"""
import sys, re, urllib.parse, urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
BASE = "https://javdb.com"

BLOCK_RE = re.compile(r'(?=<a href="/v/)')
HREF_RE = re.compile(r'^<a href="/v/([A-Za-z0-9]{4,8})"')
VCODE_RE = re.compile(r'<div class="video-title"><strong>([^<]+)</strong>')
CODE_RE = re.compile(r'<strong>番號:</strong>\s*&nbsp;<span class="value">([^<]*(?:<a[^>]*>[^<]*</a>)?[^<]*)</span>')
TITLE_RE = re.compile(r'<title>([^<]*)</title>')


def field(html, name):
    """抓取 ?panel-block? 里的字段值（番號/日期/片商/發行/系列/演員/導演/時長）"""
    j = html.find(f"<strong>{name}</strong>")
    if j < 0:
        return ""
    seg = html[j:j + 900].split("</div>")[0]
    seg = re.sub(r"<[^>]+>", " ", seg).replace(name, "")
    seg = seg.replace("&nbsp;", " ").replace("&amp;", "&")
    return re.sub(r"\s+", " ", seg).strip()


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", "ignore")


def code_to_ids(code):
    """番號 -> 站内记录 ID 列表(取精确匹配, 顺带返回全部候选)"""
    html = get(f"{BASE}/search?q={urllib.parse.quote(code)}&f=all")
    pairs = []
    for blk in BLOCK_RE.split(html):
        m = HREF_RE.match(blk)
        if not m:
            continue
        c = VCODE_RE.search(blk)
        if c:
            pairs.append((m.group(1), c.group(1).strip()))
    seen, uniq = set(), []
    for i, c in pairs:
        if (i, c) not in seen:
            seen.add((i, c)); uniq.append((i, c))
    exact = [(i, c) for i, c in uniq if c.lower() == code.lower()]
    return exact, uniq


def id_to_code(sid):
    """站内记录 ID -> (番號, 标题, 详情dict)"""
    html = get(f"{BASE}/v/{sid}")
    m = CODE_RE.search(html)
    code = re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else ""
    t = TITLE_RE.search(html)
    title = t.group(1).split("|")[0].strip() if t else ""
    detail = {k: field(html, k + ":") for k in ("日期", "片商", "發行", "系列", "演員", "導演", "時長")}
    return code, title, detail


def look(tok):
    print(f"\n== 输入: {tok}")
    if re.fullmatch(r"[A-Za-z0-9]{4,8}", tok) and re.search(r"[A-Za-z]", tok) and re.search(r"\d", tok) \
            and len(tok) <= 7 and not re.fullmatch(r"[A-Z]+-\d+", tok):
        code, title, d = id_to_code(tok)
        print(f"   记录 ID : {tok}   ->  https://javdb.com/v/{tok}")
        print(f"   番號    : {code or '(未取到)'}")
        print(f"   片商/日期: {d.get('片商') or d.get('發行') or '-'} / {d.get('日期','')}")
        print(f"   标题    : {title[:80]}")
        print(f"   站内索引: {BASE}/search?q={urllib.parse.quote(code)}" if code else "")
    else:
        exact, pairs = code_to_ids(tok)
        if exact:
            for sid, code in exact:
                print(f"   番號    : {code}   ->  记录 ID {sid}   https://javdb.com/v/{sid}")
                if len(exact) > 1:
                    c2, t2, d2 = id_to_code(sid)
                    print(f"             片商={d2.get('片商') or d2.get('發行') or '-'}  日期={d2.get('日期','')}  "
                          f"時長={d2.get('時長','')}  演員={d2.get('演員','')[:40]}")
                    print(f"             标题={t2[:70]}")
        else:
            print(f"   站内精确匹配 0 条；候选: {[c for _, c in pairs][:8]}")
        if len(exact) > 1:
            print(f"   ! 同一番號命中 {len(exact)} 条记录（不同版本/不同链接各占一个 ID）")
        # 同批次邻居：前缀相同说明该批入库时间接近
        if exact:
            sid = exact[0][0]
            pref = sid[:-2]
            near = [(i, c) for i, c in pairs if i.startswith(pref) and i != sid]
            if near:
                print(f"   同前缀批次邻居({pref}*): {near[:6]}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)
    for t in sys.argv[1:]:
        try:
            look(t.strip())
        except Exception as e:
            print(f"   ERROR {t}: {e}")
