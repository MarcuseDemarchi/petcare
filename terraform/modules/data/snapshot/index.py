"""Backup do MongoDB: snapshot diário do volume EBS de dados + retenção.

Substitui o Amazon Data Lifecycle Manager (DLM), bloqueado no Learner Lab.
Acionada pelo EventBridge (agenda diária) e uma vez no terraform apply.
"""
import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
VOLUME_ID = os.environ["VOLUME_ID"]
RETENTION = int(os.environ.get("RETENTION", "7"))
TAG = {"Key": "CreatedBy", "Value": os.environ.get("PROJECT", "petcare-cloud") + "-backup"}


def handler(_event, _context):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%MZ")
    snap = ec2.create_snapshot(
        VolumeId=VOLUME_ID,
        Description=f"Backup MongoDB {now}",
        TagSpecifications=[{"ResourceType": "snapshot", "Tags": [
            TAG, {"Key": "Name", "Value": f"mongo-backup-{now}"}]}],
    )
    snaps = ec2.describe_snapshots(
        OwnerIds=["self"],
        Filters=[{"Name": "volume-id", "Values": [VOLUME_ID]},
                 {"Name": f"tag:{TAG['Key']}", "Values": [TAG["Value"]]}],
    )["Snapshots"]
    snaps.sort(key=lambda s: s["StartTime"], reverse=True)
    removed = []
    for old in snaps[RETENTION:]:
        ec2.delete_snapshot(SnapshotId=old["SnapshotId"])
        removed.append(old["SnapshotId"])
    return {"created": snap["SnapshotId"], "removed": removed, "kept": min(len(snaps), RETENTION)}
