#!/bin/bash
# 初始化 APT 仓库 GPG 签名密钥（无口令，适合 CI）。
# 优先复用"能实际签名"的现有密钥（排除智能卡 stub 等不可用私钥），
# 否则生成一把专用于本仓库的签名密钥。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p keys

find_usable_key() {
    local cand keyid=""
    for cand in $(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/{print $5}'); do
        if printf 'probe' | gpg --batch --pinentry-mode loopback --passphrase '' \
            --local-user "$cand" --clearsign >/dev/null 2>&1; then
            keyid="$cand"
            break
        fi
    done
    echo "$keyid"
}

KEYID="$(find_usable_key)"
if [[ -n "$KEYID" ]]; then
    echo "✅ 复用可用签名密钥: $KEYID"
else
    echo "🔑 生成新的专用签名密钥（无口令，rsa4096）..."
    gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "Freelamp APT Repo (signing key) <apt@freelamp.com>" rsa4096 sign 0
    KEYID="$(find_usable_key)"
fi

gpg --armor --export "$KEYID" > keys/apt.key
echo "📄 公钥已导出: keys/apt.key"
echo "🔑 密钥 ID: $KEYID"
echo
echo "💡 备份私钥:  gpg --armor --export-secret-keys $KEYID > keys/apt.gpg.sec  (勿提交到 git!)"

echo "KEYID=$KEYID"
