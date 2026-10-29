terraform {
  # use_lockfile requires Terraform 1.10+ and provides S3-native state locking.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }

  backend "s3" {}
}
