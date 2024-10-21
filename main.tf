provider "aws" {
  region = "us-west-2"
}

variable "aws_region" {
  default = "us-west-2"
}

### Configuration of the S3 buckets, one for original images and another for thumbnails

#################################
# S3 Buckets for Image Storage  #
#################################

resource "aws_s3_bucket" "source_images" {
  bucket = "stori-thumbnail-original-images"
}

resource "aws_s3_bucket" "thumbnails" {
  bucket = "stori-thumbnail-thumbnails"
}

### IAM Roles and Policies so the interacion between modules it's independent

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

# IAM Role for Glue
resource "aws_iam_role" "glue_service_role" {
  name = "glue_service_role"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "glue.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_s3_access" {
  role       = aws_iam_role.glue_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "glue_redshift_access" {
  role       = aws_iam_role.glue_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRedshiftFullAccess"
}

resource "aws_iam_role_policy_attachment" "glue_rds_access" {
  role       = aws_iam_role.glue_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

resource "aws_iam_policy" "glue_policy" {
  name = "glue_access_policy"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "glue:GetConnection",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:CreateTable",
          "glue:UpdateTable"
        ],
        "Resource": "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_policy_attachment" {
  role       = aws_iam_role.glue_service_role.name
  policy_arn = aws_iam_policy.glue_policy.arn
}

### Security Group that makes possible to connect to the database publicly, it should be modified before production.

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


### Configuration of the MySQL Instance that allows create the database

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

### Configuration of a Redshift Cluster to admin the databases. 

##################################
# Redshift Cluster Configuration #
##################################

resource "aws_redshift_cluster" "image_tags_cluster" {
  cluster_identifier = "image-tags-cluster"
  node_type          = "dc2.large"
  master_username    = "admin"
  master_password    = "RedshiftPassword123"
  cluster_type       = "single-node"
  skip_final_snapshot = true

  tags = {
    Name = "image-tags-cluster"
  }
}

### Configuration of the Glue Database Catalog, it's unused because a limitation in the VPC configuration of redshift

##############################
# Glue Database Configuration #
##############################

resource "aws_glue_catalog_database" "rds_metadata_database" {
  name = "rds_metadata"
}

### Conection of Glue with the RDS MySQL Database, the connection its available.

#########################
# Glue Connection Setup #
#########################

resource "aws_glue_connection" "mysql_connection" {
  name = "mysql-connection"
  connection_properties = {
    "JDBC_CONNECTION_URL" : "jdbc:mysql://${aws_db_instance.mysql_db.endpoint}:3306/images_metadata"
    "USERNAME"            : "dbadmin"
    "PASSWORD"            : "MySQLPassword123"
  }

  physical_connection_requirements {
    security_group_id_list = [aws_security_group.rds_security_group.id]
    availability_zone      = "us-west-2a"
  }
}

### Crawler for the Glue Configutation with the scheduler running everyday at midnight.

##############################
# Glue Crawler Configuration #
##############################

#resource "aws_glue_crawler" "rds_crawler" {
#  name          = "rds-crawler"
#  role          = aws_iam_role.glue_service_role.arn
#  database_name = aws_glue_catalog_database.rds_metadata_database.name

#  jdbc_target {
#    connection_name = aws_glue_connection.mysql_connection.name
#    path            = "images_metadata/image_tags"  # Schema and table path
#  }

  # Optional: Configure crawler schedule (e.g., every 24 hours)
#  schedule = "cron(0 0 * * * *)"  # Optional, run every day at midnight UTC
#}

### Job configuration in AWS Glue. Definition of temporal storage.

#############################
# Glue ETL Job Configuration #
#############################

resource "aws_glue_job" "rds_to_redshift_job" {
  name        = "rds-to-redshift-job"
  role_arn    = aws_iam_role.glue_service_role.arn
  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://stori-thumbnail-thumbnails/glue-scripts/transfer_data.py"
  }

  default_arguments = {
    "--TempDir" = "s3://stori-thumbnail-thumbnails/glue-temp/"
  }

  connections = [aws_glue_connection.mysql_connection.name]
  max_retries = 1
}

### Layers of Pillow and MySQL connector that allows the usage of the librarys using AWS Lambda

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


### Configuration of the Lambda Funcion and definition of enviroment variables to connect with the MySQL Database

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

### Setup of the API Gateway and it's PUT method has a lambda integration to the integration.

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

### CloudWatch allow to review the logs of the processes.

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

### S3 notification that triggers the Lambda Function

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

