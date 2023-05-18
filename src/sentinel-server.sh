#!/bin/bash

#------------------------------------------------------------------------------
#           ENVIRONMENT VARIABLE SET UP
#------------------------------------------------------------------------------

# All following commands rely on config.json, so check if it is available.
CONFIG_FILE=/src/config.json

if [ -f "$CONFIG_FILE" ]; then
  echo "$CONFIG_FILE exists."
  # Script to load all the variables in data:{} block as environment variables
  # This relies on jq module which is installed as a dependency when dockerFile is built.
  # Make sure all the secrets are available under data:{} block of config variables.
  # All the other blocks of config files are ignored.
  # If other block needs to be loaded, please copy the following command and add another block
  echo "loading config file to env"

  # shellcheck disable=SC2154
  for s in $(echo "${values}" | jq -r '.data | to_entries | .[] | .key + "=\"" + .value + "\""' ${CONFIG_FILE}); do
   # " characters are added to the variables value which gets reflected in the files. sed is used to remove ".
   # shellcheck disable=SC2046
   export $(echo "${s}" | sed 's/\"//g')
  done
else
  echo "$CONFIG_FILE not found."
  exit 1
fi

REDIS_CONFIG_LOC=/usr/local/etc/redis

#------------------------------------------------------------------------------
#           COPY LOCAL CONFIG TO SHARED PATH EXPOSED IN KUBERNETES
#                            VOLUME STORAGE
#------------------------------------------------------------------------------

# Copy local default sentinel config
# This is where some default sentinel security configs are predefined.
cp users.acl ${REDIS_CONFIG_LOC}/sentinel-users.acl
cp sentinel.conf ${REDIS_CONFIG_LOC}/sentinel.conf

#------------------------------------------------------------------------------
#           SETUP SENTINEL USERS IN ACL
#------------------------------------------------------------------------------

# Create users.acl file for sentinel user
# NOTE: works only redis 6.2 and above
# Sentinel user list
# SENTINEL_SYNC_USERNAME - The sentinel sync user is used by Sentinel to sync b/w sentinel replicas
# SENTINEL_USERNAME - The server connects to sentinel to identify the master in the n/w
# SERVICE_USERNAME -  service account used by the application, for maintenance in future
# ADMIN_USERNAME - The admin account used to manage the sentinel server which is used to execute non-dangerous command
# Default user is switched-off to force redis user to ACL authentication

echo "
user ${SENTINEL_SYNC_USERNAME} +@all -acl -shutdown on >${SENTINEL_SYNC_PASSWORD}
user ${SENTINEL_USERNAME} +@all -acl -shutdown on >${SENTINEL_PASSWORD}
user ${SERVICE_USERNAME} +@read +@fast +info +@pubsub +@connection +@admin -shutdown -acl on >${SERVICE_PASSWORD}
user ${ADMIN_USERNAME} +@all on >${ADMIN_PASSWORD}
user default off
user kube-user on nopass +ping
">${REDIS_CONFIG_LOC}/sentinel-users.acl

#------------------------------------------------------------------------------
#           SETUP SENTINEL CONFIG TO USE ACL USERS
#------------------------------------------------------------------------------
# Once the ACL users are set. Update the configuration to use replica username for sync.
# Since password is already available to server, specifying username is good enough
{
  echo "sentinel sentinel-user ${SENTINEL_SYNC_USERNAME}"
  echo "sentinel sentinel-pass ${SENTINEL_SYNC_PASSWORD}"
} >>${REDIS_CONFIG_LOC}/sentinel.conf

#------------------------------------------------------------------------------
#           DEFINE REDIS SERVERS AND IDENTIFY MASTER BY PROBING NODES
#------------------------------------------------------------------------------

# If we are not able to find any redis-cluster in the n/w, wait few seconds for server to boot up.
# Choose second server as master doesn't output replication details ?? TODO: Need to check thisk
# SENTINEL USERNAME and PASSWORD are available in environment and setup in redis server
if [ "$(redis-cli -h "${RESOURCE_NAME}-server" --user "${SENTINEL_USERNAME}" --pass "${SENTINEL_PASSWORD}" info replication | awk '{print $1}' | grep master_host: | cut -d ":" -f2)" = "" ]; then
  echo "waiting 20 sec for the redis cluster to come up"
  sleep 20
fi

# TODO: Try to find a way to discover local instances automatically in kubernetes

# Define fully qualified redis server hostname
nodes[0]=${RESOURCE_NAME}-server-0.${RESOURCE_NAME}-server.$NAMESPACE.svc.cluster.local
nodes[1]=${RESOURCE_NAME}-server-1.${RESOURCE_NAME}-server.$NAMESPACE.svc.cluster.local
nodes[2]=${RESOURCE_NAME}-server-2.${RESOURCE_NAME}-server.$NAMESPACE.svc.cluster.local

# Arrays are not native to POSIX shell
# shellcheck disable=SC2039
for i in "${nodes[@]}"; do
  echo "Finding master at $i"
  # SENTINEL USERNAME and PASSWORD are available in environment and setup in redis server
  MASTER=$(redis-cli -h "${i}" --user "${SENTINEL_USERNAME}" --pass "${SENTINEL_PASSWORD}" info replication | awk '{print $1}' | grep master_host: | cut -d ":" -f2)
  if [ "${MASTER}" = "" ]; then
    echo "No master found"
    MASTER=
  else
    echo "found ${MASTER}"
    break
  fi
done

if [ "${MASTER}" = "" ]; then
  echo "Redis server may not be running at the provided host. Please check hostname and port. Exiting Sentinel"
  exit 1
fi

#------------------------------------------------------------------------------
#           SETUP MASTER IN SENTINEL CONFIG
#------------------------------------------------------------------------------
# and add auth mechanism to access master
{
  echo "port ${SENTINEL_PORT}"
  echo "sentinel monitor redisClusterMaster ${MASTER} ${REDIS_SERVER_PORT} 2"
  echo "sentinel down-after-milliseconds redisClusterMaster ${SENTINEL_PORT}"
  echo "sentinel failover-timeout redisClusterMaster 60000"
  echo "sentinel parallel-syncs redisClusterMaster 1"
  echo "sentinel auth-user redisClusterMaster ${SENTINEL_USERNAME}"
  echo "sentinel auth-pass redisClusterMaster ${SENTINEL_PASSWORD}"
} >>${REDIS_CONFIG_LOC}/sentinel.conf
