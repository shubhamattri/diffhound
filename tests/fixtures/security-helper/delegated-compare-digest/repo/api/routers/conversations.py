import hmac
def _verify_widget_token(conv, token):
    stored = (conv.meta or {}).get("widget_token", "")
    if not hmac.compare_digest(stored, token):
        raise ValueError
