from fastapi import APIRouter
router = APIRouter()

@router.get("")
def list_conversations():
    return {"conversations": [], "total": 0, "has_more": False}
