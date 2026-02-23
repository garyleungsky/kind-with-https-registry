.PHONY: up down clean status verify help

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: ## Create cluster and registry
	@./scripts/cluster.sh up

down: ## Destroy cluster and registry
	@./scripts/cluster.sh down

clean: ## Remove generated certificates
	@./scripts/cluster.sh clean

status: ## Check status of cluster and registry
	@./scripts/cluster.sh status

verify: ## Test registry connectivity
	@./scripts/cluster.sh verify
