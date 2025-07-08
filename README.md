## ✅ **Kubernetes Security Best Practices (Optimized)**

### 1. **Cluster Access & API Server**

* **Restrict Access to etcd**:
  Only allow the Kubernetes API server to communicate with `etcd`. Use TLS encryption and authentication.

* **Enable RBAC**:
  Configure the API server:

  ```bash
  kube-apiserver --authorization-mode=Node,RBAC,...
  ```

* **Use Namespaces for Isolation**:
  Segregate workloads using Kubernetes namespaces for better access control and policy enforcement.

---

### 2. **Pod & Container Security**

* **Apply Security Context**:

  ```yaml
  securityContext:
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    runAsUser: 4000
    capabilities:
      drop:
        - ALL
      add:
        - CHOWN
  ```

* **Use Pod Security Standards** (PSS):

  ```yaml
  metadata:
    labels:
      pod-security.kubernetes.io/enforce: "restricted"
      pod-security.kubernetes.io/audit: "restricted"
      pod-security.kubernetes.io/warn: "restricted"
  ```

* **Limit Resource Usage**:

  ```yaml
  resources:
    requests:
      memory: "100Mi"
    limits:
      memory: "200Mi"
  ```

* **Continuously Audit Privileges**:
  Regularly review container permissions and drop unnecessary capabilities.

---

### 3. **Supply Chain Security**

* **Image Policy Webhook**:
  Use the `ImagePolicyWebhook` admission controller to enforce trusted image sources.

* **Implement Vulnerability Scanning**:
  Integrate tools like:

  * Trivy
  * Clair
  * Anchore
    into CI/CD pipelines for continuous scanning.

---

### 4. **Node & Host Security**

* **Secure Kubernetes Hosts**:

  * Keep OS and kubelet patched.
  * Limit root access.
  * Use minimal base OS (e.g., Bottlerocket, Flatcar).

* **Use `kube-bench`**:
  Run [kube-bench](https://github.com/aquasecurity/kube-bench) to check compliance with the CIS Kubernetes Benchmark.

---

### 5. **Centralized Policy Management**

* **Open Policy Agent (OPA)**:
  Use **OPA Gatekeeper** to enforce custom policies cluster-wide.

---
