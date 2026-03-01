#!/usr/bin/env python3
"""Bake deterministic .cube LUT files into generated C++ sources."""
import glob
import os
import sys

TARGET_DIM = 33

LUT_DIR = "/Users/victorbarbaian/Local Projects/VTC/VTC Pack/LUTs"
LOG_DIR = os.path.join(LUT_DIR, "Log")
REC_DIR = os.path.join(LUT_DIR, "Rec 709")
CORE_DIR = "/Users/victorbarbaian/Local Projects/VTC Looks/Plugin/Core"
SHARED_DIR = "/Users/victorbarbaian/Local Projects/VTC Looks/Plugin/Shared"

LOG_ORDER = [
    "Convert Sony",
    "Dark Forest",
    "Amethyst",
    "Low Highlights",
    "Convert Canon",
    "Convert Fujifilm",
    "Convert RED",
]


def sanitize(name):
    return "".join(ch if ch.isalnum() else "_" for ch in name).strip("_")


def read_cube(filepath):
    dim = None
    data = []
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#") or s.upper().startswith("TITLE"):
                continue
            if s.upper().startswith("LUT_3D_SIZE"):
                dim = int(s.split()[1])
                continue
            if s.upper().startswith(("DOMAIN_MIN", "DOMAIN_MAX")):
                continue
            parts = s.split()
            if len(parts) >= 3:
                try:
                    data.extend([float(parts[0]), float(parts[1]), float(parts[2])])
                except ValueError:
                    continue

    if dim is None:
        entries = len(data) // 3
        dim = round(entries ** (1.0 / 3.0))

    expected = dim * dim * dim * 3
    if len(data) != expected:
        raise ValueError(f"Invalid LUT payload in {filepath}: got {len(data)} floats, expected {expected}")
    return dim, data


def lerp(a, b, t):
    return a + (b - a) * t


def sample(dim, data, r, g, b):
    r = max(0.0, min(1.0, r))
    g = max(0.0, min(1.0, g))
    b = max(0.0, min(1.0, b))

    fr = r * (dim - 1)
    fg = g * (dim - 1)
    fb = b * (dim - 1)

    r0 = int(fr)
    g0 = int(fg)
    b0 = int(fb)
    r1 = min(r0 + 1, dim - 1)
    g1 = min(g0 + 1, dim - 1)
    b1 = min(b0 + 1, dim - 1)

    fr -= r0
    fg -= g0
    fb -= b0

    def at(ri, gi, bi):
        idx = ((ri * dim + gi) * dim + bi) * 3
        return (data[idx], data[idx + 1], data[idx + 2])

    def l3(a, b, t):
        return (lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t))

    c000 = at(r0, g0, b0)
    c100 = at(r1, g0, b0)
    c010 = at(r0, g1, b0)
    c110 = at(r1, g1, b0)
    c001 = at(r0, g0, b1)
    c101 = at(r1, g0, b1)
    c011 = at(r0, g1, b1)
    c111 = at(r1, g1, b1)

    c00 = l3(c000, c100, fr)
    c10 = l3(c010, c110, fr)
    c01 = l3(c001, c101, fr)
    c11 = l3(c011, c111, fr)

    c0 = l3(c00, c10, fg)
    c1 = l3(c01, c11, fg)

    return l3(c0, c1, fb)


def resample(dim_src, data_src, dim_dst):
    if dim_src == dim_dst:
        return list(data_src)

    result = []
    for ri in range(dim_dst):
        r = ri / (dim_dst - 1) if dim_dst > 1 else 0.0
        for gi in range(dim_dst):
            g = gi / (dim_dst - 1) if dim_dst > 1 else 0.0
            for bi in range(dim_dst):
                b = bi / (dim_dst - 1) if dim_dst > 1 else 0.0
                result.extend(sample(dim_src, data_src, r, g, b))
    return result


def write_array(f, var_name, data):
    n = len(data)
    f.write(f"const float {var_name}[{n}] = {{\n")
    for i in range(0, n, 9):
        vals = ",".join(f"{v:.6f}f" for v in data[i:i + 9])
        f.write(f"{vals},\n")
    f.write("};\n\n")


def selected_popup(total):
    return "|".join([f"0/{total}"] + [f"{i}/{total}" for i in range(1, total + 1)])


def load_and_resample(filepath, name):
    print(f"  {name} ...", end=" ", flush=True)
    dim, data = read_cube(filepath)
    print(f"dim={dim}", end=" ", flush=True)
    if dim != TARGET_DIM:
        print("-> resample", end=" ", flush=True)
        data = resample(dim, data, TARGET_DIM)
    print(f"OK ({len(data)} floats)")
    return data


