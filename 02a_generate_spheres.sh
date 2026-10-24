#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

INPUT_DIR="00_INPUT"
PREP_DIR="01_PREPARE"
SITE_ROOT="02_SITE"

RECEPTOR_INPUT="$PREP_DIR/target_input.pdb"

DEFAULT_SELECTION_RADIUS="6.0"

mkdir -p "$SITE_ROOT"


# ============================================================
# Dependency check
# ============================================================

for CMD in python3 sphgen sphere_selector showsphere; do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo
        echo "ERROR: $CMD was not found."
        echo

        exit 1

    fi

done


# ============================================================
# Check receptor
# ============================================================

if [[ ! -s "$RECEPTOR_INPUT" ]]; then

    echo
    echo "ERROR: Receptor PDB was not found:"
    echo
    echo "  $RECEPTOR_INPUT"
    echo
    echo "Run 01a_prepare_target.sh first."
    echo

    exit 1

fi


# ============================================================
# Find Chimera DMS files
# ============================================================

if [[ ! -d "$INPUT_DIR" ]]; then

    echo
    echo "ERROR: Input directory was not found:"
    echo
    echo "  $INPUT_DIR"
    echo

    exit 1

fi


mapfile -t DMS_FILES < <(
    find "$INPUT_DIR" \
        -maxdepth 1 \
        -type f \
        \( -iname "*.dms" -o -iname "*.ms" \) \
        | sort
)


if [[ "${#DMS_FILES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR:"
    echo "No Chimera DMS files were found in:"
    echo
    echo "  $INPUT_DIR"
    echo
    echo "Create a molecular surface in UCSF Chimera,"
    echo "write it as DMS, and save surface normals."
    echo

    exit 1

fi


# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " DOCK6 sphere generation"
echo " Chimera DMS -> SPHGEN -> sphere_selector"
echo "============================================================"
echo

echo "Receptor:"
echo
echo "  $RECEPTOR_INPUT"
echo


# ============================================================
# Sphere-generation method
# ============================================================

echo "Sphere-generation method:"
echo
echo "  [1] Chimera DMS / SPHGEN"
echo "  [2] Terminal-plane spheres"
echo

while true; do

    read -r -p \
        "Select [1-2] (default: 1): " \
        METHOD

    METHOD="${METHOD:-1}"

    case "$METHOD" in

        1|2)
            break
            ;;

        *)
            echo "Invalid selection."
            ;;

    esac

done


# ============================================================
# METHOD 2
# Terminal-plane spheres
#
# No DMS/SPHGEN is used.
#
# 1. Select terminal residues.
# 2. Use nucleobase heavy atoms from those residues.
# 3. Fit a best-fit terminal plane.
# 4. Determine the outward side using the whole target centroid.
# 5. Build three parallel planes at:
#       D - 0.1 A
#       D
#       D + 0.1 A
# 6. Cover the complete projected nucleobase area + margin.
# 7. Fill every plane with a regular sphere grid.
# ============================================================

if [[ "$METHOD" == "2" ]]; then

    DEFAULT_TERMINAL_SPACING="2.0"
    DEFAULT_TERMINAL_RADIUS="1.5"
    DEFAULT_TERMINAL_MARGIN="1.0"

    echo
    echo "============================================================"
    echo " Terminal-plane sphere generation"
    echo "============================================================"
    echo


    # --------------------------------------------------------
    # Site name
    # --------------------------------------------------------

    while true; do

        read -r -p \
            "Site name (example: site1, face1): " \
            SITE_NAME

        if [[ -z "$SITE_NAME" ]]; then
            echo "Site name must not be empty."
            continue
        fi

        if [[ ! "$SITE_NAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            echo "Use only letters, numbers, _, -, or ."
            continue
        fi

        break

    done


    OUTDIR="$SITE_ROOT/$SITE_NAME"


    # --------------------------------------------------------
    # Existing site directory
    # --------------------------------------------------------

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
        echo "Site directory already contains files:"
        echo
        echo "  $OUTDIR"
        echo

        read -r -p \
            "Overwrite this site directory? [y/N]: " \
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


    TERMINAL_RESIDUES="$OUTDIR/terminal_residues.txt"
    SITE_REF_PDB="$OUTDIR/site_reference.pdb"
    SITE_REF_MOL2="$OUTDIR/site_reference.mol2"
    CANDIDATE_SPH="$OUTDIR/candidate.sph"
    CANDIDATE_PDB="$OUTDIR/candidate_spheres.pdb"
    SITE_REF_CANDIDATE_PDB="$OUTDIR/site_reference_with_candidates.pdb"
    TARGET_CANDIDATE_PDB="$OUTDIR/target_with_candidates.pdb"
    GEOMETRY_FILE="$OUTDIR/terminal_plane_geometry.txt"
    SUMMARY="$OUTDIR/candidate_summary.txt"


    # --------------------------------------------------------
    # Display receptor residues
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo " Receptor residues"
    echo "============================================================"
    echo

    python3 - "$RECEPTOR_INPUT" <<'PY'

from pathlib import Path
from collections import OrderedDict
import sys

pdb = Path(sys.argv[1])

chains = OrderedDict()

for line in pdb.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue

    chain = line[21:22].strip()

    if not chain:
        chain = "_"

    resid = line[22:26].strip()
    icode = line[26:27].strip()
    resname = line[17:20].strip()

    resid_full = resid + icode

    chains.setdefault(chain, [])

    item = (resid_full, resname)

    if item not in chains[chain]:
        chains[chain].append(item)


for chain, residues in chains.items():

    display_chain = "(blank)" if chain == "_" else chain

    print(f"Chain {display_chain}:")

    out = "  "

    for resid, resname in residues:

        token = f"{resid}:{resname}"

        if len(out) + len(token) + 1 > 78:
            print(out.rstrip())
            out = "  "

        out += token + " "

    if out.strip():
        print(out.rstrip())

    print()

PY


    # --------------------------------------------------------
    # Terminal-residue selection
    # --------------------------------------------------------

    : > "$TERMINAL_RESIDUES"

    echo "Select terminal residues."
    echo
    echo "Format:"
    echo
    echo "  chain residue"
    echo
    echo "Examples:"
    echo
    echo "  A 1"
    echo "  A 6"
    echo "  A 10"
    echo "  A 16"
    echo
    echo "For blank chain:"
    echo
    echo "  _ 12"
    echo
    echo "Press Enter on an empty line when finished."
    echo

    while true; do

        read -r -p "> " LINE

        if [[ -z "$LINE" ]]; then
            break
        fi

        FIELD_COUNT="$(
            printf '%s\n' "$LINE" \
                | awk '{print NF}'
        )"

        if [[ "$FIELD_COUNT" -ne 2 ]]; then
            echo
            echo "Invalid format."
            echo
            continue
        fi

        CHAIN="$(
            printf '%s\n' "$LINE" \
                | awk '{print $1}'
        )"

        RESID="$(
            printf '%s\n' "$LINE" \
                | awk '{print $2}'
        )"

        if ! python3 - \
            "$RECEPTOR_INPUT" \
            "$CHAIN" \
            "$RESID" <<'PY'

