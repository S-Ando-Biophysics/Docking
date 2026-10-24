#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

PREP_DIR="01_PREPARE"
DOCK_ROOT="04_DOCKING"
OUTPUT_ROOT="05_OUTPUT"

TARGET_PDB="$PREP_DIR/target_input.pdb"


# ============================================================
# Dependency check
# ============================================================

if ! command -v python3 >/dev/null 2>&1; then
    echo
    echo "ERROR: python3 was not found."
    echo
    exit 1
fi


# ============================================================
# Check target PDB
# ============================================================

if [[ ! -s "$TARGET_PDB" ]]; then
    echo
    echo "ERROR: Target PDB was not found:"
    echo
    echo "  $TARGET_PDB"
    echo
    echo "Run 01a_prepare_target.sh first."
    echo
    exit 1
fi


# ============================================================
# Find docking sites
# ============================================================

if [[ ! -d "$DOCK_ROOT" ]]; then
    echo
    echo "ERROR: Docking directory was not found:"
    echo
    echo "  $DOCK_ROOT"
    echo
    echo "Run 04_docking.sh first."
    echo
    exit 1
fi


mapfile -t SITE_DIRS < <(
    find "$DOCK_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        | sort
)


if [[ "${#SITE_DIRS[@]}" -eq 0 ]]; then
    echo
    echo "ERROR: No docking site directories were found."
    echo
    exit 1
fi


echo
echo "============================================================"
echo " DOCK6 export"
echo "============================================================"
echo

echo "Available docking sites:"
echo

for i in "${!SITE_DIRS[@]}"; do
    printf "  [%d] %s\n" \
        "$((i + 1))" \
        "$(basename "${SITE_DIRS[$i]}")"
done

echo


