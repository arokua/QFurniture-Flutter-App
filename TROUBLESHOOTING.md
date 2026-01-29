# Troubleshooting

## Flutter Web: Product images 404 ("assets/assets/products/...")

Flutter Web builds the asset URL as `base + "assets/" + key`. If the key is `assets/products/...`, the request becomes `assets/assets/products/...` and returns 404.

The app uses `assetKeyForImage()` so that on web the key is `products/...` (no leading `assets/`). For that to work, the asset bundle must have keys `products/...`. The pubspec includes `products/XXX/` entries; you need a **root `products` folder** that points to `assets/products`:

- **Windows** (run from project root; Admin or Developer Mode):
  ```cmd
  mklink /D products assets\products
  ```
- **macOS / Linux**:
  ```bash
  ln -s assets/products products
  ```

Then run `flutter pub get` and rebuild. Product images should load on web.

## Flutter Web: LegacyJavaScriptObject / Iterable&lt;PointerEvent&gt; error

If you see repeated console errors like:

```
TypeError: Instance of 'LegacyJavaScriptObject': type 'LegacyJavaScriptObject' is not a subtype of type 'Iterable<PointerEvent>'
```

this is a known Flutter web issue in **debug mode**: the development compiler (DDC) can pass browser pointer events in a way that triggers this type error. The app may still work, but the console will flood with errors.

### Workarounds

1. **Run web in release mode** (recommended when testing on Chrome):
   ```bash
   flutter run -d chrome --release
   ```
   Release mode uses a different compiler and typically does not show this error.

2. **Build and serve** (for production-like testing):
   ```bash
   flutter build web
   # Then serve build/web with any static server, e.g.:
   cd build/web && python -m http.server 8080
   ```

3. **Try WebAssembly** (if your Flutter version supports it):
   ```bash
   flutter run -d chrome --wasm
   ```

4. **Upgrade Flutter** to the latest stable; this class of JS interop issues is often fixed in newer SDKs:
   ```bash
   flutter upgrade
   ```
