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
