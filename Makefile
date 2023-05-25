ODIN ?= ~/odin/odin
DB_NAME ?= odin-playground
PORT ?= 8080
CONFIG = \
	-define:DB_HOST=$(DB_HOST) \
	-define:DB_USERNAME=$(DB_USERNAME) \
	-define:DB_PASSWORD=$(DB_PASSWORD) \
	-define:DB_NAME=$(DB_NAME) \
	-define:ODIN_VERSION_DETAILED="$(shell $(ODIN) version)" \
	-define:GITHUB_AUTH_HEADER="$(GITHUB_AUTH_HEADER)" \
	-define:PORT=$(PORT)

ifeq ($(shell uname), Darwin)
CONFIG += -minimum-os-version:13.0.0
endif

.PHONY: build
build:
	$(ODIN) build . -o:speed -out:odin-playground $(CONFIG)

.PHONY: run
run:
	$(ODIN) run . $(CONFIG) -debug
