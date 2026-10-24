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
DOCK_ROOT="04_DOCKING"

LIGAND_FILE="$PREP_DIR/LIG_DOCK.mol2"

DEFAULT_MAX_ORIENTATIONS="10000"
DEFAULT_NUM_FINAL_POSES="10"

mkdir -p "$DOCK_ROOT"


# ============================================================
# Start
# ============================================================

echo
echo "============================================================"
echo " DOCK6 docking"
echo "============================================================"
echo


# ============================================================
# Dependency check
# ============================================================

for CMD in \
    dock6 \
    python3
do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo
        echo "ERROR: $CMD was not found."
        echo

        exit 1

    fi

done


echo "DOCK6 executable:"
echo
echo "  $(command -v dock6)"
echo


# ============================================================
# Check ligand
# ============================================================

if [[ ! -s "$LIGAND_FILE" ]]; then

    echo
    echo "ERROR: Ligand MOL2 was not found:"
    echo
    echo "  $LIGAND_FILE"
    echo
    echo "Run 01_prepare_ligand.sh first."
    echo

    exit 1

fi


# ============================================================
# Detect DOCK6 home
# ============================================================

DOCK6_BIN="$(
    realpath "$(command -v dock6)"
)"

DOCK6_BIN_DIR="$(
    dirname "$DOCK6_BIN"
)"

DOCK6_HOME="$(
    dirname "$DOCK6_BIN_DIR"
)"


echo "Detected DOCK6 home:"
echo
echo "  $DOCK6_HOME"
echo


# ============================================================
# Parameter files
# ============================================================

VDW_DEF="$DOCK6_HOME/parameters/vdw_AMBER_parm99.defn"
FLEX_DEF="$DOCK6_HOME/parameters/flex.defn"


# Different DOCK6 installations may use one of these names.
FLEX_DRIVE=""


for CANDIDATE in \
    "$DOCK6_HOME/parameters/flex_drive.tbl" \
    "$DOCK6_HOME/parameters/flex_drive.defn"
do

    if [[ -s "$CANDIDATE" ]]; then

        FLEX_DRIVE="$CANDIDATE"
        break

    fi

done


if [[ ! -s "$VDW_DEF" ]]; then

    echo
    echo "ERROR: VDW definition file was not found:"
    echo
    echo "  $VDW_DEF"
    echo

    exit 1

fi


if [[ ! -s "$FLEX_DEF" ]]; then

    echo
    echo "ERROR: flex.defn was not found:"
    echo
    echo "  $FLEX_DEF"
    echo

    exit 1

fi


if [[ -z "$FLEX_DRIVE" ]]; then

    echo
    echo "ERROR: flex drive file was not found."
    echo
    echo "Checked:"
    echo
    echo "  $DOCK6_HOME/parameters/flex_drive.tbl"
    echo "  $DOCK6_HOME/parameters/flex_drive.defn"
    echo

    exit 1

fi


echo "Parameter files:"
echo
echo "  VDW:"
echo "    $VDW_DEF"
echo
echo "  Flex definition:"
echo "    $FLEX_DEF"
echo
echo "  Flex drive:"
echo "    $FLEX_DRIVE"
echo


# ============================================================
# Find complete docking sites
#
# Required:
#
#   02_SITE/<site>/site.sph
#   03_GRID/<site>/site_grid.nrg
#   03_GRID/<site>/site_grid.bmp
# ============================================================

VALID_SITES=()


if [[ -d "$SITE_ROOT" ]]; then

    while IFS= read -r DIR; do

        SITE_NAME="$(
            basename "$DIR"
        )"

        SITE_SPH="$DIR/site.sph"

        GRID_NRG="$GRID_ROOT/$SITE_NAME/site_grid.nrg"
        GRID_BMP="$GRID_ROOT/$SITE_NAME/site_grid.bmp"


        if [[ -s "$SITE_SPH" ]] &&
           [[ -s "$GRID_NRG" ]] &&
           [[ -s "$GRID_BMP" ]]; then

            VALID_SITES+=("$SITE_NAME")

        fi

    done < <(
        find "$SITE_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            | sort
    )

