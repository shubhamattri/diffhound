from routers.conversations import _verify_widget_token
from agent.orchestrator import _compute_email_hash

def stream(token, conv):
    _verify_widget_token(conv, token)
