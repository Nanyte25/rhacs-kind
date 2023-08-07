ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))

# Specify forked repos for development purposes.
SCANNER_GIT_REPO_OWNER := stackrox
STACKROX_GIT_REPO_OWNER := stackrox

# Set the following to point to a specific image tag.
SCANNER_BUILD_TAG := latest
CENTRAL_BUILD_TAG := latest
COLLECTOR_BUILD_TAG := latest
FLEETMANAGER_BUILD_TAG := latest

# The following variables are used by the operator as env vars.
export RELATED_IMAGE_MAIN := localhost:5001/main:$(CENTRAL_BUILD_TAG)
export RELATED_IMAGE_CENTRAL_DB := localhost:5001/central-db:$(CENTRAL_BUILD_TAG)
export RELATED_IMAGE_SCANNER := localhost:5001/scanner:$(SCANNER_BUILD_TAG)
export RELATED_IMAGE_SCANNER_DB := localhost:5001/scanner-db:$(SCANNER_BUILD_TAG)
export RELATED_IMAGE_COLLECTOR_FULL := localhost:5001/collector:$(COLLECTOR_BUILD_TAG)


# We are using a git repo for building scanner images. Unfortunately, go cares about .git
# directories therefore we have to patch the build command with -buildvcs=false.
SCANNER_BUILD_CMD := go build -buildvcs=false -trimpath -ldflags="-X github.com/stackrox/scanner/pkg/version.Version=$(TAG)" -o image/scanner/bin/scanner ./cmd/clair

.PHONY: clone-repos
clone-repos:
	sh scripts/clone-repo.sh git@github.com:$(STACKROX_GIT_REPO_OWNER)/scanner.git scanner;  \
	sh scripts/clone-repo.sh git@github.com:$(STACKROX_GIT_REPO_OWNER)/stackrox.git stackrox;  \
	sh scripts/clone-repo.sh git@github.com:$(STACKROX_GIT_REPO_OWNER)/collector.git collector true; \
	sh scripts/clone-repo.sh git@github.com:$(STACKROX_GIT_REPO_OWNER)/acs-fleet-manager.git acs-fleet-manager

.PHONY: clean
clean: delete-cluster

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
up: up-scanner up-central up-collector build-operator run-operator

.PHONY: up-scanner
ifeq (,$(wildcard scanner/image/scanner/dump/dump.zip))
up-scanner: init-scanner-build build-scanner build-scanner-db push-scanner push-scanner-db
else
up-scanner: build-scanner build-scanner-db push-scanner push-scanner-db
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

.PHONY: build-scanner
build-scanner:
	make -C scanner scanner-image BUILD_CMD='$(SCANNER_BUILD_CMD)' TAG=$(SCANNER_BUILD_TAG)

.PHONY: build-scanner-db
build-scanner-db:
	make -C scanner db-image BUILD_CMD='$(SCANNER_BUILD_CMD)' TAG=$(SCANNER_BUILD_TAG)

.PHONY: build-central
build-central:
	STORAGE=pvc \
	ROX_IMAGE_FLAVOR=development_build \
	make -C stackrox image TAG=$(CENTRAL_BUILD_TAG) SKIP_UI_BUILD=1

.PHONY: up-collector
up-collector: build-collector push-collector

.PHONY: build-collector
build-collector:
	make -C collector image COLLECTOR_TAG=$(COLLECTOR_BUILD_TAG)

.PHONY: push-collector
push-collector:
	docker tag quay.io/stackrox-io/collector:$(COLLECTOR_BUILD_TAG) $(RELATED_IMAGE_COLLECTOR_FULL) && \
	docker push $(RELATED_IMAGE_COLLECTOR_FULL)

.PHONY: build-main
build-main:
	STORAGE=pvc \
	ROX_IMAGE_FLAVOR=development_build \
	make -C stackrox docker-build-main-image TAG=$(CENTRAL_BUILD_TAG) SKIP_UI_BUILD=1

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

.PHONY: deploy-example-central
deploy-example-central:
	kubectl -n stackrox apply -f manifests/example-central.yaml

.PHONY: delete-example-central
delete-example-central:
	kubectl delete central stackrox-central-services -n stackrox

.PHONY: deploy-example-secured-cluster
deploy-example-secured-cluster:
	kubectl -n stackrox exec deploy/central -- \
  	roxctl central init-bundles generate my-test-bundle --insecure-skip-tls-verify --password letmein --output-secrets - \
  | kubectl -n stackrox apply -f -
	kubectl apply -n stackrox -f stackrox/operator/tests/common/secured-cluster-cr.yaml

