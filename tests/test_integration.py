"""Service integration checks. May call metered model APIs."""
import uuid
import httpx
import pytest
import os

pytestmark = [pytest.mark.integration, pytest.mark.skipif(os.environ.get('RUN_INTEGRATION') != '1', reason='Set RUN_INTEGRATION=1 after starting the services')]

@pytest.fixture
def client():
    with httpx.Client(base_url='http://127.0.0.1:5173', timeout=120, trust_env=False) as c:
        yield c

def test_ui_health_and_splitters(client):
    assert client.get('/').status_code == 200
    health = client.get('/health').json()
    assert health['ok']
    assert set(health['services']) == {'postgres','redis','milvus'}
    options = client.get('/api/v1/documents/splitters/options').json()
    assert {item['name'] for item in options} == {'structured','semi_structured','unstructured'}

def test_upload_retrieve_edit_disable_delete(client):
    marker = '星云' + uuid.uuid4().hex[:8]
    content = f'# {marker}报销规则\n\n{marker}项目的上海酒店费用上限为每晚六百元，员工应在出差结束后十天内提交报销。'
    response = client.post('/api/v1/documents/upload', files={'file': ('integration-test.md', content.encode(), 'text/markdown')})
    assert response.status_code == 201, response.text
    doc = response.json()['document']
    doc_id = doc['id']
    try:
        chunks = client.get(f'/api/v1/documents/{doc_id}/chunks').json()
        assert chunks
        chunk = chunks[0]
        def hits():
            r = client.post('/api/v1/retrieval/search', json={'query': f'{marker}住宿报销上限', 'top_k': 10})
            assert r.status_code == 200, r.text
            return [x for x in r.json()['items'] if x['document_id'] == doc_id]
        found = hits()
        assert found and any('vector' in h['retrieval_sources'] for h in found)
        assert any('bm25' in h['retrieval_sources'] for h in found)
        assert client.patch(f"/api/v1/chunks/{chunk['id']}", json={'enabled': False}).status_code == 200
        assert not hits()
        updated = f'{marker}项目住宿报销上限已经调整为每晚七百元。'
        assert client.patch(f"/api/v1/chunks/{chunk['id']}", json={'enabled': True, 'content': updated}).status_code == 200
        assert any('七百元' in h['content'] for h in hits())
    finally:
        assert client.delete(f'/api/v1/documents/{doc_id}').status_code == 204
    assert not hits()


def test_agent_checkpoint_persists_between_processes():
    import os
    from pathlib import Path
    import subprocess
    import sys
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, 'PYTHONPATH': str(root / 'backend')}
    thread = 'persistence-test-' + uuid.uuid4().hex
    write = """
from app.agent.memory import initialize_checkpointer, shutdown_checkpointer
from langgraph.graph import StateGraph
from typing import TypedDict
class State(TypedDict):
    count: int
g = StateGraph(State)
g.add_node('step', lambda s: {'count': s['count'] + 1})
g.set_entry_point('step'); g.set_finish_point('step')
g.compile(checkpointer=initialize_checkpointer()).invoke({'count': 6}, {'configurable': {'thread_id': THREAD}})
shutdown_checkpointer()
"""
    read = """
from app.agent.memory import initialize_checkpointer, shutdown_checkpointer
c = initialize_checkpointer()
item = c.get_tuple({'configurable': {'thread_id': THREAD}})
assert item.checkpoint['channel_values']['count'] == 7
c.delete_thread(THREAD)
shutdown_checkpointer()
"""
    for code in (write, read):
        subprocess.run([sys.executable, '-c', f'THREAD={thread!r}\n' + code], env=env, check=True, capture_output=True)
