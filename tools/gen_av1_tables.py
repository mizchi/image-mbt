"""Extract AV1 tables from the spec text into src/av1_tables.mbt.

Usage: python3 tools/gen_av1_tables.py spec.txt src/av1_tables.mbt
where spec.txt is the AV1 Bitstream & Decoding Process Specification
(https://aomediacodec.github.io/av1-spec/) converted to plain text."""
import re, sys
spec = open(sys.argv[1], encoding="utf-8").read().split("\n")
out_path = sys.argv[2]
BLOCK = ["4X4","4X8","8X4","8X8","8X16","16X8","16X16","16X32","32X16","32X32","32X64","64X32","64X64","64X128","128X64","128X128","4X16","16X4","8X32","32X8","16X64","64X16"]
TX = ["4X4","8X8","16X16","32X32","64X64","4X8","8X4","8X16","16X8","16X32","32X16","32X64","64X32","4X16","16X4","8X32","32X8","16X64","64X16"]
TXT = ["DCT_DCT","ADST_DCT","DCT_ADST","ADST_ADST","FLIPADST_DCT","DCT_FLIPADST","FLIPADST_FLIPADST","ADST_FLIPADST","FLIPADST_ADST","IDTX","V_DCT","H_DCT","V_ADST","H_ADST","V_FLIPADST","H_FLIPADST"]
sym = {}
for i, b in enumerate(BLOCK): sym["BLOCK_" + b] = i
sym["BLOCK_INVALID"] = 22
for i, t in enumerate(TX): sym["TX_" + t] = i
for i, t in enumerate(TXT): sym[t] = i
sym["SIG_COEF_CONTEXTS_2D"] = 26
def grab(name):
    start = None
    for k, l in enumerate(spec):
        if re.match(r"\s*" + re.escape(name) + r"\s*\[", l) and "=" in l:
            start = k
            break
    assert start is not None, name
    text = "\n".join(spec[start:start + 3000])
    j = text.index("{")
    depth = 0
    k = j
    while True:
        if text[k] == "{": depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    body = re.sub(r"//[^\n]*", "", text[j:k + 1])
    expr = re.sub(r"[{}\s]", "", body).split(",")
    vals = [int(eval(e, {}, dict(sym))) for e in expr if e]
    return vals