from pathlib import Path
import sys

pdb = Path(sys.argv[1])
wanted_chain = sys.argv[2]
wanted_resid = sys.argv[3]

for line in pdb.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue

    chain = line[21:22].strip()

    if not chain:
        chain = "_"

    resid = line[22:26].strip()
    icode = line[26:27].strip()
    resid_full = resid + icode

    if (
        chain == wanted_chain
        and (
            resid == wanted_resid
            or resid_full == wanted_resid
        )
    ):
        raise SystemExit(0)

raise SystemExit(1)

PY
        then
            echo
            echo "Residue not found:"
            echo
            echo "  $CHAIN $RESID"
            echo
            continue
        fi

        if grep -Fxq \
            "$CHAIN $RESID" \
            "$TERMINAL_RESIDUES"
        then
            echo "  Already selected: $CHAIN $RESID"
            continue
        fi

        echo "$CHAIN $RESID" >> "$TERMINAL_RESIDUES"
        echo "  Added: $CHAIN $RESID"

    done


    if [[ ! -s "$TERMINAL_RESIDUES" ]]; then
        echo
        echo "ERROR: No terminal residues were selected."
        echo
        exit 1
    fi


    echo
    echo "Selected terminal residues:"
    echo

    sed \
        's/^/  /' \
        "$TERMINAL_RESIDUES"

    echo


    # --------------------------------------------------------
    # Build site_reference.pdb / site_reference.mol2
    #
    # These files keep the terminal-plane mode compatible with
    # 02b_select_spheres.sh and 02c_make_box.sh.
    # Coordinates are copied directly from target_input.pdb.
    # --------------------------------------------------------

    python3 - \
        "$RECEPTOR_INPUT" \
        "$TERMINAL_RESIDUES" \
        "$SITE_REF_PDB" \
        "$SITE_REF_MOL2" <<'PYREF'

from pathlib import Path
import re
import sys

pdb_file = Path(sys.argv[1])
selection_file = Path(sys.argv[2])
out_pdb = Path(sys.argv[3])
out_mol2 = Path(sys.argv[4])

selected = set()

for line in selection_file.read_text().splitlines():
    fields = line.split()

    if len(fields) == 2:
        selected.add((fields[0], fields[1]))

atoms = []

for line in pdb_file.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue

    chain = line[21:22].strip()

    if not chain:
        chain = "_"

    resid = line[22:26].strip()
    icode = line[26:27].strip()
    resid_full = resid + icode

    if (
        (chain, resid) not in selected
        and (chain, resid_full) not in selected
    ):
        continue

    atom_name = line[12:16].strip()

    try:
        x = float(line[30:38])
        y = float(line[38:46])
        z = float(line[46:54])
    except ValueError:
        continue

    element = ""

    if len(line) >= 78:
        element = line[76:78].strip().upper()

    if not element:
        name = re.sub(r"[^A-Za-z]", "", atom_name)
        element = name[0].upper() if name else "C"

    atoms.append(
        (
            line,
            atom_name,
            x,
            y,
            z,
            element,
        )
    )

if not atoms:
    raise SystemExit(
        "ERROR: No atoms were found for selected terminal residues."
    )

with out_pdb.open("w") as f:

    for atom in atoms:
        f.write(atom[0] + "\n")

    f.write("END\n")

with out_mol2.open("w") as f:

    f.write("@<TRIPOS>MOLECULE\n")
    f.write("site_reference\n")

    f.write(
        f"{len(atoms):6d}"
        f"{0:6d}"
        f"{1:6d}"
        f"{0:6d}"
        f"{0:6d}\n"
    )

    f.write("SMALL\n")
    f.write("NO_CHARGES\n\n")
    f.write("@<TRIPOS>ATOM\n")

    for i, atom in enumerate(atoms, 1):

        _, name, x, y, z, element = atom

        f.write(
            f"{i:7d} "
            f"{name:<8s} "
            f"{x:10.4f} "
            f"{y:10.4f} "
            f"{z:10.4f} "
            f"{element:<6s} "
            f"{1:4d} "
            f"{'SITE':<8s} "
            f"{0.0:10.4f}\n"
        )

    f.write("@<TRIPOS>SUBSTRUCTURE\n")
    f.write(
        "     1 SITE        1 TEMP              "
        "0 ****  ****    0 ROOT\n"
    )

print(
    f"Reference atoms: {len(atoms)}"
)

PYREF


    if [[ ! -s "$SITE_REF_PDB" ]]; then
        echo
        echo "ERROR: site_reference.pdb was not generated."
        echo
        exit 1
    fi


    # --------------------------------------------------------
    # Geometry parameters
    # --------------------------------------------------------

    echo "============================================================"
    echo " Terminal-plane parameters"
    echo "============================================================"
    echo

    while true; do

        read -r -p \
            "Distance from terminal plane [Å]: " \
            TERMINAL_DISTANCE

        if [[ -z "$TERMINAL_DISTANCE" ]]; then
            echo "Distance must be entered."
            continue
        fi

        if python3 - "$TERMINAL_DISTANCE" <<'PYDIST'
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value <= 0.1:
    raise SystemExit(1)
