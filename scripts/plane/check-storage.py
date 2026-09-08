#!/usr/bin/env python3
"""Exercise Plane's presigned POST/GET protocol against its private Garage bucket.

Run inside the API pod, which already has boto3 and the storage environment.
Only creates and deletes one uniquely named object. Never logs signed URLs.
"""
import os
import urllib.error
import urllib.request
import uuid

import boto3
from botocore.config import Config

origin = 'https://plane.internal.prakash.com.br'
bucket = os.environ['AWS_S3_BUCKET_NAME']
key = '_plane-smoke/' + uuid.uuid4().hex + '.txt'
payload = b'Plane Garage presigned upload verification\n'
s3 = boto3.client('s3', endpoint_url=os.environ['AWS_S3_ENDPOINT_URL'],
                  region_name=os.environ['AWS_REGION'], config=Config(signature_version='s3v4'))
cleanup_client = boto3.client('s3', region_name=os.environ['AWS_REGION'])
assert cleanup_client.meta.endpoint_url == os.environ['AWS_S3_ENDPOINT_URL'], 'Export cleanup targets the wrong S3 endpoint'
post = s3.generate_presigned_post(
    Bucket=bucket, Key=key, Fields={'Content-Type': 'text/plain', 'key': key},
    Conditions=[{'bucket': bucket}, ['content-length-range', 1, 10485760],
                {'Content-Type': 'text/plain'}, {'key': key}], ExpiresIn=60,
)
boundary = 'plane-' + uuid.uuid4().hex
parts = []
for name, value in post['fields'].items():
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="check.txt"\r\nContent-Type: text/plain\r\n\r\n'.encode() + payload + b'\r\n')
parts.append(f'--{boundary}--\r\n'.encode())
try:
    preflight = urllib.request.Request(post['url'], method='OPTIONS', headers={
        'Origin': origin, 'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'content-type',
    })
    with urllib.request.urlopen(preflight, timeout=20) as response:
        assert response.headers.get('Access-Control-Allow-Origin') == origin, 'CORS origin mismatch'
    request = urllib.request.Request(post['url'], data=b''.join(parts), headers={
        'Content-Type': 'multipart/form-data; boundary=' + boundary, 'Origin': origin,
    })
    with urllib.request.urlopen(request, timeout=20) as response:
        assert response.status in (200, 201, 204), 'POST failed'
        assert response.headers.get('Access-Control-Allow-Origin') == origin, 'POST CORS header missing'
    # Match Plane's download Content-Disposition parameter too.
    download = s3.generate_presigned_url('get_object', Params={
        'Bucket': bucket, 'Key': key, 'ResponseContentDisposition': "inline; filename*=UTF-8''check.txt",
    }, ExpiresIn=60)
    with urllib.request.urlopen(download, timeout=20) as response:
        assert response.read() == payload, 'Downloaded bytes differ'
    unsigned = os.environ['AWS_S3_ENDPOINT_URL'].rstrip('/') + '/' + bucket + '/' + key
    try:
        urllib.request.urlopen(unsigned, timeout=20)
    except urllib.error.HTTPError as error:
        assert error.code == 403, 'Unexpected unauthenticated response'
    else:
        raise AssertionError('Bucket permits unauthenticated object reads')
    print('PASS: browser CORS, presigned POST, presigned GET, byte integrity and private bucket.')
finally:
    s3.delete_object(Bucket=bucket, Key=key)
