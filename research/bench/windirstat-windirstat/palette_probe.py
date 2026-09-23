# Analysis probe: how distinguishable is WinDirStat's extension palette?
# Inputs are facts quoted from windirstat/windirstat@da13ad6 (GPL-2.0, study only):
#   palette  windirstat/Controls/TreeMap.h:355-374 (DefaultCushionColors)
#   0.6 brightness normalisation  TreeMap.h:91-169 (MakeBrightColor, NormalizeColor), TreeMap.cpp:247-252
#   rank -> colour  WinDirStatModel.cpp:484-496 (colors[min(rank, 17)])
# The maths below is re-implemented from those descriptions, not copied.
# CVD model: Machado, Oliveira, Fernandes 2009, severity 1.0, applied in linear sRGB.
# Colour difference: CIEDE2000.
import math, itertools

PALETTE = [("blue", (0, 0, 255)), ("red", (255, 0, 0)), ("green", (0, 255, 0)), ("yellow", (255, 255, 0)),
           ("cyan", (0, 255, 255)), ("magenta", (255, 0, 255)), ("orange", (255, 170, 0)),
           ("dodger blue", (0, 85, 255)), ("hot pink", (255, 0, 85)), ("lime green", (85, 255, 0)),
           ("violet", (170, 0, 255)), ("spring green", (0, 255, 85)), ("deep pink", (255, 0, 170)),
           ("sky blue", (0, 170, 255)), ("orange red", (255, 85, 0)), ("aquamarine", (0, 255, 170)),
           ("indigo", (85, 0, 255)), ("white", (255, 255, 255))]


def make_bright(c, b=0.6):
    f = 3.0 * b / (sum(c) / 255.0)
    v = [int(x / 255.0 * f * 255) for x in c]
    for i in range(3):
        if v[i] > 255:
            j, k = [n for n in range(3) if n != i]
            h = (v[i] - 255) // 2
            v[i] = 255; v[j] += h; v[k] += h
            if v[j] > 255: v[k] += v[j] - 255; v[j] = 255
            elif v[k] > 255: v[j] += v[k] - 255; v[k] = 255
            break
    return tuple(v)


def lin(u): u /= 255.0; return u / 12.92 if u <= 0.04045 else ((u + 0.055) / 1.055) ** 2.4
def gam(u): u = min(max(u, 0.0), 1.0); return 12.92 * u if u <= 0.0031308 else 1.055 * u ** (1 / 2.4) - 0.055

MACHADO = {"deutan": [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
           "protan": [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]}


def simulate(c, kind):
    l = [lin(x) for x in c]
    m = MACHADO[kind]
    return tuple(round(gam(sum(m[r][k] * l[k] for k in range(3))) * 255) for r in range(3))


def lab(c):
    r, g, b = (lin(x) for x in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def de2000(c1, c2):
    L1, a1, b1 = lab(c1); L2, a2, b2 = lab(c2)
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = a1 * (1 + G), a2 * (1 + G)
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360
    h2p = math.degrees(math.atan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dh = h2p - h1p
    if C1p * C2p == 0: dh = 0
    elif dh > 180: dh -= 360
    elif dh < -180: dh += 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dh / 2))
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    if C1p * C2p == 0: hbp = h1p + h2p
    elif abs(h1p - h2p) > 180: hbp = (h1p + h2p + 360) / 2 if h1p + h2p < 360 else (h1p + h2p - 360) / 2
    else: hbp = (h1p + h2p) / 2
    T = (1 - 0.17 * math.cos(math.radians(hbp - 30)) + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6)) - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    dth = 30 * math.exp(-((hbp - 275) / 25) ** 2)
    Rc = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2)
    Sc, Sh = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * dth)) * Rc
    return math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))


if __name__ == "__main__":
    base = [(n, make_bright(c)) for n, c in PALETTE]
    assert base[0][1] == (101, 101, 255) and base[1][1] == (255, 101, 101) and base[17][1] == (153, 153, 153)
    print("rank  name          swatch RGB (after 0.6 brightness)")
    for i, (n, c) in enumerate(base):
        print(f"{i + 1:>4}  {n:<13} {c}")
    print("\nranks 18 and below all get colors[17] =", base[17][1], "(one shared gray)")
    print("\nPairs among the 17 distinct ranks with CIEDE2000 < 10 (hard to tell apart as small tiles):")
    for kind in ("normal", "deutan", "protan"):
        sim = [c if kind == "normal" else simulate(c, kind) for _, c in base[:17]]
        close = [(i + 1, j + 1, de2000(sim[i], sim[j])) for i, j in itertools.combinations(range(17), 2)]
        close = sorted([t for t in close if t[2] < 10], key=lambda t: t[2])
        print(f"  {kind:<7} {len(close):>3} pairs:", ", ".join(f"{a}-{b} ({d:.1f})" for a, b, d in close[:12]),
              "..." if len(close) > 12 else "")
    print("\nTop ranks, pairwise CIEDE2000 (normal / deutan / protan):")
    for i, j in itertools.combinations(range(5), 2):
        a, b = base[i][1], base[j][1]
        print(f"  rank {i + 1} {base[i][0]:<7} vs rank {j + 1} {base[j][0]:<7}: "
              f"{de2000(a, b):5.1f} / {de2000(simulate(a, 'deutan'), simulate(b, 'deutan')):5.1f} / "
              f"{de2000(simulate(a, 'protan'), simulate(b, 'protan')):5.1f}")
