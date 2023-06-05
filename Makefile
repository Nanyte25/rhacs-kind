# Specify forked repos for development purposes.
SCANNER_GIT_REPO_OWNER := stackrox
STACKROX_GIT_REPO_OWNER := stackrox

# Set the following to point to a specific image tag.
SCANNER_BUILD_TAG := latest
CENTRAL_BUILD_TAG := latest

# The following variables are used by the operator as env vars.
export RELATED_IMAGE_MAIN := localhost:5001/main:$(CENTRAL_BUILD_TAG)
export RELATED_IMAGE_CENTRAL_DB := localhost:5001/central-db:$(CENTRAL_BUILD_TAG)
export RELATED_IMAGE_SCANNER := localhost:5001/scanner:$(SCANNER_BUILD_TAG)
export RELATED_IMAGE_SCANNER_DB := localhost:5001/scanner-db:$(SCANNER_BUILD_TAG)


# We are using a git repo for building scanner images. Unfortunately, go cares about .git
# directories therefore we have to patch the build command with -buildvcs=false.
SCANNER_BUILD_CMD := `go build -buildvcs=false -trimpath -ldflags="-X \
	github.com/stackrox/scanner/pkg/version.Version=$(TAG)" \
	-o image/scanner/bin/scanner ./cmd/clair`

.PHONY: clone-repos
clone-repos:
	sh scripts/clone-repo.sh git@github.com:$(SCANNER_GIT_REPO_OWNER)/scanner.git && \
	sh scripts/clone-repo.sh git@github.com:$(STACKROX_GIT_REPO_OWNER)/stackrox.git

.PHONY: clean
clean: delete-cluster
	@read -p "Continue to delete the local scanner and stackrox repos/dirs? [y/n]: " yn; \
    if [ "$$yn" = "y" ]; then \
        rm -rf scanner stackrox; \
    fi

.PHONY: create-namespaces
create-namespaces:
	kubectl create ns stackrox

.PHONY: bootstrap
bootstrap: clone-repos create-cluster create-namespaces run-k8s-dashboard

.PHONY: create-cluster
create-cluster:
	sh scripts/kind-with-registry.sh && \
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml; \
	kubectl create serviceaccount -n kubernetes-dashboard admin-user; \
	kubectl create clusterrolebinding -n kubernetes-dashboard admin-user \
		--clusterrole cluster-admin \
		--serviceaccount=kubernetes-dashboard:admin-user;
	kubectl -n kubernetes-dashboard rollout status deployment kubernetes-dashboard

.PHONY: delete-cluster
delete-cluster:
	@read -p "Are you sure you want to delete the kind acs cluster? [y/n]: " yn; \
	if [ "$$yn" = "y" ]; then \
		kind delete cluster --name acs && docker rm -f kind-registry; \
	fi

.PHONY: run-k8s-dashboard
run-k8s-dashboard:
	kubectl -n kubernetes-dashboard create token admin-user; \
	echo "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"; \
	kubectl proxy

.PHONY: up
up: up-scanner up-central build-operator run-operator

.PHONY: up-scanner
ifeq (,$(wildcard image/scanner/dump/dump.zip))
up-scanner: init-scanner-build build-scanner push-scanner push-scanner-db
else
up-scanner: build-scanner push-scanner push-scanner-db
endif

.PHONY: up-central
up-central: build-central push-main

.PHONY: init-scanner-build
init-scanner-build:
	cd scanner && \
	make build-updater && \
	bin/updater generate-dump --out-file image/scanner/dump/dump.zip && \
	unzip image/scanner/dump/dump.zip -d image/scanner/dump && \
	gsutil cp gs://stackrox-scanner-ci-vuln-dump/pg-definitions.sql.gz image/db/dump/definitions.sql.gz

.PHONY: push-scanner
push-scanner:
	docker tag scanner:$(SCANNER_BUILD_TAG) $(RELATED_IMAGE_SCANNER) && \
	docker push $(RELATED_IMAGE_SCANNER)

.PHONY: push-scanner-db
push-scanner-db:
	docker tag scanner-db:$(SCANNER_BUILD_TAG) $(RELATED_IMAGE_SCANNER_DB) && \
	docker push $(RELATED_IMAGE_SCANNER_DB)

# Changed directory to scanner because scanner Makefile uses $CURDIR
.PHONY: build-scanner
build-scanner:
	cd scanner && make scanner-image BUILD_CMD="$(SCANNER_BUILD_CMD)" TAG=$(SCANNER_BUILD_TAG)

# Changed directory to scanner because scanner Makefile uses $CURDIR
.PHONY: build-scanner-db
build-scanner-db:
	cd scanner && make db-image BUILD_CMD="$(SCANNER_BUILD_CMD)" TAG=$(SCANNER_BUILD_TAG)

.PHONY: build-central
build-central:
	STORAGE=pvc \
	SKIP_UI_BUILD=1 \
	ROX_IMAGE_FLAVOR=development_build \
	make -C stackrox image TAG=$(CENTRAL_BUILD_TAG)

.PHONY: build-main
build-main:
	STORAGE=pvc \
	SKIP_UI_BUILD=1 \
	ROX_IMAGE_FLAVOR=development_build \
	make -C stackrox docker-build-main-image TAG=$(CENTRAL_BUILD_TAG)

.PHONY: push-main
push-main:
	docker tag stackrox/main:$(CENTRAL_BUILD_TAG) $(RELATED_IMAGE_MAIN) && \
	docker push $(RELATED_IMAGE_MAIN) && \
	docker tag stackrox/central-db:$(CENTRAL_BUILD_TAG) $(RELATED_IMAGE_CENTRAL_DB) && \
	docker push $(RELATED_IMAGE_CENTRAL_DB)

.PHONY: build-operator
build-operator:
	make -C stackrox/operator install \
		ROX_IMAGE_FLAVOR=development_build

.PHONY: run-operator
run-operator:
	make -C stackrox/operator run \
		ROX_IMAGE_FLAVOR=development_build


.PHONY: apply-example-central
apply-example-central:
	kubectl apply -f stackrox/operator/tests/common/central-cr.yaml -n stackrox


.PHONY: delete-example-central
delete-example-central:
	kubectl delete central stackrox-central-services -n stackrox