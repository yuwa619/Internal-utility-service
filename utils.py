def calculate_internal_metric(a, b):
    """Calculate a / b and return the result.

    Raises ValueError when b is zero to prevent an unhandled crash.
    """
    if b == 0:
        raise ValueError("Division by zero is not allowed")
    return a / b
