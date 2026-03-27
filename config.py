import os
import json


def get_secret(secret_name):
    """Fetch a secret from AWS Secrets Manager.

    Falls back to an empty dict if boto3 is unavailable or the call fails.
    This allows the app to work locally using plain environment variables.
    """
    try:
        import boto3
        from botocore.exceptions import ClientError

        region = os.environ.get("AWS_REGION", "us-east-1")
        client = boto3.client("secretsmanager", region_name=region)
        response = client.get_secret_value(SecretId=secret_name)
        return json.loads(response["SecretString"])
    except Exception:
        return {}


def _load_config():
    """Load configuration from AWS Secrets Manager or environment variables.

    Priority:
    1. AWS Secrets Manager (when AWS_SECRETS_MANAGER_SECRET_NAME is set)
    2. Environment variables (local dev / CI)
    """
    secret_name = os.environ.get("AWS_SECRETS_MANAGER_SECRET_NAME")
    secrets = get_secret(secret_name) if secret_name else {}

    return {
        "DB_HOST": secrets.get(
            "DB_HOST", os.environ.get("DB_HOST", "localhost")
        ),
        "DB_USER": secrets.get(
            "DB_USER", os.environ.get("DB_USER", "")
        ),
        "DB_PASSWORD": secrets.get(
            "DB_PASSWORD", os.environ.get("DB_PASSWORD", "")
        ),
        "DB_NAME": secrets.get(
            "DB_NAME", os.environ.get("DB_NAME", "internal_db")
        ),
        "ENVIRONMENT": os.environ.get("ENVIRONMENT", "production"),
    }


_config = _load_config()

DB_HOST = _config["DB_HOST"]
DB_USER = _config["DB_USER"]
DB_PASSWORD = _config["DB_PASSWORD"]
DB_NAME = _config["DB_NAME"]
ENVIRONMENT = _config["ENVIRONMENT"]
