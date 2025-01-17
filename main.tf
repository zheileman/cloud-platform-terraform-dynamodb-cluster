provider "aws" {
  alias  = "custom"
  region = var.aws_region
}

# attributes map here borrowed from https://github.com/cloudposse/terraform-aws-dynamodb
locals {
  attributes = concat(
    [
      {
        name = var.range_key
        type = var.range_key_type
      },
      {
        name = var.hash_key
        type = var.hash_key_type
      }
    ],
    var.attributes
  )

  # Remove the first map from the list if no `range_key` is provided
  from_index = length(var.range_key) > 0 ? 0 : 1

  attributes_final = slice(local.attributes, local.from_index, length(local.attributes))
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_dynamodb_table" "default" {
  provider       = aws.custom
  name           = "cp-${random_id.id.hex}"
  read_capacity  = var.autoscale_min_read_capacity
  write_capacity = var.autoscale_min_write_capacity
  hash_key       = var.hash_key
  range_key      = var.range_key

  dynamic "attribute" {
    for_each = local.attributes_final
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  server_side_encryption {
    enabled = var.enable_encryption
  }

  lifecycle {
    ignore_changes = [
      read_capacity,
      write_capacity,
    ]
  }

  ttl {
    attribute_name = var.ttl_attribute
    enabled        = "true"
  }

  point_in_time_recovery {
    enabled = "true"
  }

  tags = {
    business-unit          = var.business-unit
    application            = var.application
    is-production          = var.is-production
    environment-name       = var.environment-name
    owner                  = var.team_name
    infrastructure-support = var.infrastructure-support
    namespace              = var.namespace
  }
}

resource "aws_iam_user" "user" {
  name = "cp-dynamo-${random_id.id.hex}"
  path = "/system/dynamo-user/"
}

resource "aws_iam_access_key" "key" {
  user = aws_iam_user.user.name
}

resource "aws_iam_user_policy" "userpol" {
  name   = aws_iam_user.user.name
  policy = data.aws_iam_policy_document.policy.json
  user   = aws_iam_user.user.name
}

data "aws_iam_policy_document" "policy" {
  statement {
    actions = [
      "dynamodb:*",
    ]

    resources = [
      aws_dynamodb_table.default.arn,
    ]
  }
}

#######################
# dynamodb-autoscaler #
#######################

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["application-autoscaling.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role" "autoscaler" {
  count              = var.enable_autoscaler == "true" ? 1 : 0
  name               = "cp-dynamo-${random_id.id.hex}-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "autoscaler" {
  statement {
    sid = ""

    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:UpdateTable",
    ]

    resources = [
      aws_dynamodb_table.default.arn,
    ]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy" "autoscaler" {
  count  = var.enable_autoscaler == "true" ? 1 : 0
  name   = "cp-dynamo-${random_id.id.hex}-autoscaler"
  role   = join("", aws_iam_role.autoscaler.*.id)
  policy = data.aws_iam_policy_document.autoscaler.json
}

data "aws_iam_policy_document" "autoscaler_cloudwatch" {
  statement {
    sid = ""

    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DeleteAlarms",
    ]

    resources = ["*"]

    effect = "Allow"
  }
}

resource "aws_iam_role_policy" "autoscaler_cloudwatch" {
  count  = var.enable_autoscaler == "true" ? 1 : 0
  name   = "cp-dynamo-${random_id.id.hex}-cloudwatch"
  role   = join("", aws_iam_role.autoscaler.*.id)
  policy = data.aws_iam_policy_document.autoscaler_cloudwatch.json
}

# https://github.com/cloudposse/terraform-aws-dynamodb-autoscaler

module "dynamodb_autoscaler" {
  source = "cloudposse/dynamodb-autoscaler/aws"

  version                      = "0.13.0"
  enabled                      = var.enable_autoscaler
  name                         = "cp-dynamo-${random_id.id.hex}"
  dynamodb_table_name          = aws_dynamodb_table.default.id
  dynamodb_table_arn           = aws_dynamodb_table.default.arn
  autoscale_write_target       = var.autoscale_write_target
  autoscale_read_target        = var.autoscale_read_target
  autoscale_min_read_capacity  = var.autoscale_min_read_capacity
  autoscale_max_read_capacity  = var.autoscale_max_read_capacity
  autoscale_min_write_capacity = var.autoscale_min_write_capacity
  autoscale_max_write_capacity = var.autoscale_max_write_capacity
}
