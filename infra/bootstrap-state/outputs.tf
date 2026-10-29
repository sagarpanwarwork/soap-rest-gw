output "state_bucket_name" {
  description = "Use this bucket in each environment's backend.hcl."
  value       = aws_s3_bucket.terraform_state.bucket
}
