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

# Copy local redis config to the shared redis location.
# This path is mounted on to kubernetes which contains base redis config
# For data storage : mixed mode is configured already
# For acl user list : users.acl file is configured
# With other default settings that is available from redis.conf file from redis documentation.
# Replace the old redis config with new redis config.
cp redis.conf ${REDIS_CONFIG_LOC}/redis.conf
cp users.acl ${REDIS_CONFIG_LOC}/users.acl

#------------------------------------------------------------------------------
#           SETUP USERS IN ACL
#------------------------------------------------------------------------------

# NOTE:
#    >${REDIS_CONFIG_LOC}/users.acl ==> Replace the config file
#    >>${REDIS_CONFIG_LOC}/users.acl ===> Append the file
#    Difference is ">" and ">>"

# Replace users.acl config file everytime the pod inits
# ACL user list defined below:
# ${SENTINEL_USERNAME} - The sentinel user is used by Sentinel to access the redis server to identify the master and update config
# ${REPLICA_USERNAME} - Replica user is used by the replication servers to sync b/w master and slave
# ${SERVICE_USERNAME} - The service account used by the application to add new users
# ${ADMIN_USERNAME} - The admin account used to manage the redis server which is used to execute non-dangerous command
# Default user is switched-off to force redis user to ACL authentication
echo "
user ${SENTINEL_USERNAME} on >${SENTINEL_PASSWORD} allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill
user ${REPLICA_USERNAME} on >${REPLICA_PASSWORD} +psync +replconf +ping
user ${SERVICE_USERNAME} on >${SERVICE_PASSWORD} ~* &* +@read +@write +@keyspace +@list +@set +@pubsub +@sortedset +@stream +@hash +@string +@bitmap +@connection +@fast +info  +@transaction
user ${ADMIN_USERNAME} on >${ADMIN_PASSWORD} +@all
user default off
user kube-user on nopass +ping
" >${REDIS_CONFIG_LOC}/users.acl


#------------------------------------------------------------------------------
#           CONFIGURE REPLICA USER
#------------------------------------------------------------------------------

# Once the ACL users are set. Update the configuration to use replica username and password for sync.
# Make sure to append the content as the redis file is freshly replaced.
{
echo "masterauth ${REPLICA_PASSWORD}"
echo "masteruser ${REPLICA_USERNAME}"
}>>${REDIS_CONFIG_LOC}/redis.conf


#------------------------------------------------------------------------------
#               IDENTIFY MASTER USING SENTINEL OR N/W PROBE
#------------------------------------------------------------------------------


echo "Finding master..."

# Default server-0 will be the master. Construct the full name from current server replacing {{resource_name}}-server-n with 0
MASTER_FDQN=$(hostname -f | sed -e "s/${RESOURCE_NAME}-server-[0-9]\./${RESOURCE_NAME}-server-0./")

if [ "$(redis-cli -h "${RESOURCE_NAME}-sentinel" -p "${SENTINEL_PORT}" --user "${SENTINEL_USERNAME}" --pass "${SENTINEL_PASSWORD}" ping)" != "PONG" ]; then
  echo "Sentinel not found, defaulting to ${RESOURCE_NAME}-server-0"
  if [ "$(hostname)" = "${RESOURCE_NAME}-server-0" ]; then
    echo "This is ${RESOURCE_NAME}-server-0, not updating config..."
  else
    echo "Updating redis.conf..."
    echo "slaveof ${MASTER_FDQN} ${REDIS_SERVER_PORT}" >>${REDIS_CONFIG_LOC}/redis.conf
  fi
else
  echo "Sentinel found, Finding master"

  # redis-cli command outputs in array with hostname and port. Using sed we are replacing /n characters with space
  MASTER="$(redis-cli -h "${RESOURCE_NAME}-sentinel" -p "${SENTINEL_PORT}" --user "${SENTINEL_USERNAME}" --pass "${SENTINEL_PASSWORD}" sentinel get-master-addr-by-name redisClusterMaster | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g')"
  echo "Found master from sentinel ${MASTER}"

  # If the current server is the master, then don't update config
  # This occurs when the master went down and came back up before the sentinel could elect different server as master
  # We shouldn't make the server slave of itself.
  CURRENT_SERVER=$(hostname -f)
  if [ "${MASTER}" = "${CURRENT_SERVER} ${REDIS_SERVER_PORT}" ]; then
    echo "${MASTER} master is same as ${CURRENT_SERVER} current server "
    echo "Skipping configuration update"
  else
    echo "The master is different from the current server. Updating redis.conf..."
    echo "slaveof ${MASTER}" >>${REDIS_CONFIG_LOC}/redis.conf
  fi

fi
