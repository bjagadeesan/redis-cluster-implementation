#!/bin/bash
# This script will be used to convert the kubernetes templates to actual kubernetes configuration and apply them using kubectl

#------------------------------------------------------------------------------
# INSTANTIATE VARIABLES NEEDED TO CREATE KUBE/OPENSHIFT CONFIGURATION
#------------------------------------------------------------------------------

export APP_NAME="redis-custom-cluster"
# We can spin up multiple cluster by changing the resource_name
# Example: redis-custom-cluster-dev ; redis-custom-cluster-test ; redis-custom-cluster-stage with same configuration
export RESOURCE_NAME="redis-custom-cluster"
export NAMESPACE="redis-services"
export CONTAINER_IMAGE=""
# Minimum 3 is needed for both server and sentinel
export REPLICAS=3
export REDIS_SERVER_PORT=6379
export SENTINEL_PORT=5000



#------------------------------------------------------------------------------
# CONVERT TEMPLATE FILES TO ACTUAL KUBE/OPENSHIFT CONFIGURATION
#------------------------------------------------------------------------------

# Create a folder called ./tmp
if [ -d "./tmp" ]; then
  echo "./tmp does exist. Deleting it"
  rm -r ./tmp
else
  echo "./tmp does not exist. Creating it...."
  mkdir "./tmp"
fi


for filename in ./*.template.yaml; do
  [ -e "$filename" ] || continue
  echo "Creating....${filename} in ./tmp"
  envsubst <"${filename}" > "./tmp/$(basename "$filename" .template.yaml).yaml"
done

echo "Apply the yaml files to the Openshift/Kubernetes cluster"