fi


if [[ "${#VALID_SITES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR: No complete docking sites were found."
    echo
    echo "Required:"
    echo
    echo "  02_SITE/<site>/site.sph"
    echo "  03_GRID/<site>/site_grid.nrg"
    echo "  03_GRID/<site>/site_grid.bmp"
    echo

    exit 1

fi


# ============================================================
# Display docking sites
# ============================================================

echo
echo "============================================================"
echo " Available docking sites"
echo "============================================================"
echo


for i in "${!VALID_SITES[@]}"; do

    SITE_NAME="${VALID_SITES[$i]}"
    SITE_SPH="$SITE_ROOT/$SITE_NAME/site.sph"


    SPHERE_COUNT="$(
        python3 - "$SITE_SPH" <<'PY'

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
        "$SITE_NAME" \
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


SITE_NAME="${VALID_SITES[$((SITE_CHOICE - 1))]}"

SITE_SPH="$SITE_ROOT/$SITE_NAME/site.sph"

GRID_DIR="$GRID_ROOT/$SITE_NAME"
GRID_PREFIX="$GRID_DIR/site_grid"


echo
echo "Selected site:"
echo
echo "  $SITE_NAME"
echo

echo "Site spheres:"
echo
echo "  $SITE_SPH"
echo

echo "Grid prefix:"
echo
echo "  $GRID_PREFIX"
echo


# ============================================================
# Ligand information
# ============================================================

echo "============================================================"
echo " Ligand information"
echo "============================================================"
echo


read -r \
    LIG_ATOMS \
    LIG_HEAVY \
    LIG_H \
    LIG_CHARGE \
    LIG_BONDS < <(

    python3 - "$LIGAND_FILE" <<'PY'

from pathlib import Path
import sys
import re


path = Path(sys.argv[1])

section = None

natoms = 0
nheavy = 0
nh = 0
nbonds = 0
charge = 0.0


for line in path.read_text().splitlines():

    if line.startswith("@<TRIPOS>ATOM"):
        section = "ATOM"
        continue

    if line.startswith("@<TRIPOS>BOND"):
        section = "BOND"
        continue

    if line.startswith("@<TRIPOS>"):
        section = None
        continue


    if section == "ATOM" and line.strip():

        fields = line.split()

        if len(fields) < 6:
            continue

        natoms += 1

        atom_name = fields[1]
        atom_type = fields[5]

        elem = atom_type.split(".")[0].upper()

        if elem == "H" or atom_name.upper().startswith("H"):
            nh += 1
        else:
            nheavy += 1

        if len(fields) >= 9:

            try:
                charge += float(fields[8])
            except ValueError:
                pass


    elif section == "BOND" and line.strip():

        fields = line.split()

        if len(fields) >= 4:
            nbonds += 1


print(
    natoms,
    nheavy,
    nh,
    f"{charge:.6f}",
    nbonds,
)

PY
)


echo "  Atoms       : $LIG_ATOMS"
echo "  Heavy atoms : $LIG_HEAVY"
echo "  Hydrogens   : $LIG_H"
echo "  Bonds       : $LIG_BONDS"
echo "  Charge      : $LIG_CHARGE"
echo


# ============================================================
# Docking mode
# ============================================================

echo "============================================================"
echo " Docking mode"
echo "============================================================"
echo

echo "  [1] Rigid docking"
echo
echo "      Ligand conformation is kept rigid during"
echo "      the initial orientation search."
echo
echo "      Translation and rotation are sampled."
echo

echo "  [2] Flexible docking"
echo
echo "      DOCK6 Anchor-and-Grow is used."
echo "      Rotatable bonds are sampled during growth."
echo


while true; do

    read -r -p \
        "Select docking mode [1-2] (default: 1): " \
        MODE_CHOICE


    if [[ -z "$MODE_CHOICE" ]]; then
        MODE_CHOICE="1"
    fi


    case "$MODE_CHOICE" in

        1)

            DOCK_MODE="rigid"
            MODE_LABEL="Rigid"
            break
            ;;

        2)

            DOCK_MODE="flex"
            MODE_LABEL="Flexible"
            break
            ;;

        *)

            echo "Invalid selection."
            ;;

    esac