PYDIST
        then
            break
        fi

        echo "Enter a number greater than 0.1 Å."

    done


    TERMINAL_SPACING="$DEFAULT_TERMINAL_SPACING"
    TERMINAL_RADIUS="$DEFAULT_TERMINAL_RADIUS"
    TERMINAL_MARGIN="$DEFAULT_TERMINAL_MARGIN"

    echo
    echo "Fixed terminal-plane settings:"
    echo
    echo "  Sphere spacing : $TERMINAL_SPACING Å"
    echo "  Sphere radius  : $TERMINAL_RADIUS Å"
    echo "  Margin         : $TERMINAL_MARGIN Å"
    echo


    # --------------------------------------------------------
    # Generate three terminal-plane sphere layers
    # --------------------------------------------------------

    python3 - \
        "$RECEPTOR_INPUT" \
        "$TERMINAL_RESIDUES" \
        "$CANDIDATE_SPH" \
        "$CANDIDATE_PDB" \
        "$SITE_REF_PDB" \
        "$SITE_REF_CANDIDATE_PDB" \
        "$TARGET_CANDIDATE_PDB" \
        "$GEOMETRY_FILE" \
        "$TERMINAL_DISTANCE" \
        "$TERMINAL_SPACING" \
        "$TERMINAL_RADIUS" \
        "$TERMINAL_MARGIN" <<'PY'

from pathlib import Path
import sys
import math

try:
    import numpy as np
except ImportError:
    raise SystemExit(
        "ERROR: Terminal-plane mode requires NumPy."
    )


pdb_file = Path(sys.argv[1])
selection_file = Path(sys.argv[2])

sph_file = Path(sys.argv[3])
sphere_pdb = Path(sys.argv[4])
site_reference_pdb = Path(sys.argv[5])
site_combined_pdb = Path(sys.argv[6])
target_combined_pdb = Path(sys.argv[7])
geometry_file = Path(sys.argv[8])

distance = float(sys.argv[9])
spacing = float(sys.argv[10])
sphere_radius = float(sys.argv[11])
margin = float(sys.argv[12])


if distance <= 0:
    raise SystemExit(
        "ERROR: terminal distance must be > 0."
    )

if spacing <= 0:
    raise SystemExit(
        "ERROR: sphere spacing must be > 0."
    )

if sphere_radius <= 0:
    raise SystemExit(
        "ERROR: sphere radius must be > 0."
    )

if margin < 0:
    raise SystemExit(
        "ERROR: margin must be >= 0."
    )


# ============================================================
# Selected residues
# ============================================================

selected = set()

for line in selection_file.read_text().splitlines():

    fields = line.split()

    if len(fields) == 2:
        selected.add(
            (
                fields[0],
                fields[1],
            )
        )


if not selected:
    raise SystemExit(
        "ERROR: No terminal residues were selected."
    )


# ============================================================
# Nucleobase atom definitions
# ============================================================

PURINE_RING = {
    "N9", "C8", "N7", "C5", "C6",
    "N1", "C2", "N3", "C4",
}

PYRIMIDINE_RING = {
    "N1", "C2", "N3", "C4", "C5", "C6",
}

# Accept the union because residue naming varies between RNA/DNA
# and modified structures. Sugar/phosphate atoms are excluded.
BASE_RING = PURINE_RING | PYRIMIDINE_RING


# ============================================================
# Read receptor
# ============================================================

all_heavy = []
terminal_base = []
target_records = []


def infer_element(line, atom_name):

    element = ""

    if len(line) >= 78:
        element = line[76:78].strip().upper()

    if not element:
        stripped = atom_name.lstrip("0123456789")

        if stripped:
            element = stripped[0].upper()

    return element


for line in pdb_file.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue

    target_records.append(line)

    atom_name = line[12:16].strip()

    element = infer_element(
        line,
        atom_name,
    )

    if element == "H":
        continue

    try:
        xyz = np.array(
            [
                float(line[30:38]),
                float(line[38:46]),
                float(line[46:54]),
            ],
            dtype=float,
        )
    except ValueError:
        continue

    all_heavy.append(xyz)

    chain = line[21:22].strip()

    if not chain:
        chain = "_"

    resid = line[22:26].strip()
    icode = line[26:27].strip()
    resid_full = resid + icode

    is_selected = (
        (chain, resid) in selected
        or
        (chain, resid_full) in selected
    )

    if (
        is_selected
        and atom_name in BASE_RING
    ):
        terminal_base.append(
            (
                xyz,
                chain,
                resid_full,
                atom_name,
            )
        )


if len(all_heavy) < 3:
    raise SystemExit(
        "ERROR: Not enough target atoms."
    )

if len(terminal_base) < 3:
    raise SystemExit(
        "ERROR: Fewer than three nucleobase ring atoms "
        "were found in selected terminal residues."
    )


# ============================================================
# Fit terminal plane
# ============================================================

P = np.array(
    [item[0] for item in terminal_base],
    dtype=float,
)

terminal_centroid = P.mean(axis=0)

centered = P - terminal_centroid

_, _, vh = np.linalg.svd(
    centered,
    full_matrices=False,
)

normal = vh[-1]
normal = normal / np.linalg.norm(normal)


# ============================================================
# Determine outward direction
#
# Whole-target centroid is considered "inside".
# The normal is flipped so it points away from the target.
# ============================================================

target_centroid = np.array(
    all_heavy,
    dtype=float,
).mean(axis=0)

toward_target = (
    target_centroid
    - terminal_centroid
)

if np.dot(
    normal,
    toward_target,
) > 0:
    normal = -normal


# ============================================================
# In-plane axes
# ============================================================

u = vh[0]
u = u / np.linalg.norm(u)

v = np.cross(
    normal,
    u,
)

v = v / np.linalg.norm(v)


# ============================================================
# Project selected base atoms onto terminal plane
# and determine complete coverage rectangle.
# ============================================================

du_values = []
dv_values = []

for point in P:

    rel = (
        point
        - terminal_centroid
    )

    du_values.append(
        float(
            np.dot(
                rel,
                u,
            )
        )
    )

    dv_values.append(
        float(
            np.dot(
                rel,
                v,
            )
        )
    )


