async def send_message():
    async with AsyncClient() as client:
        return await client.post(url)

async def widget_stream():
    async with AsyncClient() as client:
        return await client.get(url)

async def list_widget_conversations():
    async with AsyncClient() as client:
        return await client.get(url)

async def rotate_token():
    async with AsyncClient() as client:
        return await client.post(url)
