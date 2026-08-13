TOOLS_DIR ?= $(CURDIR)/.vsphere-tools/linux_amd64
TF ?= $(TOOLS_DIR)/bin/terraform
GOVC ?= $(TOOLS_DIR)/bin/govc
JQ ?= $(TOOLS_DIR)/bin/jq
export TF_CLI_CONFIG_FILE ?= $(TOOLS_DIR)/terraform.rc
STACK ?= inventory
VAR_FILE ?=
PLAN ?=
SERVER ?=
SOURCE_VM ?= tst-win-10-12
OUTPUT_DIR ?=
CA_CERT ?=

.PHONY: help install install-online check launcher trust scan fmt init validate plan apply offline-bundle verify-vendor

help:
	@echo "make install"
	@echo "make check"
	@echo "make launcher"
	@echo "make trust SERVER=incvc.inc.elara.local"
	@echo "make scan SOURCE_VM=tst-win-10-12 OUTPUT_DIR=/private/path/vsphere-scan"
	@echo "make fmt"
	@echo "make init STACK=inventory"
	@echo "make validate"
	@echo "make plan STACK=inventory VAR_FILE=/absolute/path/inventory.tfvars"
	@echo "make plan STACK=vm-clones VAR_FILE=/absolute/path/vm-clones.tfvars"
	@echo "make plan STACK=windows-clone VAR_FILE=/absolute/path/windows-clone.tfvars"
	@echo "ALLOW_VM_APPLY=yes make apply PLAN=/absolute/path/to/saved.tfplan"
	@echo "ALLOW_WINDOWS_CLONE_APPLY=yes make apply PLAN=/absolute/path/to/windows.tfplan"
	@echo "make offline-bundle PLATFORM=linux_amd64"

install:
	python3 ./vsphere.py install

install-online:
	./scripts/install-terraform.sh
	./scripts/install-govc.sh
	./scripts/install-jq.sh

check:
	python3 ./vsphere.py check

verify-vendor:
	./scripts/verify-vendor.sh

launcher:
	python3 ./vsphere.py

trust:
	python3 ./vsphere.py trust --server "$(SERVER)"

scan:
	@set -- --source-vm "$(SOURCE_VM)"; \
	if [ -n "$(OUTPUT_DIR)" ]; then set -- "$$@" --output-dir "$(OUTPUT_DIR)"; fi; \
	if [ -n "$(CA_CERT)" ]; then set -- "$$@" --ca-cert "$(CA_CERT)"; fi; \
	GOVC_BIN="$(GOVC)" JQ_BIN="$(JQ)" ./scripts/scan-vsphere.sh "$$@"

fmt:
	$(TF) fmt -check -recursive

init:
	$(TF) -chdir=stacks/$(STACK) init -input=false -lockfile=readonly

validate:
	TF_BIN="$(TF)" ./scripts/validate.sh

plan:
	TF_BIN="$(TF)" ./scripts/plan.sh "$(STACK)" "$(VAR_FILE)"

apply:
	TF_BIN="$(TF)" ./scripts/apply-reviewed-plan.sh "$(PLAN)"

offline-bundle:
	./scripts/build-offline-bundle.sh "$(PLATFORM)"
