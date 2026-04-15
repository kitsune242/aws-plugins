output "raw_puls_data_notification_topic_arn" {
  description = "ARN of the SNS topic for raw puls_data notifications"
  value       = module.raw_puls_data_notification.topic_arn
}

output "puls_ingest_lambda_arn" {
  description = "ARN of the puls_data ingest Lambda function"
  value       = module.puls_ingest_lambda.function_arn
}
