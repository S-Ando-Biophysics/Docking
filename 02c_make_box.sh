#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

SITE_ROOT="02_SITE"
PREP_DIR="01_PREPARE"
TARGET_PDB="$PREP_DIR/target_input.pdb"

DEFAULT_BOX_MARGIN="4.0"


# ============================================================
# Dependency
# ============================================================

for CMD in showbox python3; do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo
        echo "ERROR: $CMD was not found."
        echo

        exit 1

    fi

done


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
# Find selectable sites
# ============================================================

if [[ ! -d "$SITE_ROOT" ]]; then

    echo
    echo "ERROR:"
    echo "Site directory was not found:"
    echo
    echo "  $SITE_ROOT"
    echo

    exit 1

fi


mapfile -t SITE_DIRS < <(
    find "$SITE_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        | sort
)


VALID_SITES=()


for DIR in "${SITE_DIRS[@]}"; do

    if [[ -s "$DIR/site.sph" ]]; then
        VALID_SITES+=("$DIR")
    fi

done


if [[ "${#VALID_SITES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR: No selected site.sph files found."
    echo
    echo "Run:"
    echo
    echo "  bash 02b_select_spheres.sh"
    echo

    exit 1

fi


# ============================================================
# Display
# ============================================================

echo
echo "============================================================"
echo " Available selected sites"
echo "============================================================"
echo


for i in "${!VALID_SITES[@]}"; do

    DIR="${VALID_SITES[$i]}"

    NAME="$(
        basename "$DIR"
    )"


    COUNT="$(
        python3 - "$DIR/site.sph" <<'PY'

from pathlib import Path
import sys

count = 0

for line in Path(sys.argv[1]).read_text().splitlines():

    fields = line.split()

    if len(fields) < 5:
        continue

    try:
        int(fields[0])
        float(fields[1])
        float(fields[2])
        float(fields[3])
        float(fields[4])
    except ValueError:
        continue

    count += 1

print(count)

PY
    )"


    printf \
        "  [%d] %-20s spheres=%s\n" \
        "$((i + 1))" \
        "$NAME" \
        "$COUNT"

done


echo


# ============================================================
# Select
# ============================================================

