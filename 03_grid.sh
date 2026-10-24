#!/usr/bin/env bash

set -euo pipefail


# ============================================================
# Move to project directory
# ============================================================

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

PREP_DIR="01_PREPARE"
SITE_ROOT="02_SITE"
GRID_ROOT="03_GRID"

RECEPTOR_FILE="$PREP_DIR/target_DOCK.mol2"

DEFAULT_GRID_SPACING="0.3"
DEFAULT_ENERGY_CUTOFF="10.0"
DEFAULT_DIELECTRIC_FACTOR="4.0"
DEFAULT_BUMP_OVERLAP="0.75"

mkdir -p "$GRID_ROOT"


# ============================================================
# Start
# ============================================================

echo
echo "============================================================"
echo " DOCK6 GRID generation"
echo "============================================================"
echo


# ============================================================
# Dependency check
# ============================================================

if ! command -v grid >/dev/null 2>&1; then

    echo
    echo "ERROR: grid was not found."
    echo

    exit 1

fi


echo "GRID executable:"
echo
echo "  $(command -v grid)"
echo


# ============================================================
# Check receptor
# ============================================================

if [[ ! -s "$RECEPTOR_FILE" ]]; then

    echo
    echo "ERROR: Receptor MOL2 was not found:"
    echo
    echo "  $RECEPTOR_FILE"
    echo
    echo "Run 01_prepare_target.sh first."
    echo

    exit 1

fi


# ============================================================
# Find DOCK6 directory
# ============================================================

GRID_BIN="$(
    command -v grid
)"

GRID_BIN="$(
    realpath "$GRID_BIN"
)"


DOCK_BIN_DIR="$(
    dirname "$GRID_BIN"
)"


DOCK_HOME="$(
    dirname "$DOCK_BIN_DIR"
)"


echo "Detected DOCK6 home:"
echo
echo "  $DOCK_HOME"
echo


# ============================================================
# Find VDW definition file
# ============================================================

VDW_DEF=""


CANDIDATES=(
    "$DOCK_HOME/parameters/vdw_AMBER_parm99.defn"
    "$DOCK_HOME/parameters/vdw.defn"
)


for FILE in "${CANDIDATES[@]}"; do

    if [[ -s "$FILE" ]]; then

        VDW_DEF="$FILE"
        break

    fi

done


if [[ -z "$VDW_DEF" ]]; then

    echo
    echo "ERROR:"
    echo "VDW definition file was not found."
    echo
    echo "Expected one of:"
    echo

    for FILE in "${CANDIDATES[@]}"; do
        echo "  $FILE"
    done

    echo
    echo "Search manually with:"
    echo
    echo "  find \"$DOCK_HOME\" -name 'vdw*.defn'"
    echo

    exit 1

fi


VDW_DEF="$(
    realpath "$VDW_DEF"
)"


echo "VDW definition file:"
echo
echo "  $VDW_DEF"
echo


# ============================================================
# Find available sites
#
# A valid site directory must contain:
#
#   site_box.pdb
#   site.sph
# ============================================================

if [[ ! -d "$SITE_ROOT" ]]; then

    echo
    echo "ERROR: Site directory was not found:"
    echo
    echo "  $SITE_ROOT"
    echo
    echo "Run 02c_make_box.sh first."
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

    if [[ -s "$DIR/site_box.pdb" ]] &&
       [[ -s "$DIR/site.sph" ]]; then

        VALID_SITES+=("$DIR")

    fi

done


if [[ "${#VALID_SITES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR:"
    echo "No valid sites were found in:"
    echo
    echo "  $SITE_ROOT"
    echo
    echo "A valid site requires:"
    echo
    echo "  site.sph"
    echo "  site_box.pdb"
    echo

    exit 1

fi


# ============================================================
# Show available sites
# ============================================================

echo
echo "============================================================"
echo " Available docking sites"
echo "============================================================"
echo


for i in "${!VALID_SITES[@]}"; do

    DIR="${VALID_SITES[$i]}"

    NAME="$(
        basename "$DIR"
    )"


    SPHERE_COUNT="$(
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
        "$SPHERE_COUNT"

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


SITE_DIR="$(
    realpath "${VALID_SITES[$((SITE_CHOICE - 1))]}"
)"


