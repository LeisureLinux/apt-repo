APT ?= aptly
export APTLY ?= $(APT)

.PHONY: help init publish deploy fetch

help:          ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

init:          ## 初始化 GPG 签名密钥
	bash scripts/init-gpg.sh

publish:       ## 把 incoming/*.deb 发布到所有发行版
	bash scripts/publish.sh

deploy:        ## 把产物推送到 gh-pages
	bash scripts/deploy-ghpages.sh

fetch:         ## 按 debs.list 下载 .deb 到 incoming/
	mkdir -p incoming
	@while IFS= read -r url; do \
		[[ -z "$$url" || "$$url" == \#* ]] && continue; \
		echo "⬇️  $$url"; \
		curl -fsSL -o "incoming/$$(basename "$$url")" "$$url"; \
	done < debs.list
