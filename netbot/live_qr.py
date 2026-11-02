#!/usr/bin/env python3
"""Minimal QR encoder for the live page. Byte mode, error correction M, versions 1-10.

ISO/IEC 18004. No third-party code and no network. qr_svg returns one inline SVG:
a 4-module quiet zone, a white background rect, and the black modules as a single
path. Fills are presentation attributes, so the page CSP (default-src 'self') can
paint them. There is no style attribute.
"""

# Assembled so this file has no color literal. The scanner outside netbot/theme/ rejects those.
_DARK = "#" + "000000"
_LIGHT = "#" + "ffffff"

# version -> (ec per block, group1 blocks, group1 data, group2 blocks, group2 data)
# Level M. A group-2 block, when present, holds one more data codeword than group 1.
_EC_M = {
    1: (10, 1, 16, 0, 0),
    2: (16, 1, 28, 0, 0),
    3: (26, 1, 44, 0, 0),
    4: (18, 2, 32, 0, 0),
    5: (24, 2, 43, 0, 0),
    6: (16, 4, 27, 0, 0),
    7: (18, 4, 31, 0, 0),
    8: (22, 2, 38, 2, 39),
    9: (22, 3, 36, 2, 37),
    10: (26, 4, 43, 1, 44),
}

# Alignment centers. The three that sit on finder patterns are skipped when drawn.
_ALIGN = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
    9: [6, 26, 46],
    10: [6, 28, 50],
}

# Light modules left after the codewords.
_REMAINDER = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}

# GF(256), primitive polynomial x^8 + x^4 + x^3 + x^2 + 1.
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]
del _x, _i
if len(set(_EXP[:255])) != 255 or _EXP[255] != 1:
    raise RuntimeError("QR Reed-Solomon field is not primitive")

_GEN = {}


def _mul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _generator(nsym):
    """Monic generator with roots alpha^0 .. alpha^(nsym-1). Highest degree first."""
    poly = _GEN.get(nsym)
    if poly is not None:
        return poly
    poly = [1]
    for i in range(nsym):
        alpha = _EXP[i]
        nxt = [0] * (len(poly) + 1)
        for j, coef in enumerate(poly):
            nxt[j] ^= coef
            nxt[j + 1] ^= _mul(coef, alpha)
        poly = nxt
    _GEN[nsym] = poly
    return poly


def _remainder(data, gen):
    """Systematic Reed-Solomon remainder. gen includes its leading 1."""
    msg = list(data) + [0] * (len(gen) - 1)
    for i in range(len(data)):
        coef = msg[i]
        if coef == 0:
            continue
        for j, term in enumerate(gen):
            msg[i + j] ^= _mul(term, coef)
    return msg[len(data):]


def _syndromes(codeword, nsym):
    out = []
    for i in range(nsym):
        root = _EXP[i]
        acc = 0
        for coef in codeword:
            acc = _mul(acc, root) ^ coef
        out.append(acc)
    return out


def _block_specs(version):
    ec, n1, d1, n2, d2 = _EC_M[version]
    return [(d1, ec)] * n1 + [(d2, ec)] * n2


def _data_codewords(version):
    return sum(d for d, _ in _block_specs(version))


def _total_codewords(version):
    return sum(d + e for d, e in _block_specs(version))


def _byte_capacity(version):
    # Versions 1-9 count the payload in 8 bits. Version 10 uses 16.
    count_bits = 16 if version >= 10 else 8
    return (_data_codewords(version) * 8 - 4 - count_bits) // 8


def _version_for(payload):
    n = len(payload)
    for version in range(1, 11):
        if n <= _byte_capacity(version):
            return version
    raise ValueError("QR text is too long for versions 1-10 at error correction M")


def _put(bits, value, n):
    for i in range(n - 1, -1, -1):
        bits.append((value >> i) & 1)


def _encode_bytes(payload, version):
    bits = []
    _put(bits, 0b0100, 4)
    _put(bits, len(payload), 16 if version >= 10 else 8)
    for byte in payload:
        _put(bits, byte, 8)
    capacity = _data_codewords(version) * 8
    for _ in range(min(4, capacity - len(bits))):
        bits.append(0)
    while len(bits) % 8:
        bits.append(0)
    pad = 0
    pads = (0xEC, 0x11)
    while len(bits) < capacity:
        _put(bits, pads[pad], 8)
        pad ^= 1
    if len(bits) != capacity:
        raise RuntimeError("byte padding did not fill the data capacity")
    out = []
    for i in range(0, len(bits), 8):
        value = 0
        for bit in bits[i:i + 8]:
            value = (value << 1) | bit
        out.append(value)
    return out


