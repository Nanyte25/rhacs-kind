# rhacs-kind
A development setup for RHACS operator-based deploy in a kind cluster and with a local registry.

## Prerequisites
1. Installed kind and docker binaries.
3. Clone your fork of this repository.
  ```
  $ git clone git@github.com:<user>/rhacs-kind.git
  $ cd rhacs-kind
  ```

> Note: No need to use a fork repo if you don't intend to contribute upstream.

## Set up the kind cluster

1. Bootstrap the cluster and base resources. When it's done, it will show a link to the k8s dashboard and a login token.
```
$ make boostrap
```

To run k8s dashboard for monitoring on a separate terminal.
```
$ make run-k8s-dashboard
```

## Deploy resources needed to create a Central instance
```
$ make up
```
> This can take a while as it will build the images of at least the scanner, central, collecttor, and push them to the local registry.

## Build and Run the stackrox operator
```
$ make build-operator run-operator
```

## Deploy an example Central instance
```
$ make deploy-example-central
```

## Deploy a Secured Cluster instance after the Central services are up without errors.
```
$ make deploy-example-secured-cluster
```

## Initialize monitoring
```
$ make init-monitoring
```

## Run the following to port-forward the prometheus console
```
$ make run-prometheus-console
```
## Initialize the monitoring metrics
```
$ make init-monitoring-metrics
```

## Launch the stackrox UI
```
$ kubectl -n stackrox port-forward deploy/central --address localhost 8000:8443

# This can take time for the UI to load and set up a reverse proxy.
$ make up-ui
```

## Notes
1. Scanner and Central pods can take a while to load due to their DBs taking time to load.
2. Image builds can take a while.
