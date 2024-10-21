import sys
from awsglue.transforms import *
from awsglue.context import GlueContext
from pyspark.context import SparkContext
from awsglue.dynamicframe import DynamicFrame

glueContext = GlueContext(SparkContext.getOrCreate())

# Load data from RDS MySQL
rds_dynamic_frame = glueContext.create_dynamic_frame.from_catalog(
    database="rds_metadata", 
    table_name="images_metadata"
)

# Write data to Redshift
redshift_options = {
    "url": "jdbc:redshift://image-tags-cluster.xxxxxx.redshift.amazonaws.com:5439/dev",
    "user": "admin",
    "password": "RedshiftPassword123",
    "dbtable": "public.image_metadata"
}

glueContext.write_dynamic_frame.from_jdbc_conf(
    frame=rds_dynamic_frame,
    catalog_connection="redshift-connection",
    connection_options=redshift_options
)