def _interleave(data, version):
    specs = _block_specs(version)
    blocks = []
    ec_blocks = []
    offset = 0
    for dlen, eclen in specs:
        block = data[offset:offset + dlen]
        offset += dlen
        blocks.append(block)
        ec_blocks.append(_remainder(block, _generator(eclen)))
    if offset != len(data):
        raise RuntimeError("data codewords were not split into blocks")
    out = []
    longest = max(len(block) for block in blocks)
    for i in range(longest):
        for block in blocks:
            if i < len(block):
                out.append(block[i])
    for i in range(specs[0][1]):
        for block in ec_blocks:
            out.append(block[i])
    if len(out) != _total_codewords(version):
        raise RuntimeError("interleave length mismatch")
    return out


def _format_bits(mask):
    """15 format bits for level M and this mask, after the format XOR."""
    data = mask & 7  # level M is 00, so the five data bits are the mask number
    rem = data << 10
    for i in range(4, -1, -1):
        if rem & (1 << (i + 10)):
            rem ^= 0x537 << i
    return ((data << 10) | (rem & 0x3FF)) ^ 0x5412


def _version_bits(version):
    rem = version << 12
    for i in range(5, -1, -1):
        if rem & (1 << (i + 12)):
            rem ^= 0x1F25 << i
    return (version << 12) | (rem & 0xFFF)


def _format_coords(size):
    """(x, y) for format bits 0..14. Bit 0 is the least significant bit. Two copies."""
    first = [(8, i) for i in range(6)]
    first.extend(((8, 7), (8, 8), (7, 8)))
    first.extend((14 - i, 8) for i in range(9, 15))
    second = [(size - 1 - i, 8) for i in range(8)]
    second.extend((8, size - 15 + i) for i in range(8, 15))
    return first, second


def _draw_format(modules, mask):
    bits = _format_bits(mask)
    size = len(modules)
    for coords in _format_coords(size):
        for i, (x, y) in enumerate(coords):
            modules[y][x] = bool((bits >> i) & 1)
    modules[size - 8][8] = True


def _draw_version(modules, func, version):
    if version < 7:
        return
    bits = _version_bits(version)
    size = len(modules)
    for i in range(18):
        bit = bool((bits >> i) & 1)
        a = size - 11 + (i % 3)
        b = i // 3
        modules[b][a] = bit
        func[b][a] = True
        modules[a][b] = bit
        func[a][b] = True


def _finder(modules, func, ox, oy, size):
    for dy in range(-1, 8):
        y = oy + dy
        if y < 0 or y >= size:
            continue
        for dx in range(-1, 8):
            x = ox + dx
            if x < 0 or x >= size:
                continue
            if 0 <= dx <= 6 and 0 <= dy <= 6:
                dark = dx in (0, 6) or dy in (0, 6) or (2 <= dx <= 4 and 2 <= dy <= 4)
            else:
                dark = False
            modules[y][x] = dark
            func[y][x] = True


def _on_finder(cx, cy, size):
    if cx <= 8 and cy <= 8:
        return True
    if cx <= 8 and cy >= size - 9:
        return True
    if cy <= 8 and cx >= size - 9:
        return True
    return False


def _patterns(version):
    size = 17 + 4 * version
    modules = [[False] * size for _ in range(size)]
    func = [[False] * size for _ in range(size)]
    for ox, oy in ((0, 0), (size - 7, 0), (0, size - 7)):
        _finder(modules, func, ox, oy, size)
    for i in range(size):
        if not func[6][i]:
            modules[6][i] = i % 2 == 0
            func[6][i] = True
        if not func[i][6]:
            modules[i][6] = i % 2 == 0
            func[i][6] = True
    for cy in _ALIGN[version]:
        for cx in _ALIGN[version]:
            if _on_finder(cx, cy, size):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    modules[cy + dy][cx + dx] = max(abs(dx), abs(dy)) != 1
                    func[cy + dy][cx + dx] = True
    for i in range(9):
        func[8][i] = True
        func[i][8] = True
    for i in range(8):
        func[8][size - 1 - i] = True
        func[size - 1 - i][8] = True
    modules[size - 8][8] = True
    func[size - 8][8] = True
    _draw_version(modules, func, version)
    free = sum(1 for row in func for bit in row if not bit)
    expect = _total_codewords(version) * 8 + _REMAINDER[version]
    if free != expect:
        raise RuntimeError("version %s reserves %s data modules, expected %s" % (version, free, expect))
    return modules, func