while true; do
    read -r -p "Select site [1-${#SITE_DIRS[@]}]: " SITE_CHOICE

    if [[ "$SITE_CHOICE" =~ ^[0-9]+$ ]] &&
       (( SITE_CHOICE >= 1 )) &&
       (( SITE_CHOICE <= ${#SITE_DIRS[@]} )); then
        break
    fi

    echo "Invalid selection."
done


SITE_DIR="${SITE_DIRS[$((SITE_CHOICE - 1))]}"
SITE_NAME="$(basename "$SITE_DIR")"


# ============================================================
# Find docking modes
# ============================================================

VALID_MODE_DIRS=()

for mode in rigid flex; do
    if [[ -d "$SITE_DIR/$mode" ]]; then
        VALID_MODE_DIRS+=("$SITE_DIR/$mode")
    fi
done


if [[ "${#VALID_MODE_DIRS[@]}" -eq 0 ]]; then
    echo
    echo "ERROR: No rigid/flex docking directories were found in:"
    echo
    echo "  $SITE_DIR"
    echo
    exit 1
fi


echo
echo "Available docking modes:"
echo

for i in "${!VALID_MODE_DIRS[@]}"; do
    printf "  [%d] %s\n" \
        "$((i + 1))" \
        "$(basename "${VALID_MODE_DIRS[$i]}")"
done

echo


while true; do
    read -r -p "Select mode [1-${#VALID_MODE_DIRS[@]}]: " MODE_CHOICE

    if [[ "$MODE_CHOICE" =~ ^[0-9]+$ ]] &&
       (( MODE_CHOICE >= 1 )) &&
       (( MODE_CHOICE <= ${#VALID_MODE_DIRS[@]} )); then
        break
    fi

    echo "Invalid selection."
done


MODE_DIR="${VALID_MODE_DIRS[$((MODE_CHOICE - 1))]}"
MODE_NAME="$(basename "$MODE_DIR")"


# ============================================================
# Find DOCK6 scored-pose MOL2
# ============================================================

mapfile -t MOL2_CANDIDATES < <(
    find "$MODE_DIR" \
        -maxdepth 1 \
        -type f \
        -iname "*.mol2" \
        | sort
)


if [[ "${#MOL2_CANDIDATES[@]}" -eq 0 ]]; then
    echo
    echo "ERROR: No MOL2 files were found in:"
    echo
    echo "  $MODE_DIR"
    echo
    exit 1
fi


POSE_SOURCE=""

for f in "${MOL2_CANDIDATES[@]}"; do
    base="$(basename "$f")"

    case "$base" in
        *scored*.mol2|*dock*.mol2|*pose*.mol2)
            POSE_SOURCE="$f"
            break
            ;;
    esac
done


if [[ -z "$POSE_SOURCE" && "${#MOL2_CANDIDATES[@]}" -eq 1 ]]; then
    POSE_SOURCE="${MOL2_CANDIDATES[0]}"
fi


if [[ -z "$POSE_SOURCE" ]]; then
    echo
    echo "Multiple MOL2 files were found:"
    echo

    for i in "${!MOL2_CANDIDATES[@]}"; do
        printf "  [%d] %s\n" \
            "$((i + 1))" \
            "$(basename "${MOL2_CANDIDATES[$i]}")"
    done

    echo

    while true; do
        read -r -p "Select scored-pose MOL2 [1-${#MOL2_CANDIDATES[@]}]: " MOL2_CHOICE

        if [[ "$MOL2_CHOICE" =~ ^[0-9]+$ ]] &&
           (( MOL2_CHOICE >= 1 )) &&
           (( MOL2_CHOICE <= ${#MOL2_CANDIDATES[@]} )); then
            break
        fi

        echo "Invalid selection."
    done

    POSE_SOURCE="${MOL2_CANDIDATES[$((MOL2_CHOICE - 1))]}"
fi


if [[ ! -s "$POSE_SOURCE" ]]; then
    echo
    echo "ERROR: Selected scored-pose MOL2 is empty."
    echo
    exit 1
fi


# ============================================================
# Output directory
# ============================================================

OUTDIR="$OUTPUT_ROOT/$SITE_NAME/$MODE_NAME"
POSE_DIR="$OUTDIR/poses"

mkdir -p "$POSE_DIR"

rm -f "$OUTDIR/target_input.pdb"
rm -f "$OUTDIR/all_scored_poses.mol2"
rm -f "$POSE_DIR"/pose_*.mol2 2>/dev/null || true


# ============================================================
# Copy unchanged source files
# ============================================================

cp "$TARGET_PDB" "$OUTDIR/target_input.pdb"
cp "$POSE_SOURCE" "$OUTDIR/all_scored_poses.mol2"


# ============================================================
# Split all poses into individual MOL2 files
#
# No coordinate conversion.
# No atom-type conversion.
# No element conversion.
# ============================================================

python3 - \
    "$OUTDIR/all_scored_poses.mol2" \
    "$POSE_DIR" <<'PY'

from pathlib import Path
import sys


all_poses_file = Path(sys.argv[1])
pose_dir = Path(sys.argv[2])


text = all_poses_file.read_text()
lines = text.splitlines()


starts = [
    i
    for i, line in enumerate(lines)
    if line.strip() == "@<TRIPOS>MOLECULE"
]


if not starts:
    raise RuntimeError(
        "No @<TRIPOS>MOLECULE sections were found."
    )


pose_count = 0


for i, start in enumerate(starts, 1):
    end = (
        starts[i]
        if i < len(starts)
        else len(lines)
    )

    # Keep DOCK6 metadata before the first pose.
    begin = 0 if i == 1 else start

    block = (
        "\n".join(
            lines[begin:end]
        ).strip()
        + "\n"
    )

    pose_path = (
        pose_dir
        / f"pose_{i:03d}.mol2"
    )

    pose_path.write_text(
        block
    )

    pose_count += 1


print(
    f"POSE_COUNT={pose_count}"
)

PY


# ============================================================
# Verify outputs
# ============================================================

POSE_COUNT="$(
    find "$POSE_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'pose_*.mol2' \
        | wc -l
)"


if [[ "$POSE_COUNT" -eq 0 ]]; then
    echo
    echo "ERROR: No individual pose MOL2 files were generated."
    echo
    exit 1
fi


# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo " Export completed"
echo "============================================================"
echo

echo "Site:"
echo "  $SITE_NAME"
echo

echo "Mode:"
echo "  $MODE_NAME"
echo

echo "Target PDB:"
echo "  $OUTDIR/target_input.pdb"
echo

echo "All scored poses:"
echo "  $OUTDIR/all_scored_poses.mol2"
echo

echo "Individual poses:"
echo "  $POSE_DIR/"
echo "  count: $POSE_COUNT"
echo

echo "Output structure:"
echo
echo "  $OUTDIR/"
echo "  ├── target_input.pdb"
echo "  ├── all_scored_poses.mol2"
echo "  └── poses/"
echo "      ├── pose_001.mol2"
echo "      └── ..."
echo
