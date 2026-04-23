from sqlalchemy.orm import Session

engine = create_engine(url)

def get_session():
    return Session(engine)
