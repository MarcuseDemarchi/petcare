terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.notags]
    }
    random  = { source = "hashicorp/random" }
    archive = { source = "hashicorp/archive" }
  }
}
