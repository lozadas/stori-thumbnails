import os
import json
import uuid
import boto3
from PIL import Image
import io
import mysql.connector
import re
import datetime

# Initialize AWS clients
s3 = boto3.client('s3')
rekognition = boto3.client('rekognition')

# Get environment variables
dest_bucket = os.environ['DEST_BUCKET']
rds_host = "terraform-20241020073130298600000001.creug64m4trc.us-west-2.rds.amazonaws.com"
rds_user = "dbadmin"
rds_password = "MySQLPassword123"
rds_db_name = "images_metadata"
rds_port = 3306

# rds_host = os.environ['RDS_ENDPOINT']
# rds_user = os.environ['RDS_USERNAME']
# rds_password = os.environ['RDS_PASSWORD']
# rds_db_name = os.environ['RDS_DB_NAME']
# rds_port = int(os.environ.get('RDS_PORT', 3306))  # Ensure port is an integer

def get_db_connection():
    """Establish a connection to the MySQL database."""
    try:
        conn = mysql.connector.connect(
            host=rds_host,
            user=rds_user,
            password=rds_password,
            database=rds_db_name,
            port=int(rds_port)  # Force port to be an integer
        )
        print("Successfully connected to MySQL!")
        return conn
    except mysql.connector.Error as e:
        print(f"Error connecting to MySQL: {e}")
        raise

def setup_database_and_table():
    """Ensure the MySQL table exists."""
    conn = get_db_connection()
    cursor = conn.cursor()
    create_table_sql = """
        CREATE TABLE IF NOT EXISTS image_tags (
            id VARCHAR(36) PRIMARY KEY,
            image_key VARCHAR(255) NOT NULL,
            tags TEXT,
            thumbnail_url TEXT,
            processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """
    cursor.execute(create_table_sql)
    conn.commit()
    cursor.close()
    conn.close()

def download_image_from_s3(bucket, key):
    """Download the original image from S3."""
    response = s3.get_object(Bucket=bucket, Key=key)
    return response['Body'].read()

def create_thumbnail(image_content):
    """Create a 128x128 thumbnail."""
    img = Image.open(io.BytesIO(image_content))
    img.thumbnail((128, 128))
    buffer = io.BytesIO()
    img.save(buffer, 'JPEG')
    buffer.seek(0)
    return buffer

def analyze_image(image_content):
    """Analyze the image using Rekognition to extract tags."""
    response = rekognition.detect_labels(Image={'Bytes': image_content})
    return [label['Name'] for label in response['Labels']]

def upload_thumbnail_to_s3(thumbnail, source_key):
    """Upload the thumbnail to the destination S3 bucket."""
    thumbnail_key = f"thumbnails/{source_key}"
    s3.put_object(Bucket=dest_bucket, Key=thumbnail_key, Body=thumbnail, ContentType='image/jpeg')
    return f"https://{dest_bucket}.s3.amazonaws.com/{thumbnail_key}"

def insert_metadata_into_mysql(source_key, tags, thumbnail_url, width, height):
    """Insert tags metadata into the MySQL database."""
    conn = get_db_connection()
    cursor = conn.cursor()
    insert_image_tags_sql = """
        INSERT INTO image_tags (image_key, tags, processed_at)
        VALUES (%s, %s, %s);
    """
    insert_image_url_sql = """
        INSERT INTO image_url (image_key, thumbnail_url)
        VALUES (%s, %s);
    """
    insert_image_size_sql = """
        INSERT INTO image_size (image_key, original_width, original_height)
        VALUES (%s, %s, %s);
    """
    for tag in tags:
        cursor.execute(insert_image_tags_sql, (source_key, tag, datetime.datetime.now()))
    cursor.execute(insert_image_url_sql, (source_key, thumbnail_url))
    cursor.execute(insert_image_size_sql, (source_key, width, height))
    conn.commit()
    cursor.close()
    conn.close()

def lambda_handler(event, context):
    """Main Lambda handler function."""
    try:

        # Extract event details
        source_bucket = event['Records'][0]['s3']['bucket']['name']
        source_key = event['Records'][0]['s3']['object']['key']

        # Download the original image from S3
        image_content = download_image_from_s3(source_bucket, source_key)

        # Create a thumbnail
        thumbnail = create_thumbnail(image_content)

        # Analyze the image to extract tags
        tags = analyze_image(image_content)

        # Get the original image dimensions
        img = Image.open(io.BytesIO(image_content))
        width, height = img.size

        # Rename the image key to include the upload datetime and remove spaces or special characters
        upload_datetime = datetime.datetime.now().strftime('%Y%m%d%H%M%S')
        clean_source_key = re.sub(r'\W+', '_', source_key)
        thumbnail_key = f"{upload_datetime}_{clean_source_key}"

        # Upload the thumbnail to S3 and get the URL
        thumbnail_url = upload_thumbnail_to_s3(thumbnail, thumbnail_key)
        
        # Ensure the MySQL table exists
        insert_metadata_into_mysql(source_key, tags, thumbnail_url, width, height)

        print("Creada la tabla")
        # Insert metadata into MySQL
        insert_metadata_into_mysql(source_key, tags, thumbnail_url)

        print("Insertados datos en la tabla")
        

        return {
            'statusCode': 200,
            'body': json.dumps(f"Thumbnail created and metadata stored for {source_key}")
        }

    except Exception as e:
        print(f"Error processing image: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error processing image: {str(e)}")
        }