def main():
    # Hard fail if any required Log LUT is missing.
    missing = [name for name in LOG_ORDER if not os.path.isfile(os.path.join(LOG_DIR, name + ".cube"))]
    if missing:
        print("ERROR: Missing required Log LUTs:")
        for name in missing:
            print(f"  - {name}.cube")
        sys.exit(1)

    log_luts = []
    for name in LOG_ORDER:
        cube = os.path.join(LOG_DIR, name + ".cube")
        data = load_and_resample(cube, name)
        log_luts.append((name, sanitize(name), data))

    rec_files = sorted(
        glob.glob(os.path.join(REC_DIR, "*.cube")) + glob.glob(os.path.join(REC_DIR, "*.CUBE")),
        key=lambda p: os.path.splitext(os.path.basename(p))[0].lower(),
    )

    rec_luts = []
    for fp in rec_files:
        name = os.path.splitext(os.path.basename(fp))[0]
        data = load_and_resample(fp, name)
        rec_luts.append((name, sanitize(name), data))

    print(f"\nGenerating C++ ({len(log_luts)} Log + {len(rec_luts)} Rec709) ...")

    log_cpp = os.path.join(CORE_DIR, "VTC_LUTData_Log_Gen.cpp")
    with open(log_cpp, "w", encoding="utf-8") as f:
        f.write('#include "../Shared/VTC_LUTData.h"\n\nnamespace vtc {\n\n')
        for _, sname, data in log_luts:
            write_array(f, f"kLogLUT_{sname}", data)
        f.write("const LUT3D kLogLUTs[] = {\n")
        for _, sname, _ in log_luts:
            f.write(f"    {{kLogLUT_{sname}, {TARGET_DIM}}},\n")
        f.write("};\n\n")
        f.write(f"const int kLogLUTCount = {len(log_luts)};\n\n")
        f.write("}  // namespace vtc\n")

    rec_cpp = os.path.join(CORE_DIR, "VTC_LUTData_Rec709_Gen.cpp")
    with open(rec_cpp, "w", encoding="utf-8") as f:
        f.write('#include "../Shared/VTC_LUTData.h"\n\nnamespace vtc {\n\n')
        for _, sname, data in rec_luts:
            write_array(f, f"kRecLUT_{sname}", data)
        f.write("const LUT3D kRec709LUTs[] = {\n")
        for _, sname, _ in rec_luts:
            f.write(f"    {{kRecLUT_{sname}, {TARGET_DIM}}},\n")
        f.write("};\n\n")
        f.write(f"const int kRec709LUTCount = {len(rec_luts)};\n\n")
        f.write("}  // namespace vtc\n")

    hdr = os.path.join(SHARED_DIR, "VTC_LUTData.h")
    with open(hdr, "w", encoding="utf-8") as f:
        f.write("#pragma once\n\nnamespace vtc {\n\n")
        f.write("struct LUT3D {\n    const float* data;\n    int dimension;\n};\n\n")
        f.write(f"constexpr int kLUTDim = {TARGET_DIM};\n\n")
        f.write("extern const LUT3D kLogLUTs[];\nextern const int kLogLUTCount;\n\n")
        f.write("extern const LUT3D kRec709LUTs[];\nextern const int kRec709LUTCount;\n\n")

        f.write("inline const char* const kLogLUTNames[] = {\n")
        for name, _, _ in log_luts:
            f.write(f'    "{name}",\n')
        f.write("};\n\n")

        f.write("inline const char* const kRec709LUTNames[] = {\n")
        for name, _, _ in rec_luts:
            f.write(f'    "{name}",\n')
        f.write("};\n\n")

        log_popup = "None|" + "|".join(name for name, _, _ in log_luts)
        rec_popup = "None|" + "|".join(name for name, _, _ in rec_luts)
        f.write(f'inline const char kLogPopupStr[] = "{log_popup}";\n')
        f.write(f'inline const char kRec709PopupStr[] = "{rec_popup}";\n\n')

        f.write(f'inline const char kLogSelectedPopupStr[] = "{selected_popup(len(log_luts))}";\n')
        f.write(f'inline const char kRec709SelectedPopupStr[] = "{selected_popup(len(rec_luts))}";\n\n')
        f.write("}  // namespace vtc\n")

    print(f"  {log_cpp} ({os.path.getsize(log_cpp) // 1048576} MB)")
    print(f"  {rec_cpp} ({os.path.getsize(rec_cpp) // 1048576} MB)")
    print(f"  {hdr}")
    print(f"\nDone! Log={len(log_luts)}, Rec709={len(rec_luts)}")


if __name__ == "__main__":
    main()
