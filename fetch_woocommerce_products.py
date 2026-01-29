#!/usr/bin/env python3
"""
Fetch products from WooCommerce Store API and save to assets/data/products.json
with original image URLs (images[].src) so download_product_images.py can download them.

API: https://qfurniture.com.au/wp-json/wc/store/v1/products
Fetches by batch (page/per_page). Writes: image = main URL, images = [main, ...gallery] URLs.
"""
import json
import requests
from pathlib import Path

BASE_URL = "https://qfurniture.com.au"
STORE_PRODUCTS_URL = f"{BASE_URL}/wp-json/wc/store/v1/products"

OUT_DIR = Path("assets/data")
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_FILE = OUT_DIR / "products.json"

PER_PAGE = 100


def parse_price(val):
    if val is None:
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def extract_image_urls(p):
    """
    Store API: images = [{ id, src, thumbnail, srcset, sizes, name, alt }].
    Return list of full image URLs (src) for download script.
    """
    urls = []
    for img in p.get("images") or []:
        if isinstance(img, dict) and img.get("src"):
            urls.append(str(img["src"]).strip())
        elif isinstance(img, str) and img.strip():
            urls.append(img.strip())
    if not urls and p.get("featured_src"):
        urls.append(p["featured_src"].strip())
    return urls


def normalize_categories(cats):
    """Store API: categories = [{ id, name, slug, link }]."""
    out = []
    for c in (cats or []):
        if isinstance(c, dict) and c.get("name"):
            out.append(str(c["name"]).strip())
        elif isinstance(c, str) and c.strip():
            out.append(c.strip())
    return out


def _get_attribute(p, name_or_taxonomy):
    """Get first term name from attributes by name or taxonomy (e.g. pa_material)."""
    for attr in p.get("attributes") or []:
        if not isinstance(attr, dict):
            continue
        if attr.get("name") == name_or_taxonomy or attr.get("taxonomy") == name_or_taxonomy:
            terms = attr.get("terms") or []
            if terms and isinstance(terms[0], dict) and terms[0].get("name"):
                return str(terms[0]["name"]).strip()
            if terms and isinstance(terms[0], str):
                return str(terms[0]).strip()
    return None


def _format_dimensions(dim):
    """Format dimensions: string or dict {length, width, height} -> string."""
    if dim is None:
        return None
    if isinstance(dim, str) and dim.strip():
        return dim.strip()
    if isinstance(dim, dict):
        parts = []
        for k in ("length", "width", "height"):
            v = dim.get(k)
            if v is not None and str(v).strip():
                parts.append(str(v).strip())
        if parts:
            return " x ".join(parts)
    return None


def normalize_product(p):
    """Normalize Store API product to our JSON shape; write image URLs for download script."""
    image_urls = extract_image_urls(p)
    main_url = image_urls[0] if image_urls else None
    images_list = image_urls

    categories = normalize_categories(p.get("categories"))
    sku = p.get("sku")

    # Store API: price fields can be at root or under prices (e.g. prices.price as string "48495")
    prices_obj = p.get("prices") or {}
    price = parse_price(p.get("price") or prices_obj.get("price"))
    regular_price = parse_price(p.get("regular_price") or prices_obj.get("regular_price"))
    sale_price = parse_price(p.get("sale_price") or prices_obj.get("sale_price"))

    # Stock: stock_availability.text e.g. "18 in stock", or add_to_cart.maximum
    stock_avail = p.get("stock_availability")
    stock_text = stock_avail.get("text") if isinstance(stock_avail, dict) else None
    stock_amount = stock_text if isinstance(stock_text, str) and stock_text.strip() else None
    if not stock_amount:
        add_cart = p.get("add_to_cart")
        if isinstance(add_cart, dict) and add_cart.get("maximum") is not None:
            mx = add_cart["maximum"]
            stock_amount = f"{mx} in stock"

    # Attributes: Material (pa_material), Assembly Required, Color
    material = _get_attribute(p, "Material") or _get_attribute(p, "pa_material")
    assembly_required = _get_attribute(p, "Assembly Required") or "Yes"
    color = _get_attribute(p, "Color")

    # Weight and dimensions (from API if present)
    weight_val = p.get("weight")
    weight = str(weight_val).strip() if weight_val is not None and str(weight_val).strip() else None
    dimensions = _format_dimensions(p.get("dimensions"))

    return {
        "id": p["id"],
        "slug": p.get("slug"),
        "name": p.get("name") or "",
        "sku": sku or p["id"],

        "description": (p.get("description") or "").strip(),
        "shortDescription": (p.get("short_description") or "").strip(),

        "price": price,
        "regularPrice": regular_price,
        "salePrice": sale_price,
        "onSale": bool(p.get("on_sale", False)),
        "currency": "AUD",

        "categories": categories,

        "image": main_url,
        "images": images_list,

        "inStock": bool(p.get("is_in_stock", True)),
        "stockAmount": stock_amount,
        "material": material,
        "assemblyRequired": assembly_required,
        "color": color,
        "weight": weight,
        "dimensions": dimensions,

        "modified": p.get("date_modified_gmt"),
    }


def fetch_all_products():
    """Fetch all products from Store API in batches (page/per_page)."""
    all_products = []
    page = 1

    while True:
        r = requests.get(
            STORE_PRODUCTS_URL,
            params={"page": page, "per_page": PER_PAGE},
            timeout=30,
        )
        r.raise_for_status()
        batch = r.json()

        if not batch:
            break

        all_products.extend(batch)
        total_pages = int(r.headers.get("X-WP-TotalPages", 1))
        if page >= total_pages:
            break
        page += 1

    return all_products


def main():
    print(f"Fetching products from {STORE_PRODUCTS_URL} ...")
    raw = fetch_all_products()
    print(f"Fetched {len(raw)} products")

    normalized = [normalize_product(p) for p in raw]

    OUT_FILE.write_text(
        json.dumps(normalized, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(f"✓ Saved JSON with image URLs → {OUT_FILE}")
    print("  Run: python download_product_images.py  to download images and update paths.")


if __name__ == "__main__":
    main()