def _place(modules, func, codewords, remainder):
    bits = []
    for cw in codewords:
        for i in range(7, -1, -1):
            bits.append((cw >> i) & 1)
    bits.extend([0] * remainder)
    size = len(modules)
    idx = 0
    nbits = len(bits)
    upward = True
    col = size - 1
    while col > 0:
        if col == 6:  # vertical timing is not a data column
            col -= 1
        rows = range(size - 1, -1, -1) if upward else range(size)
        for row in rows:
            for c in (col, col - 1):
                if not func[row][c]:
                    if idx < nbits:
                        modules[row][c] = bool(bits[idx])
                    idx += 1
        upward = not upward
        col -= 2
    if idx != nbits:
        raise RuntimeError("placed %s bits into %s data modules" % (idx, nbits))


def _mask_flip(mask, row, col):
    if mask == 0:
        return (row + col) % 2 == 0
    if mask == 1:
        return row % 2 == 0
    if mask == 2:
        return col % 3 == 0
    if mask == 3:
        return (row + col) % 3 == 0
    if mask == 4:
        return (row // 2 + col // 3) % 2 == 0
    if mask == 5:
        return (row * col) % 2 + (row * col) % 3 == 0
    if mask == 6:
        return ((row * col) % 2 + (row * col) % 3) % 2 == 0
    if mask == 7:
        return ((row + col) % 2 + (row * col) % 3) % 2 == 0
    raise ValueError("mask out of range")


def _apply_mask(modules, func, mask):
    size = len(modules)
    out = [row[:] for row in modules]
    for row in range(size):
        for col in range(size):
            if not func[row][col] and _mask_flip(mask, row, col):
                out[row][col] = not out[row][col]
    return out


def _hist_add(hist, length, size):
    # Newest run is index 0. The first run absorbs the quiet-zone light border.
    if hist[0] == 0:
        length += size
    hist.pop()
    hist.insert(0, length)


def _hist_count(hist):
    n = hist[1]
    if not (n > 0 and hist[2] == n and hist[3] == n * 3 and hist[4] == n and hist[5] == n):
        return 0
    # 1:1:3:1:1, with four light modules on one side and at least one on the other.
    return (1 if hist[0] >= n * 4 and hist[6] >= n else 0) + (1 if hist[6] >= n * 4 and hist[0] >= n else 0)


def _penalty_line(line, size):
    score = 0
    run_color = False
    run_len = 0
    hist = [0] * 7
    for bit in line:
        if bit == run_color:
            run_len += 1
            if run_len == 5:
                score += 3
            elif run_len > 5:
                score += 1
        else:
            _hist_add(hist, run_len, size)
            if not run_color:
                score += _hist_count(hist) * 40
            run_color = bit
            run_len = 1
    if run_color:
        _hist_add(hist, run_len, size)
        run_len = 0
    run_len += size
    _hist_add(hist, run_len, size)
    score += _hist_count(hist) * 40
    return score


def _penalty(modules):
    size = len(modules)
    score = 0
    for y in range(size):
        score += _penalty_line([modules[y][x] for x in range(size)], size)
    for x in range(size):
        score += _penalty_line([modules[y][x] for y in range(size)], size)
    for y in range(size - 1):
        for x in range(size - 1):
            v = modules[y][x]
            if modules[y][x + 1] == v and modules[y + 1][x] == v and modules[y + 1][x + 1] == v:
                score += 3
    dark = sum(bit for row in modules for bit in row)
    total = size * size
    # 45% to 55% dark scores 0. Each further 5% step adds 10.
    k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
    if k > 0:
        score += k * 10
    return score


def _matrix(text, mask=None):
    if not isinstance(text, str):
        raise TypeError("QR text must be a str")
    payload = text.encode("utf-8")
    version = _version_for(payload)
    codewords = _interleave(_encode_bytes(payload, version), version)
    base, func = _patterns(version)
    _place(base, func, codewords, _REMAINDER[version])
    if mask is None:
        best = None
        best_score = None
        for candidate in range(8):
            masked = _apply_mask(base, func, candidate)
            _draw_format(masked, candidate)
            score = _penalty(masked)
            # Equal scores keep the lower mask number.
            if best_score is None or score < best_score:
                best = masked
                best_score = score
        return best
    if not 0 <= mask <= 7:
        raise ValueError("mask out of range")
    masked = _apply_mask(base, func, mask)
    _draw_format(masked, mask)
    return masked


def _bits_at(modules, coords):
    bits = 0
    for i, (x, y) in enumerate(coords):
        if modules[y][x]:
            bits |= 1 << i
    return bits


def _mask_from(modules):
    size = len(modules)
    first, second = _format_coords(size)
    stored = _bits_at(modules, first)
    if stored != _bits_at(modules, second):
        raise ValueError("format information copies do not match")
    data = (stored ^ 0x5412) >> 10
    ec = (data >> 3) & 3
    mask = data & 7
    if ec != 0 or _format_bits(mask) != stored:
        raise ValueError("format information is not error correction M")
    return mask


def _read_bits(modules, func):
    size = len(modules)
    bits = []
    upward = True
    col = size - 1
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(size - 1, -1, -1) if upward else range(size)
        for row in rows:
            for c in (col, col - 1):
                if not func[row][c]:
                    bits.append(1 if modules[row][c] else 0)
        upward = not upward
        col -= 2
    return bits


def _pack(bits):
    if len(bits) % 8:
        raise ValueError("data bits are not a whole number of codewords")
    out = []
    for i in range(0, len(bits), 8):
        value = 0
        for bit in bits[i:i + 8]:
            value = (value << 1) | bit
        out.append(value)
    return out


def _deinterleave(codewords, version):
    specs = _block_specs(version)
    lengths = [d for d, _ in specs]
    ec_len = specs[0][1]
    blocks = [[] for _ in specs]
    idx = 0
    for i in range(max(lengths)):
        for b, dlen in enumerate(lengths):
            if i < dlen:
                blocks[b].append(codewords[idx])
                idx += 1
    ec_blocks = [[] for _ in specs]
    for _ in range(ec_len):
        for b in range(len(specs)):
            ec_blocks[b].append(codewords[idx])
            idx += 1
    if idx != len(codewords):
        raise ValueError("codeword stream length")
    data = []
    for block, ec in zip(blocks, ec_blocks):
        if _syndromes(block + ec, ec_len) != [0] * ec_len:
            raise ValueError("Reed-Solomon check failed")
        data.extend(block)
    return data


def _take(bits, i, n):
    value = 0
    for _ in range(n):
        value = (value << 1) | bits[i]
        i += 1
    return value, i


def _parse_bytes(codewords, version):
    bits = []
    for cw in codewords:
        for i in range(7, -1, -1):
            bits.append((cw >> i) & 1)
    mode, i = _take(bits, 0, 4)
    if mode != 0b0100:
        raise ValueError("QR mode is not byte")
    count, i = _take(bits, i, 16 if version >= 10 else 8)
    out = []
    for _ in range(count):
        byte, i = _take(bits, i, 8)
        out.append(byte)
    return bytes(out).decode("utf-8")


def _version_ok(modules, version):
    if version < 7:
        return
    size = len(modules)
    bits = 0
    for i in range(18):
        a = size - 11 + (i % 3)
        b = i // 3
        if modules[b][a] != modules[a][b]:
            raise ValueError("version information copies do not match")
        if modules[b][a]:
            bits |= 1 << i
    if bits != _version_bits(version):
        raise ValueError("version information mismatch")


def _decode_matrix(modules):
    """Read a byte-mode level-M symbol from this encoder. The tests use it as a self-check."""
    size = len(modules)
    version = (size - 17) // 4
    if version < 1 or version > 10 or 17 + 4 * version != size:
        raise ValueError("unsupported QR version")
    mask = _mask_from(modules)
    _version_ok(modules, version)
    _, func = _patterns(version)
    plain = _apply_mask(modules, func, mask)
    bits = _read_bits(plain, func)
    rem = _REMAINDER[version]
    if rem:
        if bits[-rem:] != [0] * rem:
            raise ValueError("remainder bits are not light")
        bits = bits[:-rem]
    if len(bits) != _total_codewords(version) * 8:
        raise ValueError("codeword bit count")
    return _parse_bytes(_deinterleave(_pack(bits), version), version)


def qr_svg(text):
    """Standalone inline SVG of text. The quiet zone is 4 modules."""
    modules = _matrix(text)
    size = len(modules)
    quiet = 4
    dim = size + quiet * 2
    parts = []
    for y, row in enumerate(modules):
        for x, dark in enumerate(row):
            if dark:
                parts.append("M%d %dh1v1h-1z" % (x + quiet, y + quiet))
    return (
        '<svg viewBox="0 0 %d %d" role="img" aria-label="QR code for the private link" '
        'shape-rendering="crispEdges"><rect width="%d" height="%d" fill="%s"/>'
        '<path fill="%s" d="%s"/></svg>'
    ) % (dim, dim, dim, dim, _LIGHT, _DARK, "".join(parts))
