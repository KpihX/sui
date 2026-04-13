.DEFAULT_GOAL := help

help:  ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

push:  ## Push current branch to all remotes (github + gitlab)
	@branch="$$(git branch --show-current)"; \
	for remote in $$(git remote); do \
		echo "==> pushing $$branch to $$remote"; \
		git push "$$remote" "$$branch"; \
	done

git-status:  ## git status --short
	@git status --short

lint:  ## Syntax check (bash -n); shellcheck if installed
	@bash -n sui.sh
	@command -v shellcheck >/dev/null 2>&1 && shellcheck sui.sh || true
