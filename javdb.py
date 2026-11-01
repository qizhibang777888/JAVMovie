#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
javdb.py —— 一条龙：本地目录  →  番号  →  JavDB 短链  →  封面 / 剧照 / 元数据

原来两个脚本（javdb_links.py 转链接、javdb_covers.py 下封面+元数据）已合并到这里：

  目录/文件名  DLDSS-325-C
      └─ 番号   DLDSS-325
          └─ 短链 https://javdb.com/v/OXXVGz          （站内搜索，精确匹配）
              ├─ FM.jpg           封面（<img class="video-cover">，CDN 直拼兜底）
              ├─ T-01.jpg … T-20.jpg  剧照（<a class="tile-item"> 里的图，数量不定）
              └─ TX.json          番號/發行/評分/類別/演員/页面地址 …

  汇总输出：<out>/links.md  links.csv  javdb_meta.json  covers_report.csv

用法:
  python3 javdb.py /Volumes/US202/1101                    # 一条龙（增量，已有就跳过）
  python3 javdb.py /Volumes/US202/1101 --force             # 全部重抓
  python3 javdb.py /Volumes/US202/1101 --links-only        # 只出链接表，不下载任何图
  python3 javdb.py /Volumes/US202/1101 --no-samples        # 不要剧照
  python3 javdb.py /Volumes/US202/1101 --no-covers         # 不要封面
  python3 javdb.py /Volumes/US202/1101 --no-meta           # 不抓字段（只下图）
  python3 javdb.py /Volumes/US202/1101 --no-per-folder     # 不写每夹 TX.json
  python3 javdb.py /Volumes/US202/1101 --sample-size s --sample-name TT
  python3 javdb.py /Volumes/US202/1101 --dry-run           # 只报告要做什么
