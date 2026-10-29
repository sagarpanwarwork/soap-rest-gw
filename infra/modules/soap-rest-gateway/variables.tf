variable "project_name" {
  description = "Short project identifier used in resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment, for example dev or prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either dev or prod."
  }
}

variable "aws_region" {
  description = "AWS Region for all regional resources."
  type        = string
  default     = "ap-south-1"
}

variable "lambda_zip_path" {
  description = "Absolute path to the pre-built Lambda ZIP package."
  type        = string
}

variable "allowed_client_cidrs" {
  description = "Approved public IPv4 CIDR ranges that may call the SOAP API through AWS WAF. Use a stable public egress IP, commonly /32."
  type        = list(string)

  validation {
    condition = length(var.allowed_client_cidrs) > 0 && alltrue([
      for cidr in var.allowed_client_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "Provide at least one valid IPv4 CIDR; 0.0.0.0/0 is not allowed."
  }
}

variable "third_party_api_url" {
  description = "Trusted HTTPS URL for the downstream mock API. This is configuration, never accepted from the incoming request."
  type        = string
  default     = "https://dummyjson.com/users/add"

  validation {
    condition     = startswith(var.third_party_api_url, "https://")
    error_message = "third_party_api_url must use HTTPS."
  }
}

variable "api_authorization" {
  description = "API Gateway method authorization. Use NONE for IP-restricted classroom dev, AWS_IAM for the production profile."
  type        = string

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.api_authorization)
    error_message = "api_authorization must be NONE or AWS_IAM."
  }
}

variable "lambda_memory_size" {
  description = "Lambda memory allocation in MB."
  type        = number

  validation {
    condition     = var.lambda_memory_size >= 128 && var.lambda_memory_size <= 10240
    error_message = "lambda_memory_size must be between 128 and 10240 MB."
  }
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number

  validation {
    condition     = var.lambda_timeout_seconds >= 1 && var.lambda_timeout_seconds <= 29
    error_message = "Use a timeout between 1 and 29 seconds for this synchronous API integration."
  }
}

variable "lambda_reserved_concurrency" {
  description = "Maximum concurrent executions reserved for this adapter; limits blast radius and unexpected spend."
  type        = number

  validation {
    condition     = var.lambda_reserved_concurrency >= 1
    error_message = "lambda_reserved_concurrency must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period for the Lambda log group."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Choose a supported CloudWatch Logs retention period."
  }
}

variable "waf_rate_limit" {
  description = "Maximum requests per five-minute window per source IP before the WAF blocks that IP. Applies only to allowlisted clients."
  type        = number

  validation {
    condition     = var.waf_rate_limit >= 100 && var.waf_rate_limit <= 2000000000
    error_message = "waf_rate_limit must be between 100 and 2,000,000,000 for this project."
  }
}

variable "api_throttle_rate_limit" {
  description = "API Gateway steady-state request rate limit (best-effort throttling)."
  type        = number

  validation {
    condition     = var.api_throttle_rate_limit > 0
    error_message = "api_throttle_rate_limit must be positive."
  }
}

variable "api_throttle_burst_limit" {
  description = "API Gateway burst request limit (best-effort throttling)."
  type        = number

  validation {
    condition     = var.api_throttle_burst_limit > 0
    error_message = "api_throttle_burst_limit must be positive."
  }
}

variable "enable_point_in_time_recovery" {
  description = "Enable DynamoDB point-in-time recovery. Enable for the production profile."
  type        = bool
}

variable "enable_deletion_protection" {
  description = "Protect the DynamoDB mapping table from accidental deletion. Enable for the production profile."
  type        = bool
}
