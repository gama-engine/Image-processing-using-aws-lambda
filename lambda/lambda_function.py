import boto3
import urllib.parse
import os
from PIL import Image
from io import BytesIO

s3 = boto3.client("s3")

processed_bucket = os.environ["PROCESSED_BUCKET"]


def lambda_handler(event, context):

    record = event["Records"][0]

    bucket_name = record["s3"]["bucket"]["name"]

    object_key = urllib.parse.unquote_plus(
        record["s3"]["object"]["key"]
    )

    print(f"Processing file: {object_key} from bucket: {bucket_name}")

    # get image
    response = s3.get_object(
        Bucket=bucket_name,
        Key=object_key
    )

    image_data = response["Body"].read()

    # open image with pillow
    image = Image.open(BytesIO(image_data))

    # resize image
    image = image.resize((300, 300))

    # save to tmp
    tmp_path = f"/tmp/{object_key}"

    image.save(tmp_path)

    # upload to processed bucket
    s3.upload_file(
        tmp_path,
        processed_bucket,
        f"processed-{object_key}"
    )

    print("Upload done")

    return {
        "statusCode": 200
    }