SITE_NAME="$(
    basename "$SITE_DIR"
)"


BOX_FILE="$SITE_DIR/site_box.pdb"
SITE_SPH="$SITE_DIR/site.sph"


echo
echo "Selected site:"
echo
echo "  $SITE_NAME"
echo

echo "Box:"
echo
echo "  $BOX_FILE"
echo


# ============================================================
# Output directory
# ============================================================

OUTDIR="$GRID_ROOT/$SITE_NAME"


if [[ -d "$OUTDIR" ]] &&
   [[ -n "$(
       find "$OUTDIR" \
           -mindepth 1 \
           -maxdepth 1 \
           -print \
           -quit \
           2>/dev/null
   )" ]]; then

    echo
    echo "WARNING:"
    echo
    echo "GRID directory already contains files:"
    echo
    echo "  $OUTDIR"
    echo

    read -r -p \
        "Overwrite existing GRID calculation? [y/N]: " \
        ANSWER


    case "$ANSWER" in

        y|Y|yes|YES)

            rm -rf "$OUTDIR"
            ;;

        *)

            echo
            echo "Cancelled."
            echo

            exit 0
            ;;

    esac

fi


mkdir -p "$OUTDIR"


# ============================================================
# Files
# ============================================================

GRID_IN="$OUTDIR/grid.in"
GRID_OUT="$OUTDIR/grid.out"

GRID_PREFIX="site_grid"

GRID_NRG="$OUTDIR/${GRID_PREFIX}.nrg"
GRID_BMP="$OUTDIR/${GRID_PREFIX}.bmp"

SUMMARY="$OUTDIR/grid_summary.txt"


# ============================================================
# Absolute paths
#
# Official DOCK6 tutorial recommends full paths.
# ============================================================

RECEPTOR_ABS="$(
    realpath "$RECEPTOR_FILE"
)"


BOX_ABS="$(
    realpath "$BOX_FILE"
)"


# ============================================================
# Fixed GRID parameters
# ============================================================

GRID_SPACING="$DEFAULT_GRID_SPACING"
ENERGY_CUTOFF="$DEFAULT_ENERGY_CUTOFF"

echo
echo "============================================================"
echo " GRID parameters (fixed defaults)"
echo "============================================================"
echo
echo "  grid_spacing               : $GRID_SPACING Å"
echo "  energy_cutoff_distance     : $ENERGY_CUTOFF Å"
echo "  atom_model                 : a"
echo "  attractive_exponent        : 6"
echo "  repulsive_exponent         : 12"
echo "  distance_dielectric        : yes"
echo "  dielectric_factor          : $DEFAULT_DIELECTRIC_FACTOR"
echo "  bump_filter                : yes"
echo "  bump_overlap               : $DEFAULT_BUMP_OVERLAP"
echo "  allow_non_integral_charges : yes"
echo


# ============================================================
# Generate grid.in
# ============================================================

cat > "$GRID_IN" <<EOF
compute_grids                  yes
grid_spacing                   ${GRID_SPACING}
output_molecule                no
contact_score                  no
energy_score                   yes
energy_cutoff_distance         ${ENERGY_CUTOFF}
atom_model                     a
attractive_exponent            6
repulsive_exponent             12
distance_dielectric            yes
dielectric_factor              ${DEFAULT_DIELECTRIC_FACTOR}
bump_filter                    yes
bump_overlap                   ${DEFAULT_BUMP_OVERLAP}
receptor_file                  ${RECEPTOR_ABS}
box_file                       ${BOX_ABS}
vdw_definition_file            ${VDW_DEF}
score_grid_prefix              ${GRID_PREFIX}
allow_non_integral_charges     yes
EOF


