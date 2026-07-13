#!/usr/bin/env python3
"""WALKTHROUGH.md 18개 → 단일 페이지 웹 뷰어(walkthrough.html) 생성기.

사용법: python3 tools/build-walkthrough.py   (저장소 루트에서)
구조: 좌측 장 목차(앵커) + 스텝 카드 + prev/next 네비 + 명령 복사 버튼.
"""
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "walkthrough.html"

CHAPTERS = [
    ("00-onramp", "00", "온램프"),
    ("01-l2-arp", "01", "L2 & ARP"),
    ("02-bcast-loop", "02", "L2 루프/스톰"),
    ("03-vlan-trunk", "03", "VLAN/트렁크"),
    ("04-l3-routing", "04", "L3 라우팅"),
    ("05-lpm-blackhole", "05", "LPM/블랙홀"),
    ("06-ttl-loop", "06", "TTL 루프"),
    ("07-vxlan-overlay", "07", "VXLAN"),
    ("08-tcp-3way", "08", "TCP 3-way"),
    ("09-conntrack", "09", "conntrack"),
    ("10-nat-basics", "10", "NAT 기본"),
    ("11-symmetry-nat", "11", "대칭성&NAT"),
    ("12-mtu-pmtud", "12", "MTU/PMTUD"),
    ("13-tunnel-mtu", "13", "터널 MTU"),
    ("14-dns", "14", "DNS"),
    ("15-icmp-blocked", "15", "ICMP 차단"),
    ("16-nat-hairpin", "16", "NAT 헤어핀"),
    ("17-dynamic-routing", "17", "OSPF/BGP"),
]


def inline(s: str) -> str:
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return s


def render_cmd(lines):
    out = []
    for ln in lines:
        esc = html.escape(ln, quote=False)
        if ln.lstrip().startswith("#"):
            out.append(f'<span class="cmt">{esc}</span>')
        else:
            out.append(esc)
    return "\n".join(out)


def render_out(lines):
    out = []
    for ln in lines:
        esc = html.escape(ln, quote=False)
        esc = re.sub(r"(←.*)$", r'<span class="note">\1</span>', esc)
        out.append(esc)
    return "\n".join(out)


def parse_chapter(md: str):
    """마크다운 → (제목, 서두, [steps]) — step = {title, kind, items}"""
    lines = md.splitlines()
    title, lede, steps = "", [], []
    cur = None
    i, n = 0, len(lines)
    para, ul, table = [], [], []

    def flush_para():
        nonlocal para
        if not para:
            return
        text = " ".join(para).strip()
        para = []
        if not text:
            return
        m = re.match(r"\*\*(의도|해석|해설)\*\*\s*:?\s*(.*)", text)
        if m:
            kind = "intent" if m.group(1) == "의도" else "interp"
            label = m.group(1)
            item = {"t": "callout", "kind": kind, "label": label, "html": inline(m.group(2))}
        else:
            item = {"t": "p", "html": inline(text)}
        (cur["items"] if cur else lede).append(item)

    def flush_ul():
        nonlocal ul
        if ul:
            (cur["items"] if cur else lede).append({"t": "ul", "rows": [inline(x) for x in ul]})
            ul = []

    def flush_table():
        nonlocal table
        if table:
            rows = [[inline(c.strip()) for c in r.strip("|").split("|")] for r in table]
            rows = [r for j, r in enumerate(rows) if j != 1]  # 구분선 제거
            (cur["items"] if cur else lede).append({"t": "table", "rows": rows})
            table = []

    def flush_all():
        flush_para(); flush_ul(); flush_table()

    def new_step(t, kind):
        nonlocal cur
        flush_all()
        cur = {"title": inline(t.strip()), "kind": kind, "items": []}
        steps.append(cur)

    while i < n:
        ln = lines[i]
        if ln.startswith("```"):
            flush_all()
            lang = ln[3:].strip()
            buf = []
            i += 1
            while i < n and not lines[i].startswith("```"):
                buf.append(lines[i]); i += 1
            kind = "cmd" if lang else "out"
            tgt = cur["items"] if cur else lede
            tgt.append({"t": kind, "lines": buf})
        elif ln.startswith("# ") and not title:
            title = ln[2:].strip()
        elif ln.startswith("# "):          # 장 중간의 파트 구분 (17a/17b)
            new_step(ln[2:], "part")
        elif ln.startswith("## "):
            new_step(ln[3:], "step")
        elif ln.startswith("### "):
            new_step(ln[4:], "step")
        elif ln.startswith("> "):
            flush_para()
            tgt = cur["items"] if cur else lede
            note = [ln[2:]]
            while i + 1 < n and lines[i + 1].startswith(">"):
                i += 1
                note.append(lines[i].lstrip("> "))
            tgt.append({"t": "quote", "html": inline(" ".join(note))})
        elif ln.startswith("|"):
            flush_para(); flush_ul(); table.append(ln)
        elif ln.startswith("- "):
            flush_para(); flush_table(); ul.append(ln[2:])
        elif ln.strip() in ("---", ""):
            flush_all()
        else:
            flush_ul(); flush_table(); para.append(ln.strip())
        i += 1
    flush_all()
    return title, lede, steps


