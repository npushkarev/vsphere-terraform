TF ?= terraform
GOVC ?= govc
JQ ?= jq
STACK ?= inventory
VAR_FILE ?=
PLAN ?=
SOURCE_VM ?= tst-win-10-12
OUTPUT_DIR ?=
CA_CERT ?=

.PHONY: help install scan fmt init validate plan apply offline-bundle

help:
	@echo "make install"
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
	./scripts/install-terraform.sh
	./scripts/install-govc.sh
	./scripts/install-jq.sh

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
	TF_BIN="$(TF)" ./scripts/build-offline-bundle.sh "$(PLATFORM)"
