# Inputs are required unless they are genuinely nullable: the root module owns
# the user-facing defaults that terraform.tfvars fills in, and this module owns
# the validation, so neither is duplicated across the two.

variable "proxmox_node" {
  description = "Existing Proxmox node that hosts every VM in this cluster."
  type        = string
}

variable "vm_datastore" {
  description = "Default existing NVMe-backed datastore supporting VM disks. Individual nodes can override it with their own `datastore`."
  type        = string
}

variable "iso_datastore" {
  description = "Existing datastore supporting ISO images."
  type        = string
}

variable "bridge" {
  description = "Existing wired Ethernet bridge."
  type        = string
}

variable "vlan_id" {
  description = "Optional VLAN tag; null uses the untagged bridge network."
  type        = number
  default     = null
  validation {
    condition     = var.vlan_id == null ? true : (var.vlan_id >= 1 && var.vlan_id <= 4094 && floor(var.vlan_id) == var.vlan_id)
    error_message = "VLAN ID must be null or an integer from 1 to 4094."
  }
}

variable "network" {
  description = "Static addressing Talos applies to each node. The node IPs in `nodes` become static addresses in this subnet."
  type = object({
    prefix      = number
    gateway     = string
    nameservers = list(string)
  })
  validation {
    condition     = var.network.prefix >= 8 && var.network.prefix <= 30 && floor(var.network.prefix) == var.network.prefix
    error_message = "network.prefix must be an integer IPv4 prefix length from 8 to 30."
  }
  validation {
    condition     = can(cidrnetmask("${var.network.gateway}/32"))
    error_message = "network.gateway must be an IPv4 address without a prefix."
  }
  validation {
    condition = (
      length(var.network.nameservers) > 0 &&
      alltrue([for ns in var.network.nameservers : can(cidrnetmask("${ns}/32"))])
    )
    error_message = "Provide at least one IPv4 nameserver address."
  }
}

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name; also prefixes the downloaded ISO."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.cluster_name))
    error_message = "Use a lowercase name starting with a letter, at most 40 characters."
  }
}

variable "api_vip" {
  description = "Unused IPv4 address outside DHCP allocation, on the control-plane layer-2 network."
  type        = string
  validation {
    condition     = can(cidrnetmask("${var.api_vip}/32"))
    error_message = "api_vip must be an IPv4 address without a prefix."
  }
  validation {
    condition     = !contains([for n in var.nodes : n.ip], var.api_vip)
    error_message = "The Kubernetes VIP must differ from every node IP."
  }
}

variable "talos_version" {
  description = "Pinned Talos release; review provider/schema compatibility before changing minor versions."
  type        = string
  validation {
    condition     = can(regex("^v1\\.13\\.[0-9]+$", var.talos_version))
    error_message = "This starter targets Talos v1.13.x with the pinned Talos provider."
  }
}

variable "kubernetes_version" {
  description = "Initial Kubernetes version (without v); not an in-place upgrade mechanism."
  type        = string
}

