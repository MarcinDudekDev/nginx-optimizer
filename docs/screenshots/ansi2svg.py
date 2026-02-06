#!/usr/bin/env python3
"""Convert ANSI-colored terminal output to SVG terminal screenshots."""
import re
import sys
import html

ANSI_COLORS = {
    '30': '#282C34', '31': '#E06C75', '32': '#98C379', '33': '#E5C07B',
    '34': '#61AFEF', '35': '#C678DD', '36': '#56B6C2', '37': '#ABB2BF',
    '90': '#5C6370', '91': '#E06C75', '92': '#98C379', '93': '#E5C07B',
    '94': '#61AFEF', '95': '#C678DD', '96': '#56B6C2', '97': '#FFFFFF',
}
DEFAULT_FG = '#ABB2BF'
ANSI_RE = re.compile(r'\x1b\[([0-9;]*)m')

def parse_ansi_line(line):
    """Parse a line with ANSI codes into (color, text) segments."""
    segments = []
    current_color = DEFAULT_FG
    bold = False
    pos = 0
    for m in ANSI_RE.finditer(line):
        # Text before this escape
        text = line[pos:m.start()]
        if text:
            segments.append((current_color, text))
        # Parse codes
        codes = m.group(1).split(';') if m.group(1) else ['0']
        for code in codes:
            if code == '0' or code == '':
                current_color = DEFAULT_FG
                bold = False
            elif code == '1':
                bold = True
            elif code in ANSI_COLORS:
                current_color = ANSI_COLORS[code]
        pos = m.end()
    # Remaining text
    text = line[pos:]
    if text:
        segments.append((current_color, text))
    return segments

def generate_svg(lines_raw, title="Terminal", width=None):
    char_w = 8.4
    char_h = 18
    padding_x = 24
    padding_y = 16
    title_h = 40
    line_h = 20

    # Parse all lines
    parsed = []
    max_chars = 0
    for line in lines_raw:
        segs = parse_ansi_line(line)
        plain = ''.join(t for _, t in segs)
        max_chars = max(max_chars, len(plain))
        parsed.append(segs)

    n_lines = len(parsed)
    w = width or max(int(max_chars * char_w + padding_x * 2 + 20), 700)
    h = int(n_lines * line_h + title_h + padding_y * 2 + 10)

    svg = []
    svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">')
    svg.append('''  <defs>
    <filter id="shadow" x="-2%" y="-2%" width="104%" height="104%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-opacity="0.3"/>
    </filter>
  </defs>''')
    svg.append(f'  <rect width="{w}" height="{h}" rx="10" fill="#282C34" filter="url(#shadow)"/>')
    svg.append(f'  <rect width="{w}" height="{title_h}" rx="10" fill="#21252B"/>')
    svg.append(f'  <rect x="0" y="30" width="{w}" height="10" fill="#21252B"/>')
    # Window buttons
    svg.append('  <circle cx="20" cy="20" r="6" fill="#E06C75"/>')
    svg.append('  <circle cx="40" cy="20" r="6" fill="#E5C07B"/>')
    svg.append('  <circle cx="60" cy="20" r="6" fill="#98C379"/>')
    # Title
    svg.append(f'  <text x="{w//2}" y="25" text-anchor="middle" '
               f'font-family="-apple-system,BlinkMacSystemFont,sans-serif" '
               f'font-size="13" fill="#9DA5B4">{html.escape(title)}</text>')

    # Lines
    y = title_h + padding_y
    for segs in parsed:
        if not segs:
            y += line_h
            continue
        x = padding_x
        parts = []
        for color, text in segs:
            escaped = html.escape(text)
            # Replace spaces with explicit spacing for monospace
            if color != DEFAULT_FG:
                parts.append(f'<tspan fill="{color}">{escaped}</tspan>')
            else:
                parts.append(escaped)
        line_content = ''.join(parts)
        svg.append(f'  <text x="{x}" y="{y}" '
                   f'font-family="\'SF Mono\',\'Fira Code\',Menlo,Monaco,Consolas,monospace" '
                   f'font-size="13.5" fill="{DEFAULT_FG}" xml:space="preserve">{line_content}</text>')
        y += line_h

    svg.append('</svg>')
    return '\n'.join(svg)

if __name__ == '__main__':
    title = sys.argv[1] if len(sys.argv) > 1 else 'Terminal'
    output = sys.argv[2] if len(sys.argv) > 2 else None
    raw = sys.stdin.read()
    lines = raw.split('\n')
    # Remove trailing empty lines
    while lines and not lines[-1].strip():
        lines.pop()
    result = generate_svg(lines, title)
    if output:
        with open(output, 'w') as f:
            f.write(result)
        print(f"Generated: {output}")
    else:
        print(result)
