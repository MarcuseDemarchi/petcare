"""Cria/remove buckets S3 em nome do Terraform (aws_lambda_invocation CRUD).

Motivo: no AWS Academy Learner Lab uma SCP nega s3:GetBucketObjectLockConfiguration,
chamada que o recurso aws_s3_bucket do provider Terraform sempre faz ao ler o bucket.
Esta função cria o bucket (sem object lock) e, no destroy, esvazia todas as versões
antes de removê-lo (equivalente a force_destroy). As demais configurações do bucket
(criptografia, versionamento, políticas, ciclo de vida) continuam em recursos Terraform.
"""
import os

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
REGION = os.environ["AWS_REGION"]


def _exists(name):
    try:
        s3.head_bucket(Bucket=name)
        return True
    except ClientError as err:
        if err.response["Error"]["Code"] in ("404", "NoSuchBucket", "NotFound"):
            return False
        raise


def _create(name):
    if _exists(name):
        return
    kwargs = {"Bucket": name, "ObjectOwnership": "BucketOwnerEnforced"}
    if REGION != "us-east-1":
        kwargs["CreateBucketConfiguration"] = {"LocationConstraint": REGION}
    s3.create_bucket(**kwargs)
    s3.get_waiter("bucket_exists").wait(Bucket=name)


def _empty_and_delete(name):
    if not _exists(name):
        return
    paginator = s3.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=name):
        objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
                for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
        for i in range(0, len(objs), 1000):
            s3.delete_objects(Bucket=name, Delete={"Objects": objs[i:i + 1000], "Quiet": True})
    for up in s3.list_multipart_uploads(Bucket=name).get("Uploads", []):
        s3.abort_multipart_upload(Bucket=name, Key=up["Key"], UploadId=up["UploadId"])
    s3.delete_bucket(Bucket=name)


def handler(event, _context):
    action = event.get("tf", {}).get("action", "create")
    name = event["bucket"]
    if action == "delete":
        _empty_and_delete(name)
    else:
        _create(name)
    return {"bucket": name, "action": action}
