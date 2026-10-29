variable "aws_region" {
  description = "AWS Region for this environment."
  type        = string
  default     = "ap-south-1"
}

variable "allowed_client_cidrs" {
  description = "Stable public IPv4 egress CIDRs allowed by WAF. Replace the example address before applying."
  type        = list(string)

  validation {
    condition = length(var.allowed_client_cidrs) > 0 && alltrue([
      for cidr in var.allowed_client_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
    ])
    error_message = "Provide at least one valid IPv4 CIDR; 0.0.0.0/0 is not allowed."
  }
}

variable "third_party_api_url" {
  description = "HTTPS mock endpoint. DummyJSON simulates POST /users/add and does not persist data."
  type        = string
  default     = "https://dummyjson.com/users/add"

  validation {
    condition     = startswith(var.third_party_api_url, "https://")
    error_message = "The downstream endpoint must use HTTPS."
  }
}

variable "api_authorization" {
  description = "API Gateway authorization type. Dev is open only to WAF-allowlisted IPs; prod profile uses SigV4 IAM auth as well."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM"], var.api_authorization)
    error_message = "api_authorization must be NONE or AWS_IAM."
  }
}

variable "lambda_memory_size" {
  description = "Lambda memory allocation in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda execution timeout. Keep it below the REST API integration limit."
  type        = number
  default     = 10
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency limits the maximum concurrent adapter executions."
  type        = number
  default     = 2
}

variable "log_retention_days" {
  description = "Lambda CloudWatch Logs retention in days."
  type        = number
  default     = 3
}

variable "waf_rate_limit" {
  description = "WAF request threshold per five-minute window per approved source IP."
  type        = number
  default     = 300
}

variable "api_throttle_rate_limit" {
  description = "API Gateway steady-state throttling limit (best effort)."
  type        = number
  default     = 5
}

variable "api_throttle_burst_limit" {
  description = "API Gateway burst throttling limit (best effort)."
  type        = number
  default     = 10
}

variable "enable_point_in_time_recovery" {
  description = "Enable DynamoDB point-in-time recovery."
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable DynamoDB deletion protection."
  type        = bool
  default     = false
}
