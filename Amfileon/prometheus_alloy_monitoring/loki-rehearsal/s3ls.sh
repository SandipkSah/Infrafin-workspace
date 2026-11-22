#!/usr/bin/env bash
# lists the rehearsal bucket: chunk objects and index tables
docker run --rm --network loki-rehearsal_loki -e AWS_ACCESS_KEY_ID=rehearsal -e AWS_SECRET_ACCESS_KEY=rehearsal-secret -e AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:2.27.0 --endpoint-url http://minio:9000 s3 ls --recursive s3://loki/ \
  | awk '{print $4}' | awk -F/ '{ if ($1=="index") t["index " $2]++; else t["chunks (tenant " $1 ")"]++ } END { for (k in t) print t[k], k }' | sort -k2