def items_html(items):
    out = []
    for it in items:
        if it["t"] == "p":
            out.append(f'<p>{it["html"]}</p>')
        elif it["t"] == "callout":
            out.append(f'<div class="callout {it["kind"]}"><span class="tag">{it["label"]}</span><div>{it["html"]}</div></div>')
        elif it["t"] == "quote":
            out.append(f'<div class="quote">{it["html"]}</div>')
        elif it["t"] == "cmd":
            out.append('<div class="term cmd"><div class="termbar"><span class="lbl">명령</span>'
                       '<button class="copy" type="button">복사</button></div>'
                       f'<pre><code>{render_cmd(it["lines"])}</code></pre></div>')
        elif it["t"] == "out":
            out.append('<div class="term out"><div class="termbar"><span class="lbl">출력</span></div>'
                       f'<pre><code>{render_out(it["lines"])}</code></pre></div>')
        elif it["t"] == "ul":
            out.append("<ul>" + "".join(f"<li>{r}</li>" for r in it["rows"]) + "</ul>")
        elif it["t"] == "table":
            head, *body = it["rows"]
            th = "".join(f"<th>{c}</th>" for c in head)
            tb = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in body)
            out.append(f'<div class="tblwrap"><table><thead><tr>{th}</tr></thead><tbody>{tb}</tbody></table></div>')
    return "\n".join(out)


