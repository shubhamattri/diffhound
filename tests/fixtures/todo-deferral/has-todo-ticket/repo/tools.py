# line 1
# line 2
# TODO(BX-XXXX): fetch user's home org via admin API once monorepo exposes it
def build_wm(org):
    return {
        "viewed_org_name": org.get("name"),
        "viewed_org_id": org.get("id"),
    }
