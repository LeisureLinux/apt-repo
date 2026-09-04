#!/bin/bash
#
# upload-to-r2.sh
#
# Scans incoming/*.deb for files that exceed the GitHub Pages 100 MB limit
# and uploads them to Cloudflare R2 for serving through a custom domain
# (default: deb.freelamp.com).
#
# Outputs a mapping file `r2-uploads.txt` containing one line per uploaded
# file in the form: <pool-relative-path>=<public-r2-url>
#
# Used by publish.yml before publish.sh runs. The Packages post-processor
# reads r2-uploads.txt to rewrite Filename: fields for large packages.
#
# Prerequisites:
#   - AWS CLI configured with R2 credentials in ~/.aws/credentials
#   - Environment variables (or .codex/.env):
#       R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com
#       R2_ACCESS_KEY_ID=...
#       R2_SECRET_ACCESS_KEY=...
#       R2_BUCKET=freelamp-debs
#       R2_PUBLIC_BASE=https://deb.freelamp.com
#   - Size threshold (default 100 MB)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# --- 加载 R2 凭据（优先从 env，其次从 ~/.codex/.env） ---
if [[ -z "${R2_ENDPOINT:-}" || -z "${R2_ACCESS_KEY_ID:-}" || -z "${R2_SECRET_ACCESS_KEY:-}" ]]; then
    if [[ -f "$HOME/.codex/.env" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$HOME/.codex/.env"
        set +a
    fi
fi

R2_BUCKET="${R2_BUCKET:-freelamp-debs}"
R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://deb.freelamp.com}"
THRESHOLD_BYTES="${R2_THRESHOLD_BYTES:-104857600}"  # 100 MB

# --- 扫描 incoming/*.deb 找大文件 ---
shopt -s nullglob
LARGE_DEBS=()
for d in "$ROOT"/incoming/*.deb; do
    size=$(stat -c%s "$d")
    if [[ $size -gt $THRESHOLD_BYTES ]]; then
        LARGE_DEBS+=("$d")
    fi
done

# --- 没有大包：直接返回 0 ---
if [[ ${#LARGE_DEBS[@]} -eq 0 ]]; then
    echo "📦 没有超过 ${THRESHOLD_BYTES} 字节的 .deb，跳过 R2 上传"
    : > "$ROOT/r2-uploads.txt"   # 清空 mapping 文件
    exit 0
fi

# --- 有大包但没 R2 凭据：报错 ---
if [[ -z "${R2_ENDPOINT:-}" || -z "${R2_ACCESS_KEY_ID:-}" || -z "${R2_SECRET_ACCESS_KEY:-}" ]]; then
    echo "❌ 检测到 ${#LARGE_DEBS[@]} 个超过 $((THRESHOLD_BYTES / 1024 / 1024)) MB 的 .deb，但没有 R2 凭据"
    echo "   请在 GitHub Secrets 里配置 R2_ENDPOINT / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY"
    echo "   或者把包拆小后重试"
    for d in "${LARGE_DEBS[@]}"; do
        echo "   - $d ($(du -h "$d" | cut -f1))"
    done
    exit 1
fi

# --- 写 AWS CLI 凭据 ---
mkdir -p "$HOME/.aws"
if ! grep -q "R2_${R2_BUCKET}" "$HOME/.aws/credentials" 2>/dev/null; then
    cat > "$HOME/.aws/credentials" <<EOF
[default]
aws_access_key_id = ${R2_ACCESS_KEY_ID}
aws_secret_access_key = ${R2_SECRET_ACCESS_KEY}
EOF
    cat > "$HOME/.aws/config" <<EOF
[default]
region = auto
output = json
EOF
fi

echo "🚀 检测到 ${#LARGE_DEBS[@]} 个大包 (>$((THRESHOLD_BYTES / 1024 / 1024)) MB)，上传到 R2..."

# --- mapping 文件: 形如 pool/main/w/workbuddy/workbuddy_5.4.7_amd64.deb|https://deb.freelamp.com/... ---
MAPPING_FILE="$ROOT/r2-uploads.txt"
: > "$MAPPING_FILE"

for deb in "${LARGE_DEBS[@]}"; do
    fname=$(basename "$deb")
    size=$(stat -c%s "$deb")
    sha256=$(sha256sum "$deb" | awk '{print $1}')

    # 计算首个字母作为 pool 子目录（aptly 风格的字母索引）
    first_letter="${fname:0:1}"
    # 第二个字母（aptly 风格是包名第一个字母后再加一个字母）
    # 这里直接用 first_letter 的小写，与实际 well-formed 仓库对齐
    pkg_letter="$(echo "$first_letter" | tr '[:upper:]' '[:lower:]')"

    # 包名（去掉 _版本_架构.deb 后缀）
    pkg_name=$(echo "$fname" | sed -E 's/_[0-9][^_]*_amd64\.deb$//; s/_[0-9][^_]*_arm64\.deb$//; s/_[0-9][^_]*_all\.deb$//')

    # R2 上的路径: main/<letter>/<pkg>/<filename>
    r2_path="main/${pkg_letter}/${pkg_name}/${fname}"
    public_url="${R2_PUBLIC_BASE}/${r2_path}"

    echo "   ⬆️  ${fname} ($((size / 1024 / 1024)) MB) → ${r2_path}"

    aws s3 cp "$deb" \
        --endpoint-url "${R2_ENDPOINT}" \
        "s3://${R2_BUCKET}/${r2_path}" \
        --only-show-errors

    # 写入 mapping 文件（Tab 分隔，方便 awk 解析）
    printf 'pool/main/%s/%s/%s\t%s\n' "$pkg_letter" "$pkg_name" "$fname" "$public_url" >> "$MAPPING_FILE"
done

echo
echo "✅ R2 上传完成，mapping 文件: ${MAPPING_FILE}"
cat "$MAPPING_FILE"