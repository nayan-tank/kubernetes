## Kubernetes Node Maintenance: Cordon, Drain, and Pod Scheduling Mechanics
------------------------------
### 1. Cordon vs. Drain Overview

| Feature | kubectl cordon <node> | kubectl drain <node> |
|---|---|---|
| New Pod Scheduling | ❌ Blocked (SchedulingDisabled) | ❌ Blocked (SchedulingDisabled) |
| Existing Application Pods | 🟢 Kept running undisturbed | 🚫 Evicted and moved elsewhere |
| DaemonSet Pods | 🟢 Kept running undisturbed | 🟢 Ignored by default (stays running) |
| Primary Use Case | Resource triage / temporary hold | Full node maintenance or deletion |

------------------------------
### 2. Production Node Maintenance Workflow## Step 1: Cordoning the Node
Marking a node as cordoned applies a taint that tells the kube-scheduler to ignore the node for future workloads.

```
kubectl cordon <node-name>
```

* Verification: Run kubectl get nodes. The node status will change to Ready,SchedulingDisabled.

#### Step 2: Draining the Node
To clear out the node safely for maintenance, execute a drain with standard production safety flags:

```
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force

* --ignore-daemonsets: Prevents the command from failing due to DaemonSet pods, which run on every node and would immediately recreate themselves if evicted.
* --delete-emptydir-data: Forces the eviction of pods using local emptyDir volumes. (Warning: Data stored in an emptyDir is local and will be permanently lost).
* --force: Forces the eviction of standalone pods not managed by a Controller (like a Deployment or ReplicaSet). These pods will be permanently deleted and not rescheduled.
```

#### Step 3: Uncordoning the Node
Once maintenance or updates are complete, manually bring the node back into service:
```
kubectl uncordon <node-name>
```

------------------------------
### 3. Pod Disruption Budgets (PDB) & Drain Behavior
How a Pod behaves when its node is drained depends heavily on its deployment type, cluster capacity, and defined PodDisruptionBudget (PDB).
##### Scenario: Evicting an Nginx Pod with minAvailable: 1## Case A: Only 1 Nginx replica exists in the cluster

   1. The Drain Blocks: The kubectl drain command will hang indefinitely and eventually timeout.
   2. The Pod Keeps Running: The Nginx pod remains online on the targeted node.
   3. The Reason: Evicting the pod would bring your available replicas down to 0. Because the PDB explicitly demands a minimum of 1 available pod, the Kubernetes Eviction API rejects the drain request to protect uptime.

##### Case B: Multiple replicas (2 or more) exist across the cluster

   1. The Drain Succeeds: The kubectl drain command proceeds smoothly.
   2. The Pod Moves: The Nginx pod on the targeted node is evicted.
   3. The Rescheduling: If it belongs to a Deployment, a new pod is scheduled and started on another healthy node.
   4. The Reason: Because the remaining replica(s) on other nodes stay alive, the minAvailable: 1 requirement is continuously met.

##### Case C: It is a Standalone Pod (No Deployment/ReplicaSet)

1. The PDB is Ignored: PDBs do not protect standalone pods.
2. The Result: The drain command will fail unless you pass the --force flag. If --force is used, the standalone pod is permanently deleted and never recreated anywhere.

------------------------------
### 4. The Impact of Hardcoded spec.nodeName
When a developer explicitly sets spec.nodeName: node-1 inside a Pod manifest, they bypass the normal Kubernetes scheduling engine entirely.
#### Core Architecture Failures

* Scheduler Bypass: The kube-scheduler completely ignores the Pod. The manifest bypasses the scheduling queue and binds directly to the named machine.
* Cordon Taint Bypass: Because the scheduler is skipped, Kubernetes fails to evaluate node taints, tolerances, or the SchedulingDisabled status caused by a kubectl cordon. The pod will land on a cordoned node anyway.
* Drain Lock-In: During a node drain, the control plane attempts to evict the pod. However, because its manifest strictly demands that specific node name, it cannot be successfully scheduled or moved to any other machine in the cluster.

#### Resource Constraint Failure States
If a pod with a hardcoded nodeName lands on a node that lacks the CPU, memory, or storage required to run it, the following occurs:

```
[ Pod Manifest ] ──( Bypasses Kube-Scheduler )──> [ Target Node ]
                                                        │
                      ┌─────────────────────────────────┴────────────────────────────────┐
                      ▼                                                                  ▼
        [ With Resource Requests ]                                         [ Without Resource Requests ]
                      │                                                                  │
         Node Kubelet rejects pod.                                         Pod starts and overcommits node.
                      │                                                                  │
                      ▼                                                                  ▼
    Stuck in Failed / OutOfcpu status.                              Triggers OOM Killer or Node Eviction Pressure.

```