# ============================================================
# Show input
# ============================================================

echo
echo "------------------------------------------------------------"
echo " GRID input"
echo "------------------------------------------------------------"
echo

cat "$GRID_IN"

echo


# ============================================================
# Confirm box geometry
# ============================================================

BOX_INFO="$(
    python3 - "$BOX_FILE" <<'PY'

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

        x = float(line[30:38])
        y = float(line[38:46])
        z = float(line[46:54])

    except ValueError:

        continue


    coords.append(
        (
            x,
            y,
            z,
        )
    )


if not coords:

    print("unknown")
    raise SystemExit(0)


xs = [p[0] for p in coords]
ys = [p[1] for p in coords]
zs = [p[2] for p in coords]


xmin = min(xs)
xmax = max(xs)

ymin = min(ys)
ymax = max(ys)

zmin = min(zs)
zmax = max(zs)


cx = (xmin + xmax) / 2.0
cy = (ymin + ymax) / 2.0
cz = (zmin + zmax) / 2.0


dx = xmax - xmin
dy = ymax - ymin
dz = zmax - zmin


print(
    f"center=({cx:.3f}, {cy:.3f}, {cz:.3f}); "
    f"dimensions=({dx:.3f}, {dy:.3f}, {dz:.3f}) A"
)

PY
)"


echo "Grid box:"
echo
echo "  $BOX_INFO"
echo


# ============================================================
# Estimate number of grid points
#
# This is only an estimate before running GRID.
# ============================================================

ESTIMATED_POINTS="$(
    python3 - \
        "$BOX_FILE" \
        "$GRID_SPACING" <<'PY'

from pathlib import Path
import sys
import math


box = Path(sys.argv[1])
spacing = float(sys.argv[2])

coords = []


for line in box.read_text().splitlines():

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

        continue


if not coords:

    print("unknown")
    raise SystemExit(0)


xs = [x for x, y, z in coords]
ys = [y for x, y, z in coords]
zs = [z for x, y, z in coords]


dx = max(xs) - min(xs)
dy = max(ys) - min(ys)
dz = max(zs) - min(zs)


nx = math.ceil(dx / spacing) + 1
ny = math.ceil(dy / spacing) + 1
nz = math.ceil(dz / spacing) + 1


total = nx * ny * nz


print(
    f"{nx} x {ny} x {nz} "
    f"({total:,} points)"
)

PY
)"


echo "Estimated grid size:"
echo
echo "  $ESTIMATED_POINTS"
echo


# ============================================================
# Run GRID
# ============================================================

echo "============================================================"
echo " Running GRID"
echo "============================================================"
echo


(
    cd "$OUTDIR"

    rm -f \
        "${GRID_PREFIX}.nrg" \
        "${GRID_PREFIX}.bmp" \
        grid.out


    grid \
        -i grid.in \
        -o grid.out
)


# ============================================================
# Validate output
# ============================================================

if [[ ! -s "$GRID_NRG" ]]; then

    echo
    echo "ERROR:"
    echo "Energy grid was not generated:"
    echo
    echo "  $GRID_NRG"
    echo
    echo "Check:"
    echo
    echo "  $GRID_OUT"
    echo

    exit 1

fi


if [[ ! -s "$GRID_BMP" ]]; then

    echo
    echo "ERROR:"
    echo "Bump grid was not generated:"
    echo
    echo "  $GRID_BMP"
    echo
    echo "Check:"
    echo
    echo "  $GRID_OUT"
    echo

    exit 1

fi


# ============================================================
# Check for successful completion
# ============================================================

if ! grep -q \
    "Finished calculation" \
    "$GRID_OUT"
then

    echo
    echo "WARNING:"
    echo
    echo "'Finished calculation' was not found in grid.out."
    echo
    echo "Inspect:"
    echo
    echo "  $GRID_OUT"
    echo

