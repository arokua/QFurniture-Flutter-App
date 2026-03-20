import requests
import json

res = requests.get("https://qtoys.com.au/wp-json/wc/store/v1/products?per_page=100")
data = res.json()
found_031 = [item for item in data if '031' in str(item.get('sku', '')).lower()]
with open("wc_031.json", "w") as f:
    json.dump(found_031, f, indent=2)
