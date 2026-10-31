#!/usr/bin/env python3
"""Writes test/fixtures/cfg_*.json: variants of the live config signed with a THROWAWAY test key
(derived from a fixed string; it signs nothing real). test/fixtures/test_pub.b64 is its public key.
Run:  python3 tool/gen_test_configs.py   (needs `pip install cryptography`)"""
import base64, copy, hashlib, json, os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

here = os.path.dirname(os.path.abspath(__file__))
fx = os.path.join(here, '..', 'test', 'fixtures')
key = Ed25519PrivateKey.from_private_bytes(hashlib.sha256(b'granth-test-config-key').digest())
pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
open(os.path.join(fx, 'test_pub.b64'), 'w').write(base64.b64encode(pub).decode())

def canon(o):
    return json.dumps(o, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()

def sign(c):
    c = copy.deepcopy(c); c.pop('sig', None)
    c['sig'] = base64.b64encode(key.sign(canon(c))).decode()
    return c

def write(name, c, raw_edit=None):
    t = json.dumps(c, ensure_ascii=False)
    if raw_edit: t = raw_edit(t)
    open(os.path.join(fx, f'cfg_{name}.json'), 'w').write(t)

live = json.load(open(os.path.join(fx, 'live_config.json'))); live.pop('sig')

v = copy.deepcopy(live)
v['version'] = 5
for r in v['structure']['religions']:
    if r['id'] == 'kabir': r['icon'] = 'ektara'
    if r['id'] == 'jain': r['icon'] = 'no-such-icon'
    if r['id'] == 'sikh': r['coming_soon'] = 'सिख ग्रंथ जल्द जोड़े जाएँगे'
    if r['id'] == 'christian':
        r['visible'] = False
        r['groups'][0]['icon'] = 'no-such-group-icon'
v['hidden_granth_ids'] = ['7']
v['announcement'] = {'enabled': True, 'text': 'नया संस्करण जल्द आ रहा है', 'id': 'ann1', 'level': 'warn'}
v['endpoints']['ai'] = 'https://ai.example.test'
v['contacts_page'] = {'title': 'हमारे जानकार'}
v['contacts'] = [
    {'id': 'c2', 'name': 'दूसरा', 'role': 'सलाहकार', 'phone': '+919876543210', 'whatsapp': True, 'order': 2, 'visible': True},
    {'id': 'c1', 'name': 'पहला', 'role': '', 'phone': '', 'whatsapp': False, 'order': 1, 'visible': True},
    {'id': 'c3', 'name': 'छिपा', 'role': '', 'phone': '', 'whatsapp': False, 'order': 3, 'visible': False},
    {'id': 'c4', 'name': 'ग़लत नंबर', 'role': '', 'phone': '98 76-54', 'whatsapp': False, 'order': 4, 'visible': True},
    {'id': 'c5', 'name': 'बिना फ़ोन व्हाट्सऐप', 'role': '', 'phone': '', 'whatsapp': True, 'order': 5, 'visible': True},
    {'id': 'c6', 'name': 'x' * 81, 'role': '', 'phone': '', 'whatsapp': False, 'order': 6, 'visible': True},
    {'id': 'c7', 'name': 'अनजान फ़ील्ड', 'role': '', 'phone': '0123456789', 'whatsapp': False, 'order': 7, 'visible': True, 'future': 1},
]
v['brand_new_field'] = {'x': 1}
write('valid', sign(v))
write('bad_sig', sign(v), lambda t: t.replace('नया संस्करण', 'बदला संस्करण'))
o = copy.deepcopy(v); o['min_app'] = 2; write('old_app', sign(o))
l = copy.deepcopy(v); l['version'] = 3; write('lower', sign(l))
s = copy.deepcopy(v); s['schema'] = 2; write('schema2', sign(s))
n = copy.deepcopy(v); n['version'] = 6; n['flags'] = {'ai_enabled': False, 'analytics_enabled': False, 'analytics_sample': 0.5, 'max_hidden_pct': 50}
n['hidden_granth_ids'] = []; n['announcement'] = {'enabled': False, 'text': '', 'id': 'a0', 'level': 'info'}
write('flags_off', sign(n))
w = copy.deepcopy(v); w['version'] = 7; w['endpoints']['ai'] = 'http://insecure.test'; del w['contacts']
write('no_contacts_http_ai', sign(w))
u = copy.deepcopy(v); u['version'] = 8; u['ui'] = {'grid': 1, 'future_key': 1}
u['announcement'] = {'enabled': True, 'text': 'यह सूचना हटाई नहीं जा सकती', 'id': 'pin1', 'level': 'info', 'pinned': True}
write('ui_pinned', sign(u))
b = copy.deepcopy(v); b['version'] = 9; b['ui'] = {'grid': 9}; b['announcement']['pinned'] = 'yes'
write('ui_bad', sign(b))
nosig = copy.deepcopy(v); write('no_sig', nosig)
print('ok')