def build():
    nav, main = [], []
    step_no = 0
    for folder, num, short in CHAPTERS:
        md = (ROOT / folder / "WALKTHROUGH.md").read_text(encoding="utf-8")
        title, lede, steps = parse_chapter(md)
        cid = f"ch{num}"
        nav.append(f'<a class="navitem" href="#{cid}" data-ch="{cid}">'
                   f'<span class="n">{num}</span><span>{short}</span></a>')
        main.append(f'<section class="chapter" id="{cid}" data-num="{num}" data-short="{short}">')
        main.append(f'<header class="chhead"><div class="eyebrow">{num}장 · {folder}/</div>'
                    f'<h1>{inline(title)}</h1>{items_html(lede)}</header>')
        for s in steps:
            step_no += 1
            sid = f"{cid}-s{len([x for x in main if x == ''])}{step_no}"
            klass = "step part" if s["kind"] == "part" else "step"
            main.append(f'<article class="{klass}" id="s{step_no}" data-ch="{cid}" data-chlabel="{num} {short}">')
            main.append(f'<h2><span class="stepno">{step_no}</span>{s["title"]}</h2>')
            main.append(items_html(s["items"]))
            main.append("</article>")
        main.append("</section>")
    total = step_no

    css = """
:root{
  --bg:#f4f6f6; --surface:#ffffff; --ink:#1a2228; --muted:#5c6b75; --line:#dbe3e6;
  --accent:#0e7c86; --accent-ink:#0a5b63; --accent-soft:#e3f0f1;
  --term-bg:#10191e; --term-ink:#cfdbe2; --term-dim:#7d919c; --term-note:#5ad0da;
  --cur:#0e7c8622;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#0d1418; --surface:#141d22; --ink:#dee7eb; --muted:#8da0ab; --line:#243138;
    --accent:#3fc1cb; --accent-ink:#7adde4; --accent-soft:#14343a;
    --term-bg:#0a1114; --term-ink:#c8d6dd; --term-dim:#6c8290; --term-note:#5ad0da; --cur:#3fc1cb26; }
}
:root[data-theme="dark"]{ --bg:#0d1418; --surface:#141d22; --ink:#dee7eb; --muted:#8da0ab; --line:#243138;
  --accent:#3fc1cb; --accent-ink:#7adde4; --accent-soft:#14343a;
  --term-bg:#0a1114; --term-ink:#c8d6dd; --term-dim:#6c8290; --term-note:#5ad0da; --cur:#3fc1cb26; }
:root[data-theme="light"]{ --bg:#f4f6f6; --surface:#ffffff; --ink:#1a2228; --muted:#5c6b75; --line:#dbe3e6;
  --accent:#0e7c86; --accent-ink:#0a5b63; --accent-soft:#e3f0f1;
  --term-bg:#10191e; --term-ink:#cfdbe2; --term-dim:#7d919c; --term-note:#5ad0da; --cur:#0e7c8622; }
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"Pretendard Variable",Pretendard,-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Segoe UI","Malgun Gothic",sans-serif;
  font-size:15.5px;line-height:1.72;}
code,pre,.stepno,.n,.counter{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;}
.wrap{display:flex;min-height:100vh;}
/* ── 사이드바 ── */
nav.side{position:sticky;top:0;height:100vh;overflow-y:auto;flex:0 0 218px;
  border-right:1px solid var(--line);background:var(--surface);padding:18px 12px 90px;}
.brand{padding:4px 10px 14px;border-bottom:1px solid var(--line);margin-bottom:10px;}
.brand b{font-size:15px;letter-spacing:-.01em;}
.brand small{display:block;color:var(--muted);font-size:11.5px;margin-top:2px;letter-spacing:.04em;}
.navitem{display:flex;gap:9px;align-items:baseline;padding:6px 10px;border-radius:7px;
  color:var(--muted);text-decoration:none;font-size:13.5px;}
.navitem .n{font-size:11.5px;color:var(--accent);min-width:20px;}
.navitem:hover{background:var(--accent-soft);color:var(--ink);}
.navitem.on{background:var(--accent-soft);color:var(--ink);font-weight:650;}
/* ── 본문 ── */
main{flex:1;min-width:0;padding:34px 40px 45vh;}
.chapter{max-width:820px;margin:0 auto 56px;}
.chhead{margin-bottom:10px;}
.eyebrow{font-size:11.5px;letter-spacing:.09em;text-transform:uppercase;color:var(--accent-ink);font-weight:700;}
.chhead h1{font-size:23px;line-height:1.35;letter-spacing:-.015em;margin:.35em 0 .5em;text-wrap:balance;}
.quote{border-left:3px solid var(--accent);background:var(--accent-soft);color:var(--ink);
  padding:10px 14px;border-radius:0 8px 8px 0;font-size:14px;margin:12px 0;}
/* ── 스텝 카드 ── */
.step{background:var(--surface);border:1px solid var(--line);border-radius:10px;
  padding:20px 24px 16px;margin:16px 0;scroll-margin-top:18px;}
.step.current{border-color:var(--accent);box-shadow:0 0 0 3px var(--cur);}
.step.part{background:transparent;border:none;padding:26px 0 0;}
.step.part h2{font-size:20px;border-bottom:2px solid var(--accent);padding-bottom:8px;}
.step h2{font-size:16.5px;margin:0 0 10px;letter-spacing:-.01em;display:flex;gap:10px;align-items:baseline;}
.stepno{font-size:11px;color:var(--accent);border:1px solid var(--accent);border-radius:999px;
  padding:1px 8px;flex:none;font-weight:600;}
.step p{margin:.55em 0;max-width:72ch;}
.step ul{margin:.4em 0;padding-left:1.3em;max-width:72ch;}
.step li{margin:.25em 0;}
/* ── 의도/해석 콜아웃 ── */
.callout{display:flex;gap:10px;align-items:flex-start;margin:.7em 0;max-width:76ch;}
.callout .tag{flex:none;font-size:11px;font-weight:700;letter-spacing:.08em;border-radius:5px;
  padding:2.5px 8px;margin-top:3px;}
.callout.intent .tag{background:var(--accent-soft);color:var(--accent-ink);}
.callout.interp .tag{background:var(--ink);color:var(--bg);}
.callout.interp{background:color-mix(in srgb,var(--surface) 60%, var(--bg));
  border:1px solid var(--line);border-radius:8px;padding:10px 12px;}
/* ── 터미널 블록 ── */
.term{border-radius:9px;overflow:hidden;margin:10px 0;background:var(--term-bg);}
.term.cmd{border-left:3px solid var(--accent);}
.term.out{border-left:3px solid var(--term-dim);opacity:.96;}
.termbar{display:flex;justify-content:space-between;align-items:center;
  padding:5px 12px 0;}
.termbar .lbl{font-size:10.5px;letter-spacing:.14em;color:var(--term-dim);font-weight:700;}
.term pre{margin:0;padding:9px 14px 12px;overflow-x:auto;}
.term code{font-size:13px;line-height:1.6;color:var(--term-ink);}
.term.out code{color:var(--term-dim);}
.term .cmt{color:var(--term-dim);font-style:italic;}
.term .note{color:var(--term-note);}
.copy{font:600 11.5px/1 inherit;font-family:inherit;color:var(--term-dim);background:transparent;
  border:1px solid var(--term-dim);border-radius:6px;padding:4px 10px;cursor:pointer;}
.copy:hover{color:var(--term-note);border-color:var(--term-note);}
.copy.ok{color:#7fe0a8;border-color:#7fe0a8;}
/* ── 표 ── */
.tblwrap{overflow-x:auto;margin:10px 0;}
table{border-collapse:collapse;font-size:13.5px;min-width:420px;}
th,td{border:1px solid var(--line);padding:6px 12px;text-align:left;}
th{background:var(--accent-soft);color:var(--accent-ink);font-weight:700;}
/* ── 플로팅 네비 ── */
.navdock{position:fixed;right:22px;bottom:20px;display:flex;gap:8px;align-items:center;
  background:var(--surface);border:1px solid var(--line);border-radius:12px;
  padding:8px 10px;box-shadow:0 6px 24px rgba(0,0,0,.18);z-index:50;}
.navdock button{font:700 13px/1 inherit;font-family:inherit;color:var(--ink);background:var(--bg);
  border:1px solid var(--line);border-radius:8px;padding:9px 14px;cursor:pointer;}
.navdock button:hover{border-color:var(--accent);color:var(--accent-ink);}
.counter{font-size:12px;color:var(--muted);min-width:110px;text-align:center;}
.counter b{color:var(--accent-ink);}
.kbd{font-size:10.5px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:1px 5px;}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;}
@media (max-width:880px){
  .wrap{display:block;}
  nav.side{position:static;height:auto;display:flex;overflow-x:auto;flex-wrap:nowrap;gap:2px;
    border-right:none;border-bottom:1px solid var(--line);padding:10px;}
  .brand{display:none;}
  .navitem{flex:none;}
  main{padding:20px 14px 40vh;}
  .navdock .kbd{display:none;}
}
@media (prefers-reduced-motion: reduce){ html{scroll-behavior:auto;} }
"""

    js = """
(function(){
  var steps=[].slice.call(document.querySelectorAll('.step'));
  var navItems=[].slice.call(document.querySelectorAll('.navitem'));
  var counter=document.getElementById('counter');
  var cur=0, total=steps.length;
  var reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
  function setCurrent(i,scroll){
    if(i<0||i>=total)return;
    steps[cur].classList.remove('current');
    cur=i; var el=steps[cur]; el.classList.add('current');
    if(scroll)el.scrollIntoView({behavior:reduced?'auto':'smooth',block:'start'});
    counter.innerHTML='<b>'+(cur+1)+'</b> / '+total+' · '+el.dataset.chlabel;
    var ch=el.dataset.ch;
    navItems.forEach(function(a){a.classList.toggle('on',a.dataset.ch===ch);});
  }
  document.getElementById('prev').addEventListener('click',function(){setCurrent(cur-1,true);});
  document.getElementById('next').addEventListener('click',function(){setCurrent(cur+1,true);});
  document.addEventListener('keydown',function(e){
    if(e.target.closest('button'))return;
    if(e.key==='ArrowRight'||e.key==='j'){e.preventDefault();setCurrent(cur+1,true);}
    if(e.key==='ArrowLeft'||e.key==='k'){e.preventDefault();setCurrent(cur-1,true);}
  });
  // 스크롤 시 현재 스텝 추적
  var io=new IntersectionObserver(function(es){
    es.forEach(function(en){
      if(en.isIntersecting){ setCurrent(steps.indexOf(en.target),false); }
    });
  },{rootMargin:'-20% 0px -70% 0px'});
  steps.forEach(function(s){io.observe(s);});
  // 복사 버튼
  document.querySelectorAll('.copy').forEach(function(btn){
    btn.addEventListener('click',function(){
      var code=btn.closest('.term').querySelector('code');
      navigator.clipboard.writeText(code.textContent).then(function(){
        btn.textContent='복사됨 ✓'; btn.classList.add('ok');
        setTimeout(function(){btn.textContent='복사'; btn.classList.remove('ok');},1400);
      });
    });
  });
  setCurrent(0,false);
})();
"""

    doc = f"""<title>network-lab 모범답안 뷰어</title>
<style>{css}</style>
<div class="wrap">
<nav class="side">
  <div class="brand"><b>network-lab</b><small>WALKTHROUGH · 모범답안 뷰어</small></div>
  {''.join(nav)}
</nav>
<main>
{''.join(main)}
</main>
</div>
<div class="navdock">
  <button id="prev" type="button" aria-label="이전 단계">← 이전</button>
  <span class="counter" id="counter">1 / {total}</span>
  <button id="next" type="button" aria-label="다음 단계">다음 →</button>
  <span class="kbd">←/→ · j/k</span>
</div>
<script>{js}</script>
"""
    OUT.write_text(doc, encoding="utf-8")
    print(f"OK: {OUT} ({OUT.stat().st_size//1024} KB, 장 {len(CHAPTERS)}개 · 스텝 {total}개)")


if __name__ == "__main__":
    build()
