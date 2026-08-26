#!/usr/bin/env python3
"""ソースを 1 つの HTML にまとめる。

file:// で開いたときブラウザは ES モジュールの読み込みを拒否するので、
単一ファイルとして配る場合は全部を埋め込む必要がある。

  python3 Web/build.py           … Web/PassVault.html だけ
  python3 Web/build.py --site    … 加えて Web/site/（ホーム画面に追加して使う一式）

site/ には本体のほかに manifest / service worker / アイコンが入る。
iPhone で使うにはこちらが要る（単一 HTML を file:// で開いても保存領域が使えない）。
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
# ホーム画面に追加して使うための出力先（GitHub Pages などに置く）
SITE = HERE / "site"
ICON_SOURCE = HERE.parent / "PassVault/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png"
# 依存の順に並べる。名前空間（V / X / A）はこの 3 つから作る。
NAMESPACED = [("core.js", "V"), ("crypto-extras.js", "X"), ("audit.js", "A")]
PLAIN = ["icons.js", "app.js", "detail.js"]

# 見た目のテーマ。style.css（骨組み）の上に重ねる。
# theme-tool / theme-macos / theme-1password から選ぶ。
THEME = "theme-macos.css"

EXPORT_DECL = re.compile(
    r"^export\s+(?:async\s+)?(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)",
    re.MULTILINE,
)
# import 文（1 行でも複数行でも）を丸ごと落とす
IMPORT_STATEMENT = re.compile(r"^import\s+[\s\S]*?from\s*['\"][^'\"]+['\"];\s*$", re.MULTILINE)
TOP_LEVEL_DECL = re.compile(
    r"^(?:export\s+)?(?:async\s+)?(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)",
    re.MULTILINE,
)


def strip_module_syntax(source: str) -> str:
    source = IMPORT_STATEMENT.sub("", source)
    source = re.sub(r"^export\s+", "", source, flags=re.MULTILINE)
    return source


def check_syntax(script: str, label: str = "まとめた結果") -> bool:
    """node があれば構文を確かめる。無ければ黙って通す。

    拡張子は必ず .mjs にする。.js だと import を含む中身のとき
    node --check が壊れていても終了コード 0 を返し、検査が素通りする。
    """
    node = shutil.which("node")
    if not node:
        print("注意: node が無いので構文チェックを飛ばしました", file=sys.stderr)
        return True
    with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name
    try:
        result = subprocess.run([node, "--check", path], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"エラー: {label}が構文として壊れています", file=sys.stderr)
            print(result.stderr.strip()[:1200], file=sys.stderr)
            return False
        return True
    finally:
        os.unlink(path)


def page(style: str, script: str, version: str, pwa: bool = False) -> str:
    """1 枚の HTML を組み立てる。pwa を立てるとホーム画面向けの記述を足す。"""
    head = ""
    tail = ""
    if pwa:
        head = """<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="PassVault">
<meta name="theme-color" content="#1c1c1e" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#e8e8ea" media="(prefers-color-scheme: light)">
<link rel="manifest" href="./manifest.webmanifest">
<link rel="apple-touch-icon" href="./apple-touch-icon.png">
<!-- 検索避け。個人の保管庫なので、見つけてもらう必要がない。 -->
<meta name="robots" content="noindex, nofollow">"""
        # 登録に失敗しても本体は動く。電波が無いときに開けなくなるだけ。
        tail = """<script>
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
}
</script>"""
    else:
        head = '<meta name="viewport" content="width=device-width, initial-scale=1">'

    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
{head}
<title>PassVault</title>
<!--
  このファイルは Web/build.py が生成したものです。直接編集しないでください。
  元は Web/style.css と Web/*.js です。
-->
<style>
{style}
</style>
</head>
<body>
<div id="gate"></div>
<div id="app">
  <div id="bar"></div>
  <div id="main"></div>
</div>
<div id="toast"></div>
<script>window.PASSVAULT_BUILD = {json.dumps(version)};</script>
<script>
{script}
</script>
{tail}
</body>
</html>
"""


