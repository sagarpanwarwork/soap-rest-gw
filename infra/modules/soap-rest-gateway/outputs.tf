output "api_url" {
  description = "SOAP endpoint URL for the configured environment."
  value       = "https://${aws_api_gateway_rest_api.soap.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.soap.stage_name}/soap"
}

output "api_id" {
  description = "API Gateway REST API identifier."
  value       = aws_api_gateway_rest_api.soap.id
}

output "lambda_function_name" {
  description = "Lambda adapter function name."
  value       = aws_lambda_function.adapter.function_name
}

output "mapping_table_name" {
  description = "DynamoDB table storing mapping templates."
  value       = aws_dynamodb_table.mappings.name
}

output "waf_web_acl_arn" {
  description = "ARN of the Regional WAF web ACL associated with the API stage."
  value       = aws_wafv2_web_acl.soap.arn
}
