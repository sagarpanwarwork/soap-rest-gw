# -----------------------------------------------------------------------------
# SOAP-to-REST adapter module.
# This module intentionally does not create a VPC: Lambda calls a public HTTPS
# mock API and DynamoDB, so VPC/NAT routing would add complexity and cost without
# providing a required private-network path for this classroom architecture.
# -----------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# DynamoDB mapping template store. The app role gets GetItem only.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "mappings" {
  name                        = "${local.name_prefix}-mappings"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "mapping_id"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "mapping_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mappings"
  })
}

# Seed the lab's versioned mapping through IaC. These are configuration values,
# not secrets. The DynamoDB table item is replaced when the template changes.
resource "aws_dynamodb_table_item" "create_user_v1" {
  table_name = aws_dynamodb_table.mappings.name
  hash_key   = aws_dynamodb_table.mappings.hash_key

  item = jsonencode({
    mapping_id = { S = "CreateUser#v1" }
    operation  = { S = "CreateUser" }
    version    = { N = "1" }
    request_template = {
      S = <<-JSON
        {
          "firstName": "{{{firstNameJson}}}",
          "lastName": "{{{lastNameJson}}}",
          "age": {{{ageJson}}}
        }
      JSON
    }
    response_template = {
      S = <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <CreateUserResponse xmlns="urn:zeron:users:v1">
              <User>
                <UserId>{{id}}</UserId>
                <FirstName>{{firstName}}</FirstName>
                <LastName>{{lastName}}</LastName>
                <Age>{{age}}</Age>
              </User>
            </CreateUserResponse>
          </soap:Body>
        </soap:Envelope>
      XML
    }
  })
}

# -----------------------------------------------------------------------------
# IAM execution role: Lambda may assume this role. Separate inline policy grants
# only GetItem access to the specific mapping table. Basic log permissions are
# attached separately.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "read_mapping" {
  name = "read-mapping-item"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem"]
      Resource = aws_dynamodb_table.mappings.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-adapter"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Lambda function. The ZIP is built by scripts/package.ps1 or package.sh before
# Terraform runs, keeping source code separate from infrastructure code.
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "adapter" {
  function_name = "${local.name_prefix}-adapter"
  description   = "Converts a SOAP 1.1 CreateUser request to JSON and back."

  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout_seconds

  # Avoid unbounded concurrency for a small teaching workload.
#   reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      MAPPING_TABLE_NAME       = aws_dynamodb_table.mappings.name
      MAPPING_ID               = "CreateUser#v1"
      THIRD_PARTY_API_URL      = var.third_party_api_url
      MAX_XML_BYTES            = "65536"
      UPSTREAM_TIMEOUT_SECONDS = "5"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_logs,
    aws_iam_role_policy.read_mapping,
    aws_cloudwatch_log_group.lambda,
    aws_dynamodb_table_item.create_user_v1
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-adapter"
  })
}

# API Gateway needs this resource-based permission to invoke the Lambda function.
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowExecutionFromApiGateway-${var.environment}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.adapter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.soap.execution_arn}/*/POST/soap"
}

# -----------------------------------------------------------------------------
# Regional API Gateway REST API. REST API is used because AWS WAF can protect
# API Gateway REST API stages. The only route is POST /soap.
# -----------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "soap" {
  name        = local.name_prefix
  description = "SOAP-to-REST adapter for ${var.environment}."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.common_tags
}

resource "aws_api_gateway_resource" "soap" {
  rest_api_id = aws_api_gateway_rest_api.soap.id
  parent_id   = aws_api_gateway_rest_api.soap.root_resource_id
  path_part   = "soap"
}

resource "aws_api_gateway_method" "soap_post" {
  rest_api_id   = aws_api_gateway_rest_api.soap.id
  resource_id   = aws_api_gateway_resource.soap.id
  http_method   = "POST"
  authorization = var.api_authorization
}

resource "aws_api_gateway_integration" "soap_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.soap.id
  resource_id             = aws_api_gateway_resource.soap.id
  http_method             = aws_api_gateway_method.soap_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.adapter.invoke_arn
}

resource "aws_api_gateway_deployment" "soap" {
  rest_api_id = aws_api_gateway_rest_api.soap.id

  # The trigger forces a new API deployment when route/method/integration
  # configuration changes. Lambda code updates do not require an API snapshot.
  triggers = {
    redeployment = sha1(jsonencode({
      resource_id      = aws_api_gateway_resource.soap.id
      method_id        = aws_api_gateway_method.soap_post.id
      method           = aws_api_gateway_method.soap_post.http_method
      authorization    = aws_api_gateway_method.soap_post.authorization
      integration_id   = aws_api_gateway_integration.soap_lambda.id
      integration_type = aws_api_gateway_integration.soap_lambda.type
      integration_uri  = aws_api_gateway_integration.soap_lambda.uri
    }))
  }

  depends_on = [
    aws_api_gateway_method.soap_post,
    aws_api_gateway_integration.soap_lambda,
    aws_lambda_permission.api_gateway_invoke
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "soap" {
  rest_api_id   = aws_api_gateway_rest_api.soap.id
  deployment_id = aws_api_gateway_deployment.soap.id
  stage_name    = var.environment

  tags = local.common_tags
}

# API Gateway throttling is a best-effort safety rail, not a guaranteed cost cap.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.soap.id
  stage_name  = aws_api_gateway_stage.soap.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "OFF"
    data_trace_enabled     = false
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }
}

# -----------------------------------------------------------------------------
# AWS WAF: default BLOCK, permit the approved client IP set, and apply a
# rate-based block to those approved IPs if they exceed the configured limit.
# WAF and the API Gateway stage must be in the same Region.
# -----------------------------------------------------------------------------
resource "aws_wafv2_ip_set" "approved_clients" {
  name               = "${local.name_prefix}-approved-ips"
  description        = "Approved public IPv4 egress CIDRs for the SOAP API."
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_client_cidrs

  tags = local.common_tags
}

resource "aws_wafv2_web_acl" "soap" {
  name        = "${local.name_prefix}-waf"
  description = "IP-restricted and rate-limited SOAP API."
  scope       = "REGIONAL"

  default_action {
    block {}
  }

  # This rule is evaluated first. Only approved IPs are counted; exceeding the
  # threshold blocks the IP for the WAF evaluation window.
  rule {
    name     = "RateLimitApprovedClients"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.approved_clients.arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${replace(local.name_prefix, "-", "")}-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  # Below the rate limit, an approved IP reaches this allow rule. All other
  # source IPs fall through to the web ACL's default BLOCK action.
  rule {
    name     = "AllowApprovedClients"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.approved_clients.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${replace(local.name_prefix, "-", "")}-allowips"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${replace(local.name_prefix, "-", "")}-webacl"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl_association" "soap_stage" {
  resource_arn = aws_api_gateway_stage.soap.arn
  web_acl_arn  = aws_wafv2_web_acl.soap.arn
}
