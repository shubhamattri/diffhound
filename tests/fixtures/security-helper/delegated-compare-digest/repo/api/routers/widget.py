from routers.conversations import _verify_widget_token
def stream(token, conv):
    _verify_widget_token(conv, token)
