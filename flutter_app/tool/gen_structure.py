#!/usr/bin/env python3
"""Writes assets/structure/structure.json (the religion -> group -> granth map).

Source of truth for the *shape* and the id lists is this file; the app only reads the JSON.
Edit the JSON directly for small changes (see docs/STRUCTURE.md); re-running this script
overwrites it. Titles come from test/fixtures/granths_104.json (id, title, position of the
live API snapshot, 2026-10-24).
"""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def leaf(id, title, icon, ids=(), kw=(), nokw=()):
    d = {'id': id, 'title': title, 'icon': icon, 'granthIds': [str(i) for i in ids]}
    if kw: d['keywords'] = list(kw)
    if nokw: d['notKeywords'] = list(nokw)
    return d


veds = [
    leaf('rigved', 'ऋग्वेद', 'scroll', [44, 45, 46, 47, 62], ['ऋग्वेद']),
    leaf('yajurved', 'यजुर्वेद', 'scroll', [37], ['यजुर्वेद']),
    leaf('samved', 'सामवेद', 'scroll', [48], ['सामवेद']),
    leaf('atharvved', 'अथर्ववेद', 'scroll', [49, 92], ['अथर्ववेद']),
    leaf('sukshmved', 'सूक्ष्मवेद', 'scroll', [], ['सूक्ष्मवेद', 'सूक्ष्म वेद']),
]
shastras = [
    leaf('nyay', 'न्याय', 'books', [], ['न्याय दर्शन', 'न्यायदर्शन']),
    leaf('vaisheshik', 'वैशेषिक', 'books', [], ['वैशेषिक']),
    leaf('sankhya', 'सांख्य', 'books', [], ['सांख्य दर्शन', 'सांख्यदर्शन', 'सांख्य कारिका']),
    leaf('yog', 'योग', 'books', [], ['योग दर्शन', 'योगदर्शन', 'योगसूत्र', 'योग सूत्र']),
    leaf('mimansa', 'मीमांसा', 'books', [], ['मीमांसा']),
    leaf('vedant', 'वेदांत', 'books', [], ['वेदांत दर्शन', 'वेदान्त दर्शन', 'ब्रह्मसूत्र', 'ब्रह्म सूत्र']),
]

hindu_groups = [
    {'id': 'ved', 'title': 'वेद', 'icon': 'scroll', 'subgroups': veds},
    leaf('geeta', 'गीता', 'book-red', [4, 76], ['श्रीमद्भगवत गीता', 'श्रीमद्भगवद्गीता', 'श्रीमद्भगवद् गीता', 'भगवद्गीता', 'भगवद गीता', 'गर्भ गीता']),
    leaf('puran', 'पुराण', 'book-green',
         [8, 9, 10, 11, 12, 13, 14, 15, 16, 19, 20, 21, 22, 23, 24, 25, 26, 30, 31, 32, 33, 34, 35, 38, 41, 57, 58, 66, 78, 79, 84, 85, 90, 103, 104, 106, 107],
         ['पुराण', 'देवीभागवत'], ['मालिक']),
    leaf('upanishad', 'उपनिषद', 'book-blue', [80], ['उपनिषद']),
    leaf('ramayan', 'रामायण', 'book-orange', [17, 42, 43, 56, 87, 96], ['रामायण', 'रामचरितमानस'], ['घट रामायण']),
    leaf('mahabharat', 'महाभारत', 'swords', [27, 29, 64, 108], ['महाभारत']),
    leaf('manusmriti', 'मनुस्मृति', 'scroll', [40], ['मनुस्मृति']),
    {'id': 'shastra', 'title': '6 शास्त्र', 'icon': 'books', 'subgroups': shastras},
]

religions = [
    {'id': 'hindu', 'title': 'हिन्दू', 'tone': 'saffron', 'icon': 'folder-open', 'groups': hindu_groups},
    {'id': 'islam', 'title': 'इस्लाम', 'tone': 'maroon', 'icon': 'folder-open', 'groups': [
        leaf('quran', 'क़ुरान', 'quran', [60], ['कुरआन', 'कुरान', 'क़ुरआन', 'क़ुरान', 'कुर्आन', 'कुर्आन शरीफ']),
        leaf('hadees', 'हदीस', 'hadees', [], ['हदीस', 'हदीथ', 'हदीष']),
    ]},
    {'id': 'sikh', 'title': 'सिख', 'tone': 'gold', 'icon': 'folder-open', 'groups': [
        leaf('guru-granth', 'गुरु ग्रंथ साहिब', 'granth-sahib', [52, 53],
             ['गुरु ग्रन्थ साहिब', 'गुरु ग्रंथ साहिब', 'गुरुग्रंथ साहिब', 'गुरुग्रन्थ साहिब']),
        leaf('dasam', 'दसम ग्रंथ', 'dasam', [], ['दसम ग्रंथ', 'दसम ग्रन्थ', 'दशम ग्रंथ', 'दशम ग्रन्थ']),
    ]},
    {'id': 'christian', 'title': 'ईसाई', 'tone': 'saffron', 'icon': 'folder-open', 'groups': [
        leaf('bible', 'बाइबल', 'bible', [61], ['बाइबल', 'बाईबल', 'बाइबिल', 'बाईबिल']),
    ]},
    {'id': 'buddh', 'title': 'बुद्ध', 'tone': 'maroon', 'icon': 'folder-open', 'groups': [
        leaf('tripitak', 'त्रिपिटक', 'tripitak', [], ['त्रिपिटक']),
        leaf('dhammapad', 'धम्मपद', 'dhammapad', [], ['धम्मपद']),
    ]},
    {'id': 'kabir', 'title': 'कबीर', 'tone': 'gold', 'icon': 'folder-open', 'groups': [
        leaf('kabir-sagar', 'कबीर सागर', 'kabir-sagar', [7, 102], ['कबीर सागर', 'अनुराग सागर']),
        leaf('bijak', 'बीजक', 'bijak', [73], ['बीजक']),
        leaf('shabdavali', 'शब्दावली', 'shabdavali', [39], ['कबीरपंथी शब्दावली', 'कबीर शब्दावली']),
    ]},
]

# Granths that sit in अन्य on purpose (their title would otherwise match a keyword, or they
# are Hindu/other texts with no group). Every other id not listed anywhere is अन्य too.
other_ids = [
    18, 36, 50, 51, 54, 55, 59, 63, 65, 67, 68, 69, 70, 71, 72, 74, 75, 77, 81, 82, 83, 86, 88, 89,
    91, 93, 94, 95, 97, 98, 99, 100, 101, 105, 109, 110,
]

doc = {
    'version': 1,
    'note': 'religion -> group -> API granth ids. Order of a granth inside a group = its API position. '
            'A granth in no list is matched by title keywords (exactly one group), else it goes to अन्य. '
            'Edit and re-test: see docs/STRUCTURE.md.',
    'religions': religions,
    'other': {'id': 'other', 'title': 'अन्य', 'icon': 'misc', 'tone': 'gold', 'forceIds': [str(i) for i in other_ids]},
}
out = os.path.join(root, 'assets/structure/structure.json')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=1)
    f.write('\n')
print('wrote', out)
