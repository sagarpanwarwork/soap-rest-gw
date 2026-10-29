provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "zeron-soap-gateway"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}
