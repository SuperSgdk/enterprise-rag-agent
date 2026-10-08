"""Create private configuration with paired random passwords; never print secrets."""
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parents[1]

def main():
    deploy = ROOT / 'deploy/.env'
    backend = ROOT / 'backend/.env'
    if deploy.exists() != backend.exists():
        raise SystemExit('Only one configuration exists. Complete the pair manually; existing files were preserved.')
    if deploy.exists():
        print('Existing configuration preserved.')
        return
    password = secrets.token_hex(24)
    minio_password = secrets.token_hex(24)
    deploy.write_text((ROOT / 'deploy/.env.example').read_text().replace('CHANGE_ME_DB_PASSWORD', password).replace('CHANGE_ME_MINIO_PASSWORD', minio_password), encoding='utf-8')
    backend.write_text((ROOT / 'backend/.env.example').read_text().replace('CHANGE_ME_DB_PASSWORD', password), encoding='utf-8')
    print('Configuration created. Fill DASHSCOPE_API_KEY in backend/.env.')

if __name__ == '__main__':
    main()
