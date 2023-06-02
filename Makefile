# Build tag to use
SCANNER_BUILD_TAG := latest
CENTRAL_BUILD_TAG := latest

# Image tags to use
ROX_MAIN_REGISTRY := localhost:5001
ROX_MAIN_VERSION := latest
ROX_SCANNER_VERSION := latest

# We are using a git repo for building scanner images. Unfortunately, go cares about .git
# directories therefore we have to patch the build command with -buildvcs=false.
SCANNER_BUILD_CMD := `go build -buildvcs=false -trimpath -ldflags="-X \
	github.com/stackrox/scanner/pkg/version.Version=$(TAG)" \
	-o image/scanner/bin/scanner ./cmd/clair`


# Cluster

.PHONY: create-cluster
create-cluster:
	sh kind-with-registry.sh && \
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml; \
	kubectl create serviceaccount -n kubernetes-dashboard admin-user; \
	kubectl create clusterrolebinding -n kubernetes-dashboard admin-user \
		--clusterrole cluster-admin \
		--serviceaccount=kubernetes-dashboard:admin-user;
	kubectl -n kubernetes-dashboard rollout status deployment kubernetes-dashboard

.PHONY: delete-cluster
delete-cluster:
	kind delete cluster --name acs && docker rm -f kind-registry

.PHONY: run-k8s-dashboard
run-k8s-dashboard:
	kubectl -n kubernetes-dashboard create token admin-user; \
	echo "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"; \
	kubectl proxy


# Scanner

.PHONY: init-scanner-build
init-scanner-build: apply-patches
	cd scanner && \
	make build-updater && \
	bin/updater generate-dump --out-file image/scanner/dump/dump.zip && \
	unzip image/scanner/dump/dump.zip -d image/scanner/dump && \
	gsutil cp gs://stackrox-scanner-ci-vuln-dump/pg-definitions.sql.gz image/db/dump/definitions.sql.gz

.PHONY: push-scanner
push-scanner:
	docker tag scanner:$(SCANNER_BUILD_TAG) $(ROX_MAIN_REGISTRY)/scanner:$(SCANNER_BUILD_TAG) && \
	docker push $(ROX_MAIN_REGISTRY)/scanner:$(SCANNER_BUILD_TAG)

.PHONY: push-scanner-db
push-scanner-db:
	docker tag scanner-db:$(SCANNER_BUILD_TAG) $(ROX_MAIN_REGISTRY)/scanner-db:$(SCANNER_BUILD_TAG) && \
	docker push $(ROX_MAIN_REGISTRY)/scanner-db:$(SCANNER_BUILD_TAG)

.PHONY: build-scanner
build-scanner:
	make -C scanner scanner-image BUILD_CMD="$$SCANNER_BUILD_CMD" TAG=$(SCANNER_BUILD_TAG)

.PHONY: build-scanner-db
build-scanner-db:
	make -C scanner db-image BUILD_CMD="$$SCANNER_BUILD_CMD" TAG=$(SCANNER_BUILD_TAG)


# Central

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

.PHONY: push-central
push-main:
	docker tag stackrox/main:$(CENTRAL_BUILD_TAG) $(ROX_MAIN_REGISTRY)/main:$(CENTRAL_BUILD_TAG) && \
	docker push $(ROX_MAIN_REGISTRY)/main:$(CENTRAL_BUILD_TAG) && \
	docker tag stackrox/central-db:$(CENTRAL_BUILD_TAG) $(ROX_MAIN_REGISTRY)/central-db:$(CENTRAL_BUILD_TAG) && \
	docker push $(ROX_MAIN_REGISTRY)/central-db:$(CENTRAL_BUILD_TAG)

# Stackrox Operator

.PHONY: build-operator
build-operator:
	make -C stackrox/operator install \
		ROX_IMAGE_FLAVOR=development_build \
		ROX_MAIN_REGISTRY=$(ROX_MAIN_REGISTRY) \
		ROX_MAIN_VERSION=$(ROX_MAIN_VERSION) \
		ROX_SCANNER_VERSION=$(ROX_SCANNER_VERSION)

.PHONY: run-operator
run-operator:
	make -C stackrox/operator run \
		ROX_IMAGE_FLAVOR=development_build \
		ROX_MAIN_REGISTRY=$(ROX_MAIN_REGISTRY) \
		ROX_MAIN_VERSION=$(ROX_MAIN_VERSION) \
		ROX_SCANNER_VERSION=$(ROX_SCANNER_VERSION)
