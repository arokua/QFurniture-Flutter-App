import os
import re
from pathlib import Path

def main():
    root_dir = Path(__file__).resolve().parent
    pubspec_path = root_dir / "pubspec.yaml"
    products_dir = root_dir / "assets" / "products"

    if not pubspec_path.exists():
        print("pubspec.yaml not found.")
        return

    content = pubspec_path.read_text(encoding="utf-8")
    
    # Collect all directories containing files under assets/products
    asset_dirs = set()
    if products_dir.exists():
        for dirpath, dirnames, filenames in os.walk(products_dir):
            if filenames:
                rel_path = Path(dirpath).relative_to(root_dir).as_posix()
                if not rel_path.endswith("/"):
                    rel_path += "/"
                asset_dirs.add(f"    - {rel_path}")

    # Add other required assets
    asset_dirs.add("    - assets/images/")
    asset_dirs.add("    - assets/data/")
    asset_dirs.add("    - assets/data/products.json")
    asset_dirs.add("    - assets/dummy_data.json")

    sorted_assets = sorted(list(asset_dirs))
    assets_block = "\n".join(sorted_assets)

    # find the assets section
    pattern = r'( +assets:\n)(.*?)(?=\n^  [a-zA-Z]|\Z)'
    
    def replacer(match):
        # We need to preserve the "assets:" header and replace the content
        return match.group(1) + assets_block

    new_content = re.sub(pattern, replacer, content, flags=re.MULTILINE|re.DOTALL)
    
    if new_content == content:
        print("No changes made to pubspec.yaml")
    else:
        pubspec_path.write_text(new_content, encoding="utf-8")
        print(f"Updated pubspec.yaml with {len(sorted_assets)} asset entries.")

if __name__ == "__main__":
    main()
