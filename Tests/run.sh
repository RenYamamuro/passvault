#!/bin/bash
# コアの検証。アプリを起動せず、暗号・TOTP・Watchtower などの正しさだけを確かめる。
#   ./Tests/run.sh
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
swiftc -O -o "$OUT/cryptocheck" \
  Tests/main.swift \
  PassVault/Core/VaultCrypto.swift \
  PassVault/Core/VaultItem.swift \
  PassVault/Core/ItemField.swift \
  PassVault/Core/ItemCategory.swift \
  PassVault/Core/OneTimePassword.swift \
  PassVault/Core/PasswordStrength.swift \
  PassVault/Core/PasswordGenerator.swift \
  PassVault/Core/Watchtower.swift \
  PassVault/Core/SyncMerge.swift \
  PassVault/Core/SyncCrypto.swift
"$OUT/cryptocheck"
