# Hybrid Data Pipeline Kubernetes Helm Chart

This repository contains a Helm Chart that can be used to deploy Hybrid Data Pipeline on a Kubernetes cluster. Below is a brief description of how to easily create a Hybrid Data Pipeline StatefulSet for development and testing.

## Getting Started

### Prerequisites

[Helm](https://helm.sh/docs/intro/install/), [Kubectl](https://kubernetes.io/docs/tasks/tools/), [AzureCLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) must be installed locally in order to use this chart.

In this release, the Helm chart is supported in Azure Kubernetes Service.

### Kubernetes Version

This Helm-chart currently support Kubernetes 1.27 or later.
 
### Installing Hybrid Data Pipeline Helm Chart

This below example Helm Chart installation will create a two-node Hybrid Data Pipeline cluster with a "Default" group. A 1GB persistent volume, 2 vCPUs, and 4GB of RAM will be allocated for the pod.

1. Add Hybrid Data Pipeline Repo to Helm:
```
helm repo add hybriddatapipeline https://github.com/progress/hdp-kubernetes-preview
```
2. Create a Kubernetes namespace:
```
kubectl create namespace hybriddatapipeline
```
3. The Hybrid Data Pipeline Helm Chart relies on two sub-charts, namely PostgreSQL and HAProxy.

To download the dependencies of the chart, execute:
```
helm dependency build
```
This action will retrieve the chart to /charts.

4. When installing the Helm Chart, the secrets for PostgreSQL and Hybrid Data Pipeline are required to be created. To create secrets:
```
kubectl apply -f secrets/hdp-secrets.yaml
kubectl apply -f secrets/account-database-secrets.yaml
```

5. Adjust the settings in the values.yaml file to create a two-node Hybrid Data Pipeline cluster with a minimum resource allocation of 2 vCPUs, 8 GB RAM, and 100 GB storage for Hybrid Data Pipeline Server. For detailed guidance, refer to the Hybrid Data Pipeline Product Requirements Documentation.

Utilize the latest Hybrid Data Pipeline Server Docker image for the new implementation as specified in the values.yaml file. To access the most recent image available, consult Progress ESD.

If necessary, push the Hybrid Data Pipeline Server Docker image to a container registry and update the image.repository and image.tag values accordingly.

Should you desire HAProxy Load Balancer service for serving Hybrid Data Pipeline Server pod containers, perform these actions:
    Specify an FQDN name in hdp.loadbalancer.hostName.
    Set haproxy.kubernetesIngress.enabled to true (default is true).

```
## Progress DataDirect Hybrid Data Pipeline Server parameters
hdp:

  # Number of HDP nodes
  replicaCount: 2

  ## Progress DataDirect Hybrid Data Pipeline Server image parameters
  image:
    repository: 
    tag: 
    pullPolicy: IfNotPresent
    
  ## Progress DataDirect Hybrid Data Pipeline Server Container persistence parameters
  persistence:    
    mountPath: /hdpshare
    size: 1Gi
    storageClassName: azurefile-csi

  ## Progress DataDirect Hybrid Data Pipeline Server Container resources parameters
  resources:
    requests:
      memory: "4096Mi"
      cpu: "2000m"
    limits:
      memory: "8096Mi"
      cpu: "4000m"

  ## Progress DataDirect Hybrid Data Pipeline Server License parameters
  licenseKey:
  
  ## Progress DataDirect Hybrid Data Pipeline Server Container load balancer parameters
  loadbalancer:
    hostName: 
```
6. Install the Hybrid Data Pipeline Helm Chart with the above custom settings.
```
helm install my-release hdp-kubernetes-preview/hybriddatapipeline --values values.yaml --namespace=hybriddatapipeline
```
Once the installation is complete and the pod is in a running state, the Hybrid Data Pipeline can be accessed using hostname as configured for the hdp.loadbalancer.hostName in values.yaml
