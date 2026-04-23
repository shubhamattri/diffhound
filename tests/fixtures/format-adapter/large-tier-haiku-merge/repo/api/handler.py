import hmac

def verify_token(token, expected):
    return hmac.compare_digest(token, expected)

def process_request(data):
    return {"result": data.get("value")}
