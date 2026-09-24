import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def scale(src, size):
    return src.resize((size, size), Image.Resampling.LANCZOS)


def macos_icon(src, size):
    # The legacy macOS appiconset includes its outer transparent canvas.
    # Reserve 3/32 on each side: an 832px tile on the 1024px master canvas.
    canvas_size = 1024
    tile_size = 832
    inset = (canvas_size - tile_size) // 2
    tile = scale(src.convert("RGB"), tile_size).convert("RGBA")
    # Source artwork has a translucent background. Only the rounded outline
    # should carry alpha on macOS, not the tile's coloured interior.
    mask = Image.new("L", (tile_size * 4, tile_size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, mask.width - 1, mask.height - 1),
        radius=mask.width * 0.22,
        fill=255,
    )
    tile.putalpha(scale(mask, tile_size))
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    canvas.alpha_composite(tile, (inset, inset))
    return scale(canvas, size)


def write_macos_icons(src):
    macos = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    master = macos_icon(src, 1024)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        scale(master, size).save(macos / f"app_icon_{size}.png", "PNG")
    print("wrote macOS launcher icons to", macos)

def main():
    parser = argparse.ArgumentParser(description="Export Harbor SSH launcher icons.")
    targets = parser.add_mutually_exclusive_group()
    targets.add_argument("--android-only", action="store_true")
    targets.add_argument("--macos-only", action="store_true")
    args = parser.parse_args()
    source = ROOT / "assets/branding/harbor-ssh-icon.png"
    with Image.open(source) as image:
        master = scale(image.convert("RGBA"), 1024)
        if not args.android_only:
            write_macos_icons(image)
    if args.macos_only:
        return
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
    # Keep the existing Windows icon treatment independent of the macOS canvas.
    mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, 4095, 4095), radius=4096 * 0.22, fill=255
    )
    master.putalpha(ImageChops.multiply(master.getchannel("A"), scale(mask, 1024)))
    ico = ROOT / "windows/runner/resources/app_icon.ico"
    sizes = (16, 24, 32, 48, 64, 128, 256)
    scale(master, 256).save(
        ico,
        sizes=[(s, s) for s in sizes],
    )
    print("wrote", ico)


if __name__ == "__main__":
    main()