done


echo
echo "Selected mode:"
echo
echo "  $MODE_LABEL"
echo


# ============================================================
# Maximum orientations (fixed)
# ============================================================

echo "============================================================"
echo " Docking parameters"
echo "============================================================"
echo

MAX_ORIENTATIONS="$DEFAULT_MAX_ORIENTATIONS"

echo "Maximum orientations:"
echo "  $MAX_ORIENTATIONS"
echo


# ============================================================
# Number final poses
# ============================================================

read -r -p \
    "Number of final scored poses ($DEFAULT_NUM_FINAL_POSES): " \
    NUM_FINAL_POSES


if [[ -z "$NUM_FINAL_POSES" ]]; then

    NUM_FINAL_POSES="$DEFAULT_NUM_FINAL_POSES"

fi


if [[ ! "$NUM_FINAL_POSES" =~ ^[0-9]+$ ]] ||
   (( NUM_FINAL_POSES < 1 )); then

    echo
    echo "ERROR: Number of poses must be a positive integer."
    echo

    exit 1

fi


# ============================================================
# Fixed docking settings
# ============================================================

# Rigid docking always uses local ligand minimization.
MINIMIZE_LIGAND="yes"

# Disable DOCK6 bump pre-filtering.
BUMP_FILTER="no"


echo
echo "Fixed settings:"
echo
echo "  Maximum orientations : $MAX_ORIENTATIONS"
echo "  Bump filter          : $BUMP_FILTER"
if [[ "$DOCK_MODE" == "rigid" ]]; then
    echo "  Rigid minimization   : $MINIMIZE_LIGAND"
fi
echo "  Final scored poses   : $NUM_FINAL_POSES"
echo


# ============================================================
# Flexible docking information
# ============================================================

if [[ "$DOCK_MODE" == "flex" ]]; then

    echo
    echo "------------------------------------------------------------"
    echo " Flexible docking"
    echo "------------------------------------------------------------"
    echo

    echo "Anchor-and-Grow parameters:"
    echo
    echo "  min_anchor_size           = 40"
    echo "  pruning_use_clustering    = yes"
    echo "  pruning_max_orients       = 100"
    echo "  pruning_clustering_cutoff = 100"
    echo "  use_clash_overlap         = no"
    echo
    echo "  minimize_anchor           = yes"
    echo "  minimize_flexible_growth  = yes"
    echo

fi


# ============================================================
# Output directory
#
# Allow rigid and flexible calculations to coexist.
# ============================================================

OUTDIR="$DOCK_ROOT/$SITE_NAME/$DOCK_MODE"


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
    echo "Docking output directory already contains files:"
    echo
    echo "  $OUTDIR"
    echo

    read -r -p \
        "Overwrite existing calculation? [y/N]: " \
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
# Absolute paths
# ============================================================

LIGAND_ABS="$(
    realpath "$LIGAND_FILE"
)"

SITE_SPH_ABS="$(
    realpath "$SITE_SPH"
)"

GRID_DIR_ABS="$(
    realpath "$GRID_DIR"
)"

GRID_PREFIX_ABS="$GRID_DIR_ABS/site_grid"

VDW_DEF_ABS="$(
    realpath "$VDW_DEF"
)"

FLEX_DEF_ABS="$(
    realpath "$FLEX_DEF"
)"

FLEX_DRIVE_ABS="$(
    realpath "$FLEX_DRIVE"
)"


# ============================================================
# Output filenames
# ============================================================

DOCK_IN="$OUTDIR/${DOCK_MODE}.in"
DOCK_OUT="$OUTDIR/${DOCK_MODE}.out"

