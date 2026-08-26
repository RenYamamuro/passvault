#!/bin/bash
# 配信用の一式を作って gh-pages の枝へ送る。
#
#   ./Web/deploy.sh
#
# 生成物は main に入れない。混ざると、どれが元でどれが出力か分からなくなる。
# 一時ディレクトリで枝を作り直して押し込む形にしている。
#
# 送ったあと iPhone 側に届くまで数分かかることがある。
# 届いたかどうかは、設定の「この画面の版」を見れば分かる。

set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE=$(git remote get-url origin)
SITE="Web/site"

echo "==> 組み立て"
python3 Web/build.py --site

# 本物の保管庫が紛れ込んでいないことを、送る前に必ず見る。
# 一度公開すると取り消せない。
if find "$SITE" -name '*.pvlt' | grep -q .; then
  echo "中止: $SITE に .pvlt が入っています" >&2
  find "$SITE" -name '*.pvlt' >&2
  exit 1
fi

VERSION=$(python3 -c "
import re, pathlib
print(re.search(r'PASSVAULT_BUILD = \"(\w+)\"', pathlib.Path('$SITE/index.html').read_text()).group(1))")

echo "==> 送る（版 $VERSION）"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$SITE/." "$WORK/"

git -C "$WORK" init -b gh-pages -q
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "PassVault web 版を配信（版 $VERSION）

Web/build.py --site の出力。生成物なので main には入れず、この枝だけに置く。"
git -C "$WORK" remote add origin "$REMOTE"

# 生成物の履歴は残す意味がないので、毎回入れ替える。
git -C "$WORK" push -q --force origin gh-pages

echo "==> 完了（版 $VERSION）"
echo "    設定の「この画面の版」がこれになれば、届いています。"
