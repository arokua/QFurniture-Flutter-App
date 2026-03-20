import json
with open('assets/data/products.json', encoding='utf-8') as f:
    data = json.load(f)
    found = [p for p in data if '031' in str(p.get('sku'))]
    for p in found:
        print(f"SKU: {p.get('sku')}, Name: {p.get('name')}, stockAmount: {p.get('stockAmount')}, inStock: {p.get('inStock')}")
