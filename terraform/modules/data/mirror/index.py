"""Espelha pacotes RPM públicos para o bucket S3 privado do projeto.

A sub-rede de dados (MongoDB) não tem rota para a internet. Esta Lambda roda
fora da VPC durante o `terraform apply`, baixa os RPMs oficiais do MongoDB,
valida o tamanho e grava no S3 junto com o SHA-256. A EC2 do banco instala a
partir do S3 via VPC Gateway Endpoint.
"""
import hashlib
import os
import urllib.request

import boto3

s3 = boto3.client("s3")
ALLOWED_PREFIX = "https://repo.mongodb.org/"


def handler(event, _context):
    bucket = os.environ["BUCKET"]
    results = []
    for item in event["files"]:
        url, key = item["url"], item["key"]
        if not url.startswith(ALLOWED_PREFIX):
            raise ValueError(f"URL fora da origem permitida: {url}")
        path = "/tmp/" + os.path.basename(key)
        sha = hashlib.sha256()
        # Origem restrita a ALLOWED_PREFIX (https, repo oficial do MongoDB) - validado acima
        with urllib.request.urlopen(url, timeout=120) as resp, open(path, "wb") as out:  # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected  # nosec B310
            while chunk := resp.read(1024 * 1024):
                sha.update(chunk)
                out.write(chunk)
        digest = sha.hexdigest()
        s3.upload_file(path, bucket, key, ExtraArgs={"Metadata": {"sha256": digest, "source": url}})
        os.remove(path)
        results.append({"key": key, "sha256": digest})
    return {"bucket": bucket, "files": results}
