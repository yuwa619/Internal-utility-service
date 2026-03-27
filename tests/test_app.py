"""
Test suite for the Internal Utility Service.

All tests run against the Flask test client — no real database or AWS calls
are made. Environment variables are set before importing the application so
that config.py reads from them rather than attempting AWS Secrets Manager.

9 tests total (8 core + 1 additional: test_calculate_metric_division_by_zero).
"""
import os

import pytest

# Set environment variables before importing the application modules so that
# config._load_config() reads these values instead of calling AWS SM.
os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("DB_HOST", "localhost")
os.environ.setdefault("DB_USER", "testuser")
os.environ.setdefault("DB_PASSWORD", "testpassword")
os.environ.setdefault("DB_NAME", "test_db")

from app import app  # noqa: E402  (import after env setup is intentional)


@pytest.fixture
def client():
    """Provide a Flask test client with TESTING mode enabled."""
    app.config["TESTING"] = True
    with app.test_client() as test_client:
        yield test_client


# ---------------------------------------------------------------------------
# Home endpoint
# ---------------------------------------------------------------------------

def test_home_returns_200(client):
    """GET / must respond with HTTP 200."""
    response = client.get("/")
    assert response.status_code == 200


def test_home_message(client):
    """GET / must include the expected service message."""
    response = client.get("/")
    data = response.get_json()
    assert data["message"] == "Internal Utility Service Running"


def test_home_no_db_host_leak(client):
    """GET / must not expose the database host in the response."""
    response = client.get("/")
    data = response.get_json()
    assert "db_host" not in data


# ---------------------------------------------------------------------------
# Users endpoint
# ---------------------------------------------------------------------------

def test_users_returns_200(client):
    """GET /users must respond with HTTP 200."""
    response = client.get("/users")
    assert response.status_code == 200


def test_users_returns_list(client):
    """GET /users must return a JSON array."""
    response = client.get("/users")
    data = response.get_json()
    assert isinstance(data, list)


def test_users_no_credentials_leaked(client):
    """GET /users must not expose db_user or db_password in any user object."""
    response = client.get("/users")
    data = response.get_json()
    for user in data:
        assert "db_user" not in user, "db_user leaked in /users response"
        assert "db_password" not in user, "db_password leaked in /users response"


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------

def test_health_endpoint(client):
    """GET /health must respond with HTTP 200 and status healthy."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "healthy"


# ---------------------------------------------------------------------------
# Utils
# ---------------------------------------------------------------------------

def test_calculate_metric_normal():
    """calculate_internal_metric must return the correct quotient."""
    from utils import calculate_internal_metric
    assert calculate_internal_metric(10, 2) == 5.0


# ---------------------------------------------------------------------------
# Additional test (requirement: add one beyond the original 8)
# ---------------------------------------------------------------------------

def test_calculate_metric_division_by_zero():
    """calculate_internal_metric must raise ValueError when b == 0."""
    from utils import calculate_internal_metric
    with pytest.raises(ValueError):
        calculate_internal_metric(10, 0)