"""
import argparse
import csv
import html as htmllib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = 'https://javdb.com'
CDN = 'https://c0.jdbstatic.com'
UA = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
COOKIE = ''          # 由 --cookie 注入，过 Cloudflare 挑战用
PROXY = ''           # 由 --proxy 注入，形如 http://127.0.0.1:7890
_OPENER = None


def _opener():
    global _OPENER
    if _OPENER is None:
        if PROXY:
            _OPENER = urllib.request.build_opener(
                urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY}))
        else:
            _OPENER = urllib.request.build_opener()
    return _OPENER


def reset_opener():
    global _OPENER
    _OPENER = None
VIDEO_EXT = {'.mp4', '.mkv', '.avi', '.mov', '.wmv', '.ts', '.m4v', '.webm', '.flv', '.iso', '.rmvb'}
HERE = os.path.dirname(os.path.abspath(__file__))

_lock = threading.Lock()
PAGE_FETCHES = [0]          # 本次运行真正请求详情页的次数


def count_page():
    with _lock:
        PAGE_FETCHES[0] += 1


# ═══════════════════════════ 1. 名字 → 番号 ═══════════════════════════
def clean_name(name):
    """剥掉站名前缀、扩展名、-C/-UC/-4k/(1) 之类的副本标记"""
    base = re.sub(r'\.[A-Za-z0-9]{2,5}$', '', name)
    base = re.sub(r'^\[[^\]]*\]\s*', '', base)
    base = re.sub(r'^[^@\s]*(?:\.com|\.net|\.tv|\.org|\.cc)@\s*', '', base, flags=re.I)
    base = re.sub(r'^(?:hhd800|www)\.?[^@\s]*-', '', base, flags=re.I)
    base = re.sub(r'\s*\(\d+\)$', '', base)
    return base.strip()


def extract_code(name):
    work = clean_name(name)
    m = re.search(r'([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?!\d)', work)
    return (f'{m.group(1).upper()}-{m.group(2)}' if m else ''), work


# ═══════════════════════════ 2. HTTP ═══════════════════════════
def http_get(url, tries=6, timeout=30, referer=None):
    last = None
    for n in range(tries):
        try:
            hdr = {'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9'}
            if COOKIE:
                hdr['Cookie'] = COOKIE
            if referer:
                hdr['Referer'] = referer
            with _opener().open(urllib.request.Request(url, headers=hdr), timeout=timeout) as r:
                return r.read(), r.headers.get('Content-Type', '')
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 403:
                # Cloudflare 挑战：重试没意义，快速失败并把原因说清楚
                if n == 0:
                    print('🚫 403 Forbidden（Cloudflare 挑战）—— 用 --cookie 或 --proxy 再试', flush=True)
                raise
            if e.code in (429, 503):
                wait = int(e.headers.get('Retry-After') or 0) or min(3 * (2 ** n), 25)
                time.sleep(wait)
                continue
            if e.code == 404:
                raise
        except Exception as e:
            last = e
            time.sleep(1.5 * (n + 1))
    raise last


# ═══════════════════════════ 3. 番号 → 短 ID（站内搜索） ═══════════════════════════
BLOCK = re.compile(r'(?=<a href="/v/)')
HREF = re.compile(r'^<a href="/v/([A-Za-z0-9]{4,8})"')
VCODE = re.compile(r'<div class="video-title"><strong>([^<]+)</strong>')


def search_id(code):
    """返回 (id, 搜索结果列表[(id, code, title)])"""
    data, _ = http_get(f'{BASE}/search?q={urllib.parse.quote(code)}&f=all')
    html = data.decode('utf-8', 'ignore')
    hits = []
    for blk in BLOCK.split(html):
        m, c = HREF.match(blk), VCODE.search(blk)
        if not (m and c):
            continue
        seg = blk[c.end():blk.find('</div>', c.end())]
        title = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', seg)).strip()
        hits.append((m.group(1), c.group(1).strip(), title))
    exact = [h for h in hits if h[1].lower() == code.lower()]
    return (exact[0][0] if exact else ''), exact


# ═══════════════════════════ 4. 详情页 → 封面 / 剧照 / 字段 ═══════════════════════════
COVER_IMG = re.compile(r'<img[^>]*class="video-cover"[^>]*?src="([^"]+)"', re.I)
COVER_IMG2 = re.compile(r'<img[^>]*src="([^"]+)"[^>]*class="video-cover"', re.I)
COVER_ANY = re.compile(r'(https?://[^"\']+/covers/[a-z0-9]{2}/[A-Za-z0-9]{4,8}\.(?:jpg|jpeg|webp|png))')
TITLE_RE = re.compile(r'<title>([^<]*)</title>')
TILE_ANCHOR = re.compile(r'<a[^>]*class="tile-item"[^>]*>([\s\S]*?)</a>', re.I)
TILE_HREF = re.compile(r'href="([^"]+)"', re.I)
TILE_IMG = re.compile(r'<img[^>]*?src="([^"]+)"', re.I)
FIELDS = ('番號', '標題', '日期', '時長', '發行', '片商', '系列', '導演',
          '評分', '評分人數', '類別', '演員', '封面地址', '页面地址', '預覽圖', '預覽圖_縮略')


def unesc(s):
    return re.sub(r'\s+', ' ', htmllib.unescape(s or '')).strip(' ,\u00a0')


def parse_panels(html):
    out = {}
    for chunk in html.split('<div class="panel-block')[1:]:
        m = re.search(r'<strong>(.*?)</strong>', chunk, re.S)
        if not m:
            continue
        label = unesc(re.sub(r'<[^>]+>', '', m.group(1))).rstrip(':：')
        body = chunk[m.end():].split('<div class="panel-block')[0]
        out.setdefault(label, unesc(re.sub(r'<[^>]+>', ' ', body)))
    return out


def parse_detail(html, sid):
    panels = parse_panels(html)
    t = TITLE_RE.search(html)
    title = unesc(t.group(1).split('|')[0]) if t else ''

    raw = panels.get('評分', '')
    m = re.search(r'([\d.]+)\s*分', raw)
    score = float(m.group(1)) if m else None
    mv = re.search(r'由\s*(\d+)\s*人評價', raw) or re.search(r'(\d+)\s*人評價', raw)
    votes = int(mv.group(1)) if mv else None

    def split_list(key):
        return [x.strip() for x in re.split(r'[,，]', panels.get(key, '')) if x.strip()]

    cover = ''
    cm = COVER_IMG.search(html) or COVER_IMG2.search(html)
    if cm:
        cover = cm.group(1)
    elif COVER_ANY.search(html):
        cover = COVER_ANY.search(html).group(1)
    if cover.startswith('//'):
        cover = 'https:' + cover

    big, small = [], []
    for am in TILE_ANCHOR.finditer(html):
        anchor, inner = am.group(0), am.group(1)
        hm = TILE_HREF.search(anchor)
        if hm:
            u = hm.group(1)
            if '/samples/' in u or '/covers/' in u:
                big.append('https:' + u if u.startswith('//') else u)
        im = TILE_IMG.search(inner)
        if im and '/samples/' in im.group(1):
            u = im.group(1)
            small.append('https:' + u if u.startswith('//') else u)

    def uniq(seq):
        seen, out = set(), []
        for x in seq:
            if x not in seen:
                seen.add(x)
                out.append(x)
        return out

    return {
        '番號': re.sub(r'\s+', '', panels.get('番號', '')),   # "DLDSS -325" -> "DLDSS-325"
        '標題': title,
        '日期': panels.get('日期', ''),
        '時長': panels.get('時長', ''),
        '發行': panels.get('發行', '') or panels.get('片商', ''),
        '片商': panels.get('片商', ''),
        '系列': panels.get('系列', ''),
        '導演': panels.get('導演', ''),
        '評分': score,
        '評分人數': votes,
        '類別': split_list('類別'),
        '演員': split_list('演員'),
        '页面地址': f'{BASE}/v/{sid}',
        '封面地址': cover,
        '預覽圖': uniq(big),
        '預覽圖_縮略': uniq(small),
    }


def cover_from_cdn(sid):
    return f'{CDN}/covers/{sid[:2].lower()}/{sid}.jpg'


# ═══════════════════════════ 5. 图片落盘 ═══════════════════════════
def image_width(path):
    try:
        out = os.popen(f'sips -g pixelWidth "{path}" 2>/dev/null').read()
        m = re.search(r'pixelWidth:\s*(\d+)', out)
        return int(m.group(1)) if m else 0
    except Exception:
        return 0


def save_image(url, dest, force=False):
    if os.path.exists(dest) and not force:
        return 'skip', os.path.getsize(dest)
    data, ctype = http_get(url, referer=f'{BASE}/')
    if len(data) < 2048:
        raise ValueError(f'图片过小 {len(data)}B')
    if data[:3] != b'\xff\xd8\xff':                       # 非 JPEG → sips 转换
        tmp = dest + '.tmp'
        with open(tmp, 'wb') as f:
            f.write(data)
        rc = os.system(f'sips -s format jpeg "{tmp}" --out "{dest}" >/dev/null 2>&1')
        if os.path.exists(tmp):
            os.remove(tmp)
        if rc != 0 or not os.path.exists(dest):
            raise ValueError(f'非 JPEG 且转换失败 ({ctype})')
    else:
        with open(dest, 'wb') as f:
            f.write(data)
    return 'ok', os.path.getsize(dest)


# ═══════════════════════════ 5b. 每夹 TX.json：既是元数据也是「已抓过」标记 ═══════════════════════════
def read_tx(folder, meta_name):
    for fn in (meta_name + '.json', 'TX.json', 'tx.json'):
        p = os.path.join(folder, fn)
        if os.path.exists(p):
            try:
                return json.load(open(p, encoding='utf-8'))
            except Exception:
                return None
    return None


def write_tx(folder, meta_name, rec):
    rec = dict(rec)
    rec['完整'] = bool(rec.get('页面地址') and (rec.get('評分') is not None or rec.get('標題')))
    rec['抓取时间'] = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(os.path.join(folder, meta_name + '.json'), 'w', encoding='utf-8') as f:
            json.dump(rec, f, ensure_ascii=False, indent=2)
        return True
    except Exception:
        return False


# ═══════════════════════════ 6. 单条处理 ═══════════════════════════
def process(item, args, links_cache, meta_cache):
    name, folder, code = item['name'], item['folder'], item['code']
    cover_dest = os.path.join(folder, args.name + '.jpg')
    rec = {
        '目錄': name, '番號': code, 'ID': '', '页面地址': '', '標題': '', '日期': '', '時長': '',
        '發行': '', '片商': '', '系列': '', '導演': '', '評分': None, '評分人數': None,
        '類別': [], '演員': [], '封面地址': '', '封面文件': cover_dest,
        '视频文件': item.get('videos') or [], '預覽圖': [], '預覽圖文件': [],
        '狀態': '', '字節': 0,
    }
    try:
        # ---- 短 ID：缓存优先，没有再查 ----
        sid = item.get('jid') or links_cache.get(code) or ''
        if not sid:
            sid, exact = search_id(code)
            if sid:
                links_cache[code] = sid
            if len(exact) > 1:
                rec['狀態'] = f'{len(exact)} 条记录（撞号，取第一条）'
            if not sid:
                rec['狀態'] = '番号查不到'
                return rec
        rec['ID'] = sid
        rec['页面地址'] = f'{BASE}/v/{sid}'

        # 缓存来源：优先本文件夹的 TX.json（最贴近现场的标记），再看汇总表
        cached = read_tx(folder, args.meta_name) or meta_cache.get((folder, code)) or {}
        want_covers = not args.no_covers
        want_samples = not args.no_samples
        want_meta = not args.no_meta

        # 元数据是否已抓过：有页面地址 + 番号，且（有评分 / 有标题 / 标记完整）
        meta_ready = bool(cached.get('页面地址') and cached.get('番號')
                          and (cached.get('評分') is not None or cached.get('標題') or cached.get('完整')))
        samples_known = bool(cached.get('預覽圖'))

        need_cover = want_covers and (args.force or not os.path.exists(cover_dest))
        need_meta = want_meta and (args.force or not meta_ready)
        need_samples = want_samples and (args.force or not samples_known)

        # 先把缓存里的字段铺上，dry-run 也能看到已有数据
        if cached:
            for k in FIELDS:
                v = cached.get(k)
                if v not in (None, '', [], 0):
                    rec[k] = v

        if args.dry_run:
            todo = [t for t, on in (('封面', need_cover), ('剧照', need_samples), ('字段', need_meta)) if on]
            rec['狀態'] = 'dry-run' + (f'（要抓: {"/".join(todo)}）' if todo else '（已完整）')
            return rec

        # ---- 详情页只抓一次，三样东西共用 ----
        detail = None
        if need_meta or need_samples:          # 只缺封面时不必抓页面：CDN 直拼就够
            try:
                count_page()
                data, _ = http_get(f'{BASE}/v/{sid}')
                detail = parse_detail(data.decode('utf-8', 'ignore'), sid)
            except Exception as e:
                rec['狀態'] = f'详情页失败: {e}'

        source = detail or cached
        if source:
            for k in FIELDS:
                v = source.get(k)
                if v not in (None, '', [], 0):
                    rec[k] = v

        # ---- 封面：页面地址优先，CDN 直拼兜底 ----
        if want_covers:
            last_err = None
            for u in [x for x in (rec.get('封面地址'), cover_from_cdn(sid)) if x]:
                try:
                    st, size = save_image(u, cover_dest, force=args.force)
                    rec['封面地址'], rec['字節'] = u, size
                    rec['狀態'] = (rec['狀態'] + f' · 封面{st}') if rec['狀態'] else st
                    break
                except Exception as e:
                    last_err = e
            else:
                rec['狀態'] = (rec['狀態'] + f' · 封面失败: {last_err}') if rec['狀態'] else f'封面失败: {last_err}'

        # ---- 剧照：T-01.jpg … 按页面顺序编号 ----
        if want_samples:
            urls = rec.get('預覽圖') or []
            if args.sample_size == 's' and (rec.get('預覽圖_縮略') or []):
                urls = rec['預覽圖_縮略']
            saved = []
            for i, u in enumerate(urls, 1):
                n = i
                if args.sample_size == 's':
                    mm = re.search(r'_s_(\d+)', u)
                    n = int(mm.group(1)) + 1 if mm else i
                dest = os.path.join(folder, f'{args.sample_name}-{n:02d}.jpg')
                try:
                    save_image(u, dest, force=args.force)
                    if args.samples_min_width > 0:
                        w = image_width(dest)
                        if w and w < args.samples_min_width:
                            os.remove(dest)
                            continue
                    saved.append(os.path.basename(dest))
                except Exception:
                    pass
            # 清理张数变少后残留的旧文件
            pat = re.compile(rf'^{re.escape(args.sample_name)}-(\d{{2,3}})\.jpg$')
            keep = set(saved)
            for f in os.listdir(folder):
                if pat.match(f) and f not in keep:
                    try:
                        os.remove(os.path.join(folder, f))
                    except Exception:
                        pass
            rec['預覽圖文件'] = saved
            tag = f'剧照{len(saved)}张'
            rec['狀態'] = (rec['狀態'] + ' · ' + tag) if rec['狀態'] else tag

        if args.per_folder and rec['页面地址']:
            write_tx(folder, args.meta_name, rec)      # 立刻写标记，下次直接跳过
    except Exception as e:
        rec['狀態'] = f'失败: {e}'
    return rec


# ═══════════════════════════ 7. 目录扫描 ═══════════════════════════
def build_items(root):
    items, seen = [], set()
    for name in sorted(os.listdir(root)):
        if name.startswith('.'):
            continue
        full = os.path.join(root, name)
        is_dir = os.path.isdir(full)
        if not is_dir and os.path.splitext(name)[1].lower() not in VIDEO_EXT:
            continue
        code, _ = extract_code(name)
        if not code or code in seen:
            continue
        seen.add(code)
        vids = []
        if is_dir:
            try:
                vids = [f for f in sorted(os.listdir(full))
                        if os.path.splitext(f)[1].lower() in VIDEO_EXT and not f.startswith('.')]
            except Exception:
                pass
        else:
            vids = [name]
        items.append({'name': name, 'folder': full if is_dir else root,
                      'code': code, 'videos': vids, 'jid': ''})
    return items


# ═══════════════════════════ 8. 输出 ═══════════════════════════
def write_outputs(results, merged_rows, out_dir, per_folder, meta_name, links_cache, root, write_meta=True):
    os.makedirs(out_dir, exist_ok=True)
    rows = sorted(results, key=lambda r: r['目錄'])

    # 链接表
    md = [f'# JavDB 链接表 · `{root}`', '',
          f'共 {len(rows)} 条，命中 {sum(1 for r in rows if r["页面地址"])} 条。', '',
          '| # | 目录/文件 | 番号 | JavDB 地址 | 片名 | 状态 |', '|---|---|---|---|---|---|']
    for i, r in enumerate(rows, 1):
        md.append(f'| {i} | `{r["目錄"]}` | {r["番號"]} | {r["页面地址"] or "—"} | '
                  f'{(r.get("標題") or "")[:60]} | {r.get("狀態", "")[:24]} |')
    open(os.path.join(out_dir, 'links.md'), 'w', encoding='utf-8').write('\n'.join(md) + '\n')

    cols_links = ['目錄', '番號', 'ID', '页面地址', '狀態']
    with open(os.path.join(out_dir, 'links.csv'), 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols_links, extrasaction='ignore')
        w.writeheader()
        for r in rows:
            w.writerow(r)

    # 元数据总表（合并全库，避免把别的目录记录冲掉）
    if write_meta:
        allrows = sorted(merged_rows, key=lambda r: (r.get('封面文件', ''), r.get('番號', '')))
        cols_meta = ['目錄', '番號', 'ID', '页面地址', '標題', '日期', '時長', '發行', '片商', '系列', '導演',
                     '評分', '評分人數', '類別', '演員', '封面地址', '封面文件', '视频文件', '預覽圖文件', '狀態', '字節']
        with open(os.path.join(out_dir, 'javdb_meta.json'), 'w', encoding='utf-8') as f:
            json.dump(allrows, f, ensure_ascii=False, indent=2)
        with open(os.path.join(out_dir, 'covers_report.csv'), 'w', encoding='utf-8-sig', newline='') as f:
            w = csv.DictWriter(f, fieldnames=cols_meta, extrasaction='ignore')
            w.writeheader()
            for r in allrows:
                row = dict(r)
                for k in ('類別', '演員', '视频文件', '預覽圖文件'):
                    row[k] = '/'.join(r.get(k) or [])
                w.writerow(row)

    # 番号→ID 缓存（下次免搜）
    with open(os.path.join(out_dir, 'links.json'), 'w', encoding='utf-8') as f:
        json.dump([{'code': c, 'jid': j, 'url': f'{BASE}/v/{j}'}
                   for c, j in sorted(links_cache.items())], f, ensure_ascii=False, indent=2)

    # 每个片夹一份
    if per_folder and write_meta:
        n = sum(1 for r in merged_rows
                if os.path.exists(os.path.join(os.path.dirname(r['封面文件']), meta_name + '.json')))
        print(f'每个文件夹 {meta_name}.json: {n} 份（已存在）')


# ═══════════════════════════ 9. main ═══════════════════════════
def main():
    ap = argparse.ArgumentParser(description='目录 → 番号 → javdb 短链 → 封面/剧照/元数据')
    ap.add_argument('dir')
    ap.add_argument('--out', default=os.path.join(HERE, 'javdb_links_out'), help='汇总输出目录')
    ap.add_argument('--name', default='FM', help='封面文件名（不含扩展名），默认 FM.jpg')
    ap.add_argument('--meta-name', default='TX', help='每夹元数据文件名，默认 TX.json')
    ap.add_argument('--sample-name', default='T', help='剧照前缀，默认 T → T-01.jpg')
    ap.add_argument('--sample-size', choices=['l', 's'], default='l', help='剧照尺寸 l=原图 / s=缩略图')
    ap.add_argument('--samples-min-width', type=int, default=0, help='丢掉宽度小于该值的剧照，0=全留')
    ap.add_argument('--no-covers', action='store_true', help='不下封面')
    ap.add_argument('--no-samples', action='store_true', help='不下剧照')
    ap.add_argument('--no-meta', action='store_true', help='不抓字段')
    ap.add_argument('--per-folder', dest='per_folder', action='store_true', default=True,
                    help='每个文件夹写一份 TX.json（默认开）')
    ap.add_argument('--no-per-folder', dest='per_folder', action='store_false', help='不写每夹 JSON')
    ap.add_argument('--links-only', action='store_true', help='只出链接表，不下载任何图')
    ap.add_argument('--force', action='store_true', help='已有文件也重抓')
    ap.add_argument('--dry-run', action='store_true', help='只报告要做什么')
    ap.add_argument('--concurrency', type=int, default=2, help='页面上限别开太大，JavDB 会限流')
    ap.add_argument('--cookie', default='', help='浏览器里复制的 Cookie，用于通过 Cloudflare 挑战')
    ap.add_argument('--proxy', default='', help='HTTP 代理，例如 http://127.0.0.1:7890')
    ap.add_argument('--ua', default='', help='自定义 User-Agent（需与取得 Cookie 的浏览器一致）')
    args = ap.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print(f'目录不存在: {root}')
        return 1
    if args.links_only:
        args.no_covers = args.no_samples = args.no_meta = True

    # 缓存：番号→ID、以及上一次的元数据（用于增量）
    global COOKIE, PROXY, UA
    COOKIE = (args.cookie or os.environ.get('JAVDB_COOKIE', '')).strip()
    PROXY = (args.proxy or os.environ.get('JAVDB_PROXY', '')).strip()
    if args.ua:
        UA = args.ua.strip()
    if PROXY:
        reset_opener()
    if COOKIE:
        print(f'🍪 使用自定义 Cookie（{len(COOKIE)} 字节）')

    links_cache = {}
    lp = os.path.join(args.out, 'links.json')
    if os.path.exists(lp):
        for r in json.load(open(lp, encoding='utf-8')):
            if r.get('code') and r.get('jid'):
                links_cache[r['code']] = r['jid']

    meta_cache = {}
    mp = os.path.join(args.out, 'javdb_meta.json')
    if os.path.exists(mp):
        try:
            for r in json.load(open(mp, encoding='utf-8')):
                meta_cache[(os.path.dirname(r.get('封面文件', '')), r.get('番號', ''))] = r
        except Exception:
            pass

    items = build_items(root)
    print(f'📂 {root}')
    print(f'   条目 {len(items)} · 已有短链 {sum(1 for i in items if i["code"] in links_cache)} · '
          f'缓存元数据 {len(meta_cache)} · 输出 {args.out}\n')

    results = []
    with ThreadPoolExecutor(max_workers=max(1, args.concurrency)) as pool:
        futs = [pool.submit(process, it, args, links_cache, meta_cache) for it in items]
        for done, fut in enumerate(as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            if r['狀態'].startswith('dry-run'):
                icon = '🧪'
            else:
                icon = '✅' if r['页面地址'] else '❌'
            star = f"{r['評分']}分/{r['評分人數']}人" if r.get('評分') else '—'
            with _lock:
                print(f'{icon} [{done}/{len(items)}] {r["目錄"]:<24} {r["番號"]:<11} '
                      f'{(r["發行"] or "—"):<14} ★{star:<16} {(r["狀態"] or "")[:30]}')

    ok_link = sum(1 for r in results if r['页面地址'])
    ok_cover = sum(1 for r in results if r['字節'])
    ok_meta = sum(1 for r in results if r.get('評分'))
    ok_shot = sum(len(r.get('預覽圖文件') or []) for r in results)
    skipped = sum(1 for r in results if 'skip' in (r['狀態'] or ''))
    print(f'\n链接 {ok_link}/{len(results)} · 封面 {ok_cover}/{len(results)} · '
          f'元数据 {ok_meta}/{len(results)} · 剧照 {ok_shot} 张')
    print(f'详情页请求 {PAGE_FETCHES[0]} 次 · 命中缓存 {skipped} 条'
          + ('  ← 无重复下载 ✅' if PAGE_FETCHES[0] == 0 else ''))

    if args.dry_run:
        print('（dry-run：未写入任何文件）')
        return 0

    merged = dict(meta_cache)
    for r in results:
        if r.get('页面地址'):
            merged[(os.path.dirname(r['封面文件']), r['番號'])] = r
    merged_rows = list(merged.values())

    write_outputs(results, merged_rows, args.out, args.per_folder, args.meta_name, links_cache, root,
                  write_meta=not args.links_only)
    out_list = 'links.md · links.csv · links.json'
    if not args.links_only:
        out_list += ' · javdb_meta.json · covers_report.csv'
    print(f'输出: {args.out}/{out_list}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
