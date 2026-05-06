#!/bin/bash
# Script de backup de PostgreSQL a S3
DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_FILE="/tmp/db-backup-$DATE.sql"
BUCKET="bucket-integracion-aws-luka-12345"

sudo -u postgres pg_dumpall > "$BACKUP_FILE"

aws s3 cp "$BACKUP_FILE" "s3://$BUCKET/backups/db-backup-$DATE.sql"

rm -f "$BACKUP_FILE"

echo "Backup completado: $DATE"
