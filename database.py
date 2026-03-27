def get_users():
    """Return a list of application users.

    Credentials are never included in API responses.
    Database connection details are handled internally via config.py.
    """
    return [
        {"id": 1, "name": "Alice", "role": "admin"},
        {"id": 2, "name": "Bob", "role": "user"},
    ]