LIGAND_PREFIX="ligand_${SITE_NAME}_${DOCK_MODE}"

SCORED_MOL2="$OUTDIR/${LIGAND_PREFIX}_scored.mol2"

SCORE_TABLE="$OUTDIR/grid_scores.tsv"

SUMMARY="$OUTDIR/docking_summary.txt"


# ============================================================
# Begin DOCK input
# ============================================================

cat > "$DOCK_IN" <<EOF
conformer_search_type                                        ${DOCK_MODE}
EOF


# ============================================================
# Flexible docking parameters
# ============================================================

if [[ "$DOCK_MODE" == "flex" ]]; then

cat >> "$DOCK_IN" <<'EOF'
min_anchor_size                                              40
pruning_use_clustering                                       yes
pruning_max_orients                                          100
pruning_clustering_cutoff                                    100
use_clash_overlap                                            no
EOF

fi


# ============================================================
# Common internal-energy parameters
# ============================================================

cat >> "$DOCK_IN" <<EOF
use_internal_energy                                          yes
internal_energy_rep_exp                                      12
EOF


# ============================================================
# Ligand input
# ============================================================

cat >> "$DOCK_IN" <<EOF
ligand_atom_file                                             ${LIGAND_ABS}
limit_max_ligands                                            no
skip_molecule                                                no
read_mol_solvation                                           no
calculate_rmsd                                               no
EOF


# ============================================================
# Orientation
# ============================================================

cat >> "$DOCK_IN" <<EOF
orient_ligand                                                yes
automated_matching                                           yes
receptor_site_file                                           ${SITE_SPH_ABS}
max_orientations                                             ${MAX_ORIENTATIONS}
critical_points                                              no
chemical_matching                                            no
use_ligand_spheres                                           no
bump_filter                                                  ${BUMP_FILTER}
EOF


# ============================================================
# Scoring
# ============================================================

cat >> "$DOCK_IN" <<EOF
score_molecules                                              yes
contact_score_primary                                        no
grid_score_primary                                           yes
grid_score_rep_rad_scale                                     1
grid_score_vdw_scale                                         1
grid_score_es_scale                                          1
grid_score_grid_prefix                                       ${GRID_PREFIX_ABS}
EOF


# ============================================================
# Minimization
# ============================================================

if [[ "$DOCK_MODE" == "rigid" ]]; then

    cat >> "$DOCK_IN" <<EOF
minimize_ligand                                              ${MINIMIZE_LIGAND}
EOF


    if [[ "$MINIMIZE_LIGAND" == "yes" ]]; then

cat >> "$DOCK_IN" <<'EOF'
simplex_max_iterations                                       1000
simplex_max_cycles                                           1
simplex_score_converge                                       0.1
simplex_cycle_converge                                       1.0
simplex_trans_step                                           1.0
simplex_rot_step                                             0.1
simplex_tors_step                                            10.0
simplex_random_seed                                          0
EOF

    fi


else

cat >> "$DOCK_IN" <<'EOF'
minimize_ligand                                              yes
minimize_anchor                                              yes
minimize_flexible_growth                                     yes
use_advanced_simplex_parameters                              no
simplex_max_cycles                                           1
simplex_score_converge                                       0.1
simplex_cycle_converge                                       1.0
simplex_trans_step                                           1.0
simplex_rot_step                                             0.1
simplex_tors_step                                            10.0
simplex_anchor_max_iterations                                500
simplex_grow_max_iterations                                  500
simplex_random_seed                                          0
EOF

fi


# ============================================================
# Atom model and DOCK parameter files
# ============================================================

cat >> "$DOCK_IN" <<EOF
atom_model                                                   all
vdw_defn_file                                                ${VDW_DEF_ABS}
flex_defn_file                                               ${FLEX_DEF_ABS}
flex_drive_file                                              ${FLEX_DRIVE_ABS}
EOF