while true; do

    read -r -p \
        "Select site [1-${#VALID_SITES[@]}]: " \
        SITE_CHOICE


    if [[ "$SITE_CHOICE" =~ ^[0-9]+$ ]] &&
       (( SITE_CHOICE >= 1 )) &&
       (( SITE_CHOICE <= ${#VALID_SITES[@]} )); then

        break

    fi


    echo "Invalid selection."

done


OUTDIR="${VALID_SITES[$((SITE_CHOICE - 1))]}"

SITE_NAME="$(
    basename "$OUTDIR"
)"


SITE_REFERENCE_PDB="$OUTDIR/site_reference.pdb"

if [[ ! -s "$SITE_REFERENCE_PDB" ]]; then

    echo
    echo "ERROR: site_reference.pdb was not found:"
    echo
    echo "  $SITE_REFERENCE_PDB"
    echo
    echo "Run 02a_generate_spheres.sh for this site first."
    echo

    exit 1

fi

TARGET_WITH_BOX="$OUTDIR/target_with_box.pdb"
SITE_REFERENCE_WITH_BOX="$OUTDIR/site_reference_with_box.pdb"


# ============================================================
# Margin
# ============================================================

echo

read -r -p \
    "Grid-box margin [Å] ($DEFAULT_BOX_MARGIN): " \
    BOX_MARGIN


BOX_MARGIN="${BOX_MARGIN:-$DEFAULT_BOX_MARGIN}"


# ============================================================
# showbox input
# ============================================================

cat > "$OUTDIR/showbox.in" <<EOF
Y
${BOX_MARGIN}
site.sph
1
site_box.pdb
EOF


echo
echo "============================================================"
echo " Running SHOWBOX"
echo "============================================================"
echo

echo "Site:"
echo
echo "  $SITE_NAME"
echo

echo "Margin:"
echo
echo "  $BOX_MARGIN Å"
echo


(
    cd "$OUTDIR"

    rm -f \
        site_box.pdb \
        showbox.log

    showbox \
        < showbox.in \
        2>&1 \
        | tee showbox.log
)


# ============================================================
# Validate
# ============================================================

if [[ ! -s "$OUTDIR/site_box.pdb" ]]; then

    echo
    echo "ERROR: site_box.pdb was not generated."
    echo

    exit 1

fi


# ============================================================
# Create combined visualization PDB files
#
# 1) target_input.pdb + site_box.pdb
# 2) site_reference.pdb + site_box.pdb
#
# Coordinates are not modified.
# ATOM/HETATM serial numbers are renumbered consecutively.
# ============================================================

python3 - \
    "$TARGET_PDB" \
    "$SITE_REFERENCE_PDB" \
    "$OUTDIR/site_box.pdb" \
    "$TARGET_WITH_BOX" \
    "$SITE_REFERENCE_WITH_BOX" <<'PYCOMBINE'

from pathlib import Path
import sys


target = Path(sys.argv[1])
site_reference = Path(sys.argv[2])
box = Path(sys.argv[3])

target_out = Path(sys.argv[4])
site_out = Path(sys.argv[5])


def read_atoms(path):
    records = []

    for line in path.read_text().splitlines():

        if line.startswith("ATOM") or line.startswith("HETATM"):
            records.append(line)

    return records


def renumber_line(line, serial):
    if len(line) < 11:
        line = line.ljust(11)

    return (
        line[:6]
        + f"{serial:5d}"
        + line[11:]
    )


def write_combined(base_file, box_file, output_file):
    base_records = read_atoms(base_file)
    box_records = read_atoms(box_file)

    if not base_records:
        raise RuntimeError(
            f"No ATOM/HETATM records found in {base_file}"
        )

    if not box_records:
        raise RuntimeError(
            f"No ATOM/HETATM records found in {box_file}"
        )

    serial = 1

    with output_file.open("w") as f:

        f.write("REMARK   Combined visualization PDB\n")
        f.write(f"REMARK   Structure: {base_file.name}\n")
        f.write(f"REMARK   Box: {box_file.name}\n")
        f.write("REMARK   Coordinates are unchanged\n")

        for line in base_records:
            f.write(
                renumber_line(
                    line,
                    serial,
                )
                + "\n"
            )
            serial += 1

        f.write("TER\n")

        for line in box_records:
            f.write(
                renumber_line(
                    line,
                    serial,
                )
                + "\n"
            )
            serial += 1

        f.write("END\n")

    return (
        len(base_records),
        len(box_records),
    )


target_atoms, target_box_atoms = write_combined(
    target,
    box,
    target_out,
)

site_atoms, site_box_atoms = write_combined(
    site_reference,
    box,
    site_out,
)


print(
    f"target_with_box.pdb: "
    f"{target_atoms} target atoms + "
    f"{target_box_atoms} box atoms"
)

print(
    f"site_reference_with_box.pdb: "
    f"{site_atoms} reference atoms + "
    f"{site_box_atoms} box atoms"
)

PYCOMBINE


for COMBINED_PDB in \
    "$TARGET_WITH_BOX" \
    "$SITE_REFERENCE_WITH_BOX"
do

    if [[ ! -s "$COMBINED_PDB" ]]; then

        echo
        echo "ERROR: Combined PDB was not generated:"
        echo
        echo "  $COMBINED_PDB"
        echo

        exit 1

    fi

done


# ============================================================
# Box dimensions
# ============================================================

BOX_INFO="$(
    python3 - "$OUTDIR/site_box.pdb" <<'PY'

from pathlib import Path
import sys

coords = []

for line in Path(sys.argv[1]).read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue

    try:
        coords.append(
            (
                float(line[30:38]),
                float(line[38:46]),
                float(line[46:54]),
            )
        )

    except ValueError:
        pass

if not coords:
    print("unknown")
    raise SystemExit

xs = [p[0] for p in coords]
ys = [p[1] for p in coords]
zs = [p[2] for p in coords]

dx = max(xs) - min(xs)
dy = max(ys) - min(ys)
dz = max(zs) - min(zs)

cx = (
    min(xs) + max(xs)
) / 2

cy = (
    min(ys) + max(ys)
) / 2

cz = (
    min(zs) + max(zs)
) / 2

print(
    f"center=({cx:.3f}, {cy:.3f}, {cz:.3f}); "
    f"dimensions=({dx:.3f}, {dy:.3f}, {dz:.3f}) A"
)

PY
)"


# ============================================================
# Summary
# ============================================================

SUMMARY="$OUTDIR/box_summary.txt"

{
    echo "============================================================"
    echo " DOCK6 box generation summary"
    echo "============================================================"
    echo

    echo "Site                    : $SITE_NAME"
    echo "Margin                  : $BOX_MARGIN A"
    echo "Geometry                : $BOX_INFO"
    echo
    echo "Sphere file             : $OUTDIR/site.sph"
    echo "Box file                : $OUTDIR/site_box.pdb"
    echo "Target + box            : $TARGET_WITH_BOX"
    echo "Site reference + box    : $SITE_REFERENCE_WITH_BOX"
    echo "SHOWBOX input           : $OUTDIR/showbox.in"
    echo "SHOWBOX log             : $OUTDIR/showbox.log"

} > "$SUMMARY"


echo
echo "============================================================"
echo " Box generation completed"
echo "============================================================"
echo

echo "Site:"
echo
echo "  $SITE_NAME"
echo

echo "Box:"
echo
echo "  $BOX_INFO"
echo

echo "Output:"
echo
echo "  Box only:"
echo "    $OUTDIR/site_box.pdb"
echo
echo "  Target + box:"
echo "    $TARGET_WITH_BOX"
echo
echo "  Site reference + box:"
echo "    $SITE_REFERENCE_WITH_BOX"
echo

echo "Summary:"
echo
echo "  $SUMMARY"
echo

echo "Next:"
echo
echo "  bash 03_grid.sh"
echo
