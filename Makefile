TF ?= terraform
STACK ?= inventory
VAR_FILE ?=
PLAN ?=

.PHONY: help install fmt init validate plan apply offline-bundle

help:
	@echo "make install"
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
