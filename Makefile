COMPOSE = docker compose
FILES = -f compose/kafka.yml -f compose/keycloak.yml -f compose/platform.yml -f compose/vault.yml

# ─── Network ───────────────────────────────────────────────────────────────────

network-create:
	docker network inspect arya-banking-net >nul 2>&1 || docker network create arya-banking-net

network-remove:
	docker network inspect arya-banking-net >nul 2>&1 && docker network rm arya-banking-net || cd .

# ─── Full Stack ────────────────────────────────────────────────────────────────

up: network-create
	$(COMPOSE) $(FILES) up -d

down:
	$(COMPOSE) $(FILES) down

restart:
	$(COMPOSE) $(FILES) restart

logs:
	$(COMPOSE) $(FILES) logs -f

ps:
	$(COMPOSE) $(FILES) ps

# ─── Individual Stacks ─────────────────────────────────────────────────────────

kafka: network-create
	$(COMPOSE) -f compose/kafka.yml up -d

kafka-down:
	$(COMPOSE) -f compose/kafka.yml down

keycloak: network-create
	$(COMPOSE) -f compose/keycloak.yml up -d

keycloak-down:
	$(COMPOSE) -f compose/keycloak.yml down

platform: network-create
	$(COMPOSE) -f compose/platform.yml up -d

platform-down:
	$(COMPOSE) -f compose/platform.yml down

vault: network-create
	$(COMPOSE) -f compose/vault.yml up -d

vault-down:
	$(COMPOSE) -f compose/vault.yml down

# ─── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	$(COMPOSE) $(FILES) down -v --remove-orphans

.PHONY: network-create network-remove up down restart logs ps \
        kafka kafka-down keycloak keycloak-down \
        platform platform-down vault vault-down clean
