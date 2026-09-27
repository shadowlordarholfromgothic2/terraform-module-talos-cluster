tflint {
  required_version = ">= 0.64"
}

config {
  format              = "compact"
  call_module_type    = "local"
  force               = false
  disabled_by_default = false
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

# Bundled ruleset — no version/source needed
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_unused_declarations" {
  enabled = true
}
