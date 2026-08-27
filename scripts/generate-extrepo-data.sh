#!/bin/bash
# generate-extrepo-data.sh
# 为本仓库生成 extrepo 数据源，并部署到 .aptly/public/extrepo-data/debian/<codename>/ 下，
# 随 GitHub Pages 一起发布。这样用户即可用 Debian 官方工具 extrepo 来管理本源：
#
#   sudo extrepo --url https://repo.freelamp.com/extrepo-data enable freelamp-<codename>
#
# 设计要点（与 extrepo 源码 Data.pm / Enable.pm 对应）：
#   - extrepo 会拉取 <url>/<dist>/<version>/index.yaml 及其 .asc 签名，并用
#     gpgv --keyring /etc/extrepo/keyring.gpg 校验签名（keyring 路径硬编码）。
#   - index.yaml 里每个 repo 用 gpg-key-file 指向独立公钥文件，并按 gpg-key-checksum
#     (sha256) 校验；enable 时该公钥被写入 /var/lib/extrepo/keys/<name>.asc 作为 apt 的 Signed-By。
#   - 这里复用本仓库既有的 apt 签名密钥（keys/apt.key），所以索引签名与 apt 包签名同源，
#     用户只需把同一把公钥导入 extrepo 的 keyring 即可，无需第二把密钥。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PUBDIR="$ROOT/.aptly/public"

[[ -f keys/apt.key ]] || { echo "❌ 找不到 keys/apt.key"; exit 1; }
[[ -f conf/distros.txt ]] || { echo "❌ 找不到 conf/distros.txt"; exit 1; }

# --- 确定 apt 签名私钥：公钥必须 == keys/apt.key，且本地要有可用私钥才能签名 ---
FPR="$(gpg --show-keys --with-colons keys/apt.key 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
if [[ -z "$FPR" ]]; then
    echo "❌ 无法读取 keys/apt.key 指纹"; exit 1
fi
if ! gpg --list-secret-keys "$FPR" >/dev/null 2>&1; then
    echo "❌ apt 签名私钥不在本地密钥环，无法签名 index.yaml。"
    echo "   请在 CI（已导入 APT_GPG_PRIVATE_KEY）中运行，或先导入私钥："
    echo "   echo \"\$APT_GPG_PRIVATE_KEY\" | gpg --batch --import"
    exit 1
fi
KEYID="$FPR"

DEST_BASE="$PUBDIR/extrepo-data/debian"
mkdir -p "$DEST_BASE"

# --- 计算公钥 sha256（公钥即 keys/apt.key，直接复用）---
CHECKSUM="$(sha256sum keys/apt.key | cut -d' ' -f1)"
echo "🔑 freelamp.asc sha256: $CHECKSUM"

# --- 按 conf/distros.txt 为每个发行版生成 entry，合并为一个 index.yaml ---
TMP_IDX="$PUBDIR/.extrepo_index.yaml"
: > "$TMP_IDX"
while read -r distro; do
    [[ -z "$distro" || "$distro" == \#* ]] && continue
    # 先用占位符写模板，再针对本发行版替换，避免全局 sed 误伤已写入的块
    block="$(cat <<'YAML'
freelamp-__DISTRO__:
  description: Freelamp APT repository (repo.freelamp.com) — LeisureLinux 的 Debian/Ubuntu 软件源
  gpg-key-file: freelamp.asc
  gpg-key-checksum:
    sha256: __CHECKSUM__
  policy: main
  source:
    Types: deb
    URIs: https://repo.freelamp.com
    Suites: __DISTRO__
    Components: main
YAML
    )"
    block="${block//__DISTRO__/$distro}"
    block="${block//__CHECKSUM__/$CHECKSUM}"
    printf '%s\n' "$block" >> "$TMP_IDX"
done < conf/distros.txt

if [[ ! -s "$TMP_IDX" ]]; then
    echo "❌ 没有从 conf/distros.txt 生成任何 entry"; exit 1
fi

# --- 对 index.yaml 做 detached 签名（与 apt 包签名同源） ---
gpg --batch --pinentry-mode loopback --passphrase '' --local-user "$KEYID" \
    --detach-sign --armor -o "$PUBDIR/.extrepo_index.yaml.asc" "$TMP_IDX"
echo "✅ 已签名 index.yaml.asc"

# --- 部署到每个 codename 目录（与客户端默认 version=<codename> 对应，--url 即可，无需改配置） ---
while read -r distro; do
    [[ -z "$distro" || "$distro" == \#* ]] && continue
    dstdir="$DEST_BASE/$distro"
    mkdir -p "$dstdir"
    cp keys/apt.key               "$dstdir/freelamp.asc"
    cp "$TMP_IDX"                 "$dstdir/index.yaml"
    cp "$PUBDIR/.extrepo_index.yaml.asc" "$dstdir/index.yaml.asc"
done < conf/distros.txt

rm -f "$TMP_IDX" "$PUBDIR/.extrepo_index.yaml.asc"
echo "✅ extrepo 数据源已生成："
find "$DEST_BASE" -type f | sed "s|$PUBDIR/||"
