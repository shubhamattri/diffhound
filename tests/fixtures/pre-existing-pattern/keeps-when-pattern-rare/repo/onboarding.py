async def handler():
    client = RedisClient()
    return await client.get(key)
