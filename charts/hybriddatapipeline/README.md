# Progress DataDirect Hybrid Data Pipeline Helm Chart Repository

This repository hosts the Helm chart for deploying Hybrid Data Pipeline on Kubernetes.

The Hybrid Data Pipeline Helm chart may be used to deploy Hybrid Data Pipeline to an Azure Kubernetes Service (AKS) cluster either with ingress (for example, Application Gateway Ingress Controller (AGIC)) or in headless mode without ingress (using external gateway routing to pod endpoints). The Helm chart is supported with Hybrid Data Pipeline 4.6.2 versions starting at 4.6.2.3113 and with 5.0.0 versions starting at 5.0.0.466.

The Hybrid Data Pipeline Kubernetes Helm chart bootstraps a Hybrid Data Pipeline deployment to a Kubernetes cluster using the Helm package manager. The following resources are deployed:

* Hybrid Data Pipeline cluster
* Persistent volume for shared files
* Persistent volume for logs
* PostgreSQL system database (dependency on Bitnami PostgreSQL Helm chart)

Image governance note: the HDP server image is customer-supplied and should use a customer-approved registry with digest pinning in production. Review and update any publicly sourced chart defaults (for example Fluent Bit and PostgreSQL images) to align with enterprise policy.

PostgreSQL production resilience note: chart defaults prioritize first-deploy simplicity. For production, explicitly set PostgreSQL resilience values such as enabling primary PDB and evaluating replication mode.


## Compatibility

The following versions of Kubernetes and Helm are required to deploy Hybrid Data Pipeline Helm chart version 2.0.0:

* Kubernetes 1.30.7+
* Helm 3.15.2+

## Getting started

Refer to the [Hybrid Data Pipeline Kubernetes Guide](https://docs.progress.com/bundle/datadirect-hybrid-data-pipeline-kubernetes/page/Deploying-a-Hybrid-Data-Pipeline-Kubernetes-cluster.html) for information on deploying and maintaining Hybrid Data Pipeline on Kubernetes with Helm chart.
