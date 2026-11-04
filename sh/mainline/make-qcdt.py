#!/usr/bin/env python3
"""Create the legacy Qualcomm QCDT v2 table consumed by lk2nd for Aljeter (MSM8937/MSM8920)."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


QCDT_MAGIC = 0x54444351  # bytes: QCDT
QCDT_VERSION = 2
HEADER_SIZE = 12
ENTRY_SIZE = 24

# Board tuples for Moto G6 Play (aljeter / jeter):
# Covers MSM8937 (platform 294 / 0x126) and MSM8920 (platform 320 / 0x140).
ALJETER_BOARD_PAIRS = (
    (0x8, 0x0),       # Generic Qualcomm MTP/test tuple
    (0x4A, 0x8100),   # Jeter/Aljeter MSM8937 revision 1
    (0x4A, 0x8000),   # Jeter/Aljeter MSM8937 revision 0
    (0x4B, 0x8000),   # Jeter/Aljeter MSM8937 revision 2
    (0x43, 0x8000),   # Jeter/Aljeter MSM8920
    (0x43, 0x83A0),   # Jeter/Aljeter MSM8920
)


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("dtb", type=Path)
    parser.add_argument("--page-size", type=int, default=2048)
    parser.add_argument("--msm-id", type=lambda value: int(value, 0), default=294)
    parser.add_argument("--board-id", type=lambda value: int(value, 0), default=None)
    parser.add_argument("--board-subtype", type=lambda value: int(value, 0), default=None)
    parser.add_argument("--soc-rev", type=lambda value: int(value, 0), default=0)
    args = parser.parse_args()

    if args.page_size <= 0 or args.page_size & (args.page_size - 1):
        parser.error("--page-size must be a positive power of two")

    dtb_data = args.dtb.read_bytes()
    if len(dtb_data) < 4 or dtb_data[:4] != b"\xd0\x0d\xfe\xed":
        parser.error(f"Not a valid flattened device tree: {args.dtb}")

    if args.board_id is None and args.board_subtype is None:
        tuples = [(args.msm_id, board, subtype, args.soc_rev)
                  for board, subtype in ALJETER_BOARD_PAIRS]
        # Also emit MSM8920 (320) board pairs for cross-SoC compatibility
        tuples.extend([(320, board, subtype, args.soc_rev)
                       for board, subtype in ALJETER_BOARD_PAIRS if board == 0x43])
    elif args.board_id is not None and args.board_subtype is not None:
        tuples = [(args.msm_id, args.board_id, args.board_subtype, args.soc_rev)]
    else:
        parser.error("Specify both --board-id and --board-subtype or neither")

    header_block_size = align(HEADER_SIZE + len(tuples) * ENTRY_SIZE + 4, args.page_size)
    dtb_offset = header_block_size
    dtb_size = len(dtb_data)

    out = bytearray()
    out.extend(struct.pack("<3I", QCDT_MAGIC, QCDT_VERSION, len(tuples)))
    for platform, board, subtype, rev in tuples:
        out.extend(struct.pack("<6I", platform, board, subtype, rev, dtb_offset, dtb_size))
    out.extend(b"\x00\x00\x00\x00")  # End of table marker
    if len(out) < header_block_size:
        out.extend(b"\x00" * (header_block_size - len(out)))

    out.extend(dtb_data)
    aligned_total = align(len(out), args.page_size)
    if len(out) < aligned_total:
        out.extend(b"\x00" * (aligned_total - len(out)))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(out)


if __name__ == "__main__":
    main()