# ============================================================
# Output settings
# ============================================================

cat >> "$DOCK_IN" <<EOF
ligand_outfile_prefix                                        ${LIGAND_PREFIX}
write_orientations                                           no
num_final_scored_poses                                       ${NUM_FINAL_POSES}
rank_ligands                                                 no
EOF


# ============================================================
# Display DOCK input
# ============================================================

echo
echo "============================================================"
echo " DOCK6 input"
echo "============================================================"
echo

cat "$DOCK_IN"

echo


# ============================================================
# Run summary before docking
# ============================================================

echo "------------------------------------------------------------"
echo " Calculation"
echo "------------------------------------------------------------"
echo

echo "Site:"
echo "  $SITE_NAME"
echo

echo "Mode:"
echo "  $MODE_LABEL"
echo

echo "Ligand:"
echo "  $LIGAND_FILE"
echo

echo "Maximum orientations:"
echo "  $MAX_ORIENTATIONS"
echo

echo "Final scored poses:"
echo "  $NUM_FINAL_POSES"
echo

echo "Bump filter:"
echo "  $BUMP_FILTER"
echo


if [[ "$DOCK_MODE" == "rigid" ]]; then

    echo "Ligand minimization:"
    echo "  $MINIMIZE_LIGAND"
    echo

fi


# ============================================================
# Run DOCK6
# ============================================================

echo "============================================================"
echo " Running DOCK6"
echo "============================================================"
echo


(
    cd "$OUTDIR"

    rm -f \
        "${DOCK_MODE}.out" \
        "${LIGAND_PREFIX}"*.mol2


    dock6 \
        -i "${DOCK_MODE}.in" \
        -o "${DOCK_MODE}.out"
)


# ============================================================
# Validate main log
# ============================================================

if [[ ! -s "$DOCK_OUT" ]]; then

    echo
    echo "ERROR: DOCK6 output was not generated:"
    echo
    echo "  $DOCK_OUT"
    echo

    exit 1

fi


# ============================================================
# Detect obvious fatal messages
# ============================================================

if grep -qiE \
    'FATAL|Segmentation fault|Quitting without|ERROR:' \
    "$DOCK_OUT"
then

    echo
    echo "WARNING:"
    echo "Potential error text was detected in:"
    echo
    echo "  $DOCK_OUT"
    echo

    grep -iE \
        'FATAL|Segmentation fault|Quitting without|ERROR:' \
        "$DOCK_OUT" \
        || true

    echo

fi


# ============================================================
# Locate scored MOL2
#
# Normally:
#
# <ligand_outfile_prefix>_scored.mol2
# ============================================================

if [[ ! -s "$SCORED_MOL2" ]]; then

    mapfile -t SCORED_CANDIDATES < <(
        find "$OUTDIR" \
            -maxdepth 1 \
            -type f \
            -name "*_scored.mol2" \
            | sort
    )


    if [[ "${#SCORED_CANDIDATES[@]}" -eq 1 ]]; then

        SCORED_MOL2="${SCORED_CANDIDATES[0]}"

    else

        echo
        echo "ERROR:"
        echo "Scored MOL2 was not found."
        echo

        echo "Expected:"
        echo
        echo "  $SCORED_MOL2"
        echo

        echo "Check:"
        echo
        echo "  $DOCK_OUT"
        echo

        exit 1

    fi

fi


# ============================================================
# Count final poses
# ============================================================

POSE_COUNT="$(
    grep -c \
        '^@<TRIPOS>MOLECULE' \
        "$SCORED_MOL2" \
        || true
)"


echo
echo "Scored poses written:"
echo
echo "  $POSE_COUNT"
echo


# ============================================================
# Extract DOCK metadata correctly
#
# Important:
# DOCK metadata lines occur before @<TRIPOS>MOLECULE.
# Therefore metadata must be buffered and assigned to the
# following molecule.
# ============================================================

python3 - \
    "$SCORED_MOL2" \
    "$SCORE_TABLE" <<'PY'

