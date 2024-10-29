# hdp-kubernetes

This a Helm Repository hosting Hybrid Data Pipeline HELM Charts.

# Hybrid Data Pipeline Kubernetes Helm Chart

_hybriddatapipeline_ is the HELM chart project that deploys Hybrid Data Pipeline in an Azure Kubernetes Cluster with 2 HDP nodes using PostgreSQL as account database and HAProxy as a Loadbalancer.

## Getting Started

### Prerequisites

In this release, the Helm chart is supported in Azure Kubernetes Service.
In Azure Cloud, a Kubernetes Cluster service(AKS) and an Azure Container Registry(ACR) need to exist to deploy Hybrid Data Pipeline.
ACR should have the HDP Docker image and the AKS should have access to ACR.

On the client side, you should have the tools - 
[Helm](https://helm.sh/docs/intro/install/), [Kubectl](https://kubernetes.io/docs/tasks/tools/), [AzureCLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) locally in order to use this chart.
Configure the Kubectl to work against the AKS context.

### Kubernetes Version

This Helm-chart currently support Kubernetes 1.27 or later.
 
### Installing Hybrid Data Pipeline Helm Chart

This below example Helm Chart installation will create a two-node Hybrid Data Pipeline cluster with a "Default" group. A 1GB persistent volume, 2 vCPUs, and 4GB of RAM will be allocated for the pod.

1. Add and Update Hybrid Data Pipeline repo to Helm:
```
helm repo add hdp https://progress.github.io/hdp-kubernetes/
helm repo update
```

2. When installing the Helm Chart, the secrets for PostgreSQL and Hybrid Data Pipeline are required to be created. 

Refer to the sample secret files under _charts/hybriddatapipeline/secrets_ folder. Make a copy of these and provide your credentials in base64 format.

To create secrets, run the following commands:
```
kubectl create -f hdp-secrets.yaml
kubectl create -f postgres-secrets.yaml
```

3. Refer to charts/hybriddatapipeline/values.yaml file for all the configurable properties.
Following are basic properties that are required to setup the Hybrid Data Pipeline. You can make a copy of the following properites and name it as _myValues.yaml _

If you intend to enable SSL, create an additional secret with the certificate.pem and key.pem file. Refer to the comments in the following file.
```
## Values used for Hybrid Data Pipeline(HDP) installation
hdp:
  ## Controls number of nodes to be deployed
  replicaCount: 2

  ## HDP Docker image details
  image:
    repository: 
    tag: 
    pullPolicy: IfNotPresent
  
  ## HDP Server License Key, leaving this blank will install HDP in Evaluation Mode
  licenseKey:
  
  ## Host name of the loadbalancer that would be in front of HDP nodes
  loadbalancer:
    hostName:
  ## Controls On-Premise Connector components configuration on the HDP Server side
  ## This should be enabled to establish On-premise datastore connections
  onPremiseConnector:
    enabled: true

## HAProxy Kubneretes Ingress Helm Chart Configuration
haproxy:
  kubernetesIngress:
    enabled: true
    ingressName: "hdp-ingress"
  ## Configure TLS for HAProxy
  ## Put the PEM-formatted SSL certificate and private key into a secret and provide the secret name in the secretName field.
  ## To generate the secret in Kubernetes: kubectl create secret tls tls-cert --cert=mycert.pem --key=privkey.pem
  tls:
    enabled: true
    secretName: "tls-cert"
```
6. Install the Hybrid Data Pipeline Helm Chart using myValues.yaml
```
helm install hdp-deploy hdp/hybriddatapipeline -f myValues.yaml
```
Once the installation is complete and the pods are in a running state, list the running services using the following command -
```
kubectl get services
```
KubernetesIngress of deployment type _LoadBalancer_ will have an external IP configured. This IP address should be configured to the DNS name to resolve the DNS correctly.
The Hybrid Data Pipeline can then be accessed using hostname as configured for the hdp.loadbalancer.hostName in myValues.yaml
****
