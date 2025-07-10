# Progress DataDirect Hybrid Data Pipeline Helm Chart Repository

This repository hosts the Helm chart for deploying Hybrid Data Pipeline on Kubernetes.

The Hybrid Data Pipeline Helm chart may be used to deploy Hybrid Data Pipeline to an Azure Kubernetes Service (AKS) cluster with the Application Gateway Ingress Controller (AGIC). The Helm chart is supported with Hybrid Data Pipeline 4.6.2.3113 and higher.

The Hybrid Data Pipeline Kubernetes Helm chart bootstraps a Hybrid Data Pipeline deployment to a Kubernetes cluster using the Helm package manager. The following resources are deployed:

* Hybrid Data Pipeline cluster
* Persistent volume for shared files
* PostgreSQL system database (dependency on Bitnami PostgreSQL Helm chart)

## Compatibility

The following versions of Kubernetes and Helm are required to deploy Hybrid Data Pipeline Helm chart version 1.0.0:

* Kubernetes 1.30.7+
* Helm 3.15.2+

## Getting started

Refer to the [Hybrid Data Pipeline Kubernetes Guide](https://docs.progress.com/bundle/datadirect-hybrid-data-pipeline-kubernetes-46/page/Deploying-a-Hybrid-Data-Pipeline-Kubernetes-cluster.html) for information on deploying and maintaining Hybrid Data Pipeline on Kubernetes with Helm chart.