from pathlib import Path
import sys
import math


src = Path(sys.argv[1])
dst = Path(sys.argv[2])


lines = src.read_text().splitlines()


metadata = {}

poses = []

current_pose = None


wanted_keys = {
    "Grid_Score",
    "Grid_vdw_energy",
    "Grid_es_energy",
    "Internal_energy_repulsive",
}


for line in lines:

    # --------------------------------------------------------
    # DOCK metadata precedes the MOL2 molecule section
    # --------------------------------------------------------

    if line.startswith("##########"):

        text = line.lstrip("#").strip()

        if ":" not in text:
            continue

        key, value = text.split(
            ":",
            1,
        )

        key = key.strip()
        value = value.strip()


        if key in wanted_keys:

            try:
                metadata[key] = float(value)
            except ValueError:
                pass

        continue


    # --------------------------------------------------------
    # Beginning of next pose
    # --------------------------------------------------------

    if line.strip() == "@<TRIPOS>MOLECULE":

        if current_pose is not None:
            poses.append(current_pose)


        current_pose = dict(metadata)

        metadata = {}


# Last pose
if current_pose is not None:
    poses.append(current_pose)


with dst.open("w") as f:

    f.write(
        "Pose\t"
        "Grid_Score\t"
        "Grid_vdw_energy\t"
        "Grid_es_energy\t"
        "Internal_energy_repulsive\n"
    )


    for i, pose in enumerate(
        poses,
        1
    ):

        def value(key):

            x = pose.get(
                key,
                float("nan"),
            )

            if math.isnan(x):
                return "NA"

            return f"{x:.6f}"


        f.write(
            f"{i}\t"
            f"{value('Grid_Score')}\t"
            f"{value('Grid_vdw_energy')}\t"
            f"{value('Grid_es_energy')}\t"
            f"{value('Internal_energy_repulsive')}\n"
        )


print(
    f"Extracted {len(poses)} poses."
)

PY


# ============================================================
# Show score table
# ============================================================

echo
echo "============================================================"
echo " Pose scores"
echo "============================================================"
echo


if command -v column >/dev/null 2>&1; then

    column \
        -t \
        -s $'\t' \
        "$SCORE_TABLE"

else

    cat "$SCORE_TABLE"

fi


# ============================================================
# Determine best Grid Score
# ============================================================

BEST_SCORE="$(
    python3 - "$SCORE_TABLE" <<'PY'

from pathlib import Path
import sys


path = Path(sys.argv[1])

results = []


for line in path.read_text().splitlines()[1:]:

    fields = line.split("\t")


    if len(fields) < 5:
        continue


    if fields[1] == "NA":
        continue


    try:

        pose = int(fields[0])

        grid = float(fields[1])

        vdw = (
            None
            if fields[2] == "NA"
            else float(fields[2])
        )

        es = (
            None
            if fields[3] == "NA"
            else float(fields[3])
        )

        internal = (
            None
            if fields[4] == "NA"
            else float(fields[4])
        )

    except ValueError:

        continue


    results.append(
        (
            grid,
            pose,
            vdw,
            es,
            internal,
        )
    )


if not results:

    print("unknown")
    raise SystemExit(0)


results.sort(
    key=lambda x: x[0]
)


grid, pose, vdw, es, internal = results[0]


def fmt(x):

    if x is None:
        return "NA"

    return f"{x:.6f}"


print(
    f"pose={pose}; "
    f"Grid={grid:.6f}; "
    f"VDW={fmt(vdw)}; "
    f"ES={fmt(es)}; "
    f"Internal={fmt(internal)}"
)

PY
)"


# ============================================================
# Extract useful log lines
# ============================================================

RESULT_LINES="$(
    grep -E \
        'Grid_Score:|Grid_vdw_energy:|Grid_es_energy:|Internal_energy_repulsive:|Orientations:|Conformations:|Number of rotatable bonds' \
        "$DOCK_OUT" \
        || true
)"


