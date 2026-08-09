# apt-repo — Freelamp 的 Debian/Ubuntu APT 仓库

用 [aptly](https://www.aptly.info/) 维护、**GitHub Pages 托管**、`repo.freelamp.com` 自定义域名分发的 APT 软件仓库。

支持：
- 多发行版：`conf/distros.txt` 里每个 codename 一个套件（当前默认 `bookworm` / `trixie`）
- 多架构：自动识别 .deb 的 `Architecture` 字段（amd64 / arm64 / armhf / loong64 / riscv64 …）
- 自己的包 + 重打包的第三方二进制（注意许可证，见文末）

## 目录结构

```
apt-repo/
├── conf/
│   ├── aptly.conf.tpl     # aptly 配置模板（publish.sh 自动生成 apt-repo/aptly.conf）
│   └── distros.txt        # 要发布的发行版 codename 列表
├── incoming/              # 待入库的 .deb（gitignore，不提交）
├── keys/apt.key           # GPG 公钥（发布时生成，可提交，给用户安装用）
├── scripts/
│   ├── init-gpg.sh        # 生成/复用 GPG 签名密钥
│   ├── publish.sh         # 核心：incoming/*.deb → aptly repo → snapshot → publish
│   ├── generate-index.sh  # 自动生成首页/软件包列表/dists/pool 索引
│   └── deploy-ghpages.sh  # 本地手动部署：把产物推送到 gh-pages 分支
├── .github/workflows/publish.yml  # CI：tag 触发 → 拉包 → 发布 → 部署 Pages
├── debs.list              # CI 拉取 .deb 直链清单（可选）
└── CNAME                  # repo.freelamp.com
```

发布产物在 `.aptly/public/`（gitignore），也就是将来 `gh-pages` 分支的全部内容：

```
public/
├── dists/
│   ├── bookworm/
│   │   ├── Release / InRelease          # InRelease = GPG 签名的 Release
│   │   └── main/binary-<arch>/Packages{,.gz,.xz}
│   └── trixie/...
├── pool/main/<prefix>/<pkg>_<ver>_<arch>.deb
├── index.html                           # 首页（generate-index.sh 自动生成，含软件包列表链接）
├── packages/index.html                  # 独立软件包列表（owner/repo、vX.Y.Z、Commit Hash，自动生成）
├── dists/index.html                     # 发行版目录索引（自动生成）
├── dists/<codename>/index.html          # 每个发行版的组件/架构索引（自动生成）
├── pool/index.html                      # 所有 .deb 文件清单（自动生成）
├── apt.key                              # 公钥，用户端安装用
└── CNAME
```

## 本地快速开始

```bash
cd apt-repo
make init            # 生成 GPG 签名密钥（无口令，适合 CI）
cp ../ghdeb/dist/*.deb incoming/   # 把 .deb 放进 incoming/
make publish         # 发布到 conf/distros.txt 里的所有发行版
make deploy          # 推送到 gh-pages 分支（需要先建好 GitHub 仓库）
```

本地预览：`cd .aptly/public && python3 -m http.server 8080`

## 发布新包

1. 把新 `.deb` 丢进 `incoming/`（或加到 `debs.list`，CI 会自动下载）
2. 本地 `make publish`，检查 `.aptly/public/dists/` 结构
3. `make deploy` 或打 tag 走 CI

## CI 自动发布

1. 在 GitHub 建同名仓库（如 `LeisureLinux/apt-repo`），Settings → Pages → 选 `gh-pages` 分支
2. 把本地私钥存成 Secret：
   ```bash
   gpg --armor --export-secret-keys <KEYID> | gh secret set APT_GPG_PRIVATE_KEY
   ```
3. 打 tag 或在 Actions 页面手动触发 `Publish APT Repo`
4. workflow 里 `cname: repo.freelamp.com` 已自动写入 CNAME

> DNS 已配好：`repo.freelamp.com` CNAME → `leisurelinux.github.io`（阿里云云解析）
> GitHub 上首次设置自定义域名时若提示验证，按提示加一条 TXT 记录即可。

## 自动同步（ghdeb / unbound-dashboard 等项目联动）

apt-repo 维护一份**声明式源列表** `conf/sources.txt`（每行一个项目，可选 `@tag` 锁定版本）。
每次发布（手动 / 项目发版联动 / 每天 02:00 UTC 定时兜底）都会：

1. 遍历 `conf/sources.txt`，从每个项目的 **GitHub Releases 最新版** 拉取全部 `.deb` 资产到 `incoming/`
2. 同时按 `debs.list` 拉取第三方重打包包（可选）
3. aptly 增量入库（只加不删）→ 快照 → 签名发布 → 部署 gh-pages

**给新项目接入只需两步：**

```bash
# 1. 把项目加进源列表（发版后自动同步，无需改 workflow）
echo "LeisureLinux/新项目" >> conf/sources.txt

# 2.（可选）让该项目发版后"即时"触发，而非等每天定时——
#    在项目仓库放一个 dispatch workflow（参考 ghdeb 的 publish-to-apt.yml），
#    并设置跨仓库 token：
gh secret set APT_REPO_TOKEN --repo <项目仓库>
```



## 首页、软件包列表与目录索引（自动更新）

`repo.freelamp.com` 的首页、软件包列表页以及 `/dists/`、`/pool/` 目录索引由 **`scripts/generate-index.sh`** 在每次发布时自动生成（CI 中位于「Publish with aptly」之后、部署 Pages 之前）：

- **首页 `index.html`**：简洁入口页，包含添加软件源、支持的发行版、使用警告，并提供指向软件包列表的链接。
- **`/packages/`**：独立软件包列表页，逐包列出包名、GitHub 上游 `owner/repo`、版本号 `vX.Y.Z` 与 Commit Hash。数据直接从 `dists/<codename>/main/binary-amd64/Packages` 的 `Description` 字段（`Upstream:` / `Commit:`）动态提取，新增的包发布后自动出现，无需手工维护。
- **`/dists/`**：列出各发行版（bookworm / trixie …）及架构徽章。
- **`/dists/<codename>/`**：列出每个发行版的组件（main …）与架构。
- **`/pool/`**：列出所有 `.deb` 文件的链接。

> 之所以需要生成这些 `index.html`，是因为 **GitHub Pages 不会为裸目录（`/dists/`、`/pool/`）自动生成目录列表**——没有 `index.html` 就会 404。文件本身的访问不受影响。

本地预览：`cd .aptly/public && python3 -m http.server 8080`，然后访问 `/`、`/dists/`、`/pool/` 即可看到生成的索引。

## 用户端安装

```bash
# 安装公钥（Debian 12 / Ubuntu 22.04+ 推荐方式）
curl -fsSL https://repo.freelamp.com/apt.key | sudo gpg --dearmor -o /usr/share/keyrings/freelamp.gpg

# 添加源（以 bookworm 为例，trixie 等同理）
sudo tee /etc/apt/sources.list.d/freelamp.sources >/dev/null <<'EOF'
Types: deb
URIs: https://repo.freelamp.com
Suites: bookworm
Components: main
Signed-By: /usr/share/keyrings/freelamp.gpg
EOF

sudo apt update
apt-cache search ghdeb      # 确认能看到包
sudo apt install ghdeb
```

## 注意事项

- **GitHub Pages 限制**：单文件 ≤ 100MB；站点软上限 1GB；带宽软上限 100GB/月。小型工具包没问题，大型第三方包长期要考虑自建服务器或 Cloudflare R2。
- **第三方包再分发**：确认许可证允许再分发。GPL 系需附源码或源码链接；闭源软件需授权。
- **GPG 私钥**：务必备份（`gpg --export-secret-keys <KEYID>`），但**不要提交到 git**。
- **发行版耦合**：Go/Rust 静态二进制可跨发行版共用；依赖系统库的包需按发行版单独建 aptly repo（把 `publish.sh` 里 `freelamp` 换成 `freelamp-<codename>` 即可）。