u_min = min(du_values) - margin
u_max = max(du_values) + margin

v_min = min(dv_values) - margin
v_max = max(dv_values) + margin


# ============================================================
# Grid helper
#
# Place points so the entire requested interval is covered.
# Both edges are always represented.
# ============================================================

def grid_axis(low, high, step):

    width = high - low

    if width <= 0:
        return [0.5 * (low + high)]

    n_intervals = max(
        1,
        math.ceil(
            width / step
        ),
    )

    actual_step = (
        width / n_intervals
    )

    return [
        low
        + i * actual_step
        for i in range(
            n_intervals + 1
        )
    ]


u_grid = grid_axis(
    u_min,
    u_max,
    spacing,
)

v_grid = grid_axis(
    v_min,
    v_max,
    spacing,
)


# ============================================================
# Three layers:
# D - 0.1, D, D + 0.1 Angstrom
# ============================================================

layer_distances = [
    distance - 0.1,
    distance,
    distance + 0.1,
]

if layer_distances[0] <= 0:
    raise SystemExit(
        "ERROR: D - 0.1 A must remain > 0."
    )


spheres = []

for layer_index, layer_distance in enumerate(
    layer_distances,
    1,
):

    layer_center = (
        terminal_centroid
        + normal * layer_distance
    )

    for du in u_grid:

        for dv in v_grid:

            point = (
                layer_center
                + u * du
                + v * dv
            )

            spheres.append(
                (
                    point,
                    layer_index,
                    layer_distance,
                )
            )


if not spheres:
    raise SystemExit(
        "ERROR: No spheres were generated."
    )


# ============================================================
# Write candidate.sph
# ============================================================

with sph_file.open("w") as f:

    f.write(
        "cluster     1   number of spheres in cluster"
        f"{len(spheres):6d}\n"
    )

    for i, item in enumerate(
        spheres,
        1,
    ):

        point, layer_index, layer_distance = item

        f.write(
            f"{i:5d}"
            f"{point[0]:10.5f}"
            f"{point[1]:10.5f}"
            f"{point[2]:10.5f}"
            f"{sphere_radius:8.3f}"
            f"{0:5d}"
            f"{0:2d}"
            f"{0:2d}\n"
        )


# ============================================================
# Write candidate_spheres.pdb
#
# Every sphere receives its own residue number:
#   SPH 1, SPH 2, SPH 3, ...
#
# B-factor stores the actual layer distance, so the three
# D-0.1 / D / D+0.1 layers can still be distinguished.
# ============================================================

with sphere_pdb.open("w") as f:

    for i, item in enumerate(
        spheres,
        1,
    ):

        point, layer_index, layer_distance = item

        f.write(
            f"HETATM{i:5d}  C   SPH S{i:4d}    "
            f"{point[0]:8.3f}"
            f"{point[1]:8.3f}"
            f"{point[2]:8.3f}"
            f"  1.00"
            f"{layer_distance:6.2f}"
            f"           C\n"
        )

    f.write("END\n")


# ============================================================
# Write combined visualization PDBs
#
# 1. site_reference.pdb + candidate_spheres.pdb
# 2. target_input.pdb + candidate_spheres.pdb
# ============================================================

def renumber_pdb_line(line, serial):

    if len(line) < 11:
        line = line.ljust(11)

    return (
        line[:6]
        + f"{serial:5d}"
        + line[11:]
    )


def pdb_atom_records(path):

    records = []

    for line in path.read_text().splitlines():

        if (
            line.startswith("ATOM")
            or line.startswith("HETATM")
        ):
            records.append(line)

    return records


def write_combined(
    base_records,
    sphere_records,
    output_file,
    label,
):

    serial = 1

    with output_file.open("w") as f:

        f.write(
            "REMARK   "
            + label
            + "\n"
        )

        f.write(
            f"REMARK   Nominal distance: {distance:.3f} A\n"
        )

        f.write(
            "REMARK   Layers: "
            f"{layer_distances[0]:.3f}, "
            f"{layer_distances[1]:.3f}, "
            f"{layer_distances[2]:.3f} A\n"
        )

        for line in base_records:

            f.write(
                renumber_pdb_line(
                    line,
                    serial,
                )
                + "\n"
            )

            serial += 1

        f.write("TER\n")

        for line in sphere_records:

            f.write(
                renumber_pdb_line(
                    line,
                    serial,
                )
                + "\n"
            )

            serial += 1

        f.write("END\n")


sphere_records = pdb_atom_records(
    sphere_pdb
)

site_records = pdb_atom_records(
    site_reference_pdb
)

write_combined(
    site_records,
    sphere_records,
    site_combined_pdb,
    "Selected terminal residues + terminal-plane candidate spheres",
)

write_combined(
    target_records,
    sphere_records,
    target_combined_pdb,
    "Target + terminal-plane candidate spheres",
)


# ============================================================
# Geometry report
# ============================================================

per_layer = (
    len(u_grid)
    * len(v_grid)
)

with geometry_file.open("w") as f:

    f.write(
        "Terminal-plane sphere geometry\n"
    )

    f.write(
        "==============================\n\n"
    )

    f.write(
        f"Selected residues       : {len(selected)}\n"
    )

    f.write(
        f"Nucleobase ring atoms   : {len(terminal_base)}\n"
    )

    f.write(
        f"Nominal distance        : {distance:.3f} A\n"
    )

    f.write(
        "Layer distances         : "
        f"{layer_distances[0]:.3f}, "
        f"{layer_distances[1]:.3f}, "
        f"{layer_distances[2]:.3f} A\n"
    )

    f.write(
        f"Requested spacing       : {spacing:.3f} A\n"
    )

    f.write(
        f"Sphere radius           : {sphere_radius:.3f} A\n"
    )

    f.write(
        f"Margin                  : {margin:.3f} A\n"
    )

    f.write(
        f"Projected U range       : "
        f"{u_min:.3f} to {u_max:.3f} A\n"
    )

    f.write(
        f"Projected V range       : "
        f"{v_min:.3f} to {v_max:.3f} A\n"
    )

    f.write(
        f"Grid                    : "
        f"{len(u_grid)} x {len(v_grid)}\n"
    )

    f.write(
        f"Spheres / layer         : {per_layer}\n"
    )

    f.write(
        f"Total candidate spheres : {len(spheres)}\n"
    )

    f.write(
        "Terminal centroid       : "
        f"{terminal_centroid[0]:.5f} "
        f"{terminal_centroid[1]:.5f} "
        f"{terminal_centroid[2]:.5f}\n"
    )

    f.write(
        "Outward normal          : "
        f"{normal[0]:.6f} "
        f"{normal[1]:.6f} "
        f"{normal[2]:.6f}\n"
    )


