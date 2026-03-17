#Image uploaded to S3 → Event-driven Lambda processing → Processed image stored in destination S3 bucket

#Creating random id for the resources to keep the resource names unique#
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_prefix         = "${var.project_name}-${var.environment}"
  upload_bucket_name    = "${local.bucket_prefix}-upload-${random_id.suffix.hex}"
  processed_bucket_name = "${local.bucket_prefix}-processed-${random_id.suffix.hex}"
  lambda_function_name  = "${var.project_name}-${var.environment}-processor"
}

#=============================================================================================================
#S3 BUCKETS
#=============================================================================================================

# Upload Bucket
resource "aws_s3_bucket" "upload_bucket" {
  bucket        = local.upload_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "upload_bucket" {
  bucket = aws_s3_bucket.upload_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "upload_bucket" {
  bucket = aws_s3_bucket.upload_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "upload_bucket" {
  bucket = aws_s3_bucket.upload_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Processed Bucket
resource "aws_s3_bucket" "processed_bucket" {
  bucket        = local.processed_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "processed_bucket" {
  bucket = aws_s3_bucket.processed_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_bucket" {
  bucket = aws_s3_bucket.processed_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "processed_bucket" {
  bucket                  = aws_s3_bucket.processed_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


#==================================================================================================================
#IAM ROLE & POLICIES
#==================================================================================================================


# IAM role for Lambda function
resource "aws_iam_role" "lambda_role" {
  name = "${local.lambda_function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Lambda function
data "aws_iam_policy_document" "lambda_combined_policy" {
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:${var.region}:*:*"]
  }

  statement {
    sid    = "ReadFromUploadBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.upload_bucket.arn,
      "${aws_s3_bucket.upload_bucket.arn}/*"
    ]
  }

  statement {
    sid    = "WriteToProcessedBucket"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]
    resources = ["${aws_s3_bucket.processed_bucket.arn}/*"]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${local.lambda_function_name}-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_combined_policy.json
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = 7 # Keep logs for a week
}


#=========================================================================================================
#LAMBDA LAYER (PILLOW)
#==========================================================================================================

data "archive_file" "pillow_layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../layers/pillow_layer"
  output_path = "${path.module}/pillow_layer.zip"
}

resource "aws_lambda_layer_version" "pillow_layer" {
  filename            = data.archive_file.pillow_layer_zip.output_path
  source_code_hash    = data.archive_file.pillow_layer_zip.output_base64sha256
  layer_name          = "${var.project_name}-pillow_layer"
  compatible_runtimes = ["python3.12"]
  description         = "Pillow library for image processing"
}

#resource "aws_lambda_layer_version" "pillow_layer" {
#filename            = "${path.module}/pillow_layer.zip"
#layer_name          = "${var.project_name}-pillow-layer"
#compatible_runtimes = ["python3.12"]
#description         = "Pillow library for image processing"
#}
# ============================================================================================================
# LAMBDA FUNCTION (Image Processor)
# ============================================================================================================


# Data source for Lambda function zip
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# Lambda function
resource "aws_lambda_function" "image_processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 512
  layers           = [aws_lambda_layer_version.pillow_layer.arn]

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed_bucket.id
      LOG_LEVEL        = "INFO"
    }
  }
}

# ============================================================================
# S3 EVENT TRIGGER
# ============================================================================

# Lambda permission to be invoked by S3
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.upload_bucket.arn
}

# S3 bucket notification to trigger Lambda
resource "aws_s3_bucket_notification" "upload_bucket_notification" {
  bucket = aws_s3_bucket.upload_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}




