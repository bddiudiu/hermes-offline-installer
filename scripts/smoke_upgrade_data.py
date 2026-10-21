"""Isolated Windows smoke fixtures; run only against disposable test homes."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import sys

sys.dont_write_bytecode = True
from upgrade_support import tree_inventory

USER_FILES = (
    'USER.md', 'custom-file.txt', 'attachments/fixture.bin',
    'sessions/upgrade-transcript.jsonl', 'skills/upgrade-fixture/SKILL.md',
    'plugins/upgrade-fixture/user-data.bin', 'memories/upgrade-fixture.md',
)
SESSION = 'offline-upgrade-existing-session'
MESSAGE = 'offline-upgrade-existing-message'


def seed(home: Path) -> None:
    import yaml
    from hermes_state import SessionDB
    cfg = yaml.safe_load((home / 'config.yaml').read_text(encoding='utf-8'))
    profile = home / 'profiles/work'
    profile.mkdir(parents=True)
    profile_cfg = json.loads(json.dumps(cfg))
    profile_cfg['model']['default'] = 'profile-upgrade-fixture-model'
    profile_cfg['platforms']['api_server']['enabled'] = False
    (profile / 'config.yaml').write_text(yaml.safe_dump(profile_cfg, sort_keys=False), encoding='utf-8')
    (profile / '.env').write_text('UPGRADE_PROFILE_FIXTURE=preserve-profile-value\n', encoding='utf-8')
    for root in (home, profile):
        for relative in USER_FILES:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('preserve:' + relative + '\n').encode('utf-8'))
        db = SessionDB(db_path=root / 'state.db')
        try:
            db.create_session(SESSION, 'cli', model='upgrade-fixture-model')
            db.append_message(SESSION, 'user', MESSAGE)
        finally:
            db.close()


def verify(home: Path) -> None:
    for root in (home, home / 'profiles/work'):
        for relative in USER_FILES:
            assert (root / relative).read_bytes() == ('preserve:' + relative + '\n').encode('utf-8'), relative
        database = root / 'state.db'
        with sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True) as conn:
            assert conn.execute('PRAGMA quick_check').fetchone() == ('ok',)
            assert conn.execute('SELECT 1 FROM sessions WHERE id=?', (SESSION,)).fetchone()
            assert conn.execute('SELECT 1 FROM messages WHERE session_id=? AND role=? AND content=?',
                                (SESSION, 'user', MESSAGE)).fetchone()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('seed', 'verify', 'inventory', 'unchanged'))
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--install', type=Path)
    parser.add_argument('--inventory', type=Path)
    args = parser.parse_args()
    if args.action == 'seed':
        seed(args.home)
    elif args.action == 'verify':
        verify(args.home)
    else:
        inventory = {'home': tree_inventory(args.home), 'install': tree_inventory(args.install)}
        if args.action == 'inventory':
            args.inventory.write_text(json.dumps(inventory, sort_keys=True), encoding='utf-8')
        else:
            assert inventory == json.loads(args.inventory.read_text(encoding='utf-8')), 'WhatIf modified installed files or home'
    print('PASS: smoke data ' + args.action)


if __name__ == '__main__':
    main()