print()
print(
    f"Nucleobase ring atoms : {len(terminal_base)}"
)
print(
    f"Grid                  : {len(u_grid)} x {len(v_grid)}"
)
print(
    f"Spheres / layer       : {per_layer}"
)
print(
    f"Total spheres         : {len(spheres)}"
)
print(
    "Layer distances       : "
    f"{layer_distances[0]:.3f}, "
    f"{layer_distances[1]:.3f}, "
    f"{layer_distances[2]:.3f} A"
)

PY


    if [[ ! -s "$CANDIDATE_SPH" ]]; then
        echo
        echo "ERROR: candidate.sph was not generated."
        echo
        exit 1
    fi


    if [[ ! -s "$CANDIDATE_PDB" ]]; then
        echo
        echo "ERROR: candidate_spheres.pdb was not generated."
        echo
        exit 1
    fi


    CANDIDATE_COUNT="$(
        python3 - "$CANDIDATE_SPH" <<'PY'

from pathlib import Path
import sys

count = 0

for line in Path(
    sys.argv[1]
).read_text().splitlines():

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


    {
        echo "============================================================"
        echo " DOCK6 terminal-plane sphere generation summary"
        echo "============================================================"
        echo
        echo "[Input]"
        echo "Receptor PDB           : $RECEPTOR_INPUT"
        echo
        echo "[Method]"
        echo "Method                 : Terminal-plane spheres"
        echo "Site name              : $SITE_NAME"
        echo
        echo "[Geometry]"
        echo "Distance               : $TERMINAL_DISTANCE A"
        echo "Layers                 : D-0.1, D, D+0.1 A"
        echo "Sphere spacing         : $TERMINAL_SPACING A"
        echo "Sphere radius          : $TERMINAL_RADIUS A"
        echo "Margin                 : $TERMINAL_MARGIN A"
        echo "Candidate spheres      : $CANDIDATE_COUNT"
        echo
        echo "[Files]"
        echo "Terminal residues      : $TERMINAL_RESIDUES"
        echo "Reference PDB          : $SITE_REF_PDB"
        echo "Reference MOL2         : $SITE_REF_MOL2"
        echo "Candidate SPH          : $CANDIDATE_SPH"
        echo "Candidate PDB          : $CANDIDATE_PDB"
        echo "Reference + candidates : $SITE_REF_CANDIDATE_PDB"
        echo "Target + candidates    : $TARGET_CANDIDATE_PDB"
        echo "Geometry report        : $GEOMETRY_FILE"
    } > "$SUMMARY"


    echo
    echo "============================================================"
    echo " Terminal-plane sphere generation completed"
    echo "============================================================"
    echo
    echo "Site:"
    echo
    echo "  $SITE_NAME"
    echo
    echo "Candidate spheres:"
    echo
    echo "  $CANDIDATE_COUNT"
    echo
    echo "Terminal-plane settings:"
    echo
    echo "  Height         : $TERMINAL_DISTANCE Å"
    echo "  Layers         : D-0.1 / D / D+0.1 Å"
    echo "  Sphere spacing : $TERMINAL_SPACING Å"
    echo "  Sphere radius  : $TERMINAL_RADIUS Å"
    echo "  Margin         : $TERMINAL_MARGIN Å"
    echo
    echo "Candidate SPH:"
    echo
    echo "  $CANDIDATE_SPH"
    echo
    echo "Site reference:"
    echo
    echo "  $SITE_REF_PDB"
    echo
    echo "Visualization:"
    echo
    echo "  $CANDIDATE_PDB"
    echo
    echo "  $SITE_REF_CANDIDATE_PDB"
    echo
    echo "  $TARGET_CANDIDATE_PDB"
    echo
    echo "Geometry:"
    echo
    echo "  $GEOMETRY_FILE"
    echo
    echo "Summary:"
    echo
    echo "  $SUMMARY"
    echo
    echo "Then run:"
    echo
    echo "  bash 02b_select_spheres.sh"
    echo

    exit 0

fi




# ============================================================
# Select DMS
# ============================================================

echo "Available DMS files:"
echo


for i in "${!DMS_FILES[@]}"; do

    printf \
        "  [%d] %s\n" \
        "$((i + 1))" \
        "$(basename "${DMS_FILES[$i]}")"

done


echo