.PHONY: init-monitoring
init-monitoring:
	kubectl create ns monitoring || \
	kubectl -n monitoring create -f manifests/prometheus-operator-bundle.yaml || \
	kubectl -n monitoring wait --for=condition=Ready pods -l  app.kubernetes.io/name=prometheus-operator && \
	kubectl -n monitoring apply -f manifests/prometheus-rbac.yaml && \
	kubectl -n monitoring apply -f manifests/prometheus.yaml && \
	kubectl -n monitoring wait --for=condition=Ready pods -l app.kubernetes.io/name=prometheus-operator && \
	kubectl -n monitoring apply -f manifests/prometheus-service.yaml

.PHONY: run-prometheus-console
run-prometheus-console:
	$(eval POD=$(shell kubectl -n monitoring get pods | grep prometheus-operator- | awk 'NR==1{print $$1}'))
	kubectl -n monitoring port-forward --address localhost $(POD) 9090:9090

.PHONY: init-monitoring-metrics
init-monitoring-metrics: init-monitoring
	sh scripts/clone-repo.sh https://github.com/kubernetes/kube-state-metrics.git kube-state-metrics; \
	kubectl apply -f kube-state-metrics/examples/standard; \
	kubectl apply -f manifests/kube-state-metrics.yaml; \
	kubectl -n monitoring apply -f manifests/rhacs-central-metrics.yaml; \
	kubectl -n monitoring apply -f manifests/rhacs-scanner-metrics.yaml; \
	kubectl -n monitoring apply -f manifests/node-exporter.yaml; \
	kubectl -n monitoring create secret generic additional-scrape-configs \
		--from-file manifests/cadvisor-scrape-config.yaml \
		--dry-run=client -oyaml > manifests/additional-scrape-configs.yaml; \
	kubectl -n monitoring apply -f manifests/additional-scrape-configs.yaml

.PHONY: delete-monitoring
delete-monitoring:
	kubectl delete crd scrapeconfigs.monitoring.coreos.com || \
	kubectl delete crd thanosruler.monitoring.coreos.com || \
	kubectl delete crd prometheusagent.monitoring.coreos.com || \
	kubectl delete crd prometheus.monitoring.coreos.com || \
	kubectl delete crd prometheusrule.monitoring.coreos.com || \
	kubectl delete crd alertmanagerconfig.monitoring.coreos.com || \
	kubectl delete crd alertmanager.monitoring.coreos.com || \
	kubectl delete crd podmonitor.monitoring.coreos.com || \
	kubectl delete ns monitoring

.PHONY: ui-port-forward
ui-port-forward:
	kubectl -n stackrox port-forward deploy/central --address localhost 8000:8443

.PHONY: up-ui
up-ui:
	make -C stackrox/ui start

PHONY: docker-rm-exited
docker-rm-exited:
	sh scripts/docker-rm-exited-containers.sh

.PHONY: bootstrap-fleet-manager
bootstrap-fleet-manager:
	make -C acs-fleet-manager deploy/bootstrap

.PHONY: build-fleet-manager
build-fleet-manager:
	make -C acs-fleet-manager/ image/build/local

.PHONY: push-fleet-manager
push-fleet-manager:
	docker tag fleet-manager:$(FLEETMANAGER_BUILD_TAG) localhost:5001/fleet-manager:$(FLEETMANAGER_BUILD_TAG) && \
	docker push localhost:5001/fleet-manager:$(FLEETMANAGER_BUILD_TAG)

.PHONY: clean-fleet-maanger
clean-fleet-manager:
	docker rm -f fleet-manager-db && \
	docker network rm fleet-manager-network

.PHONY: init-fleet-manager
init-fleet-manager: build-fleet-manager push-fleet-manager
	make -C acs-fleet-manager binary && \
	make -C acs-fleet-manager db/setup && \
	make -C acs-fleet-manager db/migrate && \
	make -C acs-fleet-manager secrets/touch

.PHONY: up-fleet-manager
up-fleet-manager:
	cd ./acs-fleet-manager && \
	OCM_ENV=development ./fleet-manager --force-leader \
		--dataplane-cluster-config-file=../config/dataplane-cluster-configuration-kind.yaml \
		--fleetshard-authz-config-file=../config/fleetshard-authz-org-ids-development.yaml \
		--central-idp-client-id="123" --central-idp-client-secret-file=<(echo "456") \
		--api-server-bindaddress localhost:9000 serve

.PHONY: up-fleetshard-sync
up-fleetshard-sync:
	cd ./acs-fleet-manager && ./fleetshard-sync