1. With Resource Requests: The local kubelet evaluates the pod's resources.requests. If the node's unallocated capacity is insufficient, the kubelet rejects it. The pod gets permanently stuck in a Failed, OutOfcpu, or OutOfmemory state.
2. Without Resource Requests: The pod is allowed to start, overcommitting the host. This activates the Linux kernel Out-Of-Memory (OOM) killer to terminate workloads, or forces the node into a DiskPressure/MemoryPressure eviction state.

------------------------------
### 5. Architectural Best Practices

#### The Native Solution: Node Selectors & Affinity
To pin workloads to specific hardware profiles (e.g., GPU nodes or SSD storage) safely, use labels and selectors. This allows the scheduler to validate resource requirements before placing the pod.

```
spec:
  nodeSelector:
    disktype: ssd  # Scheduler ensures the node has this label AND free capacity
```

#### The Enforcement Solution: Admission Controllers
To secure production environments, platform teams use tools like Kyverno to entirely block manifests containing hardcoded node names via mutating or validating webhooks.

```
apiVersion: kyverno.io/v1kind: ClusterPolicymetadata:
  name: block-hardcoded-nodenamespec:
  validationFailureAction: Enforce
  rules:
  - name: validate-nodeName-absence
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Hardcoding nodeName is forbidden. Use nodeSelector or nodeAffinity."
      pattern:
        spec:
          X(nodeName): "?*" # Rejects the pod if nodeName field is present

```

#### To master Kubernetes node maintenance and pod eviction, you should focus on how the control plane orchestrates evictions under the hood, how workloads behave during a graceful shutdown, and how the cloud infrastructure interacts with these commands.
Here are the critical missing concepts you need to know to prevent data corruption or split-brain scenarios in production.

------------------------------
## 1. The Pod Eviction API vs. Pod Deletion
When you run kubectl drain, it does not use the standard kubectl delete pod command. Instead, it interacts directly with the Kubernetes Eviction API.

* Why it matters: delete bypasses cluster policies and instantly kills the pod. evict is a strategic request. The Eviction API checks your Pod Disruption Budgets (PDBs) first. If a PDB is violated, the API rejects the request, which is why your kubectl drain hangs safely rather than crashing your application.

------------------------------
## 2. The Graceful Shutdown Lifecycle (terminationGracePeriodSeconds)
When a pod is evicted during a drain, Kubernetes initiates a strict sequence to shut down your application without dropping ongoing traffic.

```
[ Eviction API Triggered ] 
         │
         ▼
[ Pod State -> Terminating ] ──( Concurrently )──> [ Removed from Service Endpoints ] (No new traffic)
         │
         ▼
[ preStop Hook Executes ] (Ideal for finishing existing connections/requests)
         │
         ▼
[ SIGTERM Signal Sent ] (Application process begins internal shutdown)
         │
         ▼
[ Timer Starts: terminationGracePeriodSeconds ] (Default: 30 seconds)
         │
         ├─► Application exits cleanly? ──► [ Pod Deleted Immediately ]
         │
         └─► Timer expires first? ────────► [ SIGKILL Sent ] (Hard kill, potential data loss)

```

* Production Tip: If you have heavy workloads (like databases or long-running API requests), the default 30-second terminationGracePeriodSeconds might be too short, leading to hard SIGKILL cutoffs. You must increase this value in your Pod spec to match your application's actual cleanup time.

------------------------------
## 3. StatefulSet Drain Quirks (The Local Storage Trap)
Draining a node running a StatefulSet requires extra caution compared to a standard Deployment.