while true; do

    read -r -p \
        "Select DMS [1-${#DMS_FILES[@]}]: " \
        DMS_CHOICE


    if [[ "$DMS_CHOICE" =~ ^[0-9]+$ ]] &&
       (( DMS_CHOICE >= 1 )) &&
       (( DMS_CHOICE <= ${#DMS_FILES[@]} )); then

        break

    fi


    echo "Invalid selection."

done


DMS_SOURCE="$(
    realpath "${DMS_FILES[$((DMS_CHOICE - 1))]}"
)"


echo
echo "Selected DMS:"
echo
echo "  $DMS_SOURCE"
echo


# ============================================================
# Site name
# ============================================================

while true; do

    read -r -p \
        "Site name (example: site1, pocket1): " \
        SITE_NAME


    if [[ -z "$SITE_NAME" ]]; then

        echo "Site name must not be empty."
        continue

    fi


    if [[ ! "$SITE_NAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then

        echo "Use only letters, numbers, _, -, or ."
        continue

    fi


    break

done


OUTDIR="$SITE_ROOT/$SITE_NAME"


# ============================================================
# Existing site directory
# ============================================================

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
    echo "Site directory already contains files:"
    echo
    echo "  $OUTDIR"
    echo

    read -r -p \
        "Overwrite this site directory? [y/N]: " \
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
# Working files
# ============================================================

REC_DMS="$OUTDIR/rec.dms"
INSPH="$OUTDIR/INSPH"
REC_SPH="$OUTDIR/rec.sph"

RESIDUE_FILE="$OUTDIR/selected_residues.txt"

SITE_REF_PDB="$OUTDIR/site_reference.pdb"
SITE_REF_MOL2="$OUTDIR/site_reference.mol2"

CANDIDATE_SPH="$OUTDIR/candidate.sph"
CANDIDATE_PDB="$OUTDIR/candidate_spheres.pdb"

SITE_REF_CANDIDATE_PDB="$OUTDIR/site_reference_with_candidates.pdb"
TARGET_CANDIDATE_PDB="$OUTDIR/target_with_candidates.pdb"

SUMMARY="$OUTDIR/candidate_summary.txt"


# ============================================================
# Copy DMS
# ============================================================

cp \
    "$DMS_SOURCE" \
    "$REC_DMS"


if [[ ! -s "$REC_DMS" ]]; then

    echo
    echo "ERROR: Failed to copy DMS file."
    echo

    exit 1

fi


# ============================================================
# Create INSPH
#
# Same standard input used in the established workflow:
#
#   rec.dms
#   R
#   X
#   0.0
#   4.0
#   1.4
#   rec.sph
#
# ============================================================

cat > "$INSPH" <<'EOF'
rec.dms
R
X
0.0
4.0
1.4
rec.sph
EOF


echo
echo "============================================================"
echo " SPHGEN input"
echo "============================================================"
echo

cat "$INSPH"

echo


# ============================================================
# Run SPHGEN
# ============================================================

echo "============================================================"
echo " Running SPHGEN"
echo "============================================================"
echo


(
    cd "$OUTDIR"

    rm -f \
        rec.sph \
        OUTSPH \
        temp1.ms \
        temp2.sph \
        temp3.atc

    sphgen
)


if [[ ! -s "$REC_SPH" ]]; then

    echo
    echo "ERROR:"
    echo "SPHGEN did not generate:"
    echo
    echo "  $REC_SPH"
    echo

    exit 1

fi


# ============================================================
# Count all SPHGEN spheres
# ============================================================

SPHGEN_COUNT="$(
python3 - "$REC_SPH" <<'PY'

from pathlib import Path
import sys


count = 0


for line in Path(
    sys.argv[1]
).read_text().splitlines():

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


print(
    count
)

PY
)"


echo
echo "SPHGEN spheres:"
echo
echo "  $SPHGEN_COUNT"
echo


# ============================================================
# Display receptor residues
# ============================================================

echo "============================================================"
echo " Receptor residues"
echo "============================================================"
echo


python3 - "$RECEPTOR_INPUT" <<'PY'

from pathlib import Path
from collections import OrderedDict
import sys


pdb = Path(
    sys.argv[1]
)


chains = OrderedDict()


for line in pdb.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue


    chain = line[21:22].strip()

    if not chain:
        chain = "_"


    resid = line[22:26].strip()
    icode = line[26:27].strip()

    resname = line[17:20].strip()


    resid_full = (
        resid
        + icode
    )


    chains.setdefault(
        chain,
        []
    )


    item = (
        resid_full,
        resname,
    )


    if item not in chains[chain]:

        chains[chain].append(
            item
        )


for chain, residues in chains.items():

    display_chain = (
        "(blank)"
        if chain == "_"
        else chain
    )


    print(
        f"Chain {display_chain}:"
    )


    line = "  "


    for resid, resname in residues:

        token = (
            f"{resid}:{resname}"
        )


        if (
            len(line)
            + len(token)
            + 1
            > 78
        ):

            print(
                line.rstrip()
            )

            line = "  "


        line += (
            token
            + " "
        )


    if line.strip():

        print(
            line.rstrip()
        )


    print()

PY


# ============================================================
# Select binding-site residues
# ============================================================

: > "$RESIDUE_FILE"


echo "Select binding-site residues."
echo
echo "Format:"
echo
echo "  chain residue"
echo
echo "Examples:"
echo
echo "  A 6"
echo "  A 7"
echo "  B 19"
echo
echo "For blank chain:"
echo
echo "  _ 12"
echo
echo "Press Enter on an empty line when finished."
echo


while true; do

    read -r -p \
        "> " \
        LINE


    if [[ -z "$LINE" ]]; then

        break

    fi


    FIELD_COUNT="$(
        printf '%s\n' "$LINE" \
            | awk '{print NF}'
    )"


    if [[ "$FIELD_COUNT" -ne 2 ]]; then

        echo
        echo "Invalid format."
        echo

        continue

    fi


    CHAIN="$(
        printf '%s\n' "$LINE" \
            | awk '{print $1}'
    )"


    RESID="$(
        printf '%s\n' "$LINE" \
            | awk '{print $2}'
    )"


    if ! python3 - \
        "$RECEPTOR_INPUT" \
        "$CHAIN" \
        "$RESID" <<'PY'

from pathlib import Path
import sys


pdb = Path(
    sys.argv[1]
)

wanted_chain = sys.argv[2]
wanted_resid = sys.argv[3]


for line in pdb.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue


    chain = line[21:22].strip()

    if not chain:
        chain = "_"


    resid = line[22:26].strip()
    icode = line[26:27].strip()

    resid_full = (
        resid
        + icode
    )


    if (
        chain == wanted_chain
        and
        (
            resid == wanted_resid
            or
            resid_full == wanted_resid
        )
    ):

        raise SystemExit(
            0
        )


raise SystemExit(
    1
)

PY
    then

        echo
        echo "Residue not found:"
        echo
        echo "  $CHAIN $RESID"
        echo

        continue

    fi


    if grep -Fxq \
        "$CHAIN $RESID" \
        "$RESIDUE_FILE"
    then

        echo \
            "  Already selected: $CHAIN $RESID"

        continue

    fi


    echo \
        "$CHAIN $RESID" \
        >> "$RESIDUE_FILE"


    echo \
        "  Added: $CHAIN $RESID"

done


