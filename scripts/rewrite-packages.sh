#!/bin/bash
#
# rewrite-packages.sh
#
# After publish.sh generates the apt repository in .aptly/public/, this
# script:
#   1. Reads r2-uploads.txt (created by upload-to-r2.sh, mapping
#      pool_path → r2_public_url) and r2-debs.txt (created by publish.sh,
#      mapping pkg/arch → local .deb path)
#   2. For each R2-only package, generates a Packages stanza from the
#      .deb's metadata + R2 URL, and appends it to every
#      dists/*/main/binary-*/Packages[.gz] file
#   3. Regenerates Packages.gz for affected distros
#   4. Calls `aptly publish update` for each affected distro so that
#      Release/InRelease get re-signed (the new file checksums and sizes
#      are taken from the freshly-written Packages*)
#
# Note: large .deb files were intentionally NOT added to the aptly repo,
# so the pool/ directory does not contain them. The Packages file entries
# we add point at the R2 public URL.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PUB="$ROOT/.aptly/public"
MAPPING_FILE="$ROOT/r2-uploads.txt"
DEBS_FILE="$ROOT/r2-debs.txt"

if [[ ! -f "$MAPPING_FILE" || ! -s "$MAPPING_FILE" ]]; then
    echo "📦 r2-uploads.txt 为空，没有 R2 包需要追加到 Packages"
    exit 0
fi
if [[ ! -f "$DEBS_FILE" || ! -s "$DEBS_FILE" ]]; then
    echo "❌ $DEBS_FILE 不存在或为空（publish.sh 应该生成它）"
    exit 1
fi
if [[ ! -d "$PUB" ]]; then
    echo "❌ $PUB 不存在，请先运行 publish.sh"
    exit 1
fi

echo "🔧 追加 R2 包到 Packages 文件..."

# --- 解析 mapping: 每行 tab 分隔 (pool_path, r2_url) ---
declare -A R2_URLS=()
while IFS=$'\t' read -r pool_path r2_url; do
    [[ -z "$pool_path" || -z "$r2_url" ]] && continue
    fname=$(basename "$pool_path")
    R2_URLS[$fname]="$r2_url"
done < "$MAPPING_FILE"

# --- 解析 r2-debs.txt: 每行 tab 分隔 (pkg/arch, deb_path) ---
# 生成 Packages stanzas
STANZA_DIR=$(mktemp -d)
trap 'rm -rf "$STANZA_DIR"' EXIT

while IFS=$'\t' read -r key deb_path; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    fname=$(basename "$deb_path")
    r2_url="${R2_URLS[$fname]:-}"
    if [[ -z "$r2_url" ]]; then
        echo "   ⚠️  $key ($fname) 没有 R2 URL，跳过"
        continue
    fi

    # 生成该包的 Packages 条目（添加/替换 Filename 字段为 R2 URL）
    # key 格式为 pkg/arch，替换 / 为 _ 避免路径问题
    safe_key="${key//\//_}"
    stanza_file="$STANZA_DIR/${safe_key}.txt"
    dpkg-deb -f "$deb_path" > "$stanza_file"

    # 确保有 Filename 字段（dpkg-deb 不输出 Filename，需显式添加/替换）
    if grep -q '^Filename:' "$stanza_file"; then
        sed -i "s|^Filename:.*$|Filename: ${r2_url}|" "$stanza_file"
    else
        # 在 Description 字段之前插入 Filename（标准 Packages 格式中 Filename 通常在 Architecture 后 Description 前）
        sed -i "/^Description:/i Filename: ${r2_url}" "$stanza_file"
    fi

    echo "   📝 准备追加 $key (→ $r2_url)"
done < "$DEBS_FILE"

# --- 找到所有要追加的 Packages 文件 ---
PKG_FILES=$(find "$PUB/dists" -type f \( -name Packages -o -name 'Packages.gz' \) | sort)
if [[ -z "$PKG_FILES" ]]; then
    echo "❌ 找不到任何 Packages 文件，publish.sh 是否成功？"
    exit 1
fi

AFFECTED_DISTROS=()

# 为每个 (distro, arch) 决定要追加哪些 stanza
for stanza_file in "$STANZA_DIR"/*.txt; do
    [[ -f "$stanza_file" ]] || continue

    # 从 stanza 文件里读取 Package 和 Architecture 字段
    pkg_name=$(grep -m1 '^Package:' "$stanza_file" | cut -d' ' -f2)
    pkg_arch=$(grep -m1 '^Architecture:' "$stanza_file" | cut -d' ' -f2)

    # 找到该架构的 Packages 文件
    while IFS= read -r pkg_file; do
        rel_pkg="${pkg_file#$PUB/}"
        # 形如 dists/trixie/main/binary-amd64/Packages(.gz)
        if [[ "$rel_pkg" == *"/binary-${pkg_arch}/"* ]]; then
            dist_path=$(echo "$rel_pkg" | sed -E 's|/binary-[^/]+/Packages.*$||')
            AFFECTED_DISTROS+=("$dist_path")

            # 如果是 .gz，先解压到临时文件
            if [[ "$pkg_file" == *.gz ]]; then
                tmp=$(mktemp)
                gunzip -c "$pkg_file" > "$tmp"
                target="$tmp"
            else
                target="$pkg_file"
            fi

            # 追加 stanza 到 Packages
            echo "" >> "$target"
            cat "$stanza_file" >> "$target"
            echo "   ✏️  $rel_pkg: 追加 $pkg_name stanza"

            # 重新压缩
            if [[ "$pkg_file" == *.gz ]]; then
                gzip -c "$target" > "$pkg_file"
                rm -f "$target"
            fi
        fi
    done < <(echo "$PKG_FILES")
done

# --- 重新签名受影响的 distros 的 Release / InRelease ---
if [[ ${#AFFECTED_DISTROS[@]} -gt 0 ]]; then
    UNIQUE_DISTROS=($(printf '%s\n' "${AFFECTED_DISTROS[@]}" | sort -u))
    echo
    echo "🔐 重新签名受影响的 distros: ${UNIQUE_DISTROS[*]}"

    KEYID="$(bash scripts/init-gpg.sh | sed -n 's/^KEYID=//p' | tail -1)"
    CFG="$ROOT/aptly.conf"
    APTLY="${APTLY:-aptly}"

    for dist_path in "${UNIQUE_DISTROS[@]}"; do
        distro=$(echo "$dist_path" | cut -d/ -f2)
        if "$APTLY" -config="$CFG" publish show "$distro" >/dev/null 2>&1; then
            echo "   🔏 重新签名 $distro"
            "$APTLY" -config="$CFG" publish update \
                -gpg-key="$KEYID" \
                "$distro" 2>&1 | sed 's/^/      /' || {
                echo "      ⚠️  aptly publish update 失败（详见上方），请人工检查"
            }
        else
            echo "   ⚠️  $distro 还未发布，跳过重新签名"
        fi
    done
fi

echo
echo "✅ R2 包追加完成"