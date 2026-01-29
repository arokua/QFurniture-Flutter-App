# WooCommerce Product Fetcher

This Python script fetches products from your WooCommerce store and downloads all product images to the `assets/images/` folder, renaming them according to product SKU and ID.

## Setup

1. **Install Python dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

2. **Configure WooCommerce API credentials:**
   - Open `fetch_woocommerce_products.py`
   - Update the configuration at the top of the file:
     ```python
     WOOCOMMERCE_URL = "https://your-store.com"
     CONSUMER_KEY = "ck_your_consumer_key"
     CONSUMER_SECRET = "cs_your_consumer_secret"
     ```

3. **Get WooCommerce API credentials:**
   - Go to your WooCommerce admin panel
   - Navigate to: **WooCommerce → Settings → Advanced → REST API**
   - Click **Add Key**
   - Set permissions to **Read**
   - Copy the **Consumer Key** and **Consumer Secret**

## Usage

Run the script:
```bash
python fetch_woocommerce_products.py
```

## What it does

1. **Fetches all products** from your WooCommerce store via REST API
2. **Downloads all product images** to `assets/images/`
3. **Renames images** using format: `{SKU}_{ID}.{ext}` or `product_{ID}.{ext}` if no SKU
4. **Generates `products.json`** in `assets/data/` with all product information formatted for the Flutter app

## Image Naming Convention

- Main image: `{SKU}_{ID}.jpg` (e.g., `CHAIR-001_123.jpg`)
- Additional images: `{SKU}_{ID}_1.jpg`, `{SKU}_{ID}_2.jpg`, etc.
- If no SKU: `product_{ID}.jpg`

## Output

- **Images**: `assets/images/` folder
- **Product Data**: `assets/data/products.json`

The generated JSON file is automatically compatible with the Flutter app's product model.

## Notes

- The script includes rate limiting to avoid overwhelming the server
- Images are cached locally, so re-running will re-download all images
- Only published products are fetched
- The script handles variable products and product attributes
