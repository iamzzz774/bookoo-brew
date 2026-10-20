#!/usr/bin/env python3
"""Render our original geometric coffee-cup launcher icon. Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def render(size):
    image = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((22, 22, 1002, 1002), radius=222, fill='#272C30')
    draw.rounded_rectangle((642, 328, 847, 632), radius=94, outline='#A3D5C0', width=53)
    draw.rounded_rectangle((228, 328, 710, 712), radius=82, fill='#F2F0E9')
    draw.rectangle((228, 328, 710, 392), fill='#F2F0E9')
    draw.rounded_rectangle((194, 758, 788, 795), radius=18, fill='#A3D5C0')
    for bounds in [(342, 229, 378, 282), (449, 189, 485, 282), (556, 229, 592, 282)]:
        draw.rounded_rectangle(bounds, radius=18, fill='#A3D5C0')
    return image.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == '__main__':
    for density, size in {'mdpi':48, 'hdpi':72, 'xhdpi':96, 'xxhdpi':144, 'xxxhdpi':192}.items():
        target = ROOT / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'
        target.parent.mkdir(parents=True, exist_ok=True)
        render(size).save(target)
        with Image.open(target) as check:
            check.verify()
        print(f'{density}: {size}x{size}')
