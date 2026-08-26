#!/usr/bin/env python3
"""開発用の配信。**キャッシュさせない。**

  python3 Web/serve.py [ポート]

素の http.server だと、ブラウザが古い .js / .css を握ったまま離さない。
直したはずのものが直って見えず、そのたびに「効いていない」と判断を誤る。
実際にこの作業中だけで 3 回踏んだので、ここで断ち切る。

配信用（GitHub Pages）とは別物。あちらは service worker が版で管理する。
"""

import sys
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # 既定の出力は毎要求 1 行で騒がしい。失敗だけ見せる。
        if not args or not str(args[1]).startswith(("2", "3")):
            super().log_message(fmt, *args)


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8770
    handler = partial(NoCacheHandler, directory=str(Path(__file__).parent))
    print(f"http://localhost:{port}/index.html  … 分割したままのアプリ")
    print(f"http://localhost:{port}/tests.html  … 検証")
    print("キャッシュは無効にしてあります。")
    try:
        HTTPServer(("127.0.0.1", port), handler).serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
