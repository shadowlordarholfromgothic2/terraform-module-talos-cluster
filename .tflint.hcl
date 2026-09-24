config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# This module is split by concern (talos.tf, vms.tf) rather than using a single
# main.tf, so the standard-structure rule does not apply.
rule "terraform_standard_module_structure" {
  enabled = false
}