variable "nodes" {
  description = "The cluster inventory, keyed by hostname: one VM per entry, however many you list. At least one `controlplane` is required; workers are optional. IPs become the nodes' static addresses and must match the DHCP reservations used for maintenance-mode boots. Omitting `datastore` places the node's disk on var.vm_datastore. `tags` adds Proxmox tags beyond the managed ones, `labels` adds Kubernetes labels to the node object."
  type = map(object({
    role      = string
    id        = number
    ip        = string
    mac       = string
    datastore = optional(string)
    tags      = optional(list(string), [])
    labels    = optional(map(string), {})
  }))

  validation {
    # The role also selects the sizing defaults and the startup order, so an
    # unknown one has to fail here rather than deep inside a resource.
    condition     = alltrue([for n in var.nodes : contains(["controlplane", "worker"], n.role)])
    error_message = "Each node's role must be either controlplane or worker."
  }
  validation {
    # One control plane is enough for a single-node cluster; etcd only gains
    # fault tolerance at odd counts of three or more. Workers are optional, and
    # a cluster without any schedules workloads on its control planes instead.
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "Provide at least one controlplane node."
  }
  validation {
    condition = alltrue([
      for name, n in var.nodes :
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", name)) &&
      n.id >= 100 && n.id <= 999999999 && floor(n.id) == n.id &&
      can(cidrnetmask("${n.ip}/32")) &&
      can(regex("^[0-9A-Fa-f][02468AaCcEe](:[0-9A-Fa-f]{2}){5}$", n.mac))
    ])
    error_message = "Each node needs a valid DNS hostname, integer VM ID >= 100, IPv4 address and unicast MAC address."
  }
  validation {
    condition = alltrue([
      for n in var.nodes : n.datastore == null ? true : trimspace(n.datastore) == n.datastore && n.datastore != ""
    ])
    error_message = "A node's optional datastore must be a non-empty Proxmox datastore ID without surrounding whitespace."
  }
  validation {
    condition = alltrue(flatten([
      for n in var.nodes : [
        for tag in n.tags : can(regex("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$", tag))
      ]
    ]))
    error_message = "Proxmox tags must start with a letter, digit or underscore and may otherwise contain only letters, digits, underscores, dots, plus signs and hyphens."
  }
  validation {
    condition = alltrue(flatten([
      for n in var.nodes : [
        for k, v in n.labels :
        can(regex("^([a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?$", k)) &&
        can(regex("^([A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?)?$", v))
      ]
    ]))
    error_message = "Each node label needs a valid Kubernetes key (an optional DNS subdomain prefix, a slash, then a name of at most 63 characters) and a value of at most 63 characters."
  }
  validation {
    # Talos writes nodeLabels with the node's own kubelet identity, so the
    # NodeRestriction admission plugin rejects reserved keys apart from the few
    # a kubelet may set for itself. The API server refuses them after apply
    # succeeds, so catch them here instead.
    condition = alltrue(flatten([
      for n in var.nodes : [
        for k in keys(n.labels) :
        !can(regex("(^|\\.)(kubernetes|k8s)\\.io$", try(regex("^([^/]+)/", k)[0], ""))) ||
        can(regex("(^|\\.)(kubelet|node)\\.kubernetes\\.io$", regex("^([^/]+)/", k)[0])) ||
        contains([
          "kubernetes.io/arch",
          "kubernetes.io/hostname",
          "kubernetes.io/os",
          "beta.kubernetes.io/arch",
          "beta.kubernetes.io/instance-type",
          "beta.kubernetes.io/os",
          "failure-domain.beta.kubernetes.io/region",
          "failure-domain.beta.kubernetes.io/zone",
          "topology.kubernetes.io/region",
          "topology.kubernetes.io/zone",
        ], k)
      ]
    ]))
    error_message = "The kubernetes.io and k8s.io label namespaces are reserved: a node may only set topology/instance-type keys and its own kubelet.kubernetes.io or node.kubernetes.io keys. node-role.kubernetes.io/* in particular is rejected; use your own prefix, such as node.example.com/role."
  }
  validation {
    condition = (
      length(distinct([for n in var.nodes : n.id])) == length(var.nodes) &&
      length(distinct([for n in var.nodes : n.ip])) == length(var.nodes) &&
      length(distinct([for n in var.nodes : lower(n.mac)])) == length(var.nodes)
    )
    error_message = "VM IDs, IP addresses and MAC addresses must each be unique."
  }
}

variable "bootstrap_node" {
  description = "Name of the control plane that runs the one-time etcd bootstrap. Set this explicitly and never change it for the life of the cluster. Null selects the alphabetically first control plane."
  type        = string
  default     = null
  validation {
    condition     = var.bootstrap_node == null ? true : try(var.nodes[var.bootstrap_node].role, "") == "controlplane"
    error_message = "bootstrap_node must name one of the controlplane entries in nodes."
  }
}

variable "vm_boot_delay" {
  description = "Time to wait after the VMs start before the first Talos configuration attempt, allowing maintenance mode to come up."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.vm_boot_delay))
    error_message = "Use a Go duration such as 60s, 2m or 1h."
  }
}

variable "sizing" {
  description = "Per-VM allocations. Memory is MiB, disk is GiB. `controlplane` and `worker` are the defaults every node of that role gets; `worker` may be omitted when the inventory holds no workers. `nodes` overrides individual fields for one named node, and any field left out there falls back to the role default."
  type = object({
    controlplane = object({ cores = number, memory = number, disk = number })
    worker       = optional(object({ cores = number, memory = number, disk = number }))
    nodes = optional(map(object({
      cores  = optional(number)
      memory = optional(number)
      disk   = optional(number)
    })), {})
  })
  validation {
    condition = alltrue([
      for s in [var.sizing.controlplane, var.sizing.worker] :
      s == null ? true : (
        s.cores >= 2 && floor(s.cores) == s.cores &&
        s.memory >= 2048 && floor(s.memory) == s.memory &&
        s.disk >= 32 && floor(s.disk) == s.disk
      )
    ])
    error_message = "Use integer allocations of at least 2 vCPU, 2048 MiB RAM and 32 GiB disk."
  }
  validation {
    condition     = var.sizing.worker != null || length([for n in var.nodes : n if n.role == "worker"]) == 0
    error_message = "sizing.worker is required whenever nodes contains worker entries."
  }
  validation {
    condition = alltrue([
      for s in values(var.sizing.nodes) :
      (s.cores == null ? true : s.cores >= 2 && floor(s.cores) == s.cores) &&
      (s.memory == null ? true : s.memory >= 2048 && floor(s.memory) == s.memory) &&
      (s.disk == null ? true : s.disk >= 32 && floor(s.disk) == s.disk)
    ])
    error_message = "Per-node overrides in sizing.nodes must also use integer allocations of at least 2 vCPU, 2048 MiB RAM and 32 GiB disk."
  }
  validation {
    condition     = alltrue([for name in keys(var.sizing.nodes) : contains(keys(var.nodes), name)])
    error_message = "Every key in sizing.nodes must name an entry in the nodes variable."
  }
}
