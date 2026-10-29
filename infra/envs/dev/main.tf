module "soap_gateway" {
  source = "../../modules/soap-rest-gateway"

  project_name = "zeron-soap"
  environment  = "dev"
  aws_region   = var.aws_region

  # Build this artifact first with scripts/package.ps1 or scripts/package.sh.
  lambda_zip_path = abspath("${path.root}/../../../build/lambda_function.zip")

  allowed_client_cidrs = var.allowed_client_cidrs
  third_party_api_url  = var.third_party_api_url
  api_authorization    = var.api_authorization

  lambda_memory_size            = var.lambda_memory_size
  lambda_timeout_seconds        = var.lambda_timeout_seconds
  lambda_reserved_concurrency   = var.lambda_reserved_concurrency
  log_retention_days            = var.log_retention_days
  waf_rate_limit                = var.waf_rate_limit
  api_throttle_rate_limit       = var.api_throttle_rate_limit
  api_throttle_burst_limit      = var.api_throttle_burst_limit
  enable_point_in_time_recovery = var.enable_point_in_time_recovery
  enable_deletion_protection    = var.enable_deletion_protection
}