if [[ ! -s "$RESIDUE_FILE" ]]; then

    echo
    echo "ERROR: No residues were selected."
    echo

    exit 1

fi


echo
echo "Selected residues:"
echo

sed \
    's/^/  /' \
    "$RESIDUE_FILE"

echo


# ============================================================
# Build site reference PDB / MOL2
#
# sphere_selector needs a MOL2 reference structure.
# The coordinates are taken directly from target_input.pdb.
# ============================================================

python3 - \
    "$RECEPTOR_INPUT" \
    "$RESIDUE_FILE" \
    "$SITE_REF_PDB" \
    "$SITE_REF_MOL2" <<'PY'

from pathlib import Path
import sys
import re


pdb_file = Path(
    sys.argv[1]
)

selection_file = Path(
    sys.argv[2]
)

out_pdb = Path(
    sys.argv[3]
)

out_mol2 = Path(
    sys.argv[4]
)


selected = set()


for line in selection_file.read_text().splitlines():

    fields = line.split()

    if len(fields) == 2:

        selected.add(
            (
                fields[0],
                fields[1],
            )
        )


atoms = []


for line in pdb_file.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue


    chain = line[21:22].strip()

    if not chain:
        chain = "_"


    resid = line[22:26].strip()
    icode = line[26:27].strip()

    resid_full = (
        resid
        + icode
    )


    if (
        (chain, resid) not in selected
        and
        (chain, resid_full) not in selected
    ):

        continue


    atom_name = line[12:16].strip()


    try:

        x = float(
            line[30:38]
        )

        y = float(
            line[38:46]
        )

        z = float(
            line[46:54]
        )

    except ValueError:

        continue


    element = (
        line[76:78]
        .strip()
        .upper()
    )


    if not element:

        name = re.sub(
            r"[^A-Za-z]",
            "",
            atom_name,
        )


        element = (
            name[0].upper()
            if name
            else "C"
        )


    atoms.append(
        (
            line,
            atom_name,
            x,
            y,
            z,
            element,
        )
    )


if not atoms:

    raise SystemExit(
        "ERROR: No atoms were found for selected residues."
    )


with out_pdb.open(
    "w"
) as f:

    for atom in atoms:

        f.write(
            atom[0]
            + "\n"
        )


    f.write(
        "END\n"
    )


with out_mol2.open(
    "w"
) as f:

    f.write(
        "@<TRIPOS>MOLECULE\n"
    )

    f.write(
        "site_reference\n"
    )

    f.write(
        f"{len(atoms):6d}"
        f"{0:6d}"
        f"{1:6d}"
        f"{0:6d}"
        f"{0:6d}\n"
    )

    f.write(
        "SMALL\n"
    )

    f.write(
        "NO_CHARGES\n\n"
    )

    f.write(
        "@<TRIPOS>ATOM\n"
    )


    for i, atom in enumerate(
        atoms,
        1,
    ):

        _, name, x, y, z, element = atom


        f.write(
            f"{i:7d} "
            f"{name:<8s} "
            f"{x:10.4f} "
            f"{y:10.4f} "
            f"{z:10.4f} "
            f"{element:<6s} "
            f"{1:4d} "
            f"{'SITE':<8s} "
            f"{0.0:10.4f}\n"
        )


    f.write(
        "@<TRIPOS>SUBSTRUCTURE\n"
    )


    f.write(
        "     1 SITE        1 TEMP              "
        "0 ****  ****    0 ROOT\n"
    )


print(
    f"Reference atoms: {len(atoms)}"
)

PY


if [[ ! -s "$SITE_REF_MOL2" ]]; then

    echo
    echo "ERROR:"
    echo "site_reference.mol2 was not generated."
    echo

    exit 1

fi


# ============================================================
# Sphere selector radius
# ============================================================

echo
echo "============================================================"
echo " Sphere selection radius"
echo "============================================================"
echo


read -r -p \
    "Select spheres within radius [Å] ($DEFAULT_SELECTION_RADIUS): " \
    SELECTION_RADIUS


SELECTION_RADIUS="${SELECTION_RADIUS:-$DEFAULT_SELECTION_RADIUS}"


if ! python3 - \
    "$SELECTION_RADIUS" <<'PY'

import sys


try:

    value = float(
        sys.argv[1]
    )

except ValueError:

    raise SystemExit(
        1
    )


if value <= 0:

    raise SystemExit(
        1
    )

PY
then

    echo
    echo "ERROR: Radius must be a positive number."
    echo

    exit 1

fi


# ============================================================
# Run sphere_selector
# ============================================================

echo
echo "============================================================"
echo " Running sphere_selector"
echo "============================================================"
echo

echo "Radius:"
echo
echo "  $SELECTION_RADIUS Å"
echo


REC_SPH_ABS="$(
    realpath "$REC_SPH"
)"


SITE_REF_ABS="$(
    realpath "$SITE_REF_MOL2"
)"


(
    cd "$OUTDIR"

    rm -f \
        selected_spheres.sph

    sphere_selector \
        "$REC_SPH_ABS" \
        "$SITE_REF_ABS" \
        "$SELECTION_RADIUS"
)


if [[ ! -s "$OUTDIR/selected_spheres.sph" ]]; then

    echo
    echo "ERROR:"
    echo "sphere_selector did not generate selected_spheres.sph."
    echo

    exit 1

fi


mv \
    "$OUTDIR/selected_spheres.sph" \
    "$CANDIDATE_SPH"


# ============================================================
# Count selected candidate spheres
# ============================================================

CANDIDATE_COUNT="$(
python3 - "$CANDIDATE_SPH" <<'PY'

from pathlib import Path
import sys


count = 0


for line in Path(
    sys.argv[1]
).read_text().splitlines():

    fields = line.split()

    if len(fields) < 5:
        continue


    try:

        int(
            fields[0]
        )

        float(
            fields[1]
        )

        float(
            fields[2]
        )

        float(
            fields[3]
        )

        float(
            fields[4]
        )

    except ValueError:

        continue


    count += 1


print(
    count
)

PY
)"


if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then

    echo
    echo "ERROR:"
    echo "sphere_selector produced zero candidate spheres."
    echo

    exit 1

