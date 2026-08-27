# extrepo 数据源（`extrepo-data/`）

本目录存放用 Debian 官方工具 [extrepo](https://manpages.debian.org/extrepo)
管理 `repo.freelamp.com` 所需的**生成脚本与说明**。实际发布产物由
`scripts/generate-extrepo-data.sh` 在每次发布时生成，并随 GitHub Pages 部署到
`https://repo.freelamp.com/extrepo-data/`，**不提交到 git**。

## 用户怎么用

```bash
sudo apt install extrepo

# 把 freelamp 公钥追加进 extrepo 的密钥环（不会覆盖 Debian 官方密钥）
curl -fsSL https://repo.freelamp.com/extrepo-data/debian/bookworm/freelamp.asc \
  | sudo gpg --no-default-keyring --keyring /etc/extrepo/keyring.gpg --import

# 按当前系统发行版启用（默认配置 + --url 即可，无需改 /etc/extrepo/config.yaml）
codename=$(. /etc/os-release; echo $VERSION_CODENAME)
sudo extrepo --url https://repo.freelamp.com/extrepo-data enable freelamp-$codename
sudo apt update
```

启用后配置文件：`/etc/apt/sources.list.d/extrepo_freelamp-<codename>.sources`。
更新：`sudo extrepo update freelamp-<codename>`；禁用：`sudo extrepo disable freelamp-<codename>`。

## 设计要点（对应 extrepo 源码 `Data.pm` / `Enable.pm`）

- extrepo 从 `<url>/<dist>/<version>/index.yaml`（及其 `.asc` 签名）拉取数据，并用
  `gpgv --keyring /etc/extrepo/keyring.gpg` 校验签名（该 keyring 路径硬编码，无配置项）。
- `generate-extrepo-data.sh` 按 `conf/distros.txt` 的每个发行版生成一个
  `freelamp-<codename>` 条目，复用本仓库既有的 apt 签名密钥（`keys/apt.key`）对
  `index.yaml` 做 detached 签名，并把同一把公钥作为 `freelamp.asc` 提供给 apt 的 `Signed-By`。
- 因此**索引签名与 apt 包签名同源**，用户只需导入一把公钥即可。
- 产物部署路径：`extrepo-data/debian/<codename>/`（与客户端默认 `version=<codename>` 对应），
  所以用户用默认配置 + `--url` 即可，无需修改 `/etc/extrepo/config.yaml`。
- 新增 / 更新包**不需要**改这里；只有改 URL、套件、组件、架构或轮换 GPG 密钥时才需重新生成并部署。
