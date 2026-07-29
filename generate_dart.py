import json

with open('sutras.json', 'r', encoding='utf-8') as f:
    sutras = json.load(f)

code = 'final List<Sutra> _defaultSutras = [\n'
for s in sutras:
    title = s['title'].replace("'", "\\'")
    size = s['size']
    filePath = s['filePath'].replace("'", "\\'")
    folder = s['folder']
    code += f"  Sutra('{title}', '{size}', filePath: '{filePath}', folder: '{folder}'),\n"
code += '];\n'

with open('default_sutras.dart', 'w', encoding='utf-8') as f:
    f.write(code)

print('Generated default_sutras.dart')