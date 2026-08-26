#!/usr/bin/env python3
"""保管庫ファイルが壊れていないかを、復号せずに検める。

  python3 Web/check-vault.py ~/Google\\ Drive/My\\ Drive/Personal/PassVault/vault.pvlt

マスターパスワードは要らないし、聞かない。中身は一切読まない。
見るのは平文のヘッダ（形式・鍵導出の設定）と、暗号化部分の長さだけ。

クラウド同期のあとに「ちゃんとしたファイルのままか」を確かめるのに使う。
中身が正しいかどうかは、実際にアプリで開いてみるしか確かめる方法がない
（それが暗号として正しい振る舞い）。
"""

import struct
import sys
from pathlib import Path

HEADER_BYTES = 44
MAGIC = b"PVLT"
GCM_NONCE = 12
GCM_TAG = 16


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = Path(sys.argv[1]).expanduser()
    if not path.exists():
        print(f"✗ ファイルがありません: {path}")
        return 1

    data = path.read_bytes()
    print(f"ファイル: {path}")
    print(f"大きさ  : {len(data):,} バイト")

    problems = []

    if len(data) < HEADER_BYTES + GCM_NONCE + GCM_TAG:
        print("✗ 短すぎます。保管庫として成立していません。")
        return 1

    magic = data[:4]
    version, kdf = struct.unpack(">HH", data[4:8])
    (iterations,) = struct.unpack(">I", data[8:12])
    salt = data[12:HEADER_BYTES]
    body = data[HEADER_BYTES:]

    def line(label, value, ok, note=""):
        mark = "✓" if ok else "✗"
        print(f"  {mark} {label}: {value}{note}")
        if not ok:
            problems.append(label)

    print("ヘッダ:")
    line("マジック", magic.decode("latin1"), magic == MAGIC)
    line("形式の版", version, version == 1)
    line("鍵導出方式", f"{kdf}（1 = PBKDF2-HMAC-SHA512）", kdf == 1)
    # 下限だけ見ていると、壊れたファイルの出鱈目な値（16 億など）が通ってしまう。
    # 現実的な範囲に収まっているかを見る。
    plausible = 100_000 <= iterations <= 50_000_000
    line("反復回数", f"{iterations:,}", plausible,
         "" if plausible else ("  ← 少なすぎます" if iterations < 100_000 else "  ← 現実的な値ではありません"))
    line("salt の長さ", f"{len(salt)} バイト", len(salt) == 32)
    line("salt が全部同じ値でない", "問題なし", len(set(salt)) > 4)

    print("暗号化されている部分:")
    payload = len(body) - GCM_NONCE - GCM_TAG
    line("長さの整合", f"{len(body):,} バイト（nonce {GCM_NONCE} + 本文 {payload:,} + タグ {GCM_TAG}）",
         payload > 0)

    # 平文が混ざっていないことの確認。混ざっていたら暗号化に失敗している。
    suspicious = [w for w in (b"password", b'{"items', b'"title"', b"http://", b"https://",
                              b"otpauth", b"schemaVersion") if w in body]
    line("平文の痕跡", "なし" if not suspicious else f"あり: {suspicious}", not suspicious)

    # 暗号文はランダムに近いはず。偏っていたら壊れている可能性がある。
    unique = len(set(body))
    line("バイトの散らばり", f"256 種のうち {unique} 種", unique > 200,
         "" if unique > 200 else "  ← 暗号文としては偏りすぎです")

    print()
    if problems:
        print(f"✗ {len(problems)} 件おかしい点があります: {', '.join(problems)}")
        return 1
    print("✓ 保管庫として正しい形をしています。")
    print("  中身が正しいかどうかは、アプリで開いてみて初めて分かります")
    print("  （暗号として、開く以外に確かめる手段はありません）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
