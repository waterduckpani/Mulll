"""App Store screenshots: a caption above each screen, at 6.9" (1320x2868).

  flutter drive --driver=test_driver/integration_test.dart \
    --target=integration_test/tour_test.dart -d <iPhone 17 Pro Max> \
    --dart-define=MULL_SAMPLE=true
  python3 tool/store_shots.py

Reads screenshots/ (the tour's output) and writes store/screenshots/. Same
rules as the app: no colour, one focal object, Chillax for words that lead.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "screenshots"
# App Store Connect asks for whichever size it currently treats as required:
# 6.9" (1320x2868) or 6.5" (1284x2778). Both are made; upload the one it wants.
SIZES = {ROOT / "store" / "screenshots": (1320, 2868), ROOT / "store" / "screenshots-6.5": (1284, 2778)}
BG, INK, INK3 = (14, 14, 13), (242, 241, 236), (143, 142, 136)

SHOTS = [
    ("01-home", "Everything you owe,\nin one number."),
    ("12b-one-person", "Owe here, owed there?\nIt nets off."),
    ("02-claim-check", "Paid means confirmed,\nnot assumed."),
    ("03-recurring-due", "Monthly bills ask\nbefore they add."),
    ("05-settle-up", "The fewest payments\nthat clear it."),
    ("08-add-expense", "Split it any way.\nSettle over UPI."),
]

FONT = str(ROOT / "assets/fonts/Chillax-Semibold.otf")


def fitted(draw, text, width):
    """The largest size up to 92 at which every line fits the page's margins."""
    size = 92
    while size > 50:
        font = ImageFont.truetype(FONT, size)
        if draw.multiline_textbbox((0, 0), text, font=font, spacing=26)[2] <= width:
            return font
        size -= 4
    return ImageFont.truetype(FONT, size)


def render(OUT, W, H):
    OUT.mkdir(parents=True, exist_ok=True)
    for i, (name, caption) in enumerate(SHOTS, 1):
        canvas = Image.new("RGB", (W, H), BG)
        draw = ImageDraw.Draw(canvas)
        draw.multiline_text((110, 200), caption, font=fitted(draw, caption, W - 220), fill=INK, spacing=26)

        screen = Image.open(SRC / f"{name}.png").convert("RGB")
        scale = 0.80 if H >= 2868 else 0.78
        sw = int(W * scale)
        sh = int(sw * screen.height / screen.width)
        screen = screen.resize((sw, sh), Image.LANCZOS)
        mask = Image.new("L", (sw, sh), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw, sh), radius=96, fill=255)

        x, y = (W - sw) // 2, int(H * 0.195)
        # Lift, not a border: a soft shadow the way cards float in the app.
        shadow = Image.new("L", (W, H), 0)
        ImageDraw.Draw(shadow).rounded_rectangle((x, y + 24, x + sw, y + sh + 24), radius=96, fill=150)
        shadow = shadow.filter(ImageFilter.GaussianBlur(50))
        canvas.paste(Image.new("RGB", (W, H), (0, 0, 0)), (0, 0), shadow)
        # A hairline edge so a dark screen does not dissolve into a dark page.
        edge = Image.new("L", (sw + 4, sh + 4), 0)
        ImageDraw.Draw(edge).rounded_rectangle((0, 0, sw + 3, sh + 3), radius=98, fill=255)
        canvas.paste(Image.new("RGB", (sw + 4, sh + 4), (44, 44, 42)), (x - 2, y - 2), edge)
        canvas.paste(screen, (x, y), mask)

        out = OUT / f"{i:02d}.png"
        canvas.save(out, optimize=True)
        print(out)


for out, (w, h) in SIZES.items():
    render(out, w, h)
