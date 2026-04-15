import json
import logging
import os
import re
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
sns = boto3.client('sns')

LANDING_BUCKET = os.environ.get('LANDING_BUCKET')
RAW_BUCKET = os.environ.get('RAW_BUCKET')
RAW_PULS_DATA_TOPIC_ARN = os.environ.get('RAW_PULS_DATA_TOPIC_ARN')

_REQUIRED_ENV_VARS = ['LANDING_BUCKET', 'RAW_BUCKET', 'RAW_PULS_DATA_TOPIC_ARN']


def _validate_env():
    missing = [v for v in _REQUIRED_ENV_VARS if not os.environ.get(v)]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")


def _file_exists_in_raw(dest_key: str) -> bool:
    try:
        s3.head_object(Bucket=RAW_BUCKET, Key=dest_key)
        return True
    except ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        raise


def _process_record(bucket: str, key: str) -> None:
    # Reject events from unexpected buckets (defence against spoofed SNS messages)
    if bucket != LANDING_BUCKET:
        logger.warning(json.dumps({
            "message": "Ignoring event from unexpected bucket",
            "bucket": bucket,
            "expected": LANDING_BUCKET,
        }))
        return

    # Only process files matching puls*.json at the root level (no subdirectories)
    if not re.match(r'^puls[^/]*\.json$', key):
        logger.info(json.dumps({"message": "Skipping non-matching file", "key": key}))
        return

    now = datetime.now()
    dest_key = f"puls_data/{now.strftime('%Y/%m/%d')}/{key}"

    # Idempotency: skip if destination already exists (handles Lambda retries)
    if _file_exists_in_raw(dest_key):
        logger.info(json.dumps({
            "message": "Destination already exists, skipping (idempotent retry)",
            "dest_key": dest_key,
        }))
        return

    logger.info(json.dumps({"message": "Processing file", "key": key, "bucket": bucket}))

    # Copy to raw zone first
    s3.copy_object(
        Bucket=RAW_BUCKET,
        Key=dest_key,
        CopySource={'Bucket': bucket, 'Key': key},
    )
    logger.info(json.dumps({"message": "Copied to raw zone", "dest": f"s3://{RAW_BUCKET}/{dest_key}"}))

    # Only delete from landing zone after a confirmed successful copy
    s3.delete_object(Bucket=bucket, Key=key)
    logger.info(json.dumps({"message": "Deleted from landing zone", "key": key}))

    # Notify downstream
    sns.publish(
        TopicArn=RAW_PULS_DATA_TOPIC_ARN,
        Message=json.dumps({
            "status": "RAW_ZONE_UPLOAD_COMPLETE",
            "source": key,
            "destination": dest_key,
            "bucket": RAW_BUCKET,
            "timestamp": now.isoformat(),
        }),
        Subject="raw_puls_data_notification",
    )
    logger.info(json.dumps({"message": "Published SNS notification", "topic": RAW_PULS_DATA_TOPIC_ARN}))


def lambda_handler(event, context):
    _validate_env()

    for sns_record in event['Records']:
        s3_event = json.loads(sns_record['Sns']['Message'])

        for s3_record in s3_event.get('Records', []):
            bucket = s3_record['s3']['bucket']['name']
            key = s3_record['s3']['object']['key']
            try:
                _process_record(bucket, key)
            except Exception as e:
                logger.error(json.dumps({
                    "message": "Failed to process record",
                    "key": key,
                    "bucket": bucket,
                    "error": str(e),
                }))
                raise

    return {'statusCode': 200, 'body': json.dumps('Processing complete')}
