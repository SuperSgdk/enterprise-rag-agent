"""Offline checks for configuration, parsing, and splitting; no external calls."""
from pathlib import Path
import pytest
from app.config import Settings
from app.rag.loader import load_document
from app.rag.splitters import SPLITTER_REGISTRY

ROOT = Path(__file__).resolve().parents[1]

@pytest.fixture(autouse=True)
def offline_configuration(monkeypatch):
    monkeypatch.setenv('DASHSCOPE_API_KEY', 'offline-test')
    monkeypatch.setenv('MILVUS_COLLECTION', 'offline_test')
    monkeypatch.setenv('POSTGRES_DSN', 'postgresql+psycopg://rag:test@127.0.0.1:35432/rag')
    monkeypatch.setenv('REDIS_URL', 'redis://127.0.0.1:36379/0')
    monkeypatch.setenv('OCR_ENABLED', 'false')
    from app.config import get_settings
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()

@pytest.mark.parametrize('name,text', [
    ('structured', '项目: 星河\n报销上限: 每晚五百元\n提交期限: 十天'),
    ('semi_structured', '# 差旅制度\n\n住宿上限每晚五百元。\n\n## 报销\n十天内提交。'),
    ('unstructured', '员工出差住宿上限每晚五百元，十天内提交报销。'),
])
def test_splitters_preserve_business_facts(name, text):
    chunks = SPLITTER_REGISTRY[name](text)
    result = '\n'.join(c.content for c in chunks)
    assert '五百元' in result and '十天' in result
    assert [c.chunk_index for c in chunks] == list(range(len(chunks)))
    assert all(c.content.strip() for c in chunks)

@pytest.mark.parametrize('name', SPLITTER_REGISTRY)
def test_splitters_empty_input(name):
    assert SPLITTER_REGISTRY[name]('  \n  ') == []

def test_uploaded_markdown_parser(tmp_path):
    path = tmp_path / 'policy.md'
    path.write_text('# 星河报销\n\n住宿上限每晚五百元。', encoding='utf-8')
    document = load_document(path)
    assert '五百元' in document.full_text
    assert document.sections

def test_configuration_example_can_be_loaded():
    settings = Settings(_env_file=ROOT / 'backend/.env.example')
    assert settings.milvus_dimension == 1536
    assert not settings.ocr_enabled
    assert Path(settings.upload_dir).is_absolute()

def test_private_configuration_is_paired_and_idempotent(tmp_path):
    import runpy
    configure = runpy.run_path(str(ROOT / 'scripts/configure.py'))['main']
    configure.__globals__['ROOT'] = tmp_path
    for folder in ('deploy', 'backend'):
        (tmp_path / folder).mkdir()
        (tmp_path / folder / '.env.example').write_text((ROOT / folder / '.env.example').read_text(), encoding='utf-8')
    configure()
    deploy = (tmp_path / 'deploy/.env').read_text()
    backend = (tmp_path / 'backend/.env').read_text()
    password = deploy.splitlines()[0].split('=', 1)[1]
    assert len(password) >= 32
    assert password in backend and 'CHANGE_ME' not in deploy + backend
    configure()
    assert (tmp_path / 'backend/.env').read_text() == backend