* Persistent Volume Claims (PVCs): If your StatefulSet uses local Persistent Volumes bonded to that exact physical node, evicting the pod will cause it to get stuck in a Pending state indefinitely on the new node. It cannot start because its data is physically locked on the machine you just cordoned off.
* Ordinal Order: StatefulSets scale and terminate sequentially (nginx-2, then nginx-1, then nginx-0). A drain forces evictions out of ordinal order, which can temporarily disrupt applications like Kafka or [Elasticsearch](https://www.elastic.co/docs/reference/elasticsearch) that rely on specific quorum numbers.

------------------------------
## 4. Cloud Provider Autoscalers & Node Termination Handlers
In managed cloud environments (AWS EKS, [Google GKE](https://cloud.google.com/kubernetes-engine), [Azure AKS](https://azure.microsoft.com/en-us/products/kubernetes-service)), nodes are often deleted automatically by the Cluster Autoscaler or killed due to Spot/Preemptible Instance interruptions.

* The Gap: The cloud provider's infrastructure layer does not naturally know about your Kubernetes pods. If AWS terminates a Spot Instance, it will pull the plug instantly, bypassing kubectl drain.
* The Solution: You must deploy a [Node Termination Handler](https://github.com/aws/aws-node-termination-handler) or leverage built-in cloud features. These utilities intercept the cloud provider's pre-termination notice (usually given 2 minutes in advance), and automatically run kubectl drain on your behalf before the infrastructure vanishes.

------------------------------
## 5. PriorityClasses and Preemption
If your cluster is running at maximum capacity, draining a node might force a high-priority pod to look for a home on an already-full node.

* Preemption: If a critical pod needs a place to land, the kube-scheduler will actively evict lower-priority pods on other nodes to make room for it. Understanding PriorityClass ensures that your core system services (like CoreDNS or Ingress Controllers) never get blocked during a massive cluster drain.

------------------------------

## 1. Graceful Shutdown with preStop Hooks
When a pod is evicted, the kube-scheduler removes it from the Service endpoint list at the exact same time the kubelet sends the SIGTERM signal to the application container.

* The Problem: Network propagation takes time. For a brief window (a few hundred milliseconds), kube-proxy on other nodes might still send active user traffic to your pod after your application has received the shutdown signal. This results in 502 Bad Gateway or connection refused errors.
* The Solution: Use a preStop hook with a simple sleep command. This pauses the application container's shutdown process, keeping the socket open long enough for the network to update and stop sending new traffic.

Here is a production-ready Deployment manifest showing how to sequence the preStop hook alongside an extended terminationGracePeriodSeconds:

```
apiVersion: apps/v1kind: Deploymentmetadata:
  name: production-apispec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      # 1. Give the pod plenty of time to finish long running requests
      terminationGracePeriodSeconds: 60
      containers:
      - name: web-app
        image: nginx:1.25
        lifecycle:
          preStop:
            exec:
              command: 
              # 2. Wait 15 seconds for the network endpoints to completely sync.
              # This keeps the app alive to finish active, in-flight requests.
              - /bin/sh
              - -c
              - "sleep 15"
```
------------------------------
## 2. The StatefulSet Termination Mechanics
Draining a node that hosts a StatefulSet introduces unique, high-risk behaviors that do not apply to standard Deployments. [1] 

```
[ Deployment Drain ]  ──► Evicts all pods simultaneously ──► Reschedules anywhere with capacity
[ StatefulSet Drain ] ──► Evicts out of ordinal sequence  ──► Trapped by local storage & volume claims
```

## Issue A: The Local Storage Trap (PVC / PV Bonding)
StatefulSets rely on persistent, stable identities and storage. [2, 3] 

* If your StatefulSet uses Local Persistent Volumes (physical disks physically attached to that specific server), the data cannot migrate.
* When you drain the node, the pod is evicted. However, the PersistentVolumeClaim (PVC) remains strictly bound to the physical disk on that drained node. [4] 
* The Result: The pod will get stuck indefinitely in a Pending state on the new node. The scheduler cannot place it anywhere else because its required data storage is locked on the machine you just put in maintenance mode. [5] 
* The Fix: For node replacements, you must manually delete the PVC to unbind it, or use networked cloud storage (like [AWS EBS](https://aws.amazon.com/ebs/) or Google Persistent Disk) that can detach from the old node and re-attach to the new node across the network. [6] 

## Issue B: Violation of Ordinal Sequence
By default, StatefulSets scaling and deletions are ordered (app-2 must terminate completely before app-1 starts terminating). [7] 

* The Disruption: A node drain ignores this rule. If app-0 happens to live on the node you are draining, Kubernetes will evict app-0 immediately, even if app-1 and app-2 are still perfectly healthy on other nodes.
* The Risk: Applications like ZooKeeper, Kafka, or Elasticsearch rely on quorum. If a drain abruptly knocks out a specific master node or ordinal sequence pod out of turn, it can break the database quorum and trigger a split-brain scenario or read/write lockouts.

## Issue C: Automated Volume Retention
When a StatefulSet pod is evicted or deleted during a drain, Kubernetes does not delete the underlying PVCs or PVs. This is an intentional safety feature to prevent data loss. [8, 9, 10] 
If you are draining a node because you plan to permanently delete that machine from the cluster, you must manually clean up the orphaned storage volumes afterward, or configure the StatefulSet's volumeClaimTemplates.persistentVolumeClaimRetentionPolicy to automatically purge them:

```
spec:
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
  # Controls volume deletion behavior when scaling down or deleting the StatefulSet
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
```
