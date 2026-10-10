#!/usr/bin/env python3
"""
Gera tx.iconset (ícone macOS) com visual de menu-bar app:
fundo azul escuro, waveform animada estilizada e texto "tx" em mono.
"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

def make_icon(size: int) -> Image.Image:
    pad = size * 0.12
    bar_count = 13
    gap_ratio = 0.35

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Fundo com cantos arredondados
    radius = size * 0.225
    bg_color = (18, 24, 44, 255)
    rounded_rect(draw, 0, 0, size, size, radius, bg_color)

    # Gradiente de realce no topo (simulado com elipse branca semi-transparente)
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.ellipse(
        [size * 0.15, -size * 0.3, size * 0.85, size * 0.4],
        fill=(100, 140, 255, 30)
    )
    img = Image.alpha_composite(img, highlight)
    draw = ImageDraw.Draw(img)

    # Waveform — barras de altura variada formando curva senoidal
    wf_left  = pad
    wf_right = size - pad
    wf_mid_y = size * 0.52
    wf_max_h = size * 0.30

    wf_w = wf_right - wf_left
    total_gap_w = wf_w * gap_ratio
    total_bar_w = wf_w - total_gap_w
    bar_w = total_bar_w / bar_count
    gap_w = total_gap_w / (bar_count - 1)

    # Perfil de altura: senoidal dupla para parecer waveform real
    heights = []
    for i in range(bar_count):
        t = i / (bar_count - 1)
        h = (
            0.55 * abs(math.sin(t * math.pi * 2.2))
            + 0.30 * abs(math.sin(t * math.pi * 4.5 + 0.8))
            + 0.15 * abs(math.sin(t * math.pi * 1.1 + 0.3))
        )
        h = max(0.10, min(1.0, h))
        heights.append(h)

    # Normaliza para min height razoável
    max_h = max(heights)
    heights = [0.15 + (h / max_h) * 0.85 for h in heights]

    bar_radius = bar_w * 0.40

    for i, h in enumerate(heights):
        x0 = wf_left + i * (bar_w + gap_w)
        x1 = x0 + bar_w
        bh = h * wf_max_h
        y0 = wf_mid_y - bh
        y1 = wf_mid_y + bh

        # Cor: gradiente azul -> ciano por posição
        t = i / (bar_count - 1)
        r = int(56  + t * 30)
        g = int(140 + t * 90)
        b = int(255)
        alpha = 255
        rounded_rect_bar(draw, x0, y0, x1, y1, bar_radius, (r, g, b, alpha))

    # Texto "tx" pequeno abaixo da waveform
    text_y = wf_mid_y + wf_max_h + size * 0.055
    font_size = int(size * 0.14)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New Bold.ttf", font_size)
    except Exception:
        font = ImageFont.load_default()

    text = "tx"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    tx_x = (size - tw) / 2 - bbox[0]
    draw.text((tx_x, text_y), text, fill=(180, 210, 255, 200), font=font)

    return img


def rounded_rect(draw, x0, y0, x1, y1, r, fill):
    draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
    draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
    draw.ellipse([x0, y0, x0 + 2*r, y0 + 2*r], fill=fill)
    draw.ellipse([x1 - 2*r, y0, x1, y0 + 2*r], fill=fill)
    draw.ellipse([x0, y1 - 2*r, x0 + 2*r, y1], fill=fill)
    draw.ellipse([x1 - 2*r, y1 - 2*r, x1, y1], fill=fill)


def rounded_rect_bar(draw, x0, y0, x1, y1, r, fill):
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
    draw.ellipse([x0, y0, x0 + 2*r, y0 + 2*r], fill=fill)
    draw.ellipse([x1 - 2*r, y0, x1, y0 + 2*r], fill=fill)
    draw.ellipse([x0, y1 - 2*r, x0 + 2*r, y1], fill=fill)
    draw.ellipse([x1 - 2*r, y1 - 2*r, x1, y1], fill=fill)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    iconset_dir = os.path.join(project_root, "Sources/TxApp/App/tx.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        img = make_icon(s)
        img.save(os.path.join(iconset_dir, f"icon_{s}x{s}.png"))
        if s <= 512:
            img2x = make_icon(s * 2)
            img2x.save(os.path.join(iconset_dir, f"icon_{s}x{s}@2x.png"))

    # Renomeia para o formato exato que iconutil espera
    renames = {
        "icon_16x16.png":       "icon_16x16.png",
        "icon_32x32.png":       "icon_32x32@1x.png",  # alias
        "icon_32x32@2x.png":    "icon_32x32@2x.png",
        "icon_64x64.png":       "icon_64x64.png",
        "icon_128x128.png":     "icon_128x128.png",
        "icon_128x128@2x.png":  "icon_128x128@2x.png",
        "icon_256x256.png":     "icon_256x256.png",
        "icon_256x256@2x.png":  "icon_256x256@2x.png",
        "icon_512x512.png":     "icon_512x512.png",
        "icon_512x512@2x.png":  "icon_512x512@2x.png",
        "icon_1024x1024.png":   "icon_1024x1024.png",
    }

    icns_path = os.path.join(project_root, "Sources/TxApp/App/AppIcon.icns")
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icns_path}"')
    print(f"Icone gerado: {icns_path}")


if __name__ == "__main__":
    main()
