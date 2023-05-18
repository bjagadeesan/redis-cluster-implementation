# Redis Cluster Setup 

This is the redis cluster implementation on Kubernetes/Openshift 

**NOTE: Please make sure to delete the PV volume after you have done testing**

## Problem:
To host highly reliable and highly available redis cluster in Openshift/Kubernetes. The following are the features that redis cluster needs to have: <br/>
* High availability 
* Reliable
* Data Persistence
* Auto-Recovery/Fail-over

## Architecture:
### Replication and Persistence : 
To solve for high availability and reliability, redis server has to have multiple nodes (pods). The pods should be self-aware of its current state (if it is a master or slave) and should be able to identify the master at any given time in the n/w. 

At any given time, there will be 1 master and n slaves. The n slaves will be the replica of the master. The master is responsible for read and writes. The n slaves will be responsible for syncing b/w master and itself. Detailed information are available [here](https://redis.io/topics/cluster-spec) 

The data-storage/persistence mode is both AOF and RDB and the justification to have hybrid mode is explained in redis documentation [here](https://redis.io/topics/persistence).

There are some caveats for persisting the data writes:
* A write may reach a master, but while the master may be able to reply to the client, the write may not be propagated to slaves via the asynchronous replication used between master and slave nodes. If the master dies without the write reaching the slaves, the write is lost forever if the master is unreachable for a long enough period that one of its slaves is promoted. This is usually hard to observe in the case of a total, sudden failure of a master node since masters try to reply to clients (with the acknowledge of the write) and slaves (propagating the write) at about the same time. However, it is a real world failure mode.

* Another theoretically possible failure mode where writes are lost is the following:
    * A master is unreachable because of a partition.
    * It gets failed over by one of its slaves.
    * After some time it may be reachable again.
    * A client with an out-of-date routing table may write to the old master before it is converted into a slave (of the new master) by the cluster.
* Master or slave could be unavailable during drive partition or drive unavailability 

The above scenarios are likely to happen during patching of the server and something to resolve in future implementation

### Sentinel for monitoring and fail-over/recovery: 
To solve for fail-over and recovery, the sentinel should be available in the n/w to monitor the redis server. When the master is down or not responsive, sentinel will elect one of the slave to be the master. It is responsible for updating the other redis nodes in the cluster, to make sure the state is reflected through the n/w. The sentinel should be deployed as n nodes with n being an odd number. This is required inorder to achieve quorum/consensus b/w the nodes. Sentinel should be configured to discover the other sentinel nodes and redis server nodes in the n/w in case of initial boot-up or restart.

Before spinning the servers in OCP, initialization has to be done, one for redis node and one for sentinel node to ensure same config are generated each time, and it is the same among the redis and sentinel nodes. Both redis and sentinel has to have its own directory (preferable the config folder) so that it can make changes to the config on the fly if it detects any change in the n/w.The generation of config files is mandatory to define the location of acl config, log file, data storage location and other important settings. 

`initContainer` feature has to be used in the kube config to make sure the configurations are generated correctly before the actual node (either sentinel/redis-server) instance spins up.

### ACL:
From redis 6.2 and up, we have the capability to support ACL tables to maintain user profiles. This will provide us the ability to define restrictive access to user instead of default master password setup. Separate ACL conf has to be set up in redis server and sentinel and the configuration has to be set to use the ACL table. Backward compatibility mode has to be disabled to make it more secure, and it will be helpful for audit and info-sec reviews. 

## Detailed implementation :
There are two Stateful sets defined for the redis.
1. Redis Server 
2. Sentinel

Both sentinel and server should be odd number of pods. Currently, it is configured to 3.
This is required to arrive at consensus when a pod goes down. 

At a given time, there will be one master and 3 slaves in case of redis server, and 3 sentinels, which are responsible for managing and electing a redis server slave to master.

The `initContainer` in the stateful sets should have custom bash script that is executed before spinning up the node. Server and Sentinel each has its own separate boot-up script 

### Stateful Set:

For redis server, during initializing (boot-up bash script) the following has to be done:
* `redis.conf` has to be generated.
* `users.acl` has to be created, and it should be specified in `redis.conf`
* Awareness of the n/w takes place:
    * If Sentinel node found:
        * Use sentinel to identify the master redis server 
        * Make sure to use sentinel user (separate user has to be set for contacting sentinel)
    * If Sentinel not found:
        * Check if the local n/w has a master redis server by pinging each node. (This is where stateful set unique numbering of pod will be helpful).Once master is found, update the `redis.conf` to add `slaveof <ip-address-of-master> <port>`. Set replica user (separate user has to be set for syncing b/w master and slave) to the `redis.conf`
        * If no master node is found, and if it pod-0, then make itself the master (boot-up of initial node). No update to config is required. 

For Sentinel, during initialization, the following has to be done:
* `sentinel.conf` has to be generated
* `users.acl` has to be created, and it should be specified in `sentinel.conf`
* Determine the master :
    * Loop over known redis server in the n/w and identify the master. 
        * Once master is found, update the `sentinel.conf` with master information with default timeouts config required for monitoring the redis-server.
    * If the redis server is not found, poll over the for loop until the redis server is up and running. Fail the sentinel server if the redis-server is not in the network. 
 
To identify the redis server/sentinel in the n/w, this is the convention that OCP/Kubernetes follows. Headless service has to be defined for sentinel and redis server.

```
Format:
- <serverName>-{id}.<serverName>.<namespace_name>.svc.cluster.local

Example:
- redis-cluster-server-0.redis-cluster-server.redis-services.svc.cluster.local
- redis-cluster-sentinel-0.redis-cluster-sentinel.redis-services.svc.cluster.local
```

### ACL Users:
[ACL](https://redislabs.com/blog/getting-started-redis-6-access-control-lists-acls/)
article elaborate the justification for following this strategy. 
This will ensure compliance and make sure that the access is restricted for sentinel, server and administrators.

All secrets are defined in config file under `data:{}` block. The following variables are required to start the redis server
Please create this file and put it inside /src/config.json

```json5
{
  "data": {
    // The below username and password are used by replica to sync with master
    // Avoid special characters for password that is not bash compatible like #$!()
    "REPLICA_USERNAME": "replica-user",
    "REPLICA_PASSWORD": "replica-pass",
    // The below username and password are used by sentinel to identify and talk with redis-server
    // Avoid special characters for password that is not bash compatible like #$!()
    "SENTINEL_USERNAME": "sentinel-user",
    "SENTINEL_PASSWORD": "sentinel-pass",
    // The below username and password are used by sentinel to sync among sentinels
    // Avoid special characters for password that is not bash compatible like #$!()
    "SENTINEL_SYNC_USERNAME": "sentinel-user",
    "SENTINEL_SYNC_PASSWORD": "sentinel-pass",
    // USER DEFINED usernames - Out of box admin and service account are defined
    // We can add more users by adding new lines in redis-server.sh and sentinel-server.sh ACL file.
    // The below username and password is used for admin privileges
    // Avoid special characters for password that is not bash compatible like #$!()
    "ADMIN_PASSWORD": "admin",
    "ADMIN_USERNAME": "admin",
    // The below username and password is used as a service account in application
    // Avoid special characters for password that is not bash compatible like #$!()
    "SERVICE_PASSWORD": "api_pass",
    "SERVICE_USERNAME": "api_service",
    // default password for default user ?
    // TODO: disable default user
    "DEFAULT_USER_PASS": "default_pass1"
  }
}
```
You can add another account in redis-server bash file to users.acl config based on your configuration.

**_WIP : More information will be added when complete implementation is done_**

[here]: https://redis.io/topics/persistence
