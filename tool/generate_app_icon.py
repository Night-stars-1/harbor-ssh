import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def scale(src, size):
    return src.resize((size, size), Image.Resampling.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description="Export Harbor SSH launcher icons.")
    parser.add_argument("--android-only", action="store_true")
    args = parser.parse_args()
    source = ROOT / "assets/branding/harbor-ssh-icon.png"
    with Image.open(source) as image:
        master = scale(image.convert("RGBA"), 1024)
    android = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android.items():
        path = ROOT / "android/app/src/main/res" / folder / "ic_launcher.png"
        scale(master, size).save(path, "PNG")
    print("wrote Android launcher icons from", source)
    if args.android_only:
        return
    # Desktop shells draw the bare asset outline instead of masking it like Android,
    # so cut the corners here (0.22 matches the Android/iOS launcher squircle).
    mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, 4095, 4095), radius=4096 * 0.22, fill=255
    )
    master.putalpha(ImageChops.multiply(master.getchannel("A"), scale(mask, 1024)))
    macos = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        scale(master, size).save(macos / f"app_icon_{size}.png", "PNG")
    ico = ROOT / "windows/runner/resources/app_icon.ico"
    sizes = (16, 24, 32, 48, 64, 128, 256)
    scale(master, 256).save(
        ico,
        sizes=[(s, s) for s in sizes],
    )
    print("wrote", ico)


if __name__ == "__main__":
    main()
