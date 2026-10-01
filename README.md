# talos-cluster

Provisions a [Talos Linux](https://www.talos.dev/) Kubernetes cluster on a single
Proxmox VE node: it downloads the Talos ISO, creates the VMs, generates and applies
the machine configuration, performs the one-time etcd bootstrap, waits for the
cluster to report healthy, and returns a `talosconfig` and `kubeconfig`.

The cluster is exactly as large as the `nodes` map: one VM per entry, from a
single-node lab to as many control planes and workers as the Proxmox node will
hold. The module stays opinionated about everything else — a shared API VIP,
static addressing configured by Talos, one pinned Talos release — so that a
cluster comes up from an empty Proxmox node with one `apply`.

## What it does

1. Downloads `metal-amd64.iso` for the pinned Talos release into `iso_datastore`.
2. Creates one VM per entry in `nodes`, booting the ISO into maintenance mode.
3. Waits `vm_boot_delay` for maintenance mode to answer on TCP 50000.
4. Renders a machine configuration per node (static IP, hostname, install disk,
   control-plane VIP, optional node labels) and applies it.
5. Bootstraps etcd on a single control plane (`bootstrap_node`).
6. Blocks on `talos_cluster_health` until every node is ready, then fetches the
   kubeconfig. With `cni = "none"` it waits for Talos-level health only, because
   the nodes stay `NotReady` until you install a CNI (see
   [Bringing your own CNI](#bringing-your-own-cni)).

## Requirements

| Name | Version |
| --- | --- |
| terraform / opentofu | `>= 1.9.0, < 2.0.0` |
| [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox) | `0.114.0` |
| [siderolabs/talos](https://registry.terraform.io/providers/siderolabs/talos) | `0.11.0` |
| [hashicorp/time](https://registry.terraform.io/providers/hashicorp/time) | `~> 0.12` |

Provider versions are pinned exactly for `proxmox` and `talos` because the Talos
machine-config schema and the Proxmox VM schema both move between minor releases.

This module declares no `provider` blocks — it inherits the configured instances
from the root module, which is where credentials belong.

### Environment prerequisites

- A reachable Proxmox VE node with an API token that may create VMs and download
  ISOs. No SSH access is required.
- Datastores for VM disks and for ISO images, and a network bridge, all existing.
- **DHCP reservations for every node's MAC → IP pair.** A node booting the ISO has
  no configuration yet, so the module can only reach it at the address DHCP hands
  out; the reservation must match the `ip` in `nodes`. Create these before the
  first apply (by hand, or with a router module in the root configuration).
- `api_vip` must be a free address on the control-plane layer 2 network, outside
  the DHCP pool.

## Usage

Six nodes below are only an example; add or remove entries to change the size of
the cluster.

```hcl
module "talos_cluster" {
  source = "./modules/talos-cluster"

  proxmox_node  = "node0"
  vm_datastore  = "local-lvm"
  iso_datastore = "local"
  bridge        = "vmbr0"
  # vlan_id     = 20

  cluster_name = "talos-lab"
  api_vip      = "192.168.1.80"

  network = {
    prefix      = 24
    gateway     = "192.168.1.1"
    nameservers = ["192.168.1.1"]
  }

  talos_version      = "v1.13.1"
  kubernetes_version = "1.34.1"

  bootstrap_node = "talos-cp-01"
  vm_boot_delay  = "90s"

  nodes = {
    talos-cp-01 = { role = "controlplane", id = 810, ip = "192.168.1.81", mac = "02:00:00:00:08:10" }
    talos-cp-02 = { role = "controlplane", id = 811, ip = "192.168.1.82", mac = "02:00:00:00:08:11" }
    talos-cp-03 = { role = "controlplane", id = 812, ip = "192.168.1.83", mac = "02:00:00:00:08:12" }

    talos-worker-01 = {
      role      = "worker"
      id        = 820
      ip        = "192.168.1.91"
      mac       = "02:00:00:00:08:20"
      datastore = "local-lvm-2"
      tags      = ["storage"]
      labels    = { "node.example.com/role" = "storage" }
    }
    talos-worker-02 = { role = "worker", id = 821, ip = "192.168.1.92", mac = "02:00:00:00:08:21" }
    talos-worker-03 = { role = "worker", id = 822, ip = "192.168.1.93", mac = "02:00:00:00:08:22" }
  }

  sizing = {
    controlplane = { cores = 2, memory = 4096, disk = 32 }
    worker       = { cores = 4, memory = 8192, disk = 60 }
    nodes = {
      # A beefier storage worker, still on the default 4 cores.
      talos-worker-01 = { memory = 16384, disk = 500 }
    }
  }
}
```

Writing the credentials to disk after an apply:

```console
$ tofu output -raw talosconfig > ~/.talos/config
$ tofu output -raw kubeconfig  > ~/.kube/config
```

## Inputs

Only `vlan_id`, `bootstrap_node`, `cni` and `kube_proxy` have defaults; the last
two default to what Talos does on its own. Everything else is required by design:
the module owns validation, the root module owns the user-facing defaults, so
neither duplicates the other.

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `proxmox_node` | Existing Proxmox node that hosts every VM, except those that name a `proxmox_node` of their own. | `string` | n/a |
| `vm_datastore` | Default datastore for VM disks; a node may override it. | `string` | n/a |
| `iso_datastore` | Datastore that accepts ISO images. | `string` | n/a |
| `bridge` | Existing network bridge, e.g. `vmbr0`. | `string` | n/a |
| `vlan_id` | VLAN tag, `1`–`4094`. `null` uses the untagged bridge network. | `number` | `null` |
| `network` | Static addressing applied by Talos: `prefix` (8–30), `gateway`, `nameservers` (at least one). | `object` | n/a |
| `cluster_name` | Talos/Kubernetes cluster name; also prefixes the downloaded ISO. Lowercase, starts with a letter, ≤ 40 chars. | `string` | n/a |
| `api_vip` | Control-plane VIP for the Kubernetes API. Must be free, outside the DHCP pool, and not equal to any node IP. | `string` | n/a |
| `talos_version` | Talos release to install, e.g. `v1.13.1`. Constrained to `v1.13.x`. | `string` | n/a |
| `kubernetes_version` | Initial Kubernetes version, without the `v`. | `string` | n/a |
| `cni` | `flannel` lets Talos deploy Flannel; `none` leaves the cluster ready for a CNI you install afterwards. | `string` | `"flannel"` |
| `kube_proxy` | Deploy kube-proxy. `false` is only allowed with `cni = "none"`, for a CNI that replaces it. | `bool` | `true` |
| `nodes` | The cluster inventory; one VM per entry, at least one of them a control plane. See [below](#nodes). | `map(object)` | n/a |
| `bootstrap_node` | Name of the control plane that runs the one-time etcd bootstrap. `null` selects the alphabetically first one. | `string` | `null` |
| `vm_boot_delay` | Go duration to wait after the VMs start before the first configuration attempt, e.g. `90s`. | `string` | n/a |
| `sizing` | Per-VM allocations. See [below](#sizing). | `object` | n/a |

### `nodes`

```hcl
map(object({
  role         = string               # "controlplane" or "worker"
  id           = number               # Proxmox VM ID, >= 100, unused
  ip           = string               # static IPv4 inside network.prefix
  mac          = string               # unicast MAC, matching the DHCP reservation
  proxmox_node = optional(string)     # overrides proxmox_node for this VM
  datastore    = optional(string)     # overrides vm_datastore for this node's disk
  tags         = optional(list(string), [])  # extra Proxmox tags
  labels       = optional(map(string), {})   # extra Kubernetes node labels
}))
```

The map key becomes the VM name and the Kubernetes node hostname, so it must be a
valid DNS label.

Every entry becomes one VM, so the map alone decides how big the cluster is.
Validation asks only for **at least one `controlplane`** entry, that every `role`
is `controlplane` or `worker`, and that VM IDs, IP addresses and MAC addresses are
each unique across the map. Two shapes worth knowing about:

- **Control-plane count.** etcd tolerates failures only at odd counts: one node
  for a lab, three to survive one loss, five to survive two. An even count adds a
  member without adding fault tolerance.
- **No workers at all.** A control-plane-only inventory is allowed, and gets
  `allowSchedulingOnControlPlanes: true` so that it has somewhere to run
  workloads. Adding the first worker flips that back to `false` on the next apply
  and moves the workloads off the control planes.

**Placement.** A node with its own `proxmox_node` is created on that host instead
of the cluster default. VM IDs are cluster-wide in Proxmox, so they stay unique
across hosts, and `iso_datastore` plus whatever `datastore` the node uses have to
exist on each host you name. The installer ISO is downloaded once per host in use,
because on a stock install `iso_datastore` is local storage.

Moving an existing node to another host **replaces the VM**: the provider is not
asked to live-migrate, and the replacement wipes the disk. For a control plane
that means losing its etcd member, so remove it from the cluster and rejoin it
deliberately rather than letting one apply do it in passing.

`labels` are rejected if they use the reserved `kubernetes.io` / `k8s.io`
namespaces, because Talos writes them with the node's own kubelet identity and the
`NodeRestriction` admission plugin would refuse them *after* the apply appeared to
succeed. In particular `node-role.kubernetes.io/worker` will not work — use your
own prefix (`node.example.com/role`) or no prefix at all. A node's own
`kubelet.kubernetes.io/*`, `node.kubernetes.io/*` and the standard
topology/instance-type keys are allowed.

### `sizing`

```hcl
object({
  controlplane = object({ cores = number, memory = number, disk = number })
  worker       = optional(object({ cores = number, memory = number, disk = number }))
  nodes = optional(map(object({
    cores  = optional(number)
    memory = optional(number)
    disk   = optional(number)
  })), {})
})
```

Memory is MiB, disk is GiB. `controlplane` and `worker` are the defaults for every
node of that role; `nodes` overrides individual fields for one named node, and any
field left out there falls back to the role default. Keys in `sizing.nodes` must
name entries in `nodes`.

`worker` may be omitted for a control-plane-only cluster, and is required as soon
as `nodes` contains a worker.

Minimums, for role defaults and per-node overrides alike: 2 vCPU, 4096 MiB RAM,
32 GiB disk, all integers.

## Outputs

| Name | Description | Sensitive |
| --- | --- | --- |
| `nodes` | The VM inventory, echoed back for use in downstream modules and DHCP bookkeeping. | no |
| `kubernetes_endpoint` | `https://<api_vip>:6443`. | no |
| `talosconfig` | Talos client configuration, with all control planes as endpoints. | **yes** |
| `kubeconfig` | Kubeconfig fetched from the bootstrap control plane. | **yes** |

Both credentials are stored in plain text in state. Use a backend that encrypts
state and restricts access.

## Resources created

| Address | Purpose |
| --- | --- |
| `proxmox_download_file.talos` | The Talos ISO, named `<cluster_name>-talos-<version>-amd64.iso`. |
| `proxmox_virtual_environment_vm.node` (one per `nodes` entry) | The node VMs. |
| `talos_machine_secrets.cluster` | Cluster PKI and bootstrap tokens. |
| `data.talos_machine_configuration.node` (one per node) | Rendered machine configs. |
| `time_sleep.maintenance_mode` | Boot gate before the first config attempt. |
| `talos_machine_configuration_apply.node` (one per node) | Applies each config over TCP 50000. |
| `talos_machine_bootstrap.cluster` | One-time etcd bootstrap. |
| `data.talos_cluster_health.cluster` | Blocks until the cluster is ready. |
| `data.talos_client_configuration.cluster` | Source of the `talosconfig` output. |
| `talos_cluster_kubeconfig.cluster` | Source of the `kubeconfig` output. |

## Baked-in decisions

Things this module fixes rather than exposing as variables:

- **Pod subnet `10.244.0.0/16`, service subnet `10.96.0.0/12`.** A CNI you
  install yourself must use the same pod CIDR (or take it from the node objects,
  as Cilium's `ipam.mode=kubernetes` does).
- **Install disk `/dev/sda`** with `wipe: false`, matching the single virtio-SCSI
  disk attached to each VM.
- **`allowSchedulingOnControlPlanes`** is derived, not exposed: `false` whenever
  the inventory has workers, so workloads land on workers only, and `true` for a
  control-plane-only cluster, which would otherwise have nowhere to schedule.
- **SeaBIOS**, `virtio-scsi-single`, boot order `scsi0` then `ide2`, `l26` guest
  type, host CPU type, `discard`/`iothread`/`ssd` on the disk.
- **QEMU guest agent disabled**, because the stock Talos ISO ships without the
  agent extension.
- **Proxmox tags** `terraform`, `talos` and the node's role are always applied,
  lowercased and sorted alongside your `tags` so that repeat plans stay empty.
- **Startup order**: control planes `1`, workers `2`, with a 10 s up delay and a
  30 s shutdown delay, and `on_boot = true`.
- **20-minute timeouts** on config apply, bootstrap, health check and kubeconfig
  retrieval.

## Bringing your own CNI

`cni = "none"` builds a cluster without Flannel; add `kube_proxy = false` when the
CNI replaces kube-proxy as well. The module does not install the CNI — do that
from the root module or your GitOps tooling once the apply has finished:

```hcl
module "talos_cluster" {
  # ...
  cni        = "none"
  kube_proxy = false
}
```

Until a CNI is running, every node is `NotReady` and only host-network pods
(the control-plane static pods) are scheduled, so the health check skips its
Kubernetes checks in this mode; the kubeconfig is still returned.

For Cilium on Talos, the values that matter are:

```yaml
ipam:
  mode: kubernetes
kubeProxyReplacement: true          # with kube_proxy = false
k8sServiceHost: localhost           # KubePrism, on by default in Talos;
k8sServicePort: 7445                # reaches the API without kube-proxy
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
securityContext:
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
gatewayAPI:
  enabled: true                     # install the Gateway API CRDs first
```

Cilium's operator checks for the Gateway API CRDs only at startup, so apply them
before Cilium (or restart the operator afterwards).

Switching an existing cluster between `flannel` and `none` changes the machine
configuration but does not remove the Flannel or kube-proxy resources already
running in it; treat it as a rebuild.

## Lifecycle notes

- **The VIP needs the control planes.** Talos assigns `api_vip` to whichever
  control plane holds it; the Kubernetes endpoint is unavailable until at least one
  control plane is up and etcd has quorum.
- **`bootstrap_node` is permanent.** The bootstrap resource carries
  `ignore_changes = [node, endpoint]` so that re-pointing it can never re-run the
  one-time etcd bootstrap against a live cluster. Set it explicitly on day one.
- **Recreating a VM recreates its configuration.** Each
  `talos_machine_configuration_apply` has `replace_triggered_by` on its VM, so a
  replaced VM boots the ISO and gets configured again.
- **Scaling up is an apply; scaling down is not.** Adding an entry to `nodes`
  creates that VM, configures it and waits for the enlarged cluster to report
  healthy — it needs a DHCP reservation first, like any other node. Removing an
  entry only destroys the VM: Kubernetes keeps the stale node object, and a
  removed control plane stays an etcd member and costs the cluster quorum. Take
  the node out of the cluster first (`kubectl drain`, then `talosctl -n <ip>
  reset --graceful` so etcd loses the member cleanly, then `kubectl delete
  node`), and only then remove it from the map.
- **`vm_boot_delay` only costs you once.** The `time_sleep` gate re-triggers only
  when the node inventory (names → VM IDs) changes, not on every apply.
- **`kubernetes_version` is not an upgrade path.** It seeds the initial control
  plane; upgrading a running cluster is a `talosctl upgrade-k8s` operation, not a
  change to this variable.
- **`talos_version` is not an in-place upgrade either**, and the validation
  regex pins `v1.13.x` on purpose — Talos v1.14 replaces `machine.nodeLabels`
  with a `KubeNodeConfig` document, which would break the node-labels patch.
- **Changing node IPs is disruptive.** They are static addresses in the machine
  config *and* DHCP reservations for maintenance-mode boots; both have to move
  together.
- **Destroy order.** `stop_on_destroy` is set, so `tofu destroy` powers the VMs
  off rather than waiting on a graceful shutdown that Talos will not perform
  without the guest agent.

## Layout

| File | Contents |
| --- | --- |
| [variables.tf](variables.tf) | Inputs and all validation. |
| [vms.tf](vms.tf) | Locals (role split, sizing resolution, tags), ISO download, VMs. |
| [talos.tf](talos.tf) | Machine secrets, config generation and apply, bootstrap, health, kubeconfig. |
| [outputs.tf](outputs.tf) | Inventory, endpoint and credentials. |
| [versions.tf](versions.tf) | Terraform and provider constraints. |
| [templates/machine.yaml.tftpl](templates/machine.yaml.tftpl) | The machine-config patch: install disk, interface, VIP, nameservers, subnets, CNI and kube-proxy. |
