# Hybrid Data Pipeline Kubernetes Helm Chart

This chart bootstraps a Hybrid Data Pipeline deployment to a Kubernetes cluster using the Helm package manager. The following resources are deployed:

* Hybrid Data Pipeline cluster
* Persistent volume for shared files
* PostgreSQL system database (dependency on Bitnami PostgreSQL Helm chart)
* HAProxy load balancer (dependency on HAProxy Helm chart)

## Compatibility

The Hybrid Data Pipeline Helm chart supports cloud deployments on Azure Kubernetes Service (AKS). The Helm chart also supports on-premises deployments with platforms or tools such as Kubeadm or Rancher.

The Hybrid Data Pipeline Helm chart version 1.0.0 is currently tested on Azure Kubernetes Service (AKS) for cloud deployments and on Rancher for on-premises deployments.

The following versions of Kubernetes and Helm are required to deploy the Hybrid Data Pipeline Helm chart:

* Kubernetes 1.28+
* Helm 3.8.0+

## Getting started

Refer to the [Hybrid Data Pipeline Kubernetes Guide](https://docs.progress.com/bundle/datadirect-hybrid-data-pipeline-kubernetes-46/page/Deploying-a-Hybrid-Data-Pipeline-Kubernetes-cluster.html) for information on deploying and maintaining Hybrid Data Pipeline on Kubernetes with Helm chart.