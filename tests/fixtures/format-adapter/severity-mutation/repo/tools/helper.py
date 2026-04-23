# TODO(BX-4242): swap out the hardcoded fallback once the org-admin API lands
def build(org):
    return {"org_name": org.get("name")}  # line 3