fi


# ============================================================
# Convert candidate spheres to PDB using SHOWSPHERE
# ============================================================

cat > "$OUTDIR/showsphere_candidate.in" <<'EOF'
candidate.sph
1
N
candidate_spheres.pdb
EOF


(
    cd "$OUTDIR"

    rm -f \
        candidate_spheres.pdb \
        showsphere_candidate.log

    showsphere \
        < showsphere_candidate.in \
        > showsphere_candidate.log \
        2>&1
)


if [[ ! -s "$CANDIDATE_PDB" ]]; then

    echo
    echo "ERROR:"
    echo "SHOWSPHERE did not generate:"
    echo
    echo "  $CANDIDATE_PDB"
    echo
    echo "Check:"
    echo
    echo "  $OUTDIR/showsphere_candidate.log"
    echo

    exit 1

fi


# ============================================================
# Create combined visualization PDB files
#
# 1) site_reference.pdb + candidate_spheres.pdb
# 2) original target_input.pdb + candidate_spheres.pdb
#
# Coordinates are not modified.
# ATOM/HETATM serial numbers are renumbered consecutively.
# END records from source files are removed and one END is
# written at the end of each combined PDB.
# ============================================================

python3 - \
    "$SITE_REF_PDB" \
    "$RECEPTOR_INPUT" \
    "$CANDIDATE_PDB" \
    "$SITE_REF_CANDIDATE_PDB" \
    "$TARGET_CANDIDATE_PDB" <<'PYCOMBINE'

from pathlib import Path
import sys


site_reference = Path(sys.argv[1])
target = Path(sys.argv[2])
candidate = Path(sys.argv[3])

out_site = Path(sys.argv[4])
out_target = Path(sys.argv[5])


def read_atoms(path):
    records = []

    for line in path.read_text().splitlines():

        if line.startswith("ATOM") or line.startswith("HETATM"):
            records.append(line)

    return records


def renumber_line(line, serial):
    # Preserve all columns except PDB atom serial field (columns 7-11).
    if len(line) < 11:
        line = line.ljust(11)

    return (
        line[:6]
        + f"{serial:5d}"
        + line[11:]
    )


def write_combined(base_file, sphere_file, output_file):
    base_records = read_atoms(base_file)
    sphere_records = read_atoms(sphere_file)

    if not base_records:
        raise RuntimeError(
            f"No ATOM/HETATM records found in {base_file}"
        )

    if not sphere_records:
        raise RuntimeError(
            f"No ATOM/HETATM records found in {sphere_file}"
        )

    serial = 1

    with output_file.open("w") as f:

        f.write(
            "REMARK   Combined visualization PDB\n"
        )

        f.write(
            f"REMARK   Structure: {base_file.name}\n"
        )

        f.write(
            f"REMARK   Candidate spheres: {sphere_file.name}\n"
        )

        f.write(
            "REMARK   Sphere coordinates are unchanged\n"
        )

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

        for line in sphere_records:
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
        len(sphere_records),
    )


site_atoms, site_spheres = write_combined(
    site_reference,
    candidate,
    out_site,
)

target_atoms, target_spheres = write_combined(
    target,
    candidate,
    out_target,
)


print(
    f"site_reference_with_candidates.pdb: "
    f"{site_atoms} reference atoms + "
    f"{site_spheres} spheres"
)

print(
    f"target_with_candidates.pdb: "
    f"{target_atoms} target atoms + "
    f"{target_spheres} spheres"
)

PYCOMBINE


for COMBINED_PDB in \
    "$SITE_REF_CANDIDATE_PDB" \
    "$TARGET_CANDIDATE_PDB"
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
# Summary
# ============================================================

{
    echo "============================================================"
    echo " DOCK6 sphere generation summary"
    echo "============================================================"
    echo

    echo "[Input]"
    echo "Receptor PDB           : $RECEPTOR_INPUT"
    echo "DMS source             : $DMS_SOURCE"
    echo

    echo "[Site]"
    echo "Site name              : $SITE_NAME"
    echo

    echo "[SPHGEN]"
    echo "INSPH maximum radius   : 4.0 A"
    echo "INSPH minimum radius   : 1.4 A"
    echo "SPHGEN spheres         : $SPHGEN_COUNT"
    echo

    echo "[Binding-site selection]"
    echo "Sphere selector radius : $SELECTION_RADIUS A"
    echo "Candidate spheres      : $CANDIDATE_COUNT"
    echo

    echo "[Files]"
    echo "DMS copy               : $REC_DMS"
    echo "INSPH                  : $INSPH"
    echo "All SPHGEN spheres     : $REC_SPH"
    echo "Selected residues      : $RESIDUE_FILE"
    echo "Reference PDB          : $SITE_REF_PDB"
    echo "Reference MOL2         : $SITE_REF_MOL2"
    echo "Candidate SPH          : $CANDIDATE_SPH"
    echo "Candidate PDB          : $CANDIDATE_PDB"
    echo "Reference + candidates : $SITE_REF_CANDIDATE_PDB"
    echo "Target + candidates    : $TARGET_CANDIDATE_PDB"

} > "$SUMMARY"


# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo " Sphere generation completed"
echo "============================================================"
echo

echo "Site:"
echo
echo "  $SITE_NAME"
echo

echo "SPHGEN spheres:"
echo
echo "  $SPHGEN_COUNT"
echo

echo "Candidate spheres:"
echo
echo "  $CANDIDATE_COUNT"
echo

echo "Candidate sphere file:"
echo
echo "  $CANDIDATE_SPH"
echo

echo "Visualization:"
echo
echo "  Candidate spheres only:"
echo "    $CANDIDATE_PDB"
echo
echo "  Selected residues + candidate spheres:"
echo "    $SITE_REF_CANDIDATE_PDB"
echo
echo "  Full target + candidate spheres:"
echo "    $TARGET_CANDIDATE_PDB"
echo

echo "Summary:"
echo
echo "  $SUMMARY"
echo

echo "Inspect candidate_spheres.pdb in Chimera."
echo
echo "Then run:"
echo
echo "  bash 02b_select_spheres.sh"
echo
