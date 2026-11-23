"""Developer tool: explore the (unofficial) Alexa GraphQL API.

Not used by the app. It was used to discover the `airQualityHistory` query.

    .venv/bin/python tools/explore.py introspect          # list query fields
    .venv/bin/python tools/explore.py gql '<query>' '{json variables}'
    .venv/bin/python tools/explore.py get /api/path ...

Uses the login stored by `probe.py` (run that first).
"""

import asyncio
import json
import sys

from alexapy import AlexaAPI

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent.parent))
import probe  # noqa: E402

OUT = probe.OUT


async def gql(login, query, variables=None):
    data = {"query": query}
    if variables:
        data["variables"] = variables
    resp = await AlexaAPI._static_request("post", login, "/nexus/v1/graphql", data=data)
    try:
        return await resp.json(content_type=None)
    except Exception:
        return {"_status": resp.status, "_text": (await resp.text())[:2000]}


async def get(login, path):
    resp = await AlexaAPI._static_request("get", login, path)
    try:
        body = await resp.json(content_type=None)
    except Exception:
        body = (await resp.text())[:1000]
    return resp.status, body


async def main():
    login = await probe.get_login("amazon.de")
    try:
        mode = sys.argv[1] if len(sys.argv) > 1 else "introspect"
        if mode == "introspect":
            r = await gql(login, "{ __schema { queryType { fields { name args { name } } } } }")
            (OUT / "gql_schema_query.json").write_text(json.dumps(r, indent=1))
            print(json.dumps(r)[:3000])
        elif mode == "gql":
            r = await gql(login, sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
            print(json.dumps(r, indent=1)[:6000])
        elif mode == "get":
            for path in sys.argv[2:]:
                st, body = await get(login, path)
                print(path, st, json.dumps(body)[:1500] if not isinstance(body, str) else body[:500])
    finally:
        await login.close()


if __name__ == "__main__":
    asyncio.run(main())
