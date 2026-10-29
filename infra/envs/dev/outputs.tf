output "api_url" {
  description = "Invoke this URL with the SOAP XML request."
  value       = module.soap_gateway.api_url
}

output "api_id" {
  description = "API Gateway REST API ID."
  value       = module.soap_gateway.api_id
}

output "lambda_function_name" {
  description = "Lambda adapter function name."
  value       = module.soap_gateway.lambda_function_name
}

output "mapping_table_name" {
  description = "DynamoDB mapping table name."
  value       = module.soap_gateway.mapping_table_name
}

output "waf_web_acl_arn" {
  description = "Regional WAF web ACL ARN."
  value       = module.soap_gateway.waf_web_acl_arn
}