fi


# ============================================================
# Check GRID output for errors / warnings
# ============================================================

ERROR_COUNT="$(
    grep -ci \
        "error" \
        "$GRID_OUT" \
        || true
)"


WARNING_COUNT="$(
    grep -ci \
        "warning" \
        "$GRID_OUT" \
        || true
)"


# ============================================================
# Extract important GRID information
# ============================================================

GRID_REPORT="$(
    grep -E \
        'Total charge|Box center|Box dimensions|Number of grid points|Finished calculation' \
        "$GRID_OUT" \
        || true
)"


echo
echo "------------------------------------------------------------"
echo " GRID result"
echo "------------------------------------------------------------"
echo


if [[ -n "$GRID_REPORT" ]]; then

    printf '%s\n' "$GRID_REPORT"

else

    echo "No standard GRID summary lines were detected."

fi


echo


# ============================================================
# Output file sizes
# ============================================================

NRG_SIZE="$(
    du -h "$GRID_NRG" \
    | awk '{print $1}'
)"


BMP_SIZE="$(
    du -h "$GRID_BMP" \
    | awk '{print $1}'
)"


# ============================================================
# Write summary
# ============================================================

{
    echo "============================================================"
    echo " DOCK6 GRID generation summary"
    echo "============================================================"
    echo

    echo "[Site]"
    echo "Site name              : $SITE_NAME"
    echo "Site directory         : $SITE_DIR"
    echo "Site spheres           : $SITE_SPH"
    echo "Box                    : $BOX_FILE"
    echo "Box geometry           : $BOX_INFO"
    echo

    echo "[Receptor]"
    echo "Receptor MOL2          : $RECEPTOR_FILE"
    echo

    echo "[GRID parameters]"
    echo "Grid spacing           : $GRID_SPACING Å"
    echo "Energy cutoff          : $ENERGY_CUTOFF Å"
    echo "Atom model             : all atom"
    echo "Attractive exponent    : 6"
    echo "Repulsive exponent     : 12"
    echo "Distance dielectric    : yes"
    echo "Dielectric factor      : $DEFAULT_DIELECTRIC_FACTOR"
    echo "Bump filter            : yes"
    echo "Bump overlap           : $DEFAULT_BUMP_OVERLAP"
    echo "Non-integral charges   : allowed"
    echo

    echo "[VDW]"
    echo "Definition file        : $VDW_DEF"
    echo

    echo "[Estimated grid]"
    echo "Grid points            : $ESTIMATED_POINTS"
    echo

    echo "[GRID output]"
    echo "Errors matching text   : $ERROR_COUNT"
    echo "Warnings matching text : $WARNING_COUNT"
    echo

    echo "$GRID_REPORT"
    echo

    echo "[Files]"
    echo "GRID input             : $GRID_IN"
    echo "GRID output            : $GRID_OUT"
    echo "Energy grid            : $GRID_NRG"
    echo "Bump grid              : $GRID_BMP"
    echo "Energy grid size       : $NRG_SIZE"
    echo "Bump grid size         : $BMP_SIZE"

} > "$SUMMARY"


# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo " GRID generation completed"
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

echo "Grid spacing:"
echo
echo "  $GRID_SPACING Å"
echo

echo "Generated files:"
echo
echo "  Energy grid:"
echo "    $GRID_NRG"
echo "    size = $NRG_SIZE"
echo

echo "  Bump grid:"
echo "    $GRID_BMP"
echo "    size = $BMP_SIZE"
echo

echo "  GRID log:"
echo "    $GRID_OUT"
echo

echo "  Summary:"
echo "    $SUMMARY"
echo

echo "Files for the next docking step:"
echo
echo "  Site spheres:"
echo "    $SITE_SPH"
echo

echo "  Grid prefix:"
echo "    $OUTDIR/$GRID_PREFIX"
echo