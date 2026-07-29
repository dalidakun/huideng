import os
import json

def generate_sutras(base_path):
    sutras = []
    for root, dirs, files in os.walk(base_path):
        for file in files:
            if file.endswith('.txt'):
                full_path = os.path.join(root, file)
                relative_path = os.path.relpath(full_path, base_path)
                folder = os.path.dirname(relative_path).replace('\\', '/')
                size = os.path.getsize(full_path)
                size_str = f'{size}B' if size < 1024 else f'{(size / 1024):.1f}k' if size < 1024*1024 else f'{(size / (1024*1024)):.1f}M'
                sutras.append({
                    'title': file.replace('.txt', ''),
                    'size': size_str,
                    'filePath': f'assets/sutras/{relative_path}'.replace('\\', '/'),
                    'folder': folder if folder else None
                })
    return sutras

if __name__ == '__main__':
    base = 'assets/sutras'
    sutras = generate_sutras(base)
    with open('sutras.json', 'w', encoding='utf-8') as f:
        json.dump(sutras, f, ensure_ascii=False, indent=2)
    print('Generated sutras.json')