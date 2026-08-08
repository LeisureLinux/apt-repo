#!/bin/bash
# 从 conf/sources.txt 拉取各项目最新 release 的 .deb 到 incoming/
# 用法: GITHUB_TOKEN=xxx bash scripts/fetch-sources.sh   （CI 里自动带 token）
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p incoming

AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

while IFS= read -r spec; do
    [[ -z "$spec" || "$spec" == \#* ]] && continue
    tag=""
    if [[ "$spec" == *"@"* ]]; then
        tag="${spec##*@}"
        spec="${spec%%@*}"
    fi

    if [[ -n "$tag" ]]; then
        echo "📥 $spec @ $tag（锁定版本）"
        api_url="https://api.github.com/repos/$spec/releases/tags/$tag"
    else
        echo "📥 $spec（最新 release）"
        api_url="https://api.github.com/repos/$spec/releases/latest"
    fi

    curl -fsSL "$api_url" "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
        | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' > /tmp/deb-urls.txt

    if [[ ! -s /tmp/deb-urls.txt ]]; then
        echo "   ⚠️ 该 release 没有 .deb 资产，跳过"
        continue
    fi
    while IFS= read -r url; do
        echo "   ⬇️  $(basename "$url")"
        curl -fsSL --connect-timeout 20 --max-time 600 -o "incoming/$(basename "$url")" "$url"
    done < /tmp/deb-urls.txt
done < conf/sources.txt

echo "📦 incoming/ 现有包:"
ls -1 incoming/ 2>/dev/null | sed 's/^/   /'
