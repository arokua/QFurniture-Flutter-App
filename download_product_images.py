#!/usr/bin/env python3
"""
Reads assets/data/products.json (from fetch_woocommerce_products.py) with original
WooCommerce image URLs. Filters test products, downloads main + gallery images once,
dedupes by URL. Paths are formed from SKU (or id): 
  assets/products/{sku_or_id}/image_main_{sku_or_id}.{ext}
  assets/products/{sku_or_id}/gallery/image_gallery-{id}-{sku_or_id}-{i}.{ext}

Categories (Homewares, Children's Furniture, Outdoor Furniture) are for app display only.
Run after fetch: python download_product_images.py
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
ASSETS_DATA = PROJECT_ROOT / "assets" / "data"
ASSETS_PRODUCTS = PROJECT_ROOT / "assets" / "products"
PRODUCTS_JSON = ASSETS_DATA / "products.json"


def sanitize_for_path(s: str) -> str:
    """Safe folder/filename: replace spaces and invalid chars with underscore."""
    s = str(s)
    s = re.sub(r"[^\w\-.]", "_", s)
    return s or "unknown"


def should_skip(product: dict) -> bool:
    name = str(product.get("name") or "").strip().lower()
    sku = str(product.get("sku") or "").strip().lower()
    return name == "test" or sku == "test"


def _category_names(cats) -> list:
    if not cats:
        return []
    out = []
    for c in cats:
        if isinstance(c, str) and c.strip():
            out.append(c.strip())
        elif isinstance(c, dict) and c.get("name"):
            out.append(str(c["name"]).strip())
    return out


def extension_from_url(url: str) -> str:
    path = url.split("?")[0].lower()
    if ".jpg" in path or path.endswith(".jpeg"):
        return "jpg"
    if ".png" in path:
        return "png"
    if ".webp" in path:
        return "webp"
    if ".gif" in path:
        return "gif"
    return "jpg"


def download_once(url: str, out_path: Path, retries: int = 2) -> bool:
    if out_path.exists():
        return True
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; rv:91.0) Gecko/20100101 QFurniture/1.0"}
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=45) as resp:
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_bytes(resp.read())
            return True
        except Exception as e:
            if attempt < retries:
                continue
            print(f"  FAIL {url[:60]}... : {e}", file=sys.stderr)
            return False
    return False


def main():
    if not PRODUCTS_JSON.exists():
        print(f"Not found: {PRODUCTS_JSON}", file=sys.stderr)
        print("Run from project root: python download_product_images.py", file=sys.stderr)
        sys.exit(1)

    raw = json.loads(PRODUCTS_JSON.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        print("products.json is not a list", file=sys.stderr)
        sys.exit(1)

    ASSETS_PRODUCTS.mkdir(parents=True, exist_ok=True)
    seen_urls = {}
    downloaded = 0
    failed = 0

    def to_url(v):
        if not v:
            return None
        if isinstance(v, str):
            return v.strip() or None
        if isinstance(v, dict) and v.get("src"):
            return str(v["src"]).strip() or None
        return None

    out_products = []
    for p in raw:
        if should_skip(p):
            continue

        pid = p.get("id")
        if pid is None:
            continue
        pid = int(pid) if isinstance(pid, str) else pid

        sku_raw = p.get("sku")
        if not sku_raw or not str(sku_raw).strip():
            sku_raw = str(pid)
        sku_safe = sanitize_for_path(sku_raw)

        raw_price = p.get("price") or p.get("regularPrice") or p.get("salePrice")
        try:
            price = float(raw_price) if raw_price is not None else 0.0
        except (TypeError, ValueError):
            price = 0.0

        cats = _category_names(p.get("categories") or [])
        category = ", ".join(cats) if cats else (p.get("category") or "")

        # Paths from SKU (or id): assets/products/{sku_or_id}/ and .../gallery/
        product_dir = ASSETS_PRODUCTS / sku_safe
        gallery_dir = product_dir / "gallery"
        gallery_dir.mkdir(parents=True, exist_ok=True)

        main_url = to_url(p.get("image"))
        raw_subs = p.get("images") or []
        raw_subs = [to_url(u) for u in raw_subs if to_url(u)]

        # If already asset paths (re-run), normalize: strip leading assets/ so we store products/...
        if main_url and not main_url.startswith("http"):
            image_str = main_url.removeprefix("assets/") if main_url.startswith("assets/") else main_url
            asset_paths = [u for u in raw_subs if u and isinstance(u, str)]
            asset_paths = [(u.removeprefix("assets/") if u.startswith("assets/") else u) for u in asset_paths]
            if image_str and image_str not in asset_paths:
                asset_paths = [image_str] + asset_paths
            elif not asset_paths:
                asset_paths = [image_str] if image_str else []
        else:
            image_str = ""
            gallery_paths = []

            # Main image: assets/products/{sku_or_id}/image_main_{sku_or_id}.{ext}
            if main_url and main_url.startswith("http"):
                if main_url in seen_urls:
                    main_path = seen_urls[main_url]
                else:
                    ext = extension_from_url(main_url)
                    filename = f"image_main_{sku_safe}.{ext}"
                    out_path = product_dir / filename
                    if download_once(main_url, out_path):
                        main_path = f"assets/products/{sku_safe}/{filename}"
                        seen_urls[main_url] = main_path
                        downloaded += 1
                    else:
                        main_path = ""
                        failed += 1
                if main_path:
                    image_str = main_path
                    gallery_paths = [main_path]

            # Gallery: assets/products/{sku_or_id}/gallery/image_gallery-{id}-{sku_or_id}-{i}.{ext}
            sub_urls = []
            seen_sub = {main_url} if main_url else set()
            for u in raw_subs:
                u = (u or "").strip() if isinstance(u, str) else None
                if not u or not u.startswith("http") or u in seen_sub:
                    continue
                seen_sub.add(u)
                sub_urls.append(u)

            for i, url in enumerate(sub_urls):
                if url in seen_urls:
                    gallery_paths.append(seen_urls[url])
                    continue
                ext = extension_from_url(url)
                filename = f"image_gallery-{pid}-{sku_safe}-{i}.{ext}"
                out_path = gallery_dir / filename
                if download_once(url, out_path):
                    path = f"products/{sku_safe}/gallery/{filename}"
                    seen_urls[url] = path
                    gallery_paths.append(path)
                    downloaded += 1
                else:
                    failed += 1

            asset_paths = gallery_paths
            if not image_str and asset_paths:
                image_str = asset_paths[0]

        out_products.append({
            "id": pid,
            "name": p.get("name") or "",
            "slug": p.get("slug"),
            "description": p.get("description") or "",
            "shortDescription": p.get("shortDescription") or "",
            "price": price,
            "regularPrice": p.get("regularPrice"),
            "salePrice": p.get("salePrice"),
            "onSale": p.get("onSale", False),
            "currency": p.get("currency") or "AUD",
            "categories": cats,
            "category": category,
            "image": image_str,
            "images": asset_paths,
            "inStock": p.get("inStock", True),
            "stockAmount": p.get("stockAmount"),
            "material": p.get("material"),
            "assemblyRequired": p.get("assemblyRequired", "Yes"),
            "color": p.get("color"),
            "weight": p.get("weight"),
            "dimensions": p.get("dimensions"),
            "age": p.get("age", ""),
            "sku": sku_raw if isinstance(sku_raw, str) else str(sku_raw),
            "variants": p.get("variants", []),
            "modified": p.get("modified"),
        })

    PRODUCTS_JSON.write_text(
        json.dumps(out_products, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"Wrote {len(out_products)} products to {PRODUCTS_JSON}")
    print(f"Downloaded {downloaded} images, {failed} failed.")
    print(f"Images under {ASSETS_PRODUCTS}")


if __name__ == "__main__":
    main()
