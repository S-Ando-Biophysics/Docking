#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

SITE_ROOT="02_SITE"


# ============================================================
# Find candidate sites
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

    if [[ -s "$DIR/candidate.sph" ]] &&
       [[ -s "$DIR/candidate_spheres.pdb" ]]; then

        VALID_SITES+=("$DIR")

    fi

done


if [[ "${#VALID_SITES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR:"
    echo "No candidate sphere sets were found."
    echo
    echo "Run:"
    echo
    echo "  bash 02a_generate_spheres.sh"
    echo

    exit 1

fi


# ============================================================
# Display sites
# ============================================================

echo
echo "============================================================"
echo " Candidate sphere sets"
echo "============================================================"
echo


for i in "${!VALID_SITES[@]}"; do

    DIR="${VALID_SITES[$i]}"

    NAME="$(
        basename "$DIR"
    )"


    COUNT="$(
        python3 - "$DIR/candidate.sph" <<'PY'

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
        "  [%d] %-20s candidates=%s\n" \
        "$((i + 1))" \
        "$NAME" \
        "$COUNT"

done


echo


# ============================================================
# Select site
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


CANDIDATE_SPH="$OUTDIR/candidate.sph"

SITE_SPH="$OUTDIR/site.sph"
SITE_PDB="$OUTDIR/site_spheres.pdb"

SELECTION_FILE="$OUTDIR/selected_sphere_ids.txt"


# ============================================================
# Display instructions
# ============================================================

echo
echo "============================================================"
echo " Sphere selection"
echo "============================================================"
echo

echo "Site:"
echo
echo "  $SITE_NAME"
echo

echo "First inspect:"
echo
echo "  $OUTDIR/candidate_spheres.pdb"
echo

echo "Sphere IDs are the residue numbers in chain S"
echo "for custom / planar candidate PDB files."
echo

echo "Input examples:"
echo
echo "  1 2 3 4 8 9"
echo
echo "  1-10 15 20-25"
echo
echo "  all"
echo


# ============================================================
# Get valid sphere IDs
# ============================================================

mapfile -t VALID_IDS < <(
    python3 - "$CANDIDATE_SPH" <<'PY'

from pathlib import Path
import sys

for line in Path(sys.argv[1]).read_text().splitlines():

    fields = line.split()

    if len(fields) < 5:
        continue

    try:
        sphere_id = int(fields[0])

        float(fields[1])
        float(fields[2])
        float(fields[3])
        float(fields[4])

    except ValueError:
        continue

    print(sphere_id)

PY
)


TOTAL="${#VALID_IDS[@]}"


echo "Candidate sphere count:"
echo
echo "  $TOTAL"
echo


# ============================================================
# Input sphere IDs
# ============================================================

read -r -p \
    "Sphere IDs to keep: " \
    SELECTION


if [[ -z "$SELECTION" ]]; then

    echo
    echo "ERROR: Empty selection."
    echo

    exit 1

fi


# ============================================================
# Parse ranges / write selected site
# ============================================================

python3 - \
    "$CANDIDATE_SPH" \
    "$SITE_SPH" \
    "$SITE_PDB" \
    "$SELECTION_FILE" \
    "$SELECTION" <<'PY'

from pathlib import Path
import sys
import re

source = Path(sys.argv[1])

out_sph = Path(sys.argv[2])
out_pdb = Path(sys.argv[3])
selection_file = Path(sys.argv[4])

selection_text = sys.argv[5].strip()

spheres = {}

for line in source.read_text().splitlines():

    fields = line.split()

    if len(fields) < 5:
        continue

    try:

        sphere_id = int(fields[0])

        x = float(fields[1])
        y = float(fields[2])
        z = float(fields[3])
        radius = float(fields[4])

    except ValueError:

        continue

    spheres[sphere_id] = (
        x,
        y,
        z,
        radius,
    )

if not spheres:
    raise SystemExit(
        "ERROR: No candidate spheres found."
    )

if selection_text.lower() == "all":

    selected_ids = sorted(
        spheres
    )

else:

    selected = set()

    for token in re.split(
        r"[\s,]+",
        selection_text,
    ):

        if not token:
            continue

        if "-" in token:

            parts = token.split(
                "-",
                1,
            )

            try:
                start = int(parts[0])
                end = int(parts[1])
            except ValueError:
                raise SystemExit(
                    f"ERROR: Invalid range: {token}"
                )

            if start > end:
                start, end = end, start

            selected.update(
                range(
                    start,
                    end + 1,
                )
            )

        else:

            try:
                selected.add(
                    int(token)
                )
            except ValueError:

                raise SystemExit(
                    f"ERROR: Invalid ID: {token}"
                )

    unknown = (
        selected
        - set(spheres)
    )

    if unknown:

        raise SystemExit(
            "ERROR: Unknown sphere IDs: "
            + " ".join(
                map(
                    str,
                    sorted(unknown),
                )
            )
        )

    selected_ids = sorted(
        selected
    )

if not selected_ids:
    raise SystemExit(
        "ERROR: No spheres selected."
    )

with selection_file.open("w") as f:

    for sphere_id in selected_ids:
        f.write(
            f"{sphere_id}\n"
        )

with out_sph.open("w") as f:

    f.write(
        "cluster     1   number of spheres in cluster"
        f"{len(selected_ids):6d}\n"
    )

    for new_id, old_id in enumerate(
        selected_ids,
        1
    ):

        x, y, z, radius = spheres[old_id]

        f.write(
            f"{new_id:5d}"
            f"{x:10.5f}"
            f"{y:10.5f}"
            f"{z:10.5f}"
            f"{radius:8.3f}"
            f"{0:5d}"
            f"{0:2d}"
            f"{0:2d}\n"
        )

with out_pdb.open("w") as f:

    for new_id, old_id in enumerate(
        selected_ids,
        1
    ):

        x, y, z, radius = spheres[old_id]

        f.write(
            f"HETATM{new_id:5d}  C   SPH S{new_id:4d}    "
            f"{x:8.3f}"
            f"{y:8.3f}"
            f"{z:8.3f}"
            f"  1.00"
            f"{old_id:6.2f}"
            f"           C\n"
        )

    f.write("END\n")

print()
print(
    f"Candidate spheres : {len(spheres)}"
)

print(
    f"Selected spheres  : {len(selected_ids)}"
)

print()

print(
    "Original IDs:"
)

print(
    "  "
    + " ".join(
        map(
            str,
            selected_ids,
        )
    )
)

PY


# ============================================================
# Result
# ============================================================

SELECTED_COUNT="$(
    grep -c '^HETATM' "$SITE_PDB"
)"


echo
echo "============================================================"
echo " Sphere selection completed"
echo "============================================================"
echo

echo "Selected spheres:"
echo
echo "  $SELECTED_COUNT"
echo

echo "DOCK sphere file:"
echo
echo "  $SITE_SPH"
echo

echo "Visualization:"
echo
echo "  $SITE_PDB"
echo

echo "Original selected IDs:"
echo
echo "  $SELECTION_FILE"
echo

echo "Check the result visually in Chimera."
echo
echo "If satisfied:"
echo
echo "  bash 02c_make_box.sh"
echo
