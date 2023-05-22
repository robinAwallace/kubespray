terraform {
  required_providers {
    exoscale = {
      source  = "exoscale/exoscale"
      version = ">= 0.48"
    }
  }
  experiments      = [module_variable_optional_attrs]
  required_version = ">= 0.14"
}
