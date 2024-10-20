provider "aws" {
  region = "us-west-2"
}

variable "aws_region" {
  default = "us-west-2"
}

#################################
# S3 Buckets for Image Storage  #
#################################

resource "aws_s3_bucket" "source_images" {
  bucket = "stori-thumbnail-original-images"
}

resource "aws_s3_bucket" "thumbnails" {
  bucket = "stori-thumbnail-thumbnails"
}

########################################
# IAM Roles and Policies Configuration #
########################################

# IAM Role for Lambda execution
resource "aws_iam_role" "lambda_s3_exec_role" {
  name = "lambda_s3_exec_role"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  })
}

# Attach basic execution policy to Lambda
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_s3_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow Lambda access to S3 buckets
resource "aws_iam_role_policy" "s3_access_policy" {
  name = "s3_access_policy"
  role = aws_iam_role.lambda_s3_exec_role.id
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject"],
        "Resource": [
          "arn:aws:s3:::stori-thumbnail-original-images/*",
          "arn:aws:s3:::stori-thumbnail-thumbnails/*"
        ]
      }
    ]
  })
}

# Allow Lambda to use Rekognition
resource "aws_iam_role_policy" "rekognition_access_policy" {
  name = "rekognition_access_policy"
  role = aws_iam_role.lambda_s3_exec_role.id
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "rekognition:DetectLabels",
      "Resource": "*"
    }]
  })
}


#########################
# Security Group Setup  #
#########################

resource "aws_security_group" "rds_security_group" {
  name        = "allow_mysql"
  description = "Allow MySQL traffic"

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Use cautiously in production, restrict this as needed
  }

  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mysql-security-group"
  }
}


###################################
# RDS MySQL Instance Configuration #
###################################

resource "aws_db_instance" "mysql_db" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  username             = "dbadmin"
  password             = "MySQLPassword123"
  publicly_accessible  = true
  skip_final_snapshot  = true

  vpc_security_group_ids = [aws_security_group.rds_security_group.id]

  tags = {
    Name = "mysql-db-instance"
  }
}

############################
# Lambda Layer for Pillow  #
############################

resource "aws_lambda_layer_version" "pillow_layer" {
  filename   = "pillow_layer.zip"
  layer_name = "pillow-layer"
  compatible_runtimes = ["python3.9"]
  source_code_hash = filebase64sha256("pillow_layer.zip")
}

#####################################
# Lambda Layer for MySQL Connector  #
#####################################

resource "aws_lambda_layer_version" "mysql_connector_layer" {
  filename         = "mysql_connector_layer.zip"
  layer_name       = "mysql-connector-layer"
  compatible_runtimes = ["python3.9"]
}

############################
# Lambda Function Setup    #
############################

resource "aws_lambda_function" "thumbnail_generator" {
  function_name = "thumbnail-generator"
  role          = aws_iam_role.lambda_s3_exec_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  filename      = "lambda.zip"
  source_code_hash = filebase64sha256("lambda.zip")

  layers = [
    aws_lambda_layer_version.pillow_layer.arn,
    aws_lambda_layer_version.mysql_connector_layer.arn
  ]

  environment {
    variables = {
      DEST_BUCKET   = aws_s3_bucket.thumbnails.bucket
      RDS_ENDPOINT  = aws_db_instance.mysql_db.endpoint
      RDS_PORT      = "3306"
      RDS_DB_NAME   = "images_metadata"
      RDS_USERNAME  = "dbadmin"
      RDS_PASSWORD  = "MySQLPassword123"
    }
  }
}

#########################
# API Gateway Setup     #
#########################

resource "aws_api_gateway_rest_api" "thumbnail_api" {
  name = "ThumbnailGeneratorAPI"
}

resource "aws_api_gateway_resource" "upload" {
  rest_api_id = aws_api_gateway_rest_api.thumbnail_api.id
  parent_id   = aws_api_gateway_rest_api.thumbnail_api.root_resource_id
  path_part   = "upload"
}

resource "aws_api_gateway_method" "upload_put" {
  rest_api_id   = aws_api_gateway_rest_api.thumbnail_api.id
  resource_id   = aws_api_gateway_resource.upload.id
  http_method   = "PUT"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id            = aws_api_gateway_rest_api.thumbnail_api.id
  resource_id            = aws_api_gateway_resource.upload.id
  http_method            = aws_api_gateway_method.upload_put.http_method
  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.thumbnail_generator.invoke_arn
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.thumbnail_api.id
  stage_name  = "prod"
  depends_on  = [aws_api_gateway_integration.lambda_integration]
}

#########################
# CloudWatch Log Groups #
#########################

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/thumbnail-generator"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "api_gateway_log_group" {
  name              = "/aws/api-gateway/thumbnail-api"
  retention_in_days = 7
}

##################################
# S3 Notification to Invoke Lambda #
##################################

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.thumbnail_generator.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source_images.arn
}

resource "aws_s3_bucket_notification" "image_upload_notification" {
  bucket = aws_s3_bucket.source_images.bucket

  lambda_function {
    lambda_function_arn = aws_lambda_function.thumbnail_generator.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