def build_site(style: str, script: str, version: str) -> bool:
    """ホーム画面に追加して使うための一式を site/ に書く。"""
    if not ICON_SOURCE.exists():
        print(f"エラー: アイコンの元が見つかりません: {ICON_SOURCE}", file=sys.stderr)
        return False
    sips = shutil.which("sips")
    if not sips:
        print("エラー: sips が無いのでアイコンを作れません（macOS 以外）", file=sys.stderr)
        return False

    SITE.mkdir(exist_ok=True)
    (SITE / "index.html").write_text(page(style, script, version, pwa=True), encoding="utf-8")

    for name, size in [("icon-192.png", 192), ("icon-512.png", 512), ("apple-touch-icon.png", 180)]:
        result = subprocess.run(
            [sips, "-z", str(size), str(size), str(ICON_SOURCE), "--out", str(SITE / name)],
            capture_output=True, text=True)
        if result.returncode != 0:
            print(f"エラー: {name} を作れませんでした\n{result.stderr.strip()[:400]}", file=sys.stderr)
            return False

    (SITE / "manifest.webmanifest").write_text(json.dumps({
        "name": "PassVault",
        "short_name": "PassVault",
        "start_url": "./index.html",
        "scope": "./",
        "display": "standalone",
        "background_color": "#1c1c1e",
        "theme_color": "#1c1c1e",
        "icons": [
            {"src": "./icon-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "./icon-512.png", "sizes": "512x512", "type": "image/png"},
            {"src": "./icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
        ],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    worker = (HERE / "sw.js.tmpl").read_text(encoding="utf-8").replace("__VERSION__", version)
    (SITE / "sw.js").write_text(worker, encoding="utf-8")

    # GitHub Pages は _ で始まる名前を Jekyll の部品とみなして配信しない。
    # いまは該当が無いが、増えたときに黙って欠けるので先に止めておく。
    (SITE / ".nojekyll").write_text("", encoding="utf-8")

    print(f"site/ を書きました（版 {version}）")
    for path in sorted(SITE.iterdir()):
        print(f"  {path.name}（{path.stat().st_size:,} バイト）")
    return True


def main() -> int:
    bodies = []
    namespaces = []
    seen: dict[str, str] = {}
    problems = []

    for name, alias in NAMESPACED + [(n, None) for n in PLAIN]:
        source = (HERE / name).read_text(encoding="utf-8")

        if re.search(r"^export\s*\{", source, re.MULTILINE):
            problems.append(f"{name}: まとめての export は扱えません。個別に export してください。")

        exported = EXPORT_DECL.findall(source)
        if alias:
            if not exported:
                problems.append(f"{name}: export が見つかりません。")
            namespaces.append((alias, exported))

        for declared in TOP_LEVEL_DECL.findall(source):
            if declared in seen:
                problems.append(f"名前の衝突: {declared}（{seen[declared]} と {name}）")
            seen[declared] = name

        bodies.append((name, strip_module_syntax(source)))

    if problems:
        for problem in problems:
            print(f"エラー: {problem}", file=sys.stderr)
        return 1

    chunks = []
    for name, body in bodies:
        chunks.append(f"\n// ===== {name} =====\n{body}")
        # 名前空間つきの 3 つを出し終えたところで V / X / A を組み立てる。
        # これより後ろのコードが V.foo の形で参照する。
        if name == NAMESPACED[-1][0]:
            chunks.append("\n// ===== 名前空間（元は import * as ...）=====\n")
            for alias, exported in namespaces:
                # 行末の改行を忘れると、直前のコメントに巻き込まれて丸ごと無効になる
                chunks.append(f"const {alias} = {{ {', '.join(exported)} }};\n")

    style = (HERE / "style.css").read_text(encoding="utf-8")
    style += "\n\n/* ===== " + THEME + " ===== */\n"
    style += (HERE / THEME).read_text(encoding="utf-8")
    script = "".join(chunks)
    version = hashlib.sha256((style + script).encode()).hexdigest()[:12]
    html = page(style, script, version)

    # 出荷前に構文を検める。壊れたバンドルは画面が真っ白になるだけで、
    # ブラウザで開くまで気づけない。実際に 2 回やらかしている。
    if not check_syntax(script):
        return 1

    # 検証ページの構文も検める。ここが壊れると「実行中…」のまま
    # 無言で止まり、失敗として見えないまま通ったつもりになる。
    tests = HERE / "tests.html"
    if tests.exists():
        body = re.search(r'<script type="module">(.*?)</script>', tests.read_text(encoding="utf-8"), re.S)
        if body and not check_syntax(body.group(1), "tests.html の中身"):
            return 1

    # 開発用の index.html にも同じテーマを反映する。
    # 手で 2 か所を合わせる形にしていると、静かに食い違う。
    dev = HERE / "index.html"
    dev_html = dev.read_text(encoding="utf-8")
    fixed = re.sub(r'<link rel="stylesheet" href="theme-[^"]*\.css">',
                   f'<link rel="stylesheet" href="{THEME}">', dev_html)
    if fixed != dev_html:
        dev.write_text(fixed, encoding="utf-8")
        print(f"  index.html のテーマも {THEME} に合わせました")

    output = HERE / "PassVault.html"
    output.write_text(html, encoding="utf-8")
    print(f"生成しました: {output} （{len(html.encode()):,} バイト）")
    print(f"  テーマ: {THEME}")
    print(f"  版: {version}")
    for alias, exported in namespaces:
        print(f"  名前空間 {alias}: {len(exported)} 個")

    if "--site" in sys.argv:
        if not build_site(style, script, version):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
