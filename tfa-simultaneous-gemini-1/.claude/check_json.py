import json, sys
path = 'C:/Users/Nolan/OneDrive/Documents/Things-Fall-Apart/tfa-simultaneous-gemini-1/data/Dialogues.json'
text = open(path, encoding='utf-8').read()
out = []
in_str = False
esc = False
for ch in text:
    if esc:
        out.append(ch); esc = False; continue
    if ch == '\\':
        out.append(ch); esc = True; continue
    if ch == '"':
        in_str = not in_str
        out.append(ch); continue
    if in_str and ch in ('\n', '\r', '\t'):
        out.append(' '); continue
    out.append(ch)
text2 = ''.join(out)
try:
    json.loads(text2)
    print('Dialogues lenient-parse OK')
except json.JSONDecodeError as e:
    line = text2.splitlines()[e.lineno-1] if e.lineno-1 < len(text2.splitlines()) else ''
    print('FAIL', e)
    print('Context:', repr(line[max(0,e.colno-30):e.colno+30]))