tables = [
  # (moonbit name, spec name, expected count)
  ("av1_dc_qlookup", "Dc_Qlookup", 768),
  ("av1_ac_qlookup", "Ac_Qlookup", 768),
  ("av1_intra_mode_context", "Intra_Mode_Context", 13),
  ("av1_coeff_base_ctx_offset", "Coeff_Base_Ctx_Offset", 19 * 25),
  ("av1_sig_ref_diff_offset", "Sig_Ref_Diff_Offset", 30),
  ("av1_mag_ref_offset", "Mag_Ref_Offset_With_Tx_Class", 18),
  ("av1_mode_to_txfm", "Mode_To_Txfm", 14),
  ("av1_mode_to_angle", "Mode_To_Angle", 13),
  ("av1_dr_intra_derivative", "Dr_Intra_Derivative", 90),
  ("av1_cos128_lut", "Cos128_Lookup", 65),
  ("av1_transform_row_shift", "Transform_Row_Shift", 19),
  ("av1_tx_width_log2", "Tx_Width_Log2", 19),
  ("av1_tx_height_log2", "Tx_Height_Log2", 19),
  ("av1_tx_size_sqr", "Tx_Size_Sqr", 19),
  ("av1_tx_size_sqr_up", "Tx_Size_Sqr_Up", 19),
  ("av1_adjusted_tx_size", "Adjusted_Tx_Size", 19),
  ("av1_max_tx_size_rect", "Max_Tx_Size_Rect", 22),
  ("av1_subsampled_size", "Subsampled_Size", 88),
  ("av1_mi_width_log2", "Mi_Width_Log2", 22),
  ("av1_mi_height_log2", "Mi_Height_Log2", 22),
  ("av1_sm_weights_4", "Sm_Weights_Tx_4x4", 4),
  ("av1_sm_weights_8", "Sm_Weights_Tx_8x8", 8),
  ("av1_sm_weights_16", "Sm_Weights_Tx_16x16", 16),
  ("av1_sm_weights_32", "Sm_Weights_Tx_32x32", 32),
  ("av1_sm_weights_64", "Sm_Weights_Tx_64x64", 64),
  ("av1_scan_4x4", "Default_Scan_4x4", 16),
  ("av1_scan_8x8", "Default_Scan_8x8", 64),
  ("av1_scan_16x16", "Default_Scan_16x16", 256),
  ("av1_scan_32x32", "Default_Scan_32x32", 1024),
  ("av1_scan_4x8", "Default_Scan_4x8", 32),
  ("av1_scan_8x4", "Default_Scan_8x4", 32),
  ("av1_scan_8x16", "Default_Scan_8x16", 128),
  ("av1_scan_16x8", "Default_Scan_16x8", 128),
  ("av1_scan_16x32", "Default_Scan_16x32", 512),
  ("av1_scan_32x16", "Default_Scan_32x16", 512),
  ("av1_scan_4x16", "Default_Scan_4x16", 64),
  ("av1_scan_16x4", "Default_Scan_16x4", 64),
  ("av1_scan_8x32", "Default_Scan_8x32", 256),
  ("av1_scan_32x8", "Default_Scan_32x8", 256),
]
cdfs = [
  # (moonbit name, spec name, symbols N, expected entries)
  ("av1_cdf_kf_y_mode", "Default_Intra_Frame_Y_Mode_Cdf", 13, 25),
  ("av1_cdf_uv_mode_cfl_not_allowed", "Default_Uv_Mode_Cfl_Not_Allowed_Cdf", 13, 13),
  ("av1_cdf_uv_mode_cfl_allowed", "Default_Uv_Mode_Cfl_Allowed_Cdf", 14, 13),
  ("av1_cdf_angle_delta", "Default_Angle_Delta_Cdf", 7, 8),
  ("av1_cdf_partition_w8", "Default_Partition_W8_Cdf", 4, 4),
  ("av1_cdf_partition_w16", "Default_Partition_W16_Cdf", 10, 4),
  ("av1_cdf_partition_w32", "Default_Partition_W32_Cdf", 10, 4),
  ("av1_cdf_partition_w64", "Default_Partition_W64_Cdf", 10, 4),
  ("av1_cdf_partition_w128", "Default_Partition_W128_Cdf", 8, 4),
  ("av1_cdf_skip", "Default_Skip_Cdf", 2, 3),
  ("av1_cdf_intra_tx_type_set2", "Default_Intra_Tx_Type_Set2_Cdf", 5, 3 * 13),
  ("av1_cdf_txb_skip", "Default_Txb_Skip_Cdf", 2, 4 * 5 * 13),
  ("av1_cdf_eob_pt_16", "Default_Eob_Pt_16_Cdf", 5, 4 * 2 * 2),
  ("av1_cdf_eob_pt_32", "Default_Eob_Pt_32_Cdf", 6, 4 * 2 * 2),
  ("av1_cdf_eob_pt_64", "Default_Eob_Pt_64_Cdf", 7, 4 * 2 * 2),
  ("av1_cdf_eob_pt_128", "Default_Eob_Pt_128_Cdf", 8, 4 * 2 * 2),
  ("av1_cdf_eob_pt_256", "Default_Eob_Pt_256_Cdf", 9, 4 * 2 * 2),
  ("av1_cdf_eob_pt_512", "Default_Eob_Pt_512_Cdf", 10, 4 * 2),
  ("av1_cdf_eob_pt_1024", "Default_Eob_Pt_1024_Cdf", 11, 4 * 2),
  ("av1_cdf_eob_extra", "Default_Eob_Extra_Cdf", 2, 4 * 5 * 2 * 9),
  ("av1_cdf_dc_sign", "Default_Dc_Sign_Cdf", 2, 4 * 2 * 3),
  ("av1_cdf_coeff_base_eob", "Default_Coeff_Base_Eob_Cdf", 3, 4 * 5 * 2 * 4),
  ("av1_cdf_coeff_base", "Default_Coeff_Base_Cdf", 4, 4 * 5 * 2 * 42),
  ("av1_cdf_coeff_br", "Default_Coeff_Br_Cdf", 4, 4 * 5 * 2 * 21),
]
with open(out_path, "w") as f:
    f.write("// AV1 tables from the AV1 Bitstream & Decoding Process Specification.\n")
    f.write("// Generated by tools/gen_av1_tables.py from the spec text; do not edit.\n")
    def emit(name, vals, doc):
        f.write("\n///|\n/// %s\nlet %s : FixedArray[Int] = [\n" % (doc, name))
        for i in range(0, len(vals), 16):
            f.write("  " + ", ".join(str(v) for v in vals[i:i + 16]) + ",\n")
        f.write("]\n")
    for name, sname, n in tables:
        vals = grab(sname)
        assert len(vals) == n, (sname, len(vals), n)
        emit(name, vals, sname)
    for name, sname, nsym, entries in cdfs:
        vals = grab(sname)
        # Each entry: N cdf values (last 32768) + a count.
        assert len(vals) == entries * (nsym + 1), (sname, len(vals), entries * (nsym + 1))
        for e in range(entries):
            ent = vals[e * (nsym + 1):(e + 1) * (nsym + 1)]
            assert ent[nsym - 1] == 32768 and ent[nsym] == 0, (sname, e, ent)
        emit(name, vals, "%s (%d symbols per entry, + count)" % (sname, nsym))
print("ok")