# ============================================================
# Output sizes
# ============================================================

DOCK_OUT_SIZE="$(
    du -h "$DOCK_OUT" \
    | awk '{print $1}'
)"


SCORED_SIZE="$(
    du -h "$SCORED_MOL2" \
    | awk '{print $1}'
)"


# ============================================================
# Write summary
# ============================================================

{
    echo "============================================================"
    echo " DOCK6 docking summary"
    echo "============================================================"
    echo

    echo "[Mode]"
    echo "Docking mode           : $MODE_LABEL"
    echo "conformer_search_type  : $DOCK_MODE"
    echo

    echo "[Site]"
    echo "Site name              : $SITE_NAME"
    echo "Site spheres           : $SITE_SPH"
    echo "Grid prefix            : $GRID_PREFIX"
    echo

    echo "[Ligand]"
    echo "Ligand MOL2            : $LIGAND_FILE"
    echo "Atoms                  : $LIG_ATOMS"
    echo "Heavy atoms            : $LIG_HEAVY"
    echo "Hydrogens              : $LIG_H"
    echo "Bonds                  : $LIG_BONDS"
    echo "Charge                 : $LIG_CHARGE"
    echo

    echo "[Sampling]"
    echo "Max orientations       : $MAX_ORIENTATIONS"
    echo "Bump filter            : $BUMP_FILTER"


    if [[ "$DOCK_MODE" == "rigid" ]]; then

        echo "Minimize ligand        : $MINIMIZE_LIGAND"

    else

        echo "Anchor-and-Grow        : yes"
        echo "Min anchor size        : 40"
        echo "Pruning clustering     : yes"
        echo "Pruning max orientations: 100"
        echo "Minimize anchor        : yes"
        echo "Minimize growth        : yes"

    fi


    echo

    echo "[Scoring]"
    echo "Primary score          : Grid Score"
    echo "VDW scale              : 1"
    echo "Electrostatic scale    : 1"
    echo "Repulsive radius scale : 1"
    echo

    echo "[Results]"
    echo "Requested final poses  : $NUM_FINAL_POSES"
    echo "Actual poses written   : $POSE_COUNT"
    echo "Best result            : $BEST_SCORE"
    echo


    if [[ -n "$RESULT_LINES" ]]; then

        echo "[DOCK log]"
        printf '%s\n' "$RESULT_LINES"
        echo

    fi


    echo "[Files]"
    echo "DOCK input             : $DOCK_IN"
    echo "DOCK output            : $DOCK_OUT"
    echo "Scored MOL2            : $SCORED_MOL2"
    echo "Score table            : $SCORE_TABLE"
    echo "DOCK output size       : $DOCK_OUT_SIZE"
    echo "Scored MOL2 size       : $SCORED_SIZE"

} > "$SUMMARY"


# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo " Docking completed"
echo "============================================================"
echo

echo "Site:"
echo
echo "  $SITE_NAME"
echo

echo "Mode:"
echo
echo "  $MODE_LABEL"
echo

echo "Sampling:"
echo
echo "  max_orientations = $MAX_ORIENTATIONS"
echo "  bump_filter      = $BUMP_FILTER"
echo


if [[ "$DOCK_MODE" == "rigid" ]]; then

    echo "  minimize_ligand  = $MINIMIZE_LIGAND"
    echo

fi


echo "Scored poses:"
echo
echo "  $POSE_COUNT"
echo

echo "Best score:"
echo
echo "  $BEST_SCORE"
echo

echo "Generated files:"
echo

echo "  DOCK input:"
echo "    $DOCK_IN"
echo

echo "  DOCK output:"
echo "    $DOCK_OUT"
echo

echo "  Scored MOL2:"
echo "    $SCORED_MOL2"
echo

echo "  Score table:"
echo "    $SCORE_TABLE"
echo

echo "  Summary:"
echo "    $SUMMARY"
echo

echo "Next:"
echo
echo "  06_export.sh"
echo