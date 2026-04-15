variable "environment" {
  description = "The environment name"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "region" {
  description = "The AWS region"
  type        = string
}

variable "project_name" {
  description = "The project name"
  type        = string
}

# Optional overrides — if null, values are read from aws-core remote state
variable "landing_bucket_id" {
  description = "ID of the landing zone bucket (auto-read from core state if null)"
  type        = string
  default     = null
}

variable "raw_bucket_id" {
  description = "ID of the raw zone bucket (auto-read from core state if null)"
  type        = string
  default     = null
}

variable "landing_notification_topic_arn" {
  description = "ARN of the landing zone SNS notification topic (auto-read from core state if null)"
  type        = string
  default     = null
}

# Read core infrastructure outputs from remote state.
# State key matches what terraform.yml computes: inputs.path + "/terraform.tfstate"
# For aws-core with path="infra" → "infra/terraform.tfstate"
data "terraform_remote_state" "core" {
  backend = "s3"
  config = {
    bucket = "${var.project_name}-terraform-state-${var.region}-${var.environment}"
    key    = "infra/terraform.tfstate"
    region = var.region
  }
}

locals {
  landing_bucket_id              = var.landing_bucket_id != null ? var.landing_bucket_id : data.terraform_remote_state.core.outputs.landing_bucket_id
  raw_bucket_id                  = var.raw_bucket_id != null ? var.raw_bucket_id : data.terraform_remote_state.core.outputs.raw_bucket_id
  landing_notification_topic_arn = var.landing_notification_topic_arn != null ? var.landing_notification_topic_arn : data.terraform_remote_state.core.outputs.landing_notification_topic_arn
}

data "aws_caller_identity" "current" {}

module "raw_puls_data_notification" {
  source     = "git::https://github.com/kitsune242/aws-common.git//infra/modules/sns_topic?ref=v1.0.0"
  topic_name = "${var.project_name}-raw-puls-data-notification-${var.region}-${var.environment}"
  tags = {
    Environment = var.environment
    Plugin      = "puls_data"
    ManagedBy   = "terraform"
  }
}

data "aws_iam_policy_document" "puls_ingest_policy" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.landing_bucket_id}"]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${local.landing_bucket_id}/*"]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.raw_bucket_id}/puls_data/*"]
  }

  # HeadObject needed for idempotency check before copying
  statement {
    actions   = ["s3:HeadObject"]
    resources = ["arn:aws:s3:::${local.raw_bucket_id}/puls_data/*"]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [module.raw_puls_data_notification.topic_arn]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-puls-ingest-${var.region}-${var.environment}:*"
    ]
  }
}

module "puls_ingest_lambda" {
  source                     = "git::https://github.com/kitsune242/aws-common.git//infra/modules/lambda_function?ref=v1.0.0"
  function_name              = "${var.project_name}-puls-ingest-${var.region}-${var.environment}"
  handler                    = "ingest.lambda_handler"
  runtime                    = "python3.12"
  filename                   = "${path.module}/../etl/ingest.zip"
  sns_topic_subscription_arn = local.landing_notification_topic_arn
  iam_policy_json            = data.aws_iam_policy_document.puls_ingest_policy.json

  environment_variables = {
    LANDING_BUCKET          = local.landing_bucket_id
    RAW_BUCKET              = local.raw_bucket_id
    RAW_PULS_DATA_TOPIC_ARN = module.raw_puls_data_notification.topic_arn
  }

  tags = {
    Environment = var.environment
    Plugin      = "puls_data"
    ManagedBy   = "terraform"
  }
